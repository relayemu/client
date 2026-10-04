// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  InMemoryCloud.swift
//  RelaySync
//
//  A deterministic stand-in for the CloudKit private database: records with
//  versions, `serverRecordChanged` on stale saves, a change log with cursors,
//  and failure injection (quota, offline, duplicate and out-of-order
//  delivery, account identity). Transports connected to it move nothing
//  until `pump()` is called, so tests never wait on timers.

import Foundation
import RelayDomain

public actor InMemoryCloud {
    public struct Stored: Sendable {
        public var record: SyncRecord
        public var assets: [SyncAssetName: Data]
        public var version: Int
    }

    struct Change: Sendable {
        let sequence: Int
        let key: RecordKey
        let deleted: Bool
    }

    private(set) public var records: [RecordKey: Stored] = [:]
    private var log: [Change] = []
    private var nextSequence = 1
    private var quotaFull = false
    private var offline: Set<String> = []
    private(set) public var accountIdentity = "account-a"
    private var duplicateNext: Set<String> = []
    private var reorderNext: Set<String> = []
    public var saveCount = 0
    /// Heavy content uploads only.
    public var contentUploadCount = 0

    public init() {}

    // MARK: Failure injection

    public func setQuotaFull(_ full: Bool) { quotaFull = full }
    public func setOffline(_ device: String, _ isOffline: Bool) { if isOffline { offline.insert(device) } else { offline.remove(device) } }
    public func setAccountIdentity(_ identity: String) { accountIdentity = identity }
    public func duplicateNextDelivery(for device: String) { duplicateNext.insert(device) }
    public func reorderNextDelivery(for device: String) { reorderNext.insert(device) }

    public func record(_ key: RecordKey) -> Stored? { records[key] }
    public func recordCount(ofType type: SyncRecordType) -> Int { records.keys.filter { $0.type == type }.count }
    public func clear() { records.removeAll(); log.removeAll(); nextSequence = 1 }

    // MARK: Server operations

    /// Like CloudKit: a save succeeds only when the client's base version is the
    /// server's current version (a change tag); otherwise the server reports its
    /// record and the client must merge and save again on top of it.
    func save(_ change: OutboundChange, assetData: [SyncAssetName: Data], baseVersion: Int?, device: String) -> (SendResult, serverVersion: Int?) {
        if offline.contains(device) { return (SendResult(key: change.key, outcome: .failed(.network, serverRecord: nil)), nil) }
        switch change.payload {
        case .save(let record, _):
            if quotaFull { return (SendResult(key: change.key, outcome: .failed(.quotaFull, serverRecord: nil)), nil) }
            if let existing = records[change.key] {
                guard baseVersion == existing.version else {
                    return (SendResult(key: change.key, outcome: .failed(.serverRecordChanged, serverRecord: existing.record)), existing.version)
                }
                if existing.record == record, existing.assets == assetData {
                    return (SendResult(key: change.key, outcome: .saved), existing.version)
                }
                let version = existing.version + 1
                records[change.key] = Stored(record: record, assets: assetData, version: version)
                log.append(Change(sequence: nextSequence, key: change.key, deleted: false)); nextSequence += 1
                saveCount += 1
                return (SendResult(key: change.key, outcome: .saved), version)
            }
            records[change.key] = Stored(record: record, assets: assetData, version: 1)
            log.append(Change(sequence: nextSequence, key: change.key, deleted: false)); nextSequence += 1
            saveCount += 1
            return (SendResult(key: change.key, outcome: .saved), 1)
        case .delete:
            guard records[change.key] != nil else { return (SendResult(key: change.key, outcome: .failed(.unknownItem, serverRecord: nil)), nil) }
            records[change.key] = nil
            log.append(Change(sequence: nextSequence, key: change.key, deleted: true)); nextSequence += 1
            return (SendResult(key: change.key, outcome: .deleted), nil)
        }
    }

    /// Overwrites a record server-side (simulates another client or a merge accepted by the server).
    public func overwrite(_ key: RecordKey, record: SyncRecord, assets: [SyncAssetName: Data] = [:]) {
        let version = (records[key]?.version ?? 0) + 1
        records[key] = Stored(record: record, assets: assets, version: version)
        log.append(Change(sequence: nextSequence, key: key, deleted: false)); nextSequence += 1
    }

    public func delete(_ key: RecordKey) {
        records[key] = nil
        log.append(Change(sequence: nextSequence, key: key, deleted: true)); nextSequence += 1
    }

    func changes(since cursor: Int, device: String, zones: Set<SyncZone>) -> (changes: [(RecordKey, Stored?)], cursor: Int)? {
        if offline.contains(device) { return nil }
        var result: [(RecordKey, Stored?)] = []
        var newCursor = cursor
        for change in log where change.sequence > cursor && zones.contains(change.key.zone) {
            result.append((change.key, change.deleted ? nil : records[change.key]))
            newCursor = change.sequence
        }
        // Keep only the latest entry per key (like a change token fetch).
        var seen: Set<RecordKey> = []
        var deduplicated: [(RecordKey, Stored?)] = []
        for item in result.reversed() where !seen.contains(item.0) { seen.insert(item.0); deduplicated.append(item) }
        deduplicated.reverse()
        if reorderNext.remove(device) != nil { deduplicated.reverse() }
        if duplicateNext.remove(device) != nil { deduplicated += deduplicated }
        return (deduplicated, max(newCursor, cursor))
    }

    func contentRecord(_ key: RecordKey, device: String) throws -> Stored? {
        if offline.contains(device) { throw SyncTransportError.offline }
        return records[key]
    }

    func upload(_ record: SyncRecord, data: Data, device: String) throws {
        if offline.contains(device) { throw SyncTransportError.offline }
        if quotaFull { throw SyncTransportError.quotaFull }
        let key = record.key
        if let existing = records[key], existing.assets[.data] != data { throw SyncTransportError.serverRecordChanged }
        records[key] = Stored(record: record, assets: [.data: data], version: 1)
        saveCount += 1
        contentUploadCount += 1
    }

    func deleteContent(_ key: RecordKey, device: String) throws {
        if offline.contains(device) { throw SyncTransportError.offline }
        records[key] = nil
    }
}

