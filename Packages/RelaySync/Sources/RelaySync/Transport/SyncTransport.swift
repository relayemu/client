// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncTransport.swift
//  RelaySync
//
//  The boundary between Relay's semantic sync layer and whatever moves bytes:
//  CloudKit today (Packages/RelayCloudKit), an in-memory cloud in tests, a
//  shared directory in Debug walks. The transport knows nothing about games,
//  saves or the local database; the host (SyncCoordinator) knows nothing about
//  CKRecords.

import Foundation
import RelayDomain

public enum SyncReason: String, Sendable {
    /// A save, state or session was just written; upload it soon.
    case progressSaved
    /// The app became active or the user opened Home.
    case appActive
    /// Diagnostics ▸ Request Sync.
    case manual
    /// Enablement, account change accepted, reconciliation.
    case reconciliation
}

/// One pending upload or deletion built from journal intents.
public struct OutboundChange: Sendable {
    public enum Payload: Sendable {
        /// Save this record with these asset files (read by the transport during upload).
        case save(SyncRecord, assets: [SyncAssetName: URL])
        case delete
    }

    /// Journal entry ids this change carries (completed or failed together).
    public let journalIDs: [Int64]
    public let key: RecordKey
    public let payload: Payload

    public init(journalIDs: [Int64], key: RecordKey, payload: Payload) {
        self.journalIDs = journalIDs
        self.key = key
        self.payload = payload
    }
}

/// One bounded scan of a frozen journal round. Cursor advancement describes examined
/// journal rows, including rows that are in flight or cannot currently build a payload.
public struct HostedOutboundPage: Sendable {
    public let changes: [OutboundChange]
    public let nextAfterSequence: Int64
    public let throughSequence: Int64
    public let hasMore: Bool

    public init(changes: [OutboundChange], nextAfterSequence: Int64, throughSequence: Int64, hasMore: Bool) {
        self.changes = changes
        self.nextAfterSequence = nextAfterSequence
        self.throughSequence = throughSequence
        self.hasMore = hasMore
    }
}

/// One record received from the server. Asset URLs are temporary files the
/// transport owns until the host copied them into Relay-managed staging.
public struct InboundChange: Sendable {
    public let key: RecordKey
    public let record: SyncRecord
    public let assets: [SyncAssetName: URL]

    public init(key: RecordKey, record: SyncRecord, assets: [SyncAssetName: URL] = [:]) {
        self.key = key
        self.record = record
        self.assets = assets
    }
}

/// Stable classification of what went wrong; the UI and diagnostics use it, never raw errors.
public enum TransportProblem: Hashable, Sendable, CustomStringConvertible {
    case quotaFull
    case accountUnavailable
    case network
    case rateLimited(retryAfterSeconds: Int?)
    /// The server holds a different version; `SendResult` carries it when available.
    case serverRecordChanged
    case zoneMissing
    case unknownItem
    case limitExceeded
    case invalidRecord(String)
    case other(String)

    /// The engine or scheduler will retry these on its own; nothing to resolve.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .accountUnavailable, .limitExceeded, .quotaFull: return true
        case .serverRecordChanged, .zoneMissing, .unknownItem, .invalidRecord, .other: return false
        }
    }

    public var description: String {
        switch self {
        case .quotaFull: return "quotaFull"
        case .accountUnavailable: return "accountUnavailable"
        case .network: return "network"
        case .rateLimited(let s): return "rateLimited(\(s.map(String.init) ?? "-"))"
        case .serverRecordChanged: return "serverRecordChanged"
        case .zoneMissing: return "zoneMissing"
        case .unknownItem: return "unknownItem"
        case .limitExceeded: return "limitExceeded"
        case .invalidRecord(let s): return "invalidRecord(\(s))"
        case .other(let s): return "other(\(s))"
        }
    }
}

public struct SendResult: Sendable {
    public enum Outcome: Sendable {
        case saved
        case deleted
        case failed(TransportProblem, serverRecord: SyncRecord?)
    }

    public let key: RecordKey
    public let outcome: Outcome

    public init(key: RecordKey, outcome: Outcome) {
        self.key = key
        self.outcome = outcome
    }
}

public enum AccountAvailability: String, Sendable, Codable {
    case available, noAccount, restricted, temporarilyUnavailable, unknown
}

/// What the transport knows about the account. `identity` is an opaque hash
/// of the provider's user identifier (never an email or name).
public struct AccountChange: Sendable, Equatable {
    public let availability: AccountAvailability
    public let identity: String?

