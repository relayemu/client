// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CloudKitSyncTransport.swift
//  RelayCloudKit
//
//
//    - one CKSyncEngine on the user's PRIVATE database for the lightweight zone
//      `RelaySync`; its serialized state lives in a Relay-owned file and is
//      transport state, never domain state;
//    - the heavy zone `RelayContent` is never fetched automatically
//      (`nextFetchChangesOptions` excludes it) and is served by direct
//      operations on demand;
//    - outbound changes come from the host's journal through
//      `hasPendingUntrackedChanges` + `nextRecordZoneChangeBatch`, so the
//      engine never owns Relay's outbox;
//    - inbound records are decoded by `RecordCodec` and handed to the host
//      with CloudKit's temporary asset URLs; the host copies and verifies;
//    - account status and changes are observed and reported as an opaque hash;
//    - custom covers (`RelayArtwork`) are sent until the server refuses the type
//      (not yet promoted to Production), then wait for the next session, and one
//      bounded query recovers covers an older build skipped while fetching.
//
//  CKSyncEngine owns retry scheduling; this class never adds a second loop.

import CloudKit
import CryptoKit
import Foundation
import OSLog
import RelayDomain
import RelayLibrary
import RelaySync

let cloudKitLog = Logger(subsystem: "app.relayemu.relay", category: "cloudkit")
let cloudAssetLog = Logger(subsystem: "app.relayemu.relay", category: "cloudasset")