public enum SyncTransportError: Error, Equatable, Sendable {
    case offline
    case quotaFull
    case serverRecordChanged
    case notStarted
}

/// One device's connection to the in-memory cloud. Deterministic: nothing
/// happens until `pump()`; `requestSync` only records that a pump is wanted.
public final class InMemoryCloudTransport: SyncTransport, @unchecked Sendable {
    /// A test cloud stores any record type, custom covers included.
    public var sendsArtwork: Bool { true }
    public let device: String
    private let cloud: InMemoryCloud
    private let lock = NSLock()
    private var host: (any SyncTransportHost)?
    private var cursor = 0
    private var running = false
    /// The server version this device last saw per key (what CloudKit keeps as a record change tag).
    private var knownVersions: [RecordKey: Int] = [:]
    private(set) public var syncRequests: [SyncReason] = []
    /// How many fetches this device performed (tests assert that launching never fetches).
    private(set) public var fetchCount = 0
    private let temp: URL
    /// Simulates a crash between "server acknowledged" and "host told": the next send's results are dropped.
    public var dropNextSendResults = false
    /// Simulates a crash after the host applied a fetch but before the cursor advanced: the next fetch is replayed.
    public var replayNextFetch = false

    init(device: String, cloud: InMemoryCloud) {
        self.device = device
        self.cloud = cloud
        temp = FileManager.default.temporaryDirectory.appending(path: "RelayInMemoryCloud-\(device)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temp) }

    public func start(host: any SyncTransportHost) async throws {
        lock.lock(); self.host = host; running = true; lock.unlock()
        await host.accountDidChange(AccountChange(availability: .available, identity: await cloud.accountIdentity))
    }

    public func stop() async { lock.lock(); running = false; lock.unlock() }

    public func resetState() async { lock.lock(); cursor = 0; knownVersions.removeAll(); lock.unlock() }

    public func requestSync(reason: SyncReason) async { lock.lock(); syncRequests.append(reason); lock.unlock() }

    public func fetchNow() async throws { try await fetch() }

    /// Sends every pending batch, then fetches. Returns the number of changes sent.
    @discardableResult
    public func pump(maxBatches: Int = 10) async throws -> Int {
        lock.lock(); let host = self.host; let running = self.running; lock.unlock()
        guard let host, running else { throw SyncTransportError.notStarted }
        var sent = 0
        for _ in 0..<maxBatches {
            let batch = await host.nextOutboundBatch(limit: 20)
            if batch.isEmpty { break }
            var results: [SendResult] = []
            for change in batch {
                var assets: [SyncAssetName: Data] = [:]
                if case .save(_, let urls) = change.payload {
                    for (name, url) in urls { if let data = try? Data(contentsOf: url) { assets[name] = data } }
                }
                lock.lock(); let base = knownVersions[change.key]; lock.unlock()
                let (result, serverVersion) = await cloud.save(change, assetData: assets, baseVersion: base, device: device)
                lock.lock()
                if case .deleted = result.outcome { knownVersions[change.key] = nil } else if let serverVersion { knownVersions[change.key] = serverVersion }
                lock.unlock()
                results.append(result)
            }
            sent += batch.count
            lock.lock(); let drop = dropNextSendResults; dropNextSendResults = false; lock.unlock()
            if drop { continue }
            await host.didSend(results)
        }
        try await fetch()
        return sent
    }

    private func fetch() async throws {
        lock.lock(); let host = self.host; let running = self.running; let since = cursor; let replay = replayNextFetch; replayNextFetch = false; fetchCount += 1; lock.unlock()
        guard let host, running else { throw SyncTransportError.notStarted }
        guard let (items, newCursor) = await cloud.changes(since: since, device: device, zones: [.sync]) else {
            await host.transportDidUpdate(TransportStatus(isSyncing: false, lastProblem: .network, detail: "offline"))
            throw SyncTransportError.offline
        }
        var changes: [InboundChange] = []
        var deletions: [RecordKey] = []
        for (key, stored) in items {
            lock.lock(); knownVersions[key] = stored?.version; lock.unlock()
            guard let stored else { deletions.append(key); continue }
            var urls: [SyncAssetName: URL] = [:]
            for (name, data) in stored.assets {
                let url = temp.appending(path: "\(UUID().uuidString)-\(name.rawValue)")
                try data.write(to: url)
                urls[name] = url
            }
            changes.append(InboundChange(key: key, record: stored.record, assets: urls))
        }
        await host.didFetch(changes: changes, deletions: deletions)
        lock.lock(); if !replay { cursor = newCursor }; lock.unlock()
        await host.transportDidUpdate(TransportStatus(isSyncing: false, lastProblem: nil, detail: "in-memory cursor \(newCursor)"))
    }

    // MARK: Content

    public func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let data = try Data(contentsOf: fileURL)
        progress(0.5)
        try await cloud.upload(record, data: data, device: device)
        progress(1)
    }

    public func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? {
        guard let stored = try await cloud.contentRecord(key, device: device) else { return nil }
        var urls: [SyncAssetName: URL] = [:]
        for (name, data) in stored.assets {
            let url = temp.appending(path: "\(UUID().uuidString)-\(name.rawValue)")
            try data.write(to: url)
            urls[name] = url
        }
        progress(1)
        return InboundChange(key: key, record: stored.record, assets: urls)
    }

    public func contentExists(_ key: RecordKey) async throws -> Bool {
        try await cloud.contentRecord(key, device: device) != nil
    }

    public func deleteContent(_ key: RecordKey) async throws {
        try await cloud.deleteContent(key, device: device)
    }
}

public extension InMemoryCloud {
    /// A transport for one simulated device.
    nonisolated func connect(device: String) -> InMemoryCloudTransport {
        InMemoryCloudTransport(device: device, cloud: self)
    }
}
