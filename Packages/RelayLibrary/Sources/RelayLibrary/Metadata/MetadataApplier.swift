// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MetadataApplier.swift
//  RelayLibrary
//
//  Matches one local game against a metadata provider and applies the answer.
//  Import and the catalog backfill share these rules: lookup digests are read
//  from the stored file only for a provider that uses them, once per content,
//  and cached; metadata written by a different provider is never replaced; the
//  title changes only while it is still the name Relay derived from the
//  imported file. A game without local content is matched by its synced
//  title instead. Never throws: a game plays with or without metadata.

import Foundation
import RelayDomain

public struct MetadataApplier: Sendable {
    public enum Outcome: Equatable, Sendable { case skipped, unmatched, matched(renamed: Bool) }
    public struct Result: Sendable { public let game: Game; public let outcome: Outcome }

    private let store: any LibraryStore
    private let location: LibraryLocation
    private let provider: any MetadataProvider
    private let artworkStore: ArtworkStore
    private let clock: @Sendable () -> Date

    public init(store: any LibraryStore, location: LibraryLocation, provider: any MetadataProvider,
                artworkStore: ArtworkStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.location = location
        self.provider = provider
        self.artworkStore = artworkStore
        self.clock = clock
    }

    public func apply(to game: Game) async -> Result {
        guard let files = try? await store.games.files(for: game.id) else { return Result(game: game, outcome: .skipped) }
        guard let primary = files.first(where: { $0.role == .primary }) else { return await applyByTitle(to: game) }
        let url = location.url(for: primary.location)
        guard FileManager.default.fileExists(atPath: url.path) else { return Result(game: game, outcome: .skipped) }
        let request = MetadataRequest(fingerprint: game.contentFingerprint, systemID: game.systemID,
                                      fileName: primary.originalFileName, sizeInBytes: primary.sizeInBytes,
                                      lookupDigests: provider.usesLookupDigests ? await digests(for: game, at: url) : nil)
        guard let candidate = (try? await provider.match(request))?.first else { return Result(game: game, outcome: .unmatched) }
        switch await record(candidate, for: game) {
        case .otherProvider: return Result(game: game, outcome: .skipped)
        case .failed: return Result(game: game, outcome: .unmatched)
        case .recorded: break
        }
        // Rename from the stored entry, not the caller's snapshot (the backfill's can
        // be minutes old), so a favourite or rename made meanwhile is never reverted.
        let current = (try? await store.games.game(id: game.id)).flatMap { $0 } ?? game
        guard current.title == GameImporter.displayTitle(fileName: primary.originalFileName), current.title != candidate.title else {
            return Result(game: current, outcome: .matched(renamed: false))
        }
        // `updatedAt` deliberately keeps its value: a catalog title is a default, so a
        // player's rename on any device (stamped now) wins last-write-wins sync.
        var renamed = current
        renamed.title = candidate.title
        guard (try? await store.games.update(renamed)) != nil else { return Result(game: current, outcome: .matched(renamed: false)) }
        return Result(game: renamed, outcome: .matched(renamed: true))
    }

    /// A game whose content is not on this device (Apple TV, a removed download)
    /// is matched by the title it synced with. That title came from another
    /// device, so it is never changed here, and only a game without metadata is
    /// matched: an exact match made while the file was here is better.
    private func applyByTitle(to game: Game) async -> Result {
        let existing = try? await store.games.metadata(for: game.id)
        guard existing == nil else { return Result(game: game, outcome: .skipped) }
        let request = MetadataRequest(fingerprint: game.contentFingerprint, systemID: game.systemID,
                                      fileName: "", sizeInBytes: 0, title: game.title)
        guard let candidate = (try? await provider.match(request))?.first else { return Result(game: game, outcome: .unmatched) }
        switch await record(candidate, for: game) {
        case .otherProvider: return Result(game: game, outcome: .skipped)
        case .failed: return Result(game: game, outcome: .unmatched)
        case .recorded: return Result(game: game, outcome: .matched(renamed: false))
        }
    }

    private enum Recorded { case recorded, otherProvider, failed }

    /// Writes a candidate's metadata, keeping the stored artwork, unless another provider owns the record.
    private func record(_ candidate: MetadataCandidate, for game: Game) async -> Recorded {
        let source = candidate.source ?? provider.id
        let existing = try? await store.games.metadata(for: game.id)
        if let existing, existing.source != source { return .otherProvider }
        var artworkLocation = existing?.artworkLocation
        if let artwork = candidate.artwork, let stored = try? artworkStore.storeArtwork(artwork, for: game.id) { artworkLocation = stored }
        let metadata = GameMetadata(gameID: game.id, alternateTitles: candidate.alternateTitles, developer: candidate.developer,
                                    publisher: candidate.publisher, releaseYear: candidate.releaseYear, genre: candidate.genre,
                                    region: candidate.region, summary: candidate.summary, artworkLocation: artworkLocation,
                                    coverKey: candidate.coverKey, source: source, matchedAt: clock())
        return (try? await store.games.upsertMetadata(metadata)) != nil ? .recorded : .failed
    }

    private func digests(for game: Game, at url: URL) async -> LookupDigests? {
        if let cached = try? await store.games.lookupDigests(for: game.contentFingerprint) { return cached }
        guard let computed = try? await LookupDigester.digests(forFileAt: url, systemID: game.systemID) else { return nil }
        try? await store.games.setLookupDigests(computed, for: game.contentFingerprint)
        return computed
    }
}
