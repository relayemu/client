// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CustomCovers.swift
//  RelayUI
//
//  The player's own covers (cover-art spec §3) as the library model shows
//  them: a chosen cover wins over a downloaded or provider cover, which wins
//  over the placeholder. Choosing and resetting go through RelayLibrary's
//  CustomCoverEditor; the model only refreshes and reports success.

import Foundation
import RelayDomain
import RelayLibrary

public extension LibraryModel {
    func hasCustomCover(_ id: GameID) -> Bool { customCoverLocations[id] != nil }

    /// Makes image data the player chose (Photos) the game's cover. False when the image can't be used.
    @discardableResult
    func chooseCover(_ imageData: Data, for id: GameID) async -> Bool {
        guard let editor = customCoverEditor else { return false }
        return await applyCoverChange { _ = try await editor.choose(imageData, for: id) }
    }

    /// Makes an image file (Files, an open panel, a drop) the game's cover. False when it can't be used.
    @discardableResult
    func chooseCover(contentsOf url: URL, for id: GameID) async -> Bool {
        guard let editor = customCoverEditor else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return await applyCoverChange { _ = try await editor.choose(contentsOf: url, for: id) }
    }

    /// Back to the downloaded cover or the placeholder.
    func resetCover(_ id: GameID) async {
        guard let editor = customCoverEditor else { return }
        _ = await applyCoverChange { try await editor.reset(gameID: id) }
    }
}

extension LibraryModel {
    var customCoverEditor: CustomCoverEditor? {
        environment.store.map { CustomCoverEditor(store: $0, artworkStore: environment.artworkStore) }
    }

    private func applyCoverChange(_ change: () async throws -> Void) async -> Bool {
        do {
            try await change()
        } catch {
            return false
        }
        await refresh()
        return true
    }

    /// Chosen covers whose file is on this device, read once per refresh.
    func loadCustomCoverLocations(from store: any LibraryStore) async throws -> [GameID: ContentLocation] {
        var locations: [GameID: ContentLocation] = [:]
        for cover in try await store.games.customCovers() {
            if let location = environment.artworkStore.customCover(cover) { locations[cover.gameID] = location }
        }
        return locations
    }
}
