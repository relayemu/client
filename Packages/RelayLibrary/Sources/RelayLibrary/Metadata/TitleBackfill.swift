// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  TitleBackfill.swift
//  RelayLibrary
//
//  One pass that matches every local game against the metadata provider, so a
//  library imported before the title catalog (or before a catalog update)
//  gains real titles. Runs in the background, one game at a time, and holds
//  whenever the ActivityGate is paused (gameplay). Games without local content
//  are matched by their synced title (MetadataApplier).

import Foundation
import RelayDomain

/// Holds background library work while something latency-sensitive runs.
public actor ActivityGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func setPaused(_ value: Bool) {
        paused = value
        guard !value else { return }
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }

    public func waitWhilePaused() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

public struct TitleBackfill: Sendable {
    public struct Report: Equatable, Sendable {
        public var examined = 0, matched = 0, renamed = 0
        public init(examined: Int = 0, matched: Int = 0, renamed: Int = 0) {
            self.examined = examined; self.matched = matched; self.renamed = renamed
        }
    }

    private let applier: MetadataApplier
    private let store: any LibraryStore
    private let gate: ActivityGate?

    public init(applier: MetadataApplier, store: any LibraryStore, gate: ActivityGate? = nil) {
        self.applier = applier
        self.store = store
        self.gate = gate
    }

    /// Runs once per `revision` for the library whose marker file is `marker`.
    /// The marker is written only after a complete pass, so an interrupted pass
    /// reruns (cheaply: lookup digests are cached). Nil when already done.
    public func runOnce(revision: String, marker: URL) async -> Report? {
        if (try? String(contentsOf: marker, encoding: .utf8)) == revision { return nil }
        let report = await run()
        guard !Task.isCancelled else { return report }
        try? Data(revision.utf8).write(to: marker, options: .atomic)
        return report
    }

    public func run() async -> Report {
        var report = Report()
        for game in (try? await store.games.allGames()) ?? [] {
            if Task.isCancelled { break }
            await gate?.waitWhilePaused()
            report.examined += 1
            if case .matched(let renamed) = await applier.apply(to: game).outcome {
                report.matched += 1
                if renamed { report.renamed += 1 }
            }
        }
        return report
    }
}
