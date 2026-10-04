// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncCoordinator.swift
//  RelaySync
//
//  An actor that:
//    - hands the transport outbound changes built from journal intents and
//      completes/fails/resolves them from the results;
//    - validates, stages and applies inbound changes in one transaction per
//      batch, retries deferred records, and reconciles the battery graph;
//    - owns the product policy (enabled switches, account decisions, the
//      internal game-file gate) and publishes `SyncStatus`;
//    - keeps gameplay safe: heavy work waits while a game runs.
//  It never sees a CloudKit type and never blocks a save or a launch.

import Foundation
import OSLog
import RelayDomain
import RelayLibrary

let syncLog = Logger(subsystem: "app.relayemu.relay", category: "sync")
let conflictLog = Logger(subsystem: "app.relayemu.relay", category: "conflict")

public actor SyncCoordinator: SyncTransportHost {
    public struct Configuration: Sendable {
        public var capabilities: SyncCapabilities
        /// How many changes one outbound batch may carry.
        public var batchSize: Int = 50
        /// Pending intents older than this while online escalate to a Home card.
        public var pendingEscalation: TimeInterval = 10 * 60

        public init(capabilities: SyncCapabilities) {
            self.capabilities = capabilities
        }
    }

    // MARK: Dependencies

    private let store: any LibraryStore
    private let baseSyncStore: any SyncStore
    private var syncStore: any SyncStore
    private let location: LibraryLocation
    private let batterySaves: BatterySaveManager
    private let saveStates: SaveStateManager
    public let identity: SyncIdentity
    private var configuration: Configuration
    private let clock: @Sendable () -> Date
    private var transport: (any SyncTransport)?

    // MARK: State

    private(set) public var status = SyncStatus()
    private var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var inFlight: Set<Int64> = []
    private var inFlightKeys: [RecordKey: [Int64]] = [:]
    private var inFlightRecords: [RecordKey: SyncRecord] = [:]
    private var pendingGames: [RecordKey: ContentFingerprint] = [:]
    private var runningGameID: GameID?
    private var pendingReconciliation: Set<GameID> = []
    private var failedGames: [GameID: SyncProblem] = [:]
    private var transfers: [GameID: ContentTransfer] = [:]
    private var activeContentRequests: Set<GameID> = []
    private var applyGeneration = 0
    private var transportFailureNeedsSuccessfulPage = false
    private var activating = false
    private var provider: SyncProviderSelection = .iCloud
    private var activeAccountIdentity: String?
    private var lastEnabledProvider: SyncProviderSelection = .iCloud
    var transportEpoch: UInt64 = 0
    private var callbackCount = 0
    private var callbackDrain: [CheckedContinuation<Void, Never>] = []
    private var lifecycleBusy = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    /// The opaque identity of the account that replaced the one this library synced with.
    private(set) public var pendingAccountIdentity: String?

    public init(store: any LibraryStore, syncStore: any SyncStore, location: LibraryLocation, batterySaves: BatterySaveManager,
                saveStates: SaveStateManager, identity: SyncIdentity, configuration: Configuration,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.baseSyncStore = syncStore
        self.syncStore = syncStore
        self.location = location
        self.batterySaves = batterySaves
        self.saveStates = saveStates
        self.identity = identity
        self.configuration = configuration
        self.clock = clock
        status.gameFilesAllowed = configuration.capabilities.gameFileSyncAllowed
    }

    // MARK: Lifecycle

    /// Compatibility entry point for the existing iCloud and deterministic transports.
    public func start(transport: any SyncTransport) async {
        let selected = await savedProviderSelection()
        await selectProvider(selected, transport: selected == .relaySync ? nil : transport)
    }

    public func savedProviderSelection() async -> SyncProviderSelection {
        do {
            if let raw = try await syncStore.metaValue(forKey: SyncMetaKey.selectedProvider) {
                return SyncProviderSelection(rawValue: raw) ?? .off
            }
            return (try await syncStore.metaValue(forKey: SyncMetaKey.savesEnabled)) == "0" ? .off : .iCloud
        } catch { return .off }
    }

    /// Exactly one remote is selected. Local data and the previous remote remain intact.
    /// Retired callbacks are rejected; admitted operations drain before the scope changes.
    public func selectProvider(_ selection: SyncProviderSelection, transport replacement: (any SyncTransport)?,
                               capabilities: SyncCapabilities? = nil) async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        // A fresh actor's default is not the library's previous provider. Compare
        // durable policy before overwriting it so restart does not re-bridge history.
        let previousSelection = await savedProviderSelection()
        let changed = previousSelection != selection
        await retireTransport()
        provider = selection
        status = SyncStatus()
        transportFailureNeedsSuccessfulPage = false
        status.provider = selection
        status.isEnabled = selection != .off
        if selection != .off { lastEnabledProvider = selection }
        self.transport = replacement ?? (selection == .off ? self.transport : nil)
        if let capabilities { configuration.capabilities = capabilities }
        status.gameFilesAllowed = configuration.capabilities.gameFileSyncAllowed
        do {
            try await syncStore.setMetaValue(selection.rawValue, forKey: SyncMetaKey.selectedProvider)
            try await syncStore.setMetaValue(selection == .off ? "0" : "1", forKey: SyncMetaKey.savesEnabled)
            try await loadPolicy()
            if changed, selection != .off {
                // The canonical local state bridges providers, including progress fetched from the old one.
                try await syncStore.setMetaValue(nil, forKey: scopedMetaKey(SyncMetaKey.reconciled))
            }
            if selection != .off, replacement != nil { await activate(reason: .reconciliation) }
            else { status.account = .noAccount }
        } catch {
            status.isActive = false
            setProblem(.failed("provider selection"))
        }
        await refreshCounts()
        publish()
    }

    public func stop() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        await retireTransport()
        publish()
    }

    private func acquireLifecycle() async {
        if lifecycleBusy { await withCheckedContinuation { lifecycleWaiters.append($0) } }
        else { lifecycleBusy = true }
    }

    private func releaseLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleBusy = false }
        else { lifecycleWaiters.removeFirst().resume() }
    }

    private func retireTransport() async {
        transportEpoch &+= 1
        status.isActive = false
        await transport?.stop()
        if callbackCount > 0 { await withCheckedContinuation { callbackDrain.append($0) } }
        inFlight.removeAll(); inFlightKeys.removeAll(); inFlightRecords.removeAll()
        pendingGames.removeAll(); failedGames.removeAll(); transfers.removeAll()
        pendingAccountIdentity = nil
        status.isSyncing = false
        status.isFetching = false
    }

    func transportCallbackIsCurrent(epoch: UInt64) -> Bool {
        epoch == transportEpoch && provider != .off && !status.accountChangePending
    }

    func beginTransportCallback(epoch: UInt64) -> Bool {
        guard transportCallbackIsCurrent(epoch: epoch) else { return false }
        callbackCount += 1
        return true
    }

    func endTransportCallback() {
        callbackCount -= 1
        if callbackCount == 0 {
            let waiters = callbackDrain
            callbackDrain.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func scopedMetaKey(_ key: String) -> String {
        SyncMetaKey.scoped(key == SyncMetaKey.reconciled ? key + ".schema2" : key, provider: provider, account: activeAccountIdentity)
    }

    private func activate(reason: SyncReason) async {
        guard let transport, status.isEnabled, !status.accountChangePending, !activating else { return }
        let epoch = transportEpoch
        activating = true
        defer { activating = false }
        do {
            try await reconcileIfNeeded()
            try await transport.start(host: GenerationTransportHost(coordinator: self, epoch: epoch))
            guard epoch == transportEpoch, !status.accountChangePending else { return }
            status.isActive = true
            // A first account may become known during start. Record reconciliation
            // under that durable scope too, so the next cold start does not re-bridge.
            try await reconcileIfNeeded()
            await transport.requestSync(reason: reason)
        } catch {
            guard epoch == transportEpoch else { return }
            setProblem(.failed("transport start"))
        }
    }

    private func reconcileIfNeeded() async throws {
        let marker = scopedMetaKey(SyncMetaKey.reconciled)
        guard try await syncStore.metaValue(forKey: marker) != "1" else { return }
        try await syncStore.enqueueEverything()
        try await syncStore.setMetaValue("1", forKey: marker)
        syncLog.notice("initial reconciliation journaled")
    }

    private func loadPolicy() async throws {
        activeAccountIdentity = try await syncStore.metaValue(forKey: SyncMetaKey.acceptedAccount(provider: provider))
        if provider == .iCloud,
           (try await syncStore.metaValue(forKey: "provider.iCloud.legacy_migrated")) != "1" {
            if activeAccountIdentity == nil { activeAccountIdentity = try await syncStore.metaValue(forKey: SyncMetaKey.accountIdentity) }
            try await syncStore.setMetaValue(activeAccountIdentity, forKey: SyncMetaKey.acceptedAccount(provider: .iCloud))
            try await syncStore.setMetaValue(activeAccountIdentity, forKey: "provider.iCloud.original_account")
            // Legacy acknowledgements prove only schema 1. Preserve that marker
            // in place; schema 2 must rebuild all canonical membership intents.
            for key in [SyncMetaKey.gameFilesEnabled, SyncMetaKey.lastPushAt, SyncMetaKey.lastPullAt] {
                let value = try await syncStore.metaValue(forKey: key)
                try await syncStore.setMetaValue(value, forKey: scopedMetaKey(key))
            }
            try await syncStore.setMetaValue("1", forKey: "provider.iCloud.legacy_migrated")
        }
        try await updateStoreScope()
        try await loadAccountPolicy()
        await refreshConflicts()
    }

    private func updateStoreScope() async throws {
        let originalCloudAccount = try await baseSyncStore.metaValue(forKey: "provider.iCloud.original_account")
        let scope: String
        if provider == .iCloud, activeAccountIdentity == originalCloudAccount {
            scope = "cloudkit"
        } else {
            scope = SyncMetaKey.scoped("remote", provider: provider, account: activeAccountIdentity)
        }
        syncStore = ScopedSyncStore(base: baseSyncStore, scope: scope)
    }

    private func loadAccountPolicy() async throws {
        let gameFiles = try await syncStore.metaValue(forKey: scopedMetaKey(SyncMetaKey.gameFilesEnabled))
        status.gameFilesEnabled = configuration.capabilities.gameFileSyncAllowed && gameFiles == "1"
        status.lastPushAt = nil; status.lastPullAt = nil
        if let push = try await syncStore.metaValue(forKey: scopedMetaKey(SyncMetaKey.lastPushAt)), let ms = Int64(push) { status.lastPushAt = SyncTime.date(ms) }
        if let pull = try await syncStore.metaValue(forKey: scopedMetaKey(SyncMetaKey.lastPullAt)), let ms = Int64(pull) { status.lastPullAt = SyncTime.date(ms) }
    }

    // MARK: Policy (Settings)

    public func setEnabled(_ enabled: Bool) async {
        let selection = enabled ? (provider == .off ? lastEnabledProvider : provider) : .off
        await selectProvider(selection, transport: transport)
    }

    public func setCapabilities(_ capabilities: SyncCapabilities) async {
        configuration.capabilities = capabilities
        status.gameFilesAllowed = capabilities.gameFileSyncAllowed
        do { try await loadAccountPolicy() }
        catch { status.gameFilesEnabled = false; setProblem(.failed("sync metadata")) }
        publish()
    }

    public func setGameFilesEnabled(_ enabled: Bool) async {
        guard configuration.capabilities.gameFileSyncAllowed, provider != .off else { return }
        do {
            try await syncStore.setMetaValue(enabled ? "1" : "0", forKey: scopedMetaKey(SyncMetaKey.gameFilesEnabled))
            status.gameFilesEnabled = enabled
        } catch { setProblem(.failed("sync metadata")) }
        publish()
    }

    /// The owner explicitly accepts uploading the canonical library to a different account.
    public func acceptAccountChange(identityHash: String? = nil) async {
        guard let transport, let identity = identityHash ?? pendingAccountIdentity else { return }
        await acquireLifecycle()
        defer { releaseLifecycle() }
        await retireTransport()
        await transport.resetState()
        do {
            try await syncStore.setMetaValue(identity, forKey: SyncMetaKey.acceptedAccount(provider: provider))
            if provider == .iCloud { try await syncStore.setMetaValue(identity, forKey: SyncMetaKey.accountIdentity) }
            activeAccountIdentity = identity
            try await syncStore.setMetaValue(nil, forKey: scopedMetaKey(SyncMetaKey.reconciled))
            try await updateStoreScope()
            try await loadAccountPolicy()
            status.accountChangePending = false
            await activate(reason: .reconciliation)
        } catch {
            status.accountChangePending = true
            pendingAccountIdentity = identity
            setProblem(.failed("sync metadata"))
        }
        await refreshCounts()
        publish()
    }

    public func declineAccountChange() async {
        status.accountChangePending = false
        await setEnabled(false)
    }

    // MARK: Gameplay awareness

    /// A game started (`gameID`) or stopped (`nil`). Heavy work and head
    /// reconciliation for the running game wait until it stops.
    public func setGameplayActive(_ gameID: GameID?) async {
        runningGameID = gameID
        if gameID == nil, !pendingReconciliation.isEmpty {
            let games = pendingReconciliation
            pendingReconciliation.removeAll()
            for id in games { await reconcile(id) }
            publish()
        }
    }

    /// Progress was written; nudge the transport.
    public func flushSoon() async {
        await refreshCounts()
        publish()
        guard status.isOperational else { return }
        await transport?.requestSync(reason: .progressSaved)
    }

    public func requestSync(reason: SyncReason) async {
        guard status.isOperational else { return }
        await transport?.requestSync(reason: reason)
    }

    /// The app came to the foreground: synchronize now (owner policy, 2026-09-03).
    /// This is where Relay is aggressive, not on the launch path.
    public func appDidBecomeActive() async {
        guard status.isOperational else { return }
        await transport?.requestSync(reason: .appActive)
    }

    /// Local-first launch policy (owner policy, 2026-09-03): Relay never starts a
    /// fetch to launch a game and never waits for one. If a fetch happens to be in
    /// flight already, Continue pauses for an imperceptible grace so a result that is
    /// milliseconds away is not missed; otherwise this returns immediately. The save
    /// revision graph, not network latency, is the consistency mechanism: a divergent
    /// revision that lands after launch becomes Two versions, never a silent overwrite.
    public func graceForInFlightFetch(maxWait: TimeInterval = 0.25) async {
        guard status.isOperational, status.isFetching, maxWait > 0 else { return }
        let step = 0.02
        for _ in 0..<max(1, Int(maxWait / step)) {
            guard status.isFetching else { return }
            try? await Task.sleep(for: .seconds(step))
        }
    }

    // MARK: Observation

    public func statusStream() -> AsyncStream<SyncStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish() {
        for continuation in continuations.values { continuation.yield(status) }
    }

    /// Cloud status of one game for status lines and badges.
    public func gameStatus(_ game: Game, hasLocalContent: Bool) async -> GameCloudStatus {
        if let transfer = transfers[game.id], transfer.direction == .download { return .downloading(progress: transfer.progress) }
        if status.conflictGameIDs.contains(game.id) { return .conflict }
        if let problem = failedGames[game.id] { return .failed(problem) }
        if !hasLocalContent {
            if let descriptor = try? await syncStore.contentDescriptor(for: game.contentFingerprint), descriptor.generation == game.generation { return .cloudOnly(size: descriptor.sizeInBytes) }
            return .onAnotherDevice
        }
        guard status.isEnabled, status.account == .available || status.lastPushAt != nil else { return .localOnly }
        if let since = await pendingSince(for: game.contentFingerprint) { return .pending(since: since) }
        return status.lastPushAt == nil && status.lastPullAt == nil ? .localOnly : .upToDate
    }

    public func conflict(for gameID: GameID) async -> BatteryConflict? {
        try? await batterySaves.conflict(for: gameID)
    }

    /// Fingerprints whose content this device knows to be in iCloud (Remove Download stays safe).
    public func cloudContentFingerprints() async -> Set<ContentFingerprint> {
        Set(((try? await syncStore.contentDescriptors()) ?? []).map(\.fingerprint))
    }

    public func transfer(for gameID: GameID) -> ContentTransfer? { transfers[gameID] }

    // MARK: Conflicts

    /// Two versions: keep `revisionID`, journal the merge, refresh.
    public func resolveConflict(gameID: GameID, keeping revisionID: BatteryRevisionID) async throws {
        let merged = try await batterySaves.resolve(gameID: gameID, keeping: revisionID, now: clock())
        conflictLog.notice("conflict resolved for \(gameID, privacy: .public) with merge \(merged.id, privacy: .public)")
        await refreshConflicts()
        await flushSoon()
    }

    /// Recomputes the conflict list (after resolution, deletion, or a new session).
    public func refreshConflicts() async {
        var ids: [GameID] = []
        if let games = try? await store.games.allGames() {
            for game in games where (try? await batterySaves.conflict(for: game.id)) != nil { ids.append(game.id) }
        }
        status.conflictGameIDs = ids
    }

    // MARK: SyncTransportHost

    public func nextOutboundBatch(limit: Int) async -> [OutboundChange] {
        guard status.isEnabled, status.account == .available, !status.accountChangePending else { return [] }
        let excluded = await outboundExclusions()
        let entries = ((try? await syncStore.journal.pending(limit: max(limit, configuration.batchSize) + inFlight.count, excluding: excluded)) ?? [])
            .filter { !inFlight.contains($0.id) }
            .prefix(limit)
        guard !entries.isEmpty else { return [] }
        let builder = OutboundBuilder(store: store, syncStore: syncStore, location: location, identity: identity)
        let built = await builder.build(from: Array(entries))
        if !built.completed.isEmpty { try? await syncStore.journal.complete(built.completed) }
        return admitOutbound(built)
    }

    public func nextHostedOutboundPage(afterSequence: Int64, throughSequence: Int64?, limit: Int) async throws -> HostedOutboundPage {
        guard provider == .relaySync, status.isEnabled, status.account == .available, !status.accountChangePending else {
            throw SyncPageError.inactiveProvider
        }
        guard (1...1_000).contains(limit), afterSequence >= 0, throughSequence.map({ $0 >= afterSequence }) ?? true else {
            throw SyncPageError.invalidScope
        }
        let page = try await syncStore.journal.pending(afterSequence: afterSequence, throughSequence: throughSequence, limit: limit,
                                                        excluding: await outboundExclusions())
        let entries = page.entries.filter { !inFlight.contains($0.id) }
        let builder = OutboundBuilder(store: store, syncStore: syncStore, location: location, identity: identity)
        let built = await builder.build(from: entries)
        if !built.completed.isEmpty { try await syncStore.journal.complete(built.completed) }
        let changes = admitOutbound(built)
        return HostedOutboundPage(changes: changes, nextAfterSequence: page.entries.last?.id ?? afterSequence,
                                  throughSequence: page.throughSequence, hasMore: page.hasMore)
    }

    /// Covers wait (journalled, never blocking) until the active transport can carry them.
    private func outboundExclusions() async -> Set<SyncIntent.Kind> {
        await transport?.sendsArtwork == true ? [] : [.artwork]
    }

    private func admitOutbound(_ built: OutboundBuilder.Built) -> [OutboundChange] {
        for change in built.changes {
            inFlight.formUnion(change.journalIDs)
            inFlightKeys[change.key] = change.journalIDs
            if case .save(let record, _) = change.payload { inFlightRecords[change.key] = record }
        }
        pendingGames.merge(built.gameByKey) { _, new in new }
        status.isSyncing = !built.changes.isEmpty
        publish()
        return built.changes
    }

    public func didSend(_ results: [SendResult]) async {
        var completed: [Int64] = []
        var failed: [(ids: [Int64], reason: String)] = []
        var waiting: [(ids: [Int64], reason: String)] = []
        var resend: [(RecordKey, SyncRecord)] = []
        var worstProblem: TransportProblem?
        for result in results {
            let ids = inFlightKeys[result.key] ?? []
            let local = inFlightRecords[result.key]
            inFlightKeys[result.key] = nil
            inFlightRecords[result.key] = nil
            inFlight.subtract(ids)
            switch result.outcome {
            case .saved, .deleted:
                completed.append(contentsOf: ids)
                pendingGames[result.key] = nil
            case .failed(let problem, _) where result.key.type == .artwork && problem != .serverRecordChanged:
                // A cover that could not go yet stays journaled and retries; it is never a sync problem.
                syncLog.notice("artwork waits: \(result.key.description, privacy: .public): \(problem.description, privacy: .public)")
                waiting.append((ids, problem.description))
            case .failed(let problem, let serverRecord):
                note(problem: problem, for: result.key)
                switch problem {
                case .serverRecordChanged:
                    guard let local else { completed.append(contentsOf: ids); continue }
                    switch SyncResolution.resolve(local: local, server: serverRecord) {
                    case .acceptServer:
                        completed.append(contentsOf: ids)
                        pendingGames[result.key] = nil
                    case .resend(let merged):
                        // Re-send once with the merged record (the journal row stays; the next batch rebuilds from rows,
                        // so persist the merge into the rows where it matters).
                        await persistMerge(merged)
                        resend.append((result.key, merged))
                        failed.append((ids, problem.description))
                    case .integrityError(let reason):
                        syncLog.error("integrity: \(reason, privacy: .public)")
                        status.lastErrorCategory = "integrity"
                        completed.append(contentsOf: ids)
                        pendingGames[result.key] = nil
                    }
                case .unknownItem:
                    completed.append(contentsOf: ids)   // deleting something already gone
                case .invalidRecord(let why):
                    // Never drop a local object because the server refused it: keep the
                    // intent, surface it, and let it retry. Silent loss is not an option.
                    syncLog.error("record refused by the server: \(result.key.description, privacy: .public): \(why, privacy: .public)")
                    status.lastErrorCategory = "invalidRecord"
                    failed.append((ids, problem.description))
                case .zoneMissing:
                    failed.append((ids, problem.description))
                    await zoneWasReset()
                default:
                    failed.append((ids, problem.description))
                    worstProblem = Self.worse(worstProblem, problem)
                }
            }
        }
        if !completed.isEmpty { try? await syncStore.journal.complete(completed) }
        for entry in failed + waiting { try? await syncStore.journal.fail(entry.ids, reason: entry.reason) }
        _ = resend
        if !completed.isEmpty {
            status.lastPushAt = clock()
            try? await syncStore.setMetaValue(String(SyncTime.millis(status.lastPushAt!)), forKey: scopedMetaKey(SyncMetaKey.lastPushAt))
        }
        if let worstProblem {
            setProblem(Self.problem(for: worstProblem))
        } else if failed.isEmpty, !transportFailureNeedsSuccessfulPage {
            clearProblem()
        }
        await refreshCounts()
        status.isSyncing = false
        publish()
    }

    public func didFetch(changes: [InboundChange], deletions: [RecordKey]) async {
        guard status.isEnabled, !status.accountChangePending else { return }
        status.isApplying = true
        publish()
        defer { status.isApplying = false }
        let applier = RemoteApplier(store: store, syncStore: syncStore, location: location, saveStates: saveStates, identity: identity)
        await apply(changes: changes, deletions: deletions, applier: applier)
        await retryDeferred(applier: applier)
        status.lastPullAt = clock()
        try? await syncStore.setMetaValue(String(SyncTime.millis(status.lastPullAt!)), forKey: scopedMetaKey(SyncMetaKey.lastPullAt))
        await refreshCounts()
        publish()
    }

    public func hostedCursor(scope: String) async throws -> Int64 {
        let key = try hostedCursorKey(scope)
        guard let value = try await syncStore.metaValue(forKey: key) else { return 0 }
        guard let sequence = Int64(value), sequence >= 0 else { throw SyncPageError.invalidScope }
        return sequence
    }

    public func hostedPendingJournalIDs(in ids: [Int64]) async throws -> Set<Int64> {
        guard ids.count <= 10_000 else { throw SyncPageError.invalidScope }
        return try await syncStore.journal.pendingIDs(in: ids)
    }

    /// Unlike CKSyncEngine's callback, a hosted page must report failure to its
    /// caller. A failed validation or transaction leaves the cursor unchanged.
    public func applyHostedPage(changes: [InboundChange], deletions: [RecordKey], cursor: Int64, scope: String) async throws {
        guard status.isEnabled, !status.accountChangePending else { throw SyncPageError.inactiveProvider }
        let key = try hostedCursorKey(scope)
        guard cursor >= 0 else { throw SyncPageError.invalidScope }
        status.isApplying = true
        publish()
        defer { status.isApplying = false; publish() }
        let applier = RemoteApplier(store: store, syncStore: syncStore, location: location, saveStates: saveStates, identity: identity)
        for attempt in 0..<2 {
            var prepared = try await applier.prepare(changes: changes, deletions: deletions, now: clock())
            // A refused cover is cosmetic: it never holds back the progress on the same page.
            for (key, reason) in prepared.rejected where key.type == .artwork {
                syncLog.notice("rejected \(key.description, privacy: .public): \(reason, privacy: .public)")
            }
            prepared.rejected.removeAll { $0.0.type == .artwork }
            guard prepared.rejected.isEmpty else {
                for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
                status.lastErrorCategory = "rejected"
                throw SyncPageError.rejectedRecords
            }
            prepared.batch.checkpoint = SyncCheckpoint(key: key, sequence: cursor)
            do {
                let outcome = try await syncStore.applyRemote(prepared.batch)
                await finish(outcome: outcome, prepared: prepared)
            } catch {
                for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
                if let libraryError = error as? LibraryError, Self.membershipRace(libraryError), attempt == 0 { continue }
                status.lastErrorCategory = "apply"
                throw error
            }
            await retryDeferred(applier: applier)
            status.lastPullAt = clock()
            // The checkpoint above already committed with the page. This date
            // is only a display hint and cannot acknowledge an uncommitted page.
            try? await syncStore.setMetaValue(String(SyncTime.millis(status.lastPullAt!)), forKey: scopedMetaKey(SyncMetaKey.lastPullAt))
            await refreshCounts()
            // A retry-start/status heartbeat is not evidence of recovery. A committed
            // page is, provided no outbound intents still require repair or retry.
            if transportFailureNeedsSuccessfulPage, status.problem == .failed("sync transport"),
               (try? await syncStore.journal.pendingCount()) == 0 {
                clearProblem()
            }
            return
        }
    }

    private func hostedCursorKey(_ scope: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        guard !scope.isEmpty, scope.utf8.count <= 200,
              scope.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw SyncPageError.invalidScope }
        return "hosted.cursor." + scope
    }

    public func accountDidChange(_ change: AccountChange) async {
        status.account = change.availability
        if change.availability == .available, let identityHash = change.identity {
            let stored = activeAccountIdentity
            if stored == nil {
                do {
                    try await syncStore.setMetaValue(identityHash, forKey: SyncMetaKey.acceptedAccount(provider: provider))
                    if provider == .iCloud, (try await syncStore.metaValue(forKey: SyncMetaKey.accountIdentity)) == nil {
                        try await syncStore.setMetaValue(identityHash, forKey: SyncMetaKey.accountIdentity)
                        try await syncStore.setMetaValue(identityHash, forKey: "provider.iCloud.original_account")
                    }
                    activeAccountIdentity = identityHash
                    try await updateStoreScope()
                    try await loadAccountPolicy()
                } catch {
                    status.accountChangePending = true
                    pendingAccountIdentity = identityHash
                    status.isActive = false
                    await transport?.stop()
                    setProblem(.failed("sync metadata"))
                }
            } else if stored != identityHash {
                status.accountChangePending = true
                pendingAccountIdentity = identityHash
                status.isActive = false
                status.isSyncing = false
                await transport?.stop()
                syncLog.notice("sync account changed; frozen pending owner decision")
            } else if !status.isActive, status.isEnabled, !activating, !lifecycleBusy {
                await activate(reason: .appActive)
            }
        }
        if change.availability != .available {
            status.isSyncing = false
            setProblem(change.availability == .unknown ? nil : .accountUnavailable)
        } else if status.problem == .accountUnavailable { clearProblem() }
        publish()
    }

    public func transportDidUpdate(_ update: TransportStatus) async {
        status.isSyncing = update.isSyncing
        status.isFetching = update.isFetching
        status.transportDetail = update.detail
        if let problem = update.lastProblem {
            switch problem {
            case .quotaFull: setProblem(.quotaFull)
            case .network, .rateLimited: setProblem(.network)
            case .accountUnavailable: setProblem(.accountUnavailable)
            case .invalidRecord(let reason) where reason == "hosted history requires original installation"
                || reason == "hosted state retention deletion unsupported":
                setProblem(.failed(reason))
            default:
                // Transport payloads may contain opaque server text. Surface the failure
                // with a fixed classification instead of hiding it or exposing that text.
                setProblem(.failed("sync transport"))
                transportFailureNeedsSuccessfulPage = provider == .relaySync
            }
        }
        publish()
    }

    public func zoneWasReset() async {
        syncLog.notice("relay zone reset; re-journaling the library")
        try? await syncStore.setMetaValue(nil, forKey: scopedMetaKey(SyncMetaKey.reconciled))
        try? await syncStore.enqueueEverything()
        try? await syncStore.setMetaValue("1", forKey: scopedMetaKey(SyncMetaKey.reconciled))
        await transport?.requestSync(reason: .reconciliation)
    }

    // MARK: Apply

    private func apply(changes: [InboundChange], deletions: [RecordKey], applier: RemoteApplier) async {
        guard !changes.isEmpty || !deletions.isEmpty else { return }
        let now = clock()
        for attempt in 0..<2 {
            let prepared: RemoteApplier.Prepared
            do {
                prepared = try await applier.prepare(changes: changes, deletions: deletions, now: now)
            } catch {
                syncLog.error("prepare failed: \(String(describing: error), privacy: .public)")
                status.lastErrorCategory = "prepare"
                return
            }
            for (key, reason) in prepared.rejected {
                syncLog.notice("rejected \(key.description, privacy: .public): \(reason, privacy: .public)")
                status.lastErrorCategory = "rejected"
            }
            guard !prepared.batch.isEmpty else { return }
            do {
                let outcome = try await syncStore.applyRemote(prepared.batch)
                await finish(outcome: outcome, prepared: prepared)
                return
            } catch let error as LibraryError {
                if Self.membershipRace(error), attempt == 0 {
                    // A local import or retirement raced preparation: rebuild membership before installing again.
                    for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
                    continue
                }
                for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
                syncLog.error("apply failed: \(String(describing: error), privacy: .public)")
                status.lastErrorCategory = "apply"
                return
            } catch {
                for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
                syncLog.error("apply failed: \(String(describing: error), privacy: .public)")
                status.lastErrorCategory = "apply"
                return
            }
        }
    }

    private static func membershipRace(_ error: LibraryError) -> Bool {
        switch error {
        case .duplicateContent, .membershipChanged: return true
        default: return false
        }
    }

    private func finish(outcome: RemoteApplyOutcome, prepared: RemoteApplier.Prepared) async {
        for id in outcome.deletedGameIDs {
            let fm = FileManager.default
            for dir in [location.directory(forGame: id), location.savesDirectory(forGame: id),
                        location.screenshotsDirectory.appending(path: id.description, directoryHint: .isDirectory),
                        location.artworkDirectory.appending(path: id.description, directoryHint: .isDirectory)] {
                try? fm.removeItem(at: dir)
            }
        }
        for state in outcome.deletedStates { saveStates.removeFilesOfDeleted(state) }
        // Keep only the cover file each game's committed value names.
        let artwork = ArtworkStore(location: location)
        for gameID in prepared.coverGames {
            guard let current = try? await store.games.customCover(for: gameID) else { continue }
            artwork.removeCustomCovers(for: gameID, keeping: current.fingerprint)
        }
        for gameID in outcome.gamesNeedingReconciliation { await reconcile(gameID) }
        if !outcome.createdGameIDs.isEmpty || !outcome.deletedGameIDs.isEmpty { await refreshConflicts() }
        applyGeneration += 1
    }

    private func reconcile(_ gameID: GameID) async {
        if runningGameID == gameID { pendingReconciliation.insert(gameID); return }
        do {
            let outcome = try await batterySaves.reconcile(gameID: gameID, now: clock())
            switch outcome {
            case .unchanged: break
            case .adopted(let r): conflictLog.info("adopted remote head \(r.id, privacy: .public) for \(gameID, privacy: .public)")
            case .joinedIdentical(let r): conflictLog.info("joined identical heads into \(r.id, privacy: .public) for \(gameID, privacy: .public)")
            case .conflict(let c): conflictLog.notice("two versions for \(gameID, privacy: .public): \(c.heads.count) heads")
            }
            if case .joinedIdentical = outcome { await transport?.requestSync(reason: .progressSaved) }
        } catch {
            conflictLog.error("reconcile failed for \(gameID, privacy: .public): \(String(describing: error), privacy: .public)")
            status.lastErrorCategory = "reconcile"
        }
        await refreshConflicts()
    }

    private func retryDeferred(applier: RemoteApplier, retryMembershipRace: Bool = true) async {
        guard let deferred = try? await syncStore.deferredRecords(), !deferred.isEmpty else { return }
        let rebuilt = applier.inboundChanges(fromDeferred: deferred)
        guard !rebuilt.isEmpty else { return }
        var prepared: RemoteApplier.Prepared
        do { prepared = try await applier.prepare(changes: rebuilt.map(\.1), deletions: [], now: clock(), retryingDeferred: true) } catch { return }
        // Records that became applicable are no longer deferred; the ones re-deferred replace themselves.
        let redeferred = Set(prepared.batch.deferred.map(\.key))
        // A refused cover cannot become valid later (its bytes are fixed): it leaves the store, logged.
        for (key, reason) in prepared.rejected where key.type == .artwork {
            syncLog.notice("deferred cover dropped \(key.description, privacy: .public): \(reason, privacy: .public)")
        }
        let rejected = Set(prepared.rejected.filter { $0.0.type != .artwork }.map { "\($0.0.type.rawValue):\($0.0.name)" })
        prepared.batch.resolvedDeferredKeys = rebuilt.map(\.0).filter { !redeferred.contains($0) && !rejected.contains($0) }
        prepared.batch.deferred = []   // keep the existing rows for the ones still waiting
        guard !prepared.batch.isEmpty else { return }
        do {
            let outcome = try await syncStore.applyRemote(prepared.batch)
            let resolved = deferred.filter { prepared.batch.resolvedDeferredKeys.contains($0.key) }
            applier.removeInboxAssets(of: resolved)
            await finish(outcome: outcome, prepared: prepared)
            if !resolved.isEmpty { await retryDeferred(applier: applier) }   // a resolved parent may unlock more
        } catch {
            for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
            if retryMembershipRace, let libraryError = error as? LibraryError, Self.membershipRace(libraryError) {
                await retryDeferred(applier: applier, retryMembershipRace: false)
                return
            }
            syncLog.error("deferred apply failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Merged mutable records are persisted so the next build from rows sends the merge.
    private func persistMerge(_ merged: SyncRecord) async {
        switch merged {
        case .game(let entry):
            guard var game = try? await store.games.game(fingerprint: entry.fingerprint), game.generation == entry.generation, game.systemID.rawValue == entry.systemID else { return }
            game.title = entry.title
            game.isFavorite = entry.isFavorite
            game.updatedAt = SyncTime.date(entry.updatedAt)
            try? await store.games.update(game)
        default:
            break
        }
    }

    // MARK: Counts and problems

    private func refreshCounts() async {
        // A cover waiting for a capable transport is not pending progress.
        let entries = (try? await syncStore.journal.pending(limit: 1, excluding: [.artwork])) ?? []
        status.pendingCount = (try? await syncStore.journal.pendingCount()) ?? 0
        status.pendingSince = entries.first?.createdAt
        let descriptors = (try? await syncStore.contentDescriptors()) ?? []
        var cloudOnly = 0
        var bytes: Int64 = 0
        for descriptor in descriptors {
            bytes += descriptor.sizeInBytes
            if let game = try? await store.games.game(fingerprint: descriptor.fingerprint),
               let files = try? await store.games.files(for: game.id), files.isEmpty { cloudOnly += 1 }
        }
        status.cloudOnlyCount = cloudOnly
        status.approximateCloudBytes = bytes
    }

    private func pendingSince(for fingerprint: ContentFingerprint) async -> Date? {
        // A cover waiting for a capable transport never makes its game look unsynced.
        let pending = (try? await syncStore.journal.pending(limit: 500, excluding: [.artwork])) ?? []
        var oldest: Date?
        for entry in pending {
            var matches = false
            switch entry.intent.kind {
            case .gameEntry, .contentIndex, .gameContent:
                matches = (try? SyncIntent.contentMembership(parsing: entry.intent.key).fingerprint) == fingerprint
            case .tombstone:
                matches = OutboundBuilder.tombstoneTarget(entry.intent.key) == .game(fingerprint)
            case .playSession:
                if let id = PlaySessionID(entry.intent.key), let session = try? await store.playHistory.session(id: id),
                   let game = try? await store.games.game(id: session.gameID) { matches = game.contentFingerprint == fingerprint }
            case .batteryRevision:
                if let id = BatteryRevisionID(entry.intent.key), let revision = try? await store.saves.batteryRevision(id: id),
                   let game = try? await store.games.game(id: revision.gameID) { matches = game.contentFingerprint == fingerprint }
            case .saveState:
                if let id = SaveStateID(entry.intent.key), let state = try? await store.saves.saveState(id: id),
                   let game = try? await store.games.game(id: state.gameID) { matches = game.contentFingerprint == fingerprint }
            case .artwork:
                matches = false
            }
            if matches { oldest = min(oldest ?? entry.createdAt, entry.createdAt) }
        }
        return oldest
    }

    /// Keeps the last few send/apply problems for diagnostics. Record type and
    /// classification only: never a key, a payload or an account identifier.
    private func note(problem: TransportProblem, for key: RecordKey) {
        let line = "\(key.type.rawValue):\(problem.description)"
        status.recentProblems.removeAll { $0 == line }
        status.recentProblems.insert(line, at: 0)
        if status.recentProblems.count > 5 { status.recentProblems.removeLast() }
    }

    private func setProblem(_ problem: SyncProblem?) {
        transportFailureNeedsSuccessfulPage = false
        guard let problem else { clearProblem(); return }
        if status.problem != problem { status.problemSince = clock() }
        status.problem = problem
    }

    private func clearProblem() {
        transportFailureNeedsSuccessfulPage = false
        status.problem = nil
        status.problemSince = nil
    }

    static func problem(for transport: TransportProblem) -> SyncProblem {
        switch transport {
        case .quotaFull: return .quotaFull
        case .accountUnavailable: return .accountUnavailable
        case .network, .rateLimited, .limitExceeded: return .network
        case .serverRecordChanged, .zoneMissing, .unknownItem, .invalidRecord, .other: return .failed(transport.description)
        }
    }

    static func worse(_ a: TransportProblem?, _ b: TransportProblem) -> TransportProblem {
        guard let a else { return b }
        func rank(_ p: TransportProblem) -> Int {
            switch p {
            case .quotaFull: return 3
            case .accountUnavailable: return 2
            case .network, .rateLimited, .limitExceeded: return 1
            default: return 0
            }
        }
        return rank(b) > rank(a) ? b : a
    }

    // MARK: Content (heavy, on demand)

    /// Uploads a game's content when game-file sync is on and the content is not already remote.
    public func uploadContent(gameID: GameID) async throws {
        guard status.isOperational, status.gameFilesEnabled, let transport else { return }
        guard runningGameID == nil else { return }
        guard activeContentRequests.insert(gameID).inserted else { return }
        defer { activeContentRequests.remove(gameID) }
        let epoch = transportEpoch
        guard beginTransportCallback(epoch: epoch) else { return }
        defer { endTransportCallback() }
        guard let game = try await store.games.game(id: gameID),
              let primary = try await store.games.files(for: gameID).first(where: { $0.role == .primary }) else { return }

        guard primary.sizeInBytes <= configuration.capabilities.maxGameContentSize else {
            syncLog.notice("content \(game.contentFingerprint.hexDigest.prefix(8), privacy: .public) exceeds the selected transport size limit; not uploaded")
            return
        }
        let key = RecordKey.gameContent(game.contentFingerprint, part: 0, generation: game.generation)
        let record = SyncGameContent(fingerprint: game.contentFingerprint, partIndex: 0, partCount: 1, partFingerprint: primary.fingerprint, partSize: primary.sizeInBytes, generation: game.generation)
        transfers[gameID] = ContentTransfer(gameID: gameID, direction: .upload, progress: 0)
        publish()
        defer { transfers[gameID] = nil }
        do {
            if try await transport.contentExists(key) == false {
                try await transport.uploadContent(.gameContent(record), fileURL: location.url(for: primary.location)) { [weak self] p in
                    Task { await self?.updateTransfer(gameID, progress: p, epoch: epoch) }
                }
            }
            guard epoch == transportEpoch else { throw CancellationError() }
            guard let current = try await store.games.game(id: gameID), current.generation == game.generation, (try await syncStore.retiredGeneration(for: game.contentFingerprint) ?? -1) < game.generation else { throw SyncContentError.unavailable }
            let descriptor = GameContentDescriptor.singleFile(fingerprint: game.contentFingerprint, sizeInBytes: primary.sizeInBytes,
                                                              fileName: LibraryLocation.sanitizedFileName(primary.originalFileName),
                                                              systemID: game.systemID, uploadedAt: clock(), generation: game.generation)
            try await syncStore.recordContentDescriptor(descriptor)
            failedGames[gameID] = nil
            await flushSoon()
        } catch {
            failedGames[gameID] = .failed("upload")
            syncLog.error("content upload failed for \(gameID, privacy: .public)")
            throw error
        }
    }

    /// Downloads, verifies and installs content already owned by the player.
    /// Recovery is Free and does not mutate the stored game-file-sync opt-in.
    public func downloadContent(gameID: GameID, ingestion: GameIngestion) async throws -> GameFile {
        guard status.isOperational, let transport else { throw SyncContentError.unavailable }
        guard activeContentRequests.insert(gameID).inserted else { throw SyncContentError.unavailable }
        defer { activeContentRequests.remove(gameID) }
        let epoch = transportEpoch
        guard beginTransportCallback(epoch: epoch) else { throw SyncContentError.unavailable }
        defer { endTransportCallback() }
        guard let game = try await store.games.game(id: gameID) else { throw LibraryError.gameNotFound(gameID) }
        guard let descriptor = try await syncStore.contentDescriptor(for: game.contentFingerprint) else { throw SyncContentError.notInCloud }
        guard descriptor.generation == game.generation else { throw SyncContentError.notInCloud }
        guard descriptor.parts.count == 1 else { throw SyncContentError.unsupportedLayout }
        transfers[gameID] = ContentTransfer(gameID: gameID, direction: .download, progress: 0)
        publish()
        defer { transfers[gameID] = nil; publish() }
        let key = RecordKey.gameContent(descriptor.fingerprint, part: 0, generation: descriptor.generation)
        do {
            guard let inbound = try await transport.fetchContent(key, progress: { [weak self] p in Task { await self?.updateTransfer(gameID, progress: p, epoch: epoch) } }) else {
                throw SyncContentError.notInCloud
            }
            defer { Task { await transport.releaseContent(inbound) } }
            guard case .gameContent(let content) = try SyncRecordValidator().validate(inbound.record),
                  let assetURL = inbound.assets[.data] else {
                throw SyncContentError.notInCloud
            }
            guard epoch == transportEpoch else { throw CancellationError() }
            guard content.generation == game.generation, inbound.key == key, content.fingerprint == descriptor.fingerprint, content.partFingerprint == descriptor.parts[0].fingerprint else {
                throw SyncContentError.verificationFailed
            }
            guard let current = try await store.games.game(id: gameID), current.generation == game.generation, (try await syncStore.retiredGeneration(for: game.contentFingerprint) ?? -1) < game.generation else { throw SyncContentError.unavailable }
            // Stage in Relay-owned storage before anything is verified or installed.
            let inbox = try location.makeSyncInboxDirectory()
            defer { try? FileManager.default.removeItem(at: inbox) }
            let staged = inbox.appending(path: LibraryLocation.sanitizedFileName(descriptor.fileName))
            try FileManager.default.copyItem(at: assetURL, to: staged)
            let file: GameFile
            do {
                file = try await ingestion.installDownloadedContent(gameID: gameID, stagedURL: staged, descriptor: descriptor)
            } catch GameIngestionError.contentMismatch {
                throw SyncContentError.verificationFailed
            }
            failedGames[gameID] = nil
            await refreshCounts()
            return file
        } catch {
            failedGames[gameID] = .failed("download")
            syncLog.error("content download failed for \(gameID, privacy: .public)")
            throw error
        }
    }

    private func updateTransfer(_ gameID: GameID, progress: Double, epoch: UInt64) {
        guard epoch == transportEpoch else { return }
        guard var transfer = transfers[gameID] else { return }
        transfer.progress = progress
        transfers[gameID] = transfer
        publish()
    }

    /// Delete from Library also removes the cloud content records this device knows about.
    public func contentWasDeleted(fingerprint: ContentFingerprint) async {
        await flushSoon()
    }

    /// Diagnostics: the pending journal, in order.
    public func pendingEntries(limit: Int = 200) async -> [SyncJournalEntry] {
        (try? await syncStore.journal.pending(limit: limit)) ?? []
    }

    public func deferredCount() async -> Int {
        (try? await syncStore.deferredRecords().count) ?? 0
    }
}

public enum SyncContentError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable
    case notInCloud
    case unsupportedLayout
    case verificationFailed

    public var description: String {
        switch self {
        case .unavailable: return "sync is not available"
        case .notInCloud: return "the content is not in iCloud"
        case .unsupportedLayout: return "multi-part content is not supported by this version"
        case .verificationFailed: return "the downloaded content did not verify"
        }
    }
}
