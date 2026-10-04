// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverDownloads.swift
//  RelayUI
//
//  Catalog cover downloads (cover-art spec §2) as the library model runs
//  them: the queue starts after the library opens, looks again after every
//  refresh (imports, synced games, the metadata backfill), retries after a
//  failure only when the app returns to the foreground, and is held during
//  gameplay by the environment's activity gate. Builds without a cover
//  origin never create it.

import Foundation
import RelayLibrary

/// The Download Covers preference, read by the background queue before every request.
final class CoverDownloadSetting: @unchecked Sendable {   // UserDefaults is thread-safe.
    static let key = "relay.covers.download"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

public extension LibraryModel {
    /// Whether this build can download covers at all (Settings shows the option only then).
    var canDownloadCovers: Bool { environment.coverSource != nil }

    func setDownloadCovers(_ on: Bool) {
        coverSetting.isOn = on
        downloadCovers = on
        if on { resumeCoverDownloads() }
    }

    /// Deletes every downloaded cover; provider artwork stays.
    func removeDownloadedCovers() async {
        await coverQueue?.removeDownloadedCovers()
    }

    /// The app is active again: a queue suspended by a network failure may retry.
    func resumeCoverDownloads() {
        guard let coverQueue else { return }
        Task { await coverQueue.foregroundDidResume() }
    }
}

extension LibraryModel {
    func startCoverDownloads() {
        guard coverQueue == nil, let store = environment.store, let source = environment.coverSource else { return }
        let applier = MetadataApplier(store: store, location: environment.location, provider: environment.metadataProvider,
                                      artworkStore: environment.artworkStore)
        let setting = coverSetting
        coverQueue = CoverQueue(store: store, artworkStore: environment.artworkStore, source: source, applier: applier,
                                gate: environment.backgroundActivity, isEnabled: { setting.isOn },
                                onChange: { [weak self] in await self?.refresh() })
        scheduleCoverDownloads()
    }

    func scheduleCoverDownloads() {
        guard let coverQueue else { return }
        Task { await coverQueue.schedule() }
    }
}