public final class CloudKitSyncTransport: NSObject, SyncTransport, CKSyncEngineDelegate, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var containerIdentifier: String
        /// Where the engine's serialized state is kept (`Library/Sync/cksyncengine-state.json`).
        public var stateFileURL: URL
        /// Where inbound assets are copied out of CloudKit's temporary location before the host sees them.
        public var scratchDirectory: URL
        public var automaticallySync: Bool
        public var subscriptionID: String
        public var syncZoneName: String
        public var contentZoneName: String

        public init(containerIdentifier: String, stateFileURL: URL, scratchDirectory: URL,
                    automaticallySync: Bool = true, subscriptionID: String = "relay-sync-engine",
                    syncZoneName: String = CloudKitSyncTransport.syncZoneName,
                    contentZoneName: String = CloudKitSyncTransport.contentZoneName) {
            self.containerIdentifier = containerIdentifier
            self.stateFileURL = stateFileURL
            self.scratchDirectory = scratchDirectory
            self.automaticallySync = automaticallySync
            self.subscriptionID = subscriptionID
            self.syncZoneName = syncZoneName
            self.contentZoneName = contentZoneName
        }
    }

    public static let syncZoneName = "RelaySync"
    public static let contentZoneName = "RelayContent"

    private let configuration: Configuration
    // Defer CloudKit initialization until an active operation needs it. Constructing
    // a disabled transport must not require an iCloud-entitled process or account.
    private var cloudContainer: CKContainer?
    private var container: CKContainer {
        lock.withLock {
            if let cloudContainer { return cloudContainer }
            let container = CKContainer(identifier: configuration.containerIdentifier)
            cloudContainer = container
            return container
        }
    }
    private var database: CKDatabase { container.privateCloudDatabase }
    private let codec = RecordCodec()
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var host: (any SyncTransportHost)?
    private var accountObserver: NSObjectProtocol?
    /// The latest server records seen for mutable types (change tags for the next save).
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    /// Outbound changes handed to the engine, by record id, until they are reported sent.
    private var inFlight: [CKRecord.ID: OutboundChange] = [:]
    private var status = TransportStatus()
    private var contentZoneReady = false
    /// Guards against overlapping manual sends/fetches, which CloudKit treats as fatal.
    private var immediateSyncRunning = false
    /// Binds every callback and direct asset operation to one transport lifetime.
    private var generation: UInt64 = 0
    private var contentOperations: [ObjectIdentifier: CKDatabaseOperation] = [:]
    /// Set when the server refused a RelayArtwork save this session; covers then wait in the journal.
    private var artworkRefused = false

    public let syncZoneID: CKRecordZone.ID
    public let contentZoneID: CKRecordZone.ID

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.syncZoneID = CKRecordZone.ID(zoneName: configuration.syncZoneName, ownerName: CKCurrentUserDefaultName)
        self.contentZoneID = CKRecordZone.ID(zoneName: configuration.contentZoneName, ownerName: CKCurrentUserDefaultName)
        super.init()
    }

    // MARK: SyncTransport

    public func start(host: any SyncTransportHost) async throws {
        let generation = lock.withLock {
            self.generation &+= 1
            self.host = host
            self.artworkRefused = false
            return self.generation
        }
        try FileManager.default.createDirectory(at: configuration.scratchDirectory, withIntermediateDirectories: true)
        await reportAccount(host: host, generation: generation)
        // The account callback can stop us while asking the owner to accept a new account.
        guard isCurrent(generation: generation) else { throw CancellationError() }
        let savedState = loadState()
        var engineConfiguration = CKSyncEngine.Configuration(database: database, stateSerialization: savedState, delegate: self)
        engineConfiguration.automaticallySync = configuration.automaticallySync
        engineConfiguration.subscriptionID = configuration.subscriptionID
        let engine = CKSyncEngine(engineConfiguration)
        let installed = lock.withLock {
            guard self.generation == generation else { return false }
            self.engine = engine
            return true
        }
        guard installed else { await engine.cancelOperations(); throw CancellationError() }
        observeAccountChanges(generation: generation)
        // Idempotent: the engine ignores a zone that already exists.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: syncZoneID))])
        cloudKitLog.notice("engine started for \(self.configuration.containerIdentifier, privacy: .public)")
        let markerExists = FileManager.default.fileExists(atPath: artworkCatchUpMarker.path)
        if Self.needsArtworkCatchUp(markerExists: markerExists, hadEngineState: savedState != nil) {
            Task { await self.catchUpArtwork(generation: generation) }
        } else if !markerExists {
            markArtworkCaughtUp()   // A fresh engine fetches every record, covers included.
        }
    }

    /// Custom covers travel until the server refuses their type this session.
    public var sendsArtwork: Bool {
        get async { lock.withLock { !artworkRefused } }
    }

    // MARK: Artwork catch-up

    /// An engine whose state predates artwork fetched past any RelayArtwork record it could not
    /// decode then; only such an engine needs the catch-up, once.
    static func needsArtworkCatchUp(markerExists: Bool, hadEngineState: Bool) -> Bool { !markerExists && hadEngineState }

    /// A RelayArtwork save the server refuses as a record (the type is absent from the
    /// environment's schema, or an argument it rejects) turns covers off for the session.
    static func refusesArtwork(_ error: CKError) -> Bool {
        [.invalidArguments, .serverRejectedRequest, .unknownItem, .constraintViolation].contains(error.code)
    }

    private var artworkCatchUpMarker: URL {
        configuration.stateFileURL.deletingLastPathComponent().appending(path: "cksyncengine-artwork-caught-up")
    }

    private func markArtworkCaughtUp() {
        try? AtomicFile().write(Data("1".utf8), to: artworkCatchUpMarker)
    }

    /// One bounded query over the sync zone's covers (at most one per game), applied through the
    /// same path as fetched changes. A missing type means there is nothing to recover; any other
    /// failure retries at the next start.
    private func catchUpArtwork(generation: UInt64) async {
        var cursor: CKQueryOperation.Cursor?
        do {
            for _ in 0..<20 {
                let (records, next) = try await queryArtwork(cursor: cursor, generation: generation)
                var inbound: [InboundChange] = []
                for record in records where record.recordID.zoneID == syncZoneID {
                    do {
                        let (decoded, assets) = try codec.decode(record)
                        inbound.append(InboundChange(key: decoded.key, record: decoded, assets: try stage(assets)))
                        lock.withLock { if self.generation == generation { serverRecords[record.recordID] = record } }
                    } catch {
                        cloudKitLog.notice("artwork skipped: \(String(describing: error), privacy: .public)")
                    }
                }
                guard let host = lock.withLock({ self.generation == generation ? self.host : nil }) else { cleanScratch(inbound); return }
                if !inbound.isEmpty { await host.didFetch(changes: inbound, deletions: []) }
                cleanScratch(inbound)
                cursor = next
                if cursor == nil { break }
            }
            guard cursor == nil else { return }   // Bounded; the rest continues at the next start.
            markArtworkCaughtUp()
            cloudKitLog.notice("artwork catch-up complete")
        } catch let error as CKError where error.code == .unknownItem {
            markArtworkCaughtUp()   // The type was never created: no cover to recover.
        } catch {
            cloudKitLog.notice("artwork catch-up deferred: \(String(describing: error), privacy: .public)")
        }
    }

    private func queryArtwork(cursor: CKQueryOperation.Cursor?, generation: UInt64) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation = cursor.map { CKQueryOperation(cursor: $0) }
                ?? CKQueryOperation(query: CKQuery(recordType: SyncRecordType.artwork.rawValue, predicate: NSPredicate(value: true)))
            operation.zoneID = syncZoneID
            operation.resultsLimit = 200
            let operationID = ObjectIdentifier(operation)
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result { records.append(record) }
            }
            operation.queryResultBlock = { [weak self] result in
                self?.completeContentOperation(operationID)
                switch result {
                case .success(let next): continuation.resume(returning: (records, next))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            operation.qualityOfService = .utility
            Self.bound(operation)
            do { try addContentOperation(operation, generation: generation) }
            catch { continuation.resume(throwing: error) }
        }
    }

    public func stop() async {
        let retired: (CKSyncEngine?, [CKDatabaseOperation]) = lock.withLock {
            generation &+= 1
            let retired = (engine, Array(contentOperations.values))
            engine = nil
            host = nil
            contentOperations.removeAll()
            inFlight.removeAll()
            immediateSyncRunning = false
            contentZoneReady = false
            if let observer = accountObserver { NotificationCenter.default.removeObserver(observer) }
            accountObserver = nil
            return retired
        }
        for operation in retired.1 { operation.cancel() }
        // stop can be invoked from an engine account-change delegate callback.
        // Awaiting cancellation there would wait for our own callback to return.
        // The host/engine were already detached atomically; all retired delegates are ignored.
        if let engine = retired.0 { Task { await engine.cancelOperations() } }
    }

    public func resetState() async {
        await stop()
        try? FileManager.default.removeItem(at: configuration.stateFileURL)
        lock.lock(); serverRecords.removeAll(); inFlight.removeAll(); lock.unlock()
        cloudKitLog.notice("engine state discarded")
    }

    /// Relay is aggressive where it is free (owner policy, 2026-09-03): foreground,
    /// explicit requests and reconciliation sync immediately; a save marks work as
    /// pending and lets the engine schedule it. Nothing here is on a launch path.
    ///
    /// `CKSyncEngine.sendChanges` and `fetchChanges` must not overlap: CloudKit
    /// raises an unrecoverable Swift assertion (not a thrown error) when a manual
    /// send runs while another is in flight. Immediate syncs are therefore
    /// serialised — one at a time, send then fetch — and a request that arrives
    /// while one is running simply marks the state, which the running pass picks up.
    public func requestSync(reason: SyncReason) async {
        lock.lock(); let engine = self.engine; lock.unlock()
        guard let engine else { return }
        // Always tell the engine there is work; this alone is enough for it to
        // schedule a send on its own (and is all a save needs).
        engine.state.hasPendingUntrackedChanges = true
        switch reason {
        case .progressSaved:
            return
        case .manual, .reconciliation, .appActive:
            break
        }
        lock.lock()
        if self.engine !== engine || immediateSyncRunning { lock.unlock(); return }
        immediateSyncRunning = true
        lock.unlock()
        let zone = syncZoneID
        Task { [weak self] in
            defer { self?.finishImmediateSync(engine: engine) }
            guard self?.isCurrent(engine: engine) == true else { return }
            do {
                try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs([zone])))
            } catch {
                cloudKitLog.notice("immediate send failed: \(CloudKitErrorClassifier.classify(error).description, privacy: .public)")
            }
            guard self?.isCurrent(engine: engine) == true, let options = self?.fetchOptions() else { return }
            do {
                try await engine.fetchChanges(options)
            } catch {
                cloudKitLog.notice("immediate fetch failed: \(CloudKitErrorClassifier.classify(error).description, privacy: .public)")
            }
        }
    }

    private func finishImmediateSync(engine: CKSyncEngine) {
        lock.withLock { if self.engine === engine { immediateSyncRunning = false } }
    }

    public func fetchNow() async throws {
        lock.lock()
        guard let engine = self.engine else { lock.unlock(); throw CloudKitTransportError.notStarted }
        if immediateSyncRunning { lock.unlock(); return }   // one manual pass at a time
        immediateSyncRunning = true
        lock.unlock()
        defer { finishImmediateSync(engine: engine) }
        try await engine.fetchChanges(fetchOptions())
    }

    private func fetchOptions() -> CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([syncZoneID]))
        options.prioritizedZoneIDs = [syncZoneID]
        return options
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let host = currentHost(engine: syncEngine) else { return }
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization, engine: syncEngine)
        case .accountChange(let change):
            await handleAccountChange(change, host: host, engine: syncEngine)
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == syncZoneID {
                cloudKitLog.notice("relay zone deleted on the server (\(String(describing: deletion.reason), privacy: .public))")
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: syncZoneID))])
                lock.withLock { if self.engine === syncEngine { serverRecords.removeAll() } }
                await host.zoneWasReset()
            }
        case .fetchedRecordZoneChanges(let changes):
            await handleFetched(changes, host: host, engine: syncEngine)
        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, host: host, engine: syncEngine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                cloudKitLog.error("zone save failed: \(failure.error.code.description, privacy: .public)")
                await updateStatus(host: host, engine: syncEngine) { $0.lastProblem = CloudKitErrorClassifier.classify(failure.error) }
            }
        case .willFetchChanges:
            await updateStatus(host: host, engine: syncEngine) { $0.isSyncing = true; $0.isFetching = true }
        case .willSendChanges:
            await updateStatus(host: host, engine: syncEngine) { $0.isSyncing = true }
        case .didFetchChanges:
            await updateStatus(host: host, engine: syncEngine) { $0.isSyncing = false; $0.isFetching = false; $0.lastPullAt = Date() }
        case .didSendChanges:
            await updateStatus(host: host, engine: syncEngine) { $0.isSyncing = false }
            // More journal entries may be waiting.
            let more = await host.nextOutboundBatch(limit: 1)
            guard isCurrent(engine: syncEngine) else { return }
            if !more.isEmpty {
                guard storeInFlight(more, engine: syncEngine) else { return }
                syncEngine.state.hasPendingUntrackedChanges = true
            }
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let host = currentHost(engine: syncEngine) else { return nil }
        // Changes already handed out but not yet reported, then fresh ones from the journal.
        var changes = lock.withLock { self.engine === syncEngine ? Array(inFlight.values) : [] }
        if changes.isEmpty {
            changes = await host.nextOutboundBatch(limit: 40)
            guard isCurrent(engine: syncEngine) else { return nil }
            guard storeInFlight(changes, engine: syncEngine) else { return nil }
        }
        if changes.isEmpty {
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var contentDeletes: [OutboundChange] = []
        for change in changes {
            let id = recordID(for: change.key)
            guard context.options.scope.contains(id) else { continue }
            if change.key.zone == .content {
                contentDeletes.append(change)   // content zone changes are direct operations, never engine batches
                continue
            }
            switch change.payload {
            case .save(let record, let assets):
                let cached = lock.withLock { self.engine === syncEngine ? serverRecords[id] : nil }
                let target = cached.map { $0 } ?? CKRecord(recordType: change.key.type.rawValue, recordID: id)
                codec.encode(record, assets: assets, into: target)
                recordsToSave.append(target)
            case .delete:
                recordIDsToDelete.append(id)
            }
        }
        if !contentDeletes.isEmpty { Task { await self.performContentDeletes(contentDeletes, host: host, engine: syncEngine) } }
        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else {
            syncEngine.state.hasPendingUntrackedChanges = false
            return nil
        }
        guard isCurrent(engine: syncEngine) else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, atomicByZone: false)
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        guard isCurrent(engine: syncEngine) else { return CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([])) }
        return fetchOptions()
    }

    // MARK: Inbound

    private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, host: any SyncTransportHost, engine syncEngine: CKSyncEngine) async {
        guard isCurrent(engine: syncEngine) else { return }
        var inbound: [InboundChange] = []
        var deletions: [RecordKey] = []
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordID.zoneID == syncZoneID else { continue }
            do {
                let (decoded, assets) = try codec.decode(record)
                let staged = try stage(assets)
                if !decoded.isImmutable { cacheServerRecord(record, for: record.recordID, engine: syncEngine) }
                inbound.append(InboundChange(key: decoded.key, record: decoded, assets: staged))
            } catch {
                cloudKitLog.notice("record skipped \(record.recordType, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for deletion in changes.deletions where deletion.recordID.zoneID == syncZoneID {
            if let key = RecordCodec.key(for: deletion.recordID, type: deletion.recordType) { deletions.append(key) }
            cacheServerRecord(nil, for: deletion.recordID, engine: syncEngine)
        }
        await host.didFetch(changes: inbound, deletions: deletions)
        cleanScratch(inbound)
    }

    /// CloudKit's asset URLs are temporary; copy them into Relay's scratch directory first.
    private func stage(_ assets: [SyncAssetName: URL]) throws -> [SyncAssetName: URL] {
        var staged: [SyncAssetName: URL] = [:]
        for (name, url) in assets {
            let destination = configuration.scratchDirectory.appending(path: "\(UUID().uuidString)-\(name.rawValue)")
            try FileManager.default.copyItem(at: url, to: destination)
            staged[name] = destination
        }
        return staged
    }

    private func cleanScratch(_ changes: [InboundChange]) {
        for change in changes { for (_, url) in change.assets { try? FileManager.default.removeItem(at: url) } }
    }

    // MARK: Outbound results

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, host: any SyncTransportHost, engine syncEngine: CKSyncEngine) async {
        guard isCurrent(engine: syncEngine) else { return }
        var results: [SendResult] = []
        var worst: TransportProblem?
        for record in sent.savedRecords {
            guard let change = takeInFlight(record.recordID, engine: syncEngine) else { continue }
            if case .save(let local, _) = change.payload, !local.isImmutable { cacheServerRecord(record, for: record.recordID, engine: syncEngine) }
            results.append(SendResult(key: change.key, outcome: .saved))
        }
        for failure in sent.failedRecordSaves {
            guard let change = takeInFlight(failure.record.recordID, engine: syncEngine) else { continue }
            let problem = CloudKitErrorClassifier.classify(failure.error)
            if change.key.type == .artwork, problem != .serverRecordChanged {
                // A cover never becomes a transport problem; a refused type waits for the next session.
                if Self.refusesArtwork(failure.error) {
                    lock.withLock { if self.engine === syncEngine { artworkRefused = true } }
                    cloudKitLog.notice("artwork refused (\(failure.error.code.description, privacy: .public)); covers wait this session")
                }
                results.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                continue
            }
            var serverRecord: SyncRecord?
            if problem == .serverRecordChanged, let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                cacheServerRecord(server, for: server.recordID, engine: syncEngine)
                serverRecord = try? codec.decode(server).0
            }
            if problem.isTransient, worst == nil || problem == .quotaFull { worst = problem }
            results.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: serverRecord)))
        }
        for id in sent.deletedRecordIDs {
            guard let change = takeInFlight(id, engine: syncEngine) else { continue }
            cacheServerRecord(nil, for: id, engine: syncEngine)
            results.append(SendResult(key: change.key, outcome: .deleted))
        }
        for (id, error) in sent.failedRecordDeletes {
            guard let change = takeInFlight(id, engine: syncEngine) else { continue }
            results.append(SendResult(key: change.key, outcome: .failed(CloudKitErrorClassifier.classify(error), serverRecord: nil)))
        }
        await host.didSend(results)
        await updateStatus(host: host, engine: syncEngine) { s in
            if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty { s.lastPushAt = Date() }
            s.lastProblem = worst
        }
    }

    private func takeInFlight(_ id: CKRecord.ID, engine: CKSyncEngine) -> OutboundChange? {
        lock.withLock {
            guard self.engine === engine else { return nil }
            return inFlight.removeValue(forKey: id)
        }
    }

    private func storeInFlight(_ changes: [OutboundChange], engine: CKSyncEngine) -> Bool {
        lock.withLock {
            guard self.engine === engine else { return false }
            for change in changes { inFlight[recordID(for: change.key)] = change }
            return true
        }
    }

    private func cacheServerRecord(_ record: CKRecord?, for id: CKRecord.ID, engine: CKSyncEngine) {
        lock.withLock {
            guard self.engine === engine else { return }
            serverRecords[id] = record
        }
    }

    private func performContentDeletes(_ changes: [OutboundChange], host: any SyncTransportHost, engine: CKSyncEngine) async {
        guard isCurrent(engine: engine) else { return }
        var results: [SendResult] = []
        for change in changes {
            guard isCurrent(engine: engine) else { return }
            let id = recordID(for: change.key)
            _ = takeInFlight(id, engine: engine)
            do {
                _ = try await database.modifyRecords(saving: [], deleting: [id])
                results.append(SendResult(key: change.key, outcome: .deleted))
            } catch {
                let problem = CloudKitErrorClassifier.classify(error)
                results.append(SendResult(key: change.key, outcome: .failed(problem == .unknownItem ? .unknownItem : problem, serverRecord: nil)))
            }
        }
        await host.didSend(results)
    }

    // MARK: Account

    private func reportAccount(host: any SyncTransportHost, generation: UInt64) async {
        let availability: AccountAvailability
        do { availability = CloudKitErrorClassifier.availability(try await container.accountStatus()) } catch { availability = .unknown }
        var identity: String?
        if availability == .available, let recordID = try? await container.userRecordID() {
            identity = Self.hash(recordID.recordName)
        }
        guard isCurrent(generation: generation) else { return }
        await host.accountDidChange(AccountChange(availability: availability, identity: identity))
    }

    private func observeAccountChanges(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation, accountObserver == nil, let host else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self, weak host] _ in
            guard let host else { return }
            Task { await self?.reportAccount(host: host, generation: generation) }
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, host: any SyncTransportHost, engine: CKSyncEngine) async {
        switch change.changeType {
        case .signIn(let user):
            await host.accountDidChange(AccountChange(availability: .available, identity: Self.hash(user.recordName)))
        case .signOut:
            await host.accountDidChange(AccountChange(availability: .noAccount, identity: nil))
        case .switchAccounts(_, let user):
            await host.accountDidChange(AccountChange(availability: .available, identity: Self.hash(user.recordName)))
        @unknown default:
            let generation = lock.withLock { self.generation }
            guard isCurrent(engine: engine) else { return }
            await reportAccount(host: host, generation: generation)
        }
    }

    /// Opaque identity: SHA-256 of the CloudKit user record name (never stored raw).
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Content zone (direct operations, on demand)

    private func ensureContentZone(generation: UInt64) async throws {
        guard isCurrent(generation: generation) else { throw CancellationError() }
        lock.lock(); let ready = contentZoneReady; lock.unlock()
        if ready { return }
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: contentZoneID)], deleting: [])
        } catch let error as CKError where error.code == .partialFailure || error.code == .serverRecordChanged {
            // Already exists.
        }
        try lock.withLock {
            guard self.generation == generation else { throw CancellationError() }
            contentZoneReady = true
        }
    }

    public func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let generation = try contentGeneration()
        try await CloudContentParts(directory: configuration.scratchDirectory).upload(record, file: fileURL, progress: progress) { [self] part, file, update in
            guard isCurrent(generation: generation) else { throw CancellationError() }
            try await uploadContentPart(part, fileURL: file, progress: update)
            guard isCurrent(generation: generation) else { throw CancellationError() }
        }
    }

    public func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? {
        let generation = try contentGeneration()
        let result = try await CloudContentParts(directory: configuration.scratchDirectory).fetch(key, progress: progress, get: { [self] key, update in
            guard isCurrent(generation: generation) else { throw CancellationError() }
            let result = try await fetchContentPart(key, progress: update)
            guard isCurrent(generation: generation) else {
                if let result { await releaseContent(result) }
                throw CancellationError()
            }
            return result
        }, release: { [self] change in await releaseContent(change) })
        guard isCurrent(generation: generation) else {
            if let result { await releaseContent(result) }
            throw CancellationError()
        }
        return result
    }

    public func releaseContent(_ change: InboundChange) async {
        for file in change.assets.values where file.standardizedFileURL.deletingLastPathComponent() == configuration.scratchDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func uploadContentPart(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let generation = try contentGeneration()
        try await ensureContentZone(generation: generation)
        let id = recordID(for: record.key)
        let ckRecord = CKRecord(recordType: record.type.rawValue, recordID: id)
        codec.encode(record, assets: [.data: fileURL], into: ckRecord)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [ckRecord], recordIDsToDelete: nil)
            let operationID = ObjectIdentifier(operation)
            operation.savePolicy = .allKeys // immutable, verified content; retries replace identical parts
            operation.perRecordProgressBlock = { _, p in progress(p) }
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.completeContentOperation(operationID)
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            operation.qualityOfService = .utility
            Self.bound(operation)
            do { try addContentOperation(operation, generation: generation) }
            catch { continuation.resume(throwing: error) }
        }
        guard isCurrent(generation: generation) else { throw CancellationError() }
        cloudAssetLog.notice("content uploaded \(record.key.name.prefix(24), privacy: .public)")
    }

    private func fetchContentPart(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? {
        let generation = try contentGeneration()
        let id = recordID(for: key)
        let record: CKRecord? = try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            let operationID = ObjectIdentifier(operation)
            operation.perRecordProgressBlock = { _, p in progress(p) }
            var fetched: CKRecord?
            operation.perRecordResultBlock = { _, result in
                if case .success(let r) = result { fetched = r }
            }
            operation.fetchRecordsResultBlock = { [weak self] result in
                self?.completeContentOperation(operationID)
                switch result {
                case .success: continuation.resume(returning: fetched)
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem { continuation.resume(returning: nil) } else { continuation.resume(throwing: error) }
                }
            }
            operation.qualityOfService = .utility
            Self.bound(operation)
            do { try addContentOperation(operation, generation: generation) }
            catch { continuation.resume(throwing: error) }
        }
        guard isCurrent(generation: generation) else { throw CancellationError() }
        guard let record else { return nil }
        let (decoded, assets) = try codec.decode(record)
        guard case .gameContent(let part) = try SyncRecordValidator().validate(decoded), part.partSize > 0,
              part.partSize <= SyncLimits.maxContentPartSize, let file = assets[.data],
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(part.partSize) else { throw SyncContentError.verificationFailed }
        return InboundChange(key: key, record: decoded, assets: try stage(assets))
    }

    public func contentExists(_ key: RecordKey) async throws -> Bool {
        let generation = try contentGeneration()
        let id = recordID(for: key)
        let exists: Bool = try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            let operationID = ObjectIdentifier(operation)
            operation.desiredKeys = [RecordCodec.Field.schema]   // metadata only: never the asset
            var found = false
            operation.perRecordResultBlock = { _, result in if case .success = result { found = true } }
            operation.fetchRecordsResultBlock = { [weak self] result in
                self?.completeContentOperation(operationID)
                switch result {
                case .success: continuation.resume(returning: found)
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem || ck.code == .partialFailure { continuation.resume(returning: found) } else { continuation.resume(throwing: error) }
                }
            }
            Self.bound(operation)
            do { try addContentOperation(operation, generation: generation) }
            catch { continuation.resume(throwing: error) }
        }
        guard isCurrent(generation: generation) else { throw CancellationError() }
        return exists
    }

    public func deleteContent(_ key: RecordKey) async throws {
        let generation = try contentGeneration()
        guard let membership = key.contentMembership,
              key == .gameContent(membership.fingerprint, part: 0, generation: membership.generation) else { throw SyncContentError.unsupportedLayout }
        // Include parts left by an interrupted upload whose root never appeared.
        let ids = (0..<SyncLimits.maxPartCount).map { recordID(for: .gameContent(membership.fingerprint, part: $0, generation: membership.generation)) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            let operationID = ObjectIdentifier(operation)
            operation.isAtomic = false
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.completeContentOperation(operationID)
                switch result {
                case .success: continuation.resume()
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .unknownItem ||
                        (ck.code == .partialFailure && ck.partialErrorsByItemID?.values.allSatisfy({ ($0 as? CKError)?.code == .unknownItem }) == true) {
                        continuation.resume()
                    } else { continuation.resume(throwing: error) }
                }
            }
            Self.bound(operation)
            do { try addContentOperation(operation, generation: generation) }
            catch { continuation.resume(throwing: error) }
        }
        guard isCurrent(generation: generation) else { throw CancellationError() }
    }

    // MARK: Helpers

    private func contentGeneration() throws -> UInt64 {
        try lock.withLock {
            guard engine != nil, host != nil else { throw CloudKitTransportError.notStarted }
            return generation
        }
    }

    private func addContentOperation(_ operation: CKDatabaseOperation, generation: UInt64) throws {
        let database = self.database
        try lock.withLock {
            guard self.generation == generation, engine != nil else { throw CancellationError() }
            contentOperations[ObjectIdentifier(operation)] = operation
            database.add(operation)
        }
    }

    private func completeContentOperation(_ id: ObjectIdentifier) {
        _ = lock.withLock { contentOperations.removeValue(forKey: id) }
    }

    /// Heavy-content operations are direct and user-visible: bound them so a stalled
    /// request surfaces as a failure instead of pinning the task that awaits it.
    /// The operation's own configuration is mutated, because replacing it would drop
    /// the container the database gave it.
    static func bound(_ operation: CKOperation) {
        operation.configuration.timeoutIntervalForRequest = 60
        operation.configuration.timeoutIntervalForResource = 300
    }

    private func recordID(for key: RecordKey) -> CKRecord.ID {
        RecordCodec.recordID(for: key, zoneID: key.zone == .content ? contentZoneID : syncZoneID)
    }

    private func currentHost(engine: CKSyncEngine) -> (any SyncTransportHost)? {
        lock.withLock { self.engine === engine ? host : nil }
    }

    private func isCurrent(engine: CKSyncEngine) -> Bool {
        lock.withLock { self.engine === engine }
    }

    private func isCurrent(generation: UInt64) -> Bool {
        lock.withLock { self.generation == generation && host != nil }
    }

    private func updateStatus(host: any SyncTransportHost, engine: CKSyncEngine, _ change: (inout TransportStatus) -> Void) async {
        let snapshot: TransportStatus? = lock.withLock {
            guard self.engine === engine else { return nil }
            change(&status)
            return status
        }
        guard var detail = snapshot else { return }
        detail.detail = engineDetail()
        await host.transportDidUpdate(detail)
    }

    /// Diagnostics line: engine state health without any payload.
    public func engineDetail() -> String {
        lock.lock(); let engine = self.engine; let inFlightCount = inFlight.count; lock.unlock()
        guard let engine else { return "engine stopped" }
        let state = engine.state
        return "engine running; pending records \(state.pendingRecordZoneChanges.count), pending zones \(state.pendingDatabaseChanges.count), untracked \(state.hasPendingUntrackedChanges), in flight \(inFlightCount), unfetched zones \(state.zoneIDsWithUnfetchedServerChanges.count), state file \(FileManager.default.fileExists(atPath: configuration.stateFileURL.path) ? "present" : "absent")"
    }

    // MARK: Engine state persistence (transport state, atomic)

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: configuration.stateFileURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ serialization: CKSyncEngine.State.Serialization, engine: CKSyncEngine) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        lock.withLock {
            guard self.engine === engine else { return }
            try? AtomicFile().write(data, to: configuration.stateFileURL)
        }
    }
}

public enum CloudKitTransportError: Error, Equatable, Sendable {
    case notStarted
}
