// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncStatus.swift
//  RelaySync
//
//  a problem only while progress is at risk. Nothing here is a CloudKit type.

import Foundation
import RelayDomain

public enum SyncProblem: Hashable, Sendable {
    /// iCloud storage is full: local writes succeed, uploads wait.
    case quotaFull
    /// No account, restricted, or temporarily unavailable.
    case accountUnavailable
    /// Offline or transient server failures; the engine retries on its own.
    case network
    /// A record was refused or could not be applied; details in diagnostics.
    case failed(String)
}

public struct SyncStatus: Equatable, Sendable {
    public var provider: SyncProviderSelection = .iCloud
    /// Master switch (Settings ▸ iCloud ▸ Sync saves) as stored.
    public var isEnabled: Bool = true
    /// Effective game-file sync switch (transport support + stored Free opt-in).
    public var gameFilesEnabled: Bool = false
    public var gameFilesAllowed: Bool = false
    public var account: AccountAvailability = .unknown
    /// A transport is attached and running.
    public var isActive: Bool = false
    public var isSyncing: Bool = false
    /// A fetch is in flight (the only case where Continue may pause imperceptibly).
    public var isFetching: Bool = false
    /// Remote changes are being applied (Home may show "Updating…" briefly).
    public var isApplying: Bool = false
    public var pendingCount: Int = 0
    /// When the oldest pending intent was created (drives the "pending too long" card).
    public var pendingSince: Date?
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    public var problem: SyncProblem?
    public var problemSince: Date?
    /// Games with unresolved battery conflicts ("Two versions").
    public var conflictGameIDs: [GameID] = []
    /// A different iCloud account is signed in than the one this library synced with.
    public var accountChangePending: Bool = false
    /// Games whose content is in iCloud but not on this device.
    public var cloudOnlyCount: Int = 0
    /// Approximate bytes of Relay content this device knows to be in iCloud (content descriptors + local uploads).
    public var approximateCloudBytes: Int64 = 0
    /// Transport health line for diagnostics.
    public var transportDetail: String = ""
    /// Last apply/validation problem classification (diagnostics).
    public var lastErrorCategory: String?
    /// The most recent send/apply problems, as "<record type>:<classification>".
    /// Bounded and payload-free; Settings ▸ Diagnostics shows them verbatim.
    public var recentProblems: [String] = []

    public init() {}

    /// Sync is on, an account is available and no account decision is pending.
    public var isOperational: Bool { isEnabled && account == .available && !accountChangePending && isActive }
}

/// Per-game cloud status for status lines and badges (CONTINUITY_UX.md §4).
public enum GameCloudStatus: Equatable, Sendable {
    /// Sync is off, or nothing about this game has ever synced.
    case localOnly
    /// Everything about this game has been acknowledged by the server.
    case upToDate
    /// Something about this game waits for upload (`since` is the oldest intent).
    case pending(since: Date)
    /// Content is in iCloud but not on this device.
    case cloudOnly(size: Int64)
    case downloading(progress: Double)
    /// Progress exists (sessions/saves) but the file is on no reachable source.
    case onAnotherDevice
    /// Two battery versions exist.
    case conflict
    /// The last transfer for this game failed (download verification, upload refused).
    case failed(SyncProblem)
}

/// Content download/upload progress the UI can show on a card.
public struct ContentTransfer: Equatable, Sendable {
    public enum Direction: Sendable { case download, upload }
    public let gameID: GameID
    public let direction: Direction
    public var progress: Double

    public init(gameID: GameID, direction: Direction, progress: Double) {
        self.gameID = gameID
        self.direction = direction
        self.progress = progress
    }
}
