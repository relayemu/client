// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverQueue.swift
//  RelayLibrary
//
//  Downloads catalog covers in the background. One pass at a time walks the
//  library: a game without content on this device is first matched by its
//  synced title, then every game with a cover key and no other artwork gets
//  its cover, a few requests at a time, held while a game is playing. A
//  missing or unusable cover is not asked for again for 30 days; a network
//  or server failure suspends the queue until the app returns to the
//  foreground. Nothing is requested while downloading is off. Never on the
//  launch path, and never replaces artwork that is not a downloaded cover.

import Foundation
import RelayDomain

public actor CoverQueue {
    public struct Report: Equatable, Sendable {
        public var stored = 0, reused = 0, missing = 0, matched = 0
        public var suspended = false
        public init() {}
        /// Whether anything the library shows changed.
        public var changed: Bool { stored + reused + matched > 0 }
    }

    /// How long a missing or unusable cover is left alone.
    public static let missRetention: TimeInterval = 30 * 86_400
    /// Covers stored between two library refreshes during a long pass.
    static let refreshBatch = 12

    private let store: any LibraryStore
    private let artworkStore: ArtworkStore
    private let source: any CoverArtSource
    private let applier: MetadataApplier?
    private let gate: ActivityGate?
    private let isEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let concurrency: Int
    private let onChange: @Sendable () async -> Void

    private var suspended = false
    private var running: Task<Void, Never>?
    private var rerun = false

    public init(store: any LibraryStore, artworkStore: ArtworkStore, source: any CoverArtSource,
                applier: MetadataApplier?, gate: ActivityGate?, isEnabled: @escaping @Sendable () -> Bool,
                clock: @escaping @Sendable () -> Date = { Date() }, concurrency: Int = 4,
                onChange: @escaping @Sendable () async -> Void) {
        self.store = store
        self.artworkStore = artworkStore
        self.source = source
        self.applier = applier
        self.gate = gate
        self.isEnabled = isEnabled
        self.clock = clock
        self.concurrency = max(1, concurrency)
        self.onChange = onChange
    }

    /// Starts a background pass, or asks the running one to go again when it ends.
    public func schedule() {
        guard running == nil else { rerun = true; return }
        running = Task(priority: .utility) { await self.drain() }
    }

    /// The app is in the foreground again: a suspended queue may try again.
    public func foregroundDidResume() {
        suspended = false
        schedule()
    }

    public func waitUntilIdle() async {
        while let task = running { await task.value }
    }

    private func drain() async {
        repeat {
            rerun = false
            let report = await runPass()
            if report.changed { await onChange() }
        } while rerun && !Task.isCancelled
        running = nil
    }

    /// One pass over the library; `schedule()` is the normal entry point.
    public func runPass() async -> Report {
        var report = Report()
        guard !suspended, isEnabled(), let games = try? await store.games.allGames(), !games.isEmpty else { return report }
        var next = 0
        var storedSinceRefresh = 0
        await withTaskGroup(of: Outcome.self) { group in
            while next < min(concurrency, games.count) {
                let game = games[next]
                group.addTask { await self.process(game) }
                next += 1
            }
            for await outcome in group {
                if outcome.matched { report.matched += 1 }
                switch outcome.cover {
                case .none: break
                case .reused: report.reused += 1
                case .stored: report.stored += 1; storedSinceRefresh += 1
                case .missing: report.missing += 1
                case .unavailable: report.suspended = true
                }
                if storedSinceRefresh >= Self.refreshBatch {
                    storedSinceRefresh = 0
                    await onChange()
                }
                guard !report.suspended, next < games.count, isEnabled() else { continue }
                let game = games[next]
                group.addTask { await self.process(game) }
                next += 1
            }
        }
        if report.suspended { suspended = true }
        return report
    }

    /// Deletes every downloaded cover and the references to them; other artwork stays.
    public func removeDownloadedCovers() async {
        guard let games = try? await store.games.allGames() else { return }
        var changed = false
        for game in games {
            artworkStore.removeCatalogCover(for: game.id)
            guard let metadata = try? await store.games.metadata(for: game.id), let artwork = metadata.artworkLocation,
                  LibraryLocation.isCatalogCover(artwork) else { continue }
            try? await store.games.setArtworkLocation(nil, for: game.id)
            changed = true
        }
        if changed { await onChange() }
    }

    // MARK: One game

    private struct Outcome: Sendable {
        enum Cover: Sendable { case none, reused, stored, missing, unavailable }
        var matched = false
        var cover: Cover = .none
    }

    private nonisolated func process(_ game: Game) async -> Outcome {
        await gate?.waitWhilePaused()
        var outcome = Outcome()
        guard isEnabled() else { return outcome }
        var metadata = try? await store.games.metadata(for: game.id)
        if metadata == nil, let applier, let files = try? await store.games.files(for: game.id), !files.contains(where: { $0.role == .primary }) {
            guard case .matched = await applier.apply(to: game).outcome else { return outcome }
            outcome.matched = true
            metadata = try? await store.games.metadata(for: game.id)
        }
        guard let metadata, let key = metadata.coverKey, CoverKey.isValid(key) else { return outcome }
        if let artwork = metadata.artworkLocation, !LibraryLocation.isCatalogCover(artwork) { return outcome }
        if let existing = artworkStore.catalogCover(for: game.id) {
            guard metadata.artworkLocation != existing, (try? await store.games.setArtworkLocation(existing, for: game.id)) != nil else { return outcome }
            outcome.cover = .reused
            return outcome
        }
        if let missed = try? await store.games.coverMissedAt(key: key), clock().timeIntervalSince(missed) < Self.missRetention {
            return outcome
        }
        guard isEnabled() else { return outcome }
        switch await source.cover(forKey: key) {
        case .image(let data):
            guard let format = CoverImage.validate(data) else {
                outcome.cover = await recordMiss(key)
                return outcome
            }
            guard isEnabled(), let stored = try? artworkStore.storeCatalogCover(data, format: format, for: game.id),
                  (try? await store.games.setArtworkLocation(stored, for: game.id)) != nil else { return outcome }
            outcome.cover = .stored
        case .notFound, .invalid:
            outcome.cover = await recordMiss(key)
        case .unavailable:
            outcome.cover = .unavailable
        }
        return outcome
    }

    private nonisolated func recordMiss(_ key: String) async -> Outcome.Cover {
        try? await store.games.recordCoverMiss(key: key, at: clock())
        return .missing
    }
}