    public init(availability: AccountAvailability, identity: String?) {
        self.availability = availability
        self.identity = identity
    }
}

public struct TransportStatus: Sendable, Equatable {
    public var isSyncing: Bool
    /// A fetch (not a send) is running right now. Only this justifies the
    /// imperceptible launch grace; Relay never starts a fetch to launch a game.
    public var isFetching: Bool
    public var lastProblem: TransportProblem?
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    /// Transport-specific health line for diagnostics (English, technical).
    public var detail: String

    public init(isSyncing: Bool = false, isFetching: Bool = false, lastProblem: TransportProblem? = nil,
                lastPushAt: Date? = nil, lastPullAt: Date? = nil, detail: String = "") {
        self.isSyncing = isSyncing
        self.isFetching = isFetching
        self.lastProblem = lastProblem
        self.lastPushAt = lastPushAt
        self.lastPullAt = lastPullAt
        self.detail = detail
    }
}

/// Implemented by `SyncCoordinator`; called by transports.
public protocol SyncTransportHost: AnyObject, Sendable {
    /// Up to `limit` changes to send next; the transport reports each with `didSend`.
    func nextOutboundBatch(limit: Int) async -> [OutboundChange]
    /// Hosted transports persist the round cursor; legacy transports remain oldest-first.
    func nextHostedOutboundPage(afterSequence: Int64, throughSequence: Int64?, limit: Int) async throws -> HostedOutboundPage
    func didSend(_ results: [SendResult]) async
    /// Records fetched (saved or modified) and record keys deleted on the server.
    func didFetch(changes: [InboundChange], deletions: [RecordKey]) async
    /// Hosted pages are acknowledged only after records, deferred envelopes and
    /// the account-scoped checkpoint have committed in one local transaction.
    func applyHostedPage(changes: [InboundChange], deletions: [RecordKey], cursor: Int64, scope: String) async throws
    func hostedCursor(scope: String) async throws -> Int64
    /// Exact acknowledgement proof used to retire already accepted operation
    /// receipts. A persistence failure must propagate, never look like absence.
    func hostedPendingJournalIDs(in ids: [Int64]) async throws -> Set<Int64>
    func accountDidChange(_ change: AccountChange) async
    func transportDidUpdate(_ status: TransportStatus) async
    /// The server lost the Relay zone (user deleted iCloud data or a purge): the host re-journals everything.
    func zoneWasReset() async
}

public enum SyncPageError: Error, Sendable, Equatable {
    case unsupportedHost
    case inactiveProvider
    case invalidScope
    case rejectedRecords
}

public extension SyncTransportHost {
    func nextHostedOutboundPage(afterSequence: Int64, throughSequence: Int64?, limit: Int) async throws -> HostedOutboundPage {
        throw SyncPageError.unsupportedHost
    }

    func applyHostedPage(changes: [InboundChange], deletions: [RecordKey], cursor: Int64, scope: String) async throws {
        throw SyncPageError.unsupportedHost
    }

    func hostedCursor(scope: String) async throws -> Int64 {
        throw SyncPageError.unsupportedHost
    }

    func hostedPendingJournalIDs(in ids: [Int64]) async throws -> Set<Int64> {
        throw SyncPageError.unsupportedHost
    }
}

/// Implemented by RelayCloudKit's CKSyncEngine adapter, the in-memory cloud and the file transport.
public protocol SyncTransport: AnyObject, Sendable {
    func start(host: any SyncTransportHost) async throws
    func stop() async
    /// Discards transport state (change tokens, engine serialization). Used on account change.
    func resetState() async
    /// Ask for a send + fetch soon (the transport decides when).
    func requestSync(reason: SyncReason) async
    /// Fetch now, returning when the fetch completed or failed (bounded by the caller).
    func fetchNow() async throws

    // Heavy content (on demand; never part of automatic fetches).
    func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Nil when the record does not exist on the server.
    func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange?
    /// Releases a fetched temporary asset after the host copied or rejected it.
    func releaseContent(_ change: InboundChange) async
    /// Metadata only (no asset download); nil when absent.
    func contentExists(_ key: RecordKey) async throws -> Bool
    func deleteContent(_ key: RecordKey) async throws
    /// Whether custom covers (artwork) can be sent right now. While false, artwork
    /// intents stay journalled and are left out of outbound batches entirely.
    var sendsArtwork: Bool { get async }
}

public extension SyncTransport {
    func releaseContent(_ change: InboundChange) async {}
    var sendsArtwork: Bool { get async { false } }
}
