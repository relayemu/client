// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayLibrary
import RelaySync

/// Protocol 1.2.0 provider: semantic schema 3 (schema 2 plus custom-cover artwork), falling back to 2 for
/// the session when the server answers 426 naming 2. All semantic validation, conflicts and local writes remain in RelaySync.
public actor RelayHostedSyncTransport: SyncTransport {
    private struct Pending: Codable, Sendable {
        var key: RecordKey
        var journalIDs: [Int64]
        var operation: HostedOperation
        var terminal: Bool = false
        var accepted: Bool = false
        var deferred: Bool = false
    }
    private struct OutboundScan: Codable, Sendable {
        var afterSequence: Int64
        var throughSequence: Int64
    }
    private struct State: Codable, Sendable {
        // Optional for compatibility with transport files written before bounded journal rotation.
        var outboundScan: OutboundScan?
        var pending: [Pending] = []
        var content: [String: SyncContentIndex] = [:]
        var systems: [String: String] = [:]
        /// The cursor position through which artwork was received. Schema-2 pages skip artwork,
        /// so the range above this and below the cursor is replayed for artwork only under schema 3.
        /// Absent in state files written before covers synced: everything below the cursor.
        var artworkThrough: Int64?
    }
    private let http: HostedHTTPClient
    private let content: HostedContentClient
    private let accountIdentity: String
    private let scope: String
    private let stateURL: URL
    private let stagingRoot: URL
    private var assetsLease: HostedStagingDirectory?
    private let automaticSync: Bool
    private var state = State()
    private var loaded = false
    private var heavyCancellations: [UUID: @Sendable () -> Void] = [:]
    // The coordinator passes a generation-scoped proxy whose lifetime belongs
    // to the active transport. stop() releases it and breaks the ownership cycle.
    private var host: (any SyncTransportHost)?
    private var run: Task<Void, Error>?
    private var requestedDuringRun = false
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var writeBlocked = false
    private var status = TransportStatus(detail: "Relay Sync")

    public init(http: HostedHTTPClient, content: HostedContentClient, accountIdentity: String,
                installationID: InstallationID, stateDirectory: URL, automaticSync: Bool = true, environmentID: String = "preproduction", vaultWritable: Bool = true) throws {
        guard !environmentID.isEmpty, environmentID.count <= 256, !accountIdentity.isEmpty, accountIdentity.count <= 256 else { throw HostedHTTPError.invalidResponse }
        self.http = http; self.content = content; self.accountIdentity = accountIdentity
        self.automaticSync = automaticSync; self.writeBlocked = !vaultWritable
        let hash = try SHA256ContentHasher().hash(data: Data((environmentID + ":" + accountIdentity).utf8)).fingerprint.hexDigest
        self.scope = "relay-hosted-" + hash + ".schema2"
        let directory = stateDirectory.appendingPathComponent(hash, isDirectory: true)
        self.stagingRoot = directory.appendingPathComponent("Assets", isDirectory: true)
        // The canonical SQLite generation migration and reconciliation complete before start.
        // Preserve schema-1 receipts and checkpoints intact: new canonical intents get new UUIDs.
        self.stateURL = directory.appendingPathComponent("transport.schema2.json")
    }

    public func start(host: any SyncTransportHost) async throws {
        let epoch = generation
        // Local-only reclamation also runs when the account is read-only or no transfer follows.
        try await content.prepareStaging()
        guard generation == epoch else { throw CancellationError() }
        if assetsLease == nil {
            let root = stagingRoot
            let lease = try await Task.detached(priority: .utility) { try HostedStagingDirectory.acquire(in: root) }.value
            guard generation == epoch else { throw CancellationError() }
            if assetsLease == nil { assetsLease = lease }
        } else {
            let root = stagingRoot
            _ = try await Task.detached(priority: .utility) { try HostedStagingDirectory.reclaimAbandoned(in: root) }.value
            guard generation == epoch else { throw CancellationError() }
        }
        if !loaded {
            let stateURL = stateURL
            let restored = try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
                let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else { throw HostedHTTPError(status: 413, problem: .limitExceeded) }
                // Corruption must not discard uncertain operation UUIDs. Preserve the file for repair.
                do { return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) }
                catch { throw HostedHTTPError.invalidResponse }
            }.value
            guard generation == epoch else { throw CancellationError() }
            guard restored.pending.allSatisfy({ pending in
                (SyncSchema.version...SyncSchema.artwork).contains(pending.operation.schema)
                    && (pending.operation.kind != "artwork" || pending.operation.schema >= SyncSchema.artwork)
                    && pending.operation.object["generation"]?.integer.map { (0...2_147_483_647).contains($0) } == true
            }) else { throw HostedHTTPError.invalidResponse }
            state = restored; loaded = true
        }
        self.host = host
        await host.accountDidChange(AccountChange(availability: .available, identity: accountIdentity))
        guard generation == epoch, self.host != nil else { throw CancellationError() }
        await host.transportDidUpdate(status)
    }
    public func stop() async {
        generation += 1
        retry?.cancel(); retry = nil
        for cancel in heavyCancellations.values { cancel() }
        heavyCancellations.removeAll()
        run?.cancel()
        // Keep the Assets lease alive: cancellation does not join detached state-file work,
        // and admitted host callbacks may still be copying those files. Its final owner releases it.
        run = nil; host = nil; requestedDuringRun = false
    }
    public func resetState() async {
        // Account namespaces isolate state. Preserve operation UUIDs even when tokens reset;
        // replaying from the durable semantic cursor remains safe.
        writeBlocked = false; failures = 0
    }
    public func requestSync(reason: SyncReason) async {
        guard automaticSync, host != nil else { return }
        if run != nil { requestedDuringRun = true; return }
        // Events trigger one bounded pass. The task owns itself; no view must stay alive.
        Task { [weak self] in try? await self?.synchronize() }
    }
    public func synchronize() async throws {
        if let run { return try await run.value }
        guard host != nil else { throw HostedHTTPError(status: 401, problem: .accountUnavailable) }
        let epoch = generation
        let task = Task { try await self.performPass(epoch: epoch) }
        run = task
        defer { if generation == epoch { run = nil } }
        do {
            try await task.value; failures = 0
            if requestedDuringRun && automaticSync { requestedDuringRun = false; scheduleContinuation(after: 1) }
        }
        catch {
            if !(error is CancellationError) {
                let problem = (error as? HostedHTTPError)?.problem ?? .invalidRecord("hosted sync")
                status.isSyncing = false; status.isFetching = false; status.lastProblem = problem
                await host?.transportDidUpdate(status)
                if (error as? HostedHTTPError)?.status == 401 {
                    await host?.accountDidChange(AccountChange(availability: .noAccount, identity: nil))
                } else if problem.isTransient && automaticSync {
                    failures = min(failures + 1, 8)
                    let delay = max((error as? HostedHTTPError)?.retryAfterSeconds ?? 0, min(300, 1 << failures))
                    retry?.cancel()
                    retry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation(); try await self?.synchronize() }
                        catch { }
                    }
                }
            }
            throw error
        }
    }
    public func fetchNow() async throws {
        if let run { return try await run.value }
        guard host != nil else { throw HostedHTTPError(status: 401, problem: .accountUnavailable) }
        let epoch = generation
        let task = Task { try await self.pull(epoch: epoch) }
        run = task
        defer { if generation == epoch { run = nil } }
        try await task.value
        if requestedDuringRun && automaticSync { requestedDuringRun = false; scheduleContinuation(after: 1) }
    }
    private func ensureActive(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == generation, host != nil else { throw CancellationError() }
    }
    private func persist() throws { try AtomicFile().write(HostedWireCodec.encoded(state), to: stateURL) }

    private func performPass(epoch: Int) async throws {
        try ensureActive(epoch)
        status.isSyncing = true; status.lastProblem = nil
        await host?.transportDidUpdate(status)
        // Pull first reconciles remote tombstones/progress before this provider sees local intents.
        try await pull(epoch: epoch)
        if !writeBlocked {
            do { try await push(epoch: epoch) }
            catch let error as HostedHTTPError where error.status == 423 {
                writeBlocked = true; status.lastProblem = .other("vaultReadOnly")
            }
        }
        try await pull(epoch: epoch)
        status.isSyncing = false
        await host?.transportDidUpdate(status)
        if automaticSync && state.pending.contains(where: { $0.deferred && !$0.terminal }) {
            retry?.cancel()
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)); try Task.checkCancellation(); try await self?.synchronize() }
                catch { }
            }
        }
    }

    /// Called after a fresh account overview. Recovery is read-only; local data is untouched.
    public func setVaultWritable(_ writable: Bool) { writeBlocked = !writable }

    /// Custom covers travel only while this session speaks schema 3.
    public nonisolated var sendsArtwork: Bool {
        get async { http.negotiatedSchema >= SyncSchema.artwork }
    }

    /// Operations wait with the schema they were first sent under, so a replay is byte-identical.
    /// When the session falls back below that schema, an unconfirmed operation is rebuilt instead:
    /// a journaled one from its journal row, a journal-less availability removal under a new UUID.
    /// Artwork cannot be expressed below schema 3 and waits in the journal.
    private func reconcilePendingSchema() {
        let negotiated = http.negotiatedSchema
        state.pending = state.pending.compactMap { item in
            guard !item.accepted, !item.terminal, item.operation.schema > negotiated else { return item }
            guard item.journalIDs.isEmpty, item.operation.kind != "artwork" else { return nil }
            var rebuilt = item
            rebuilt.operation.schema = negotiated; rebuilt.operation.operationId = UUID().uuidString.lowercased(); rebuilt.deferred = false
            return rebuilt
        }
    }

    private func push(epoch: Int) async throws {
        guard let host else { throw CancellationError() }
        reconcilePendingSchema()
        // Retry uncertain/deferred operations in bounded batches, with their original bytes and IDs.
        let prior = Array(state.pending.filter { !$0.terminal && !$0.accepted }.prefix(100))
        let retried = try await submitBatch(prior, epoch: epoch)
        var heldFailures: [SendResult] = []
        var deferredContent = false
        var active: [OutboundChange] = []
        do {
            // The durable scan cursor advances through raw journal rows, including failures
            // that build no change. A frozen ceiling bounds each round even as new rows arrive.
            // Failures remain journaled; advancing this scheduling cursor never acknowledges them.
            for pageNumber in 0..<10 {
                try ensureActive(epoch)
                let scan = state.outboundScan
                let after = scan?.afterSequence ?? 0
                let page = try await host.nextHostedOutboundPage(afterSequence: after,
                    throughSequence: scan?.throughSequence, limit: 100)
                try ensureActive(epoch)
                guard page.nextAfterSequence >= after, page.throughSequence >= page.nextAfterSequence,
                      scan == nil || scan?.throughSequence == page.throughSequence,
                      !page.hasMore || page.nextAfterSequence > after, page.changes.count <= 100 else {
                    throw HostedHTTPError.invalidResponse
                }
                active = page.changes
                var ready: [Pending] = []
                for change in active {
                    try ensureActive(epoch)
                    if let prior = state.pending.first(where: { $0.key == change.key && $0.journalIDs == change.journalIDs }) {
                        if prior.terminal {
                            heldFailures.append(SendResult(key: change.key, outcome: .failed(.invalidRecord("hosted payload rejected; repair required"), serverRecord: nil)))
                        } else if prior.accepted {
                            await host.didSend([SendResult(key: change.key, outcome: .saved)])
                        } else if retried[prior.operation.operationId] == "deferred" {
                            heldFailures.append(SendResult(key: change.key, outcome: .failed(.rateLimited(retryAfterSeconds: 60), serverRecord: nil)))
                        } else { ready.append(prior) }
                        continue
                    }
                    let schema = http.negotiatedSchema
                    if change.key.type == .artwork && schema < SyncSchema.artwork {
                        // The session fell back after this page was read: the cover waits, quietly.
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(.rateLimited(retryAfterSeconds: 60), serverRecord: nil)))
                        continue
                    }
                    do {
                        if try await releaseWithdrawn(change, host: host, epoch: epoch) { continue }
                        let operation: HostedOperation
                        switch change.payload {
                        case .save(let record, let assets):
                            let screenshot = try await uploadAssets(record, assets: assets, epoch: epoch)
                            operation = try HostedWireCodec.encode(record, operationID: UUID(), schema: schema, screenshot: screenshot)
                        case .delete:
                            // State deletion must arrive as a canonical tombstone. Legacy raw
                            // deletion intents are migrated by the repository, never forged here.
                            guard change.key.type != .state else {
                                let problem = TransportProblem.invalidRecord("state deletion requires canonical tombstone")
                                heldFailures.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                                status.lastProblem = problem
                                continue
                            }
                            operation = try availabilityRemoval(change.key)
                        }
                        // Uploads yield to gameplay. Retention may withdraw this exact
                        // intent while its payload is transferring; the tombstone has
                        // its own later journal ID and must still be sent normally.
                        if try await releaseWithdrawn(change, host: host, epoch: epoch) { continue }
                        let pending = Pending(key: change.key, journalIDs: change.journalIDs, operation: operation)
                        state.pending.append(pending)
                        ready.append(pending)
                    } catch where Self.isMissingLocalAsset(error) {
                        // Close the race between the membership check and opening a
                        // canonical URL. Missing bytes alone never prove deletion.
                        if try await releaseWithdrawn(change, host: host, epoch: epoch) { continue }
                        let problem = TransportProblem.invalidRecord("local asset is missing; repair required")
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                        status.lastProblem = problem
                    } catch let error as HostedHTTPError where error.code == "content_generation_future" {
                        // Keep scanning so this pass can send the retirement prerequisite.
                        // No operation UUID exists until the payload can attach to its membership.
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(error.problem, serverRecord: nil)))
                        status.lastProblem = error.problem; deferredContent = true
                    } catch let error as HostedHTTPError where error.problem.isTransient == false && error.status != 401 && error.status != 403 && error.status != 423 {
                        // A malformed local payload must not starve unrelated later journal rows.
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(error.problem, serverRecord: nil)))
                        status.lastProblem = error.problem
                    } catch is SyncValidationError {
                        let problem = TransportProblem.invalidRecord("local semantic record requires repair")
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                        status.lastProblem = problem
                    } catch let error as HostedContentError {
                        switch error {
                        case .transferFailed, .verificationTimedOut: throw HostedHTTPError(problem: .network)
                        default:
                            let problem = TransportProblem.invalidRecord("hosted content requires repair")
                            heldFailures.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                            status.lastProblem = problem
                        }
                    } catch is ContentHashingError {
                        let problem = TransportProblem.invalidRecord("local content requires repair")
                        heldFailures.append(SendResult(key: change.key, outcome: .failed(problem, serverRecord: nil)))
                        status.lastProblem = problem
                    }
                }
                if !ready.isEmpty { try persist() }
                let results = try await submitBatch(ready, epoch: epoch)
                for item in ready {
                    guard let result = results[item.operation.operationId] else { throw HostedHTTPError.invalidResponse }
                    if result == "rejected" {
                        heldFailures.append(SendResult(key: item.key, outcome: .failed(.invalidRecord("hosted payload rejected; repair required"), serverRecord: nil)))
                    } else if result == Self.reupload {
                        heldFailures.append(SendResult(key: item.key, outcome: .failed(.rateLimited(retryAfterSeconds: 60), serverRecord: nil)))
                    } else if result == "deferred" {
                        heldFailures.append(SendResult(key: item.key, outcome: .failed(.rateLimited(retryAfterSeconds: 60), serverRecord: nil)))
                    } else {
                        await host.didSend([SendResult(key: item.key, outcome: .saved)])
                    }
                }
                try ensureActive(epoch)
                state.outboundScan = page.hasMore
                    ? OutboundScan(afterSequence: page.nextAfterSequence, throughSequence: page.throughSequence)
                    : nil
                try persist()
                active = []
                if !page.hasMore { break } // Do not wrap and retry this round's failures in the same pass.
                if pageNumber == 9 && automaticSync { scheduleContinuation(after: 30) }
            }
            await host.didSend(heldFailures)
            try await compactReceipts(host: host)
            if deferredContent && automaticSync { scheduleContinuation(after: 60) }
        } catch {
            let problem = (error as? HostedHTTPError)?.problem ?? .invalidRecord("hosted asset or record")
            let heldKeys = Set(heldFailures.map(\.key))
            await host.didSend(heldFailures + active.filter { !heldKeys.contains($0.key) }.map { SendResult(key: $0.key, outcome: .failed(problem, serverRecord: nil)) })
            throw error
        }
    }

    /// The host acknowledges only the journal IDs captured when this change was
    /// admitted. A successful throwing read is required before releasing them.
    private func releaseWithdrawn(_ change: OutboundChange, host: any SyncTransportHost, epoch: Int) async throws -> Bool {
        guard !change.journalIDs.isEmpty else { return false }
        let pending = try await host.hostedPendingJournalIDs(in: change.journalIDs)
        try ensureActive(epoch)
        guard pending.isEmpty else { return false }
        await host.didSend([SendResult(key: change.key, outcome: .deleted)])
        try ensureActive(epoch)
        return true
    }

    private static func isMissingLocalAsset(_ error: any Error) -> Bool {
        if case ContentHashingError.fileNotFound = error { return true }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain &&
            (cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError)
    }

    /// Only a successful throwing membership read proves journal acknowledgement durable.
    private func compactReceipts(host: any SyncTransportHost) async throws {
        let accepted = state.pending.filter { $0.accepted && !$0.journalIDs.isEmpty }
        let ids = Array(Set(accepted.flatMap(\.journalIDs)))
        guard !ids.isEmpty else { return }
        var pendingIDs = Set<Int64>()
        for start in stride(from: 0, to: ids.count, by: 10_000) {
            pendingIDs.formUnion(try await host.hostedPendingJournalIDs(in: Array(ids[start..<min(start + 10_000, ids.count)])))
        }
        state.pending.removeAll { item in
            item.accepted && !item.journalIDs.isEmpty && Set(item.journalIDs).isDisjoint(with: pendingIDs)
        }
        try persist()
    }

    private func scheduleContinuation(after seconds: Int) {
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation(); try await self?.synchronize() }
            catch { }
        }
    }

    /// One request may carry 100 operations, but the encoded body remains below 1 MiB.
    /// The durable snapshot predates every send; responses update receipts before journal acknowledgement.
    @discardableResult private func submitBatch(_ pending: [Pending], epoch: Int) async throws -> [String: String] {
        struct Request: Encodable { let operations: [HostedOperation] }
        var remaining = pending[...], results: [String: String] = [:]
        while !remaining.isEmpty {
            // One request carries one schema, the one its operations were built under.
            let schema = remaining.first!.operation.schema
            guard (SyncSchema.version...SyncSchema.artwork).contains(schema) else { throw HostedHTTPError.invalidResponse }
            var batch: [Pending] = [], budget = 32
            for item in remaining.prefix(100) {
                guard item.operation.schema == schema else { break }
                let size = try HostedWireCodec.encoded(item.operation).count
                guard size <= 65_536 else { throw HostedHTTPError(status: 413, problem: .limitExceeded) }
                if budget + size + 1 > 1_048_576 { break }
                budget += size + 1; batch.append(item)
            }
            guard !batch.isEmpty else { throw HostedHTTPError(status: 413, problem: .limitExceeded) }
            let response: HostedPushResponse = try await http.request(method: "POST", path: "/v1/sync/push",
                body: HostedWireCodec.encoded(Request(operations: batch.map(\.operation))), schema: schema, as: HostedPushResponse.self)
            try ensureActive(epoch)
            let expected = Set(batch.map { $0.operation.operationId })
            guard response.results.count == batch.count,
                  Set(response.results.map(\.operationId)) == expected else { throw HostedHTTPError.invalidResponse }
            guard response.results.allSatisfy({ result in
                ["applied", "duplicate", "ignored", "deferred", "rejected"].contains(result.status)
                    && (result.sequence == nil || result.sequence! > 0)
                    && state.pending.contains(where: { $0.operation.operationId == result.operationId })
            }) else { throw HostedHTTPError.invalidResponse }
            for result in response.results {
                guard let index = state.pending.firstIndex(where: { $0.operation.operationId == result.operationId }) else { throw HostedHTTPError.invalidResponse }
                if result.status == "rejected", result.error == Self.coverNotOwned, state.pending[index].operation.kind == "artwork" {
                    // The server no longer holds this account's reference to the image (released or
                    // collected after upload). Not terminal: the journal row rebuilds and re-uploads.
                    state.pending.remove(at: index)
                    results[result.operationId] = Self.reupload
                    continue
                }
                state.pending[index].terminal = result.status == "rejected"
                state.pending[index].accepted = result.status != "rejected" && result.status != "deferred"
                state.pending[index].deferred = result.status == "deferred"
                results[result.operationId] = result.status
                if result.status == "rejected" { status.lastProblem = .invalidRecord("hosted payload rejected; repair required") }
            }
            state.pending.removeAll { $0.accepted && $0.journalIDs.isEmpty }
            try persist()
            status.lastPushAt = Date()
            remaining = remaining.dropFirst(batch.count)
        }
        return results
    }

    private static let coverNotOwned = "verified artwork is not owned"
    private static let reupload = "reupload"

    private func pull(epoch: Int) async throws {
        guard let host else { throw CancellationError() }
        status.isFetching = true
        await host.transportDidUpdate(status)
        defer { status.isFetching = false }
        var cursor = try await host.hostedCursor(scope: scope)
        var hasMore = false
        guard cursor >= 0 else { throw HostedHTTPError.invalidResponse }
        if http.negotiatedSchema >= SyncSchema.artwork { try await catchUpArtwork(through: cursor, host: host, epoch: epoch) }
        // A page is intentionally small: save assets are fetched sequentially, keeping memory bounded.
        for _ in 0..<20 {
            try ensureActive(epoch)
            let (page, served) = try await http.negotiatedRequest(method: "GET", path: "/v1/sync/changes?cursor=\(cursor)&limit=50", as: HostedChangesPage.self)
            try ensureActive(epoch)
            guard page.schema == served, page.changes.count <= 50, page.nextCursor >= cursor,
                  !page.hasMore || !page.changes.isEmpty else { throw HostedHTTPError.invalidResponse }
            var previous = cursor
            var inbound: [InboundChange] = [], deletions: [RecordKey] = [], temporary: [URL] = []
            defer { for url in temporary { discardAsset(url) } }
            for change in page.changes {
                guard change.sequence > previous, change.sequence <= page.nextCursor else { throw HostedHTTPError.invalidResponse }
                previous = change.sequence
                let fp = change.object["fingerprint"]?.string ?? ""
                let membership = (try? ContentFingerprint(parsing: fp)).map { RecordKey.game($0, generation: change.object["generation"]?.integer ?? -1).name } ?? ""
                let decoded = try HostedWireCodec.decode(change, schema: page.schema, gameSystemID: state.systems[membership] ?? "unknown")
                if let record = decoded.record {
                    do {
                        let assets = try await downloadAssets(record, screenshot: decoded.screenshot, epoch: epoch)
                        temporary.append(contentsOf: assets.values)
                        inbound.append(InboundChange(key: record.key, record: record, assets: assets))
                    } catch let error as HostedHTTPError where error.status == 404 && record.key.type == .artwork {
                        // A cover is released only when a later value replaced it; that value follows in the feed.
                        continue
                    } catch let error as HostedHTTPError where error.status == 404 {
                        // A deletion can release an old blob while its earlier metadata is still
                        // in the feed. Only a validated, covering tombstone permits skipping it.
                        guard let tombstone = try await coveringTombstone(for: record, startingAt: cursor, epoch: epoch) else { throw error }
                        inbound.append(InboundChange(key: tombstone.key, record: tombstone))
                    }
                    if case .game(let game) = record { state.systems[RecordKey.game(game.fingerprint, generation: game.generation).name] = game.systemID }
                    if case .contentIndex(let index) = record { state.content[RecordKey.contentIndex(index.fingerprint, generation: index.generation).name] = index }
                    if case .tombstone(let tombstone) = record, tombstone.targetKind == "game" {
                        state.content = state.content.filter { $0.value.fingerprint.description != tombstone.targetKey || $0.value.generation > tombstone.generation }
                    }
                }
                if let deletion = decoded.deletion {
                    deletions.append(deletion)
                    state.content = state.content.filter { RecordKey.contentIndex($0.value.fingerprint, generation: $0.value.generation) != deletion }
                }
            }
            guard page.nextCursor == previous else { throw HostedHTTPError.invalidResponse }
            // Cache may lead the semantic cursor after a crash, but never trails it. Replay repairs it.
            try persist()
            try ensureActive(epoch)
            try await host.applyHostedPage(changes: inbound, deletions: deletions, cursor: page.nextCursor, scope: scope)
            if page.schema >= SyncSchema.artwork, (state.artworkThrough ?? 0) >= cursor {
                // Contiguous with what was already received: artwork is complete through this page.
                state.artworkThrough = max(state.artworkThrough ?? 0, page.nextCursor); try persist()
            }
            cursor = page.nextCursor; hasMore = page.hasMore
            if !page.hasMore { break }
        }
        if hasMore && automaticSync { scheduleContinuation(after: 30) }
        status.lastPullAt = Date(); status.isFetching = false
        await host.transportDidUpdate(status)
    }

    /// Replays the range schema-2 pages skipped, applying only its artwork: every other kind in
    /// it was already applied, and the semantic cursor does not move. Bounded per pass; the rest
    /// continues on the next one. A cover released since is superseded later in the same range.
    private func catchUpArtwork(through cursor: Int64, host: any SyncTransportHost, epoch: Int) async throws {
        var from = state.artworkThrough ?? 0
        guard from < cursor else { return }
        for _ in 0..<20 {
            try ensureActive(epoch)
            let (page, served) = try await http.negotiatedRequest(method: "GET", path: "/v1/sync/changes?cursor=\(from)&limit=50", as: HostedChangesPage.self)
            try ensureActive(epoch)
            guard served >= SyncSchema.artwork else { return } // The session fell back: nothing to receive.
            guard page.schema == served, page.changes.count <= 50, page.nextCursor >= from,
                  !page.hasMore || !page.changes.isEmpty else { throw HostedHTTPError.invalidResponse }
            var previous = from
            var latest: [String: HostedChange] = [:]
            for change in page.changes {
                guard change.sequence > previous, change.sequence <= page.nextCursor else { throw HostedHTTPError.invalidResponse }
                previous = change.sequence
                if change.sequence <= cursor, change.kind == "artwork" { latest[change.objectKey] = change }
            }
            guard page.nextCursor == previous else { throw HostedHTTPError.invalidResponse }
            var inbound: [InboundChange] = [], temporary: [URL] = []
            defer { for url in temporary { discardAsset(url) } }
            for change in latest.values.sorted(by: { $0.sequence < $1.sequence }) {
                guard let record = try HostedWireCodec.decode(change, schema: page.schema).record else { continue }
                do {
                    let assets = try await downloadAssets(record, screenshot: nil, epoch: epoch)
                    temporary.append(contentsOf: assets.values)
                    inbound.append(InboundChange(key: record.key, record: record, assets: assets))
                } catch let error as HostedHTTPError where error.status == 404 { continue }
            }
            if !inbound.isEmpty {
                try await host.applyHostedPage(changes: inbound, deletions: [], cursor: cursor, scope: scope)
            }
            from = min(page.nextCursor, cursor)
            if !page.hasMore { from = cursor }
            state.artworkThrough = from; try persist()
            if from >= cursor { return }
        }
    }

    private func coveringTombstone(for record: SyncRecord, startingAt: Int64, epoch: Int) async throws -> SyncRecord? {
        let stateID: String?
        switch record {
        case .batteryRevision: stateID = nil
        case .state(let r): stateID = r.stateID.description
        case .session: stateID = nil
        default: return nil
        }
        var cursor = startingAt
        for _ in 0..<100 {
            try ensureActive(epoch)
            let (page, served) = try await http.negotiatedRequest(method: "GET", path: "/v1/sync/changes?cursor=\(cursor)&limit=500", as: HostedChangesPage.self)
            guard page.schema == served, page.changes.count <= 500, page.nextCursor >= cursor, !page.hasMore || !page.changes.isEmpty else { throw HostedHTTPError.invalidResponse }
            var previous = cursor
            for change in page.changes {
                guard change.sequence > previous, change.sequence <= page.nextCursor else { throw HostedHTTPError.invalidResponse }
                previous = change.sequence
                guard change.kind == "tombstone", case .tombstone(let tombstone)? = try HostedWireCodec.decode(change, schema: page.schema).record else { continue }
                if (tombstone.targetKind == "game" && tombstone.targetKey == record.gameFingerprint?.description && tombstone.generation >= record.generation)
                    || (tombstone.targetKind == "state" && tombstone.targetKey == stateID) {
                    return .tombstone(tombstone)
                }
            }
            guard page.nextCursor == previous else { throw HostedHTTPError.invalidResponse }
            if !page.hasMore { return nil }
            cursor = page.nextCursor
        }
        // Stop rather than silently skip live data when the bounded lookahead is exhausted.
        throw HostedHTTPError(status: 413, problem: .limitExceeded)
    }

    private func discardAsset(_ url: URL) {
        if let directory = assetsLease?.directory,
           url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        } else {
            let content = content
            Task { await content.discardDownloadedFile(url) }
        }
    }

    private func uploadAssets(_ record: SyncRecord, assets: [SyncAssetName: URL], epoch: Int) async throws -> ContentFingerprint? {
        if case .artwork(let r) = record {
            // The account must own the normalized image before the value names it. A reset names none.
            guard let cover = r.artworkFingerprint else { return nil }
            guard let source = assets[.data], let size = r.artworkSize else { throw HostedHTTPError.invalidResponse }
            try await content.upload(fileURL: source, fingerprint: cover, byteCount: size, storageClass: .critical,
                target: HostedContentTarget(category: "screenshots_other", refType: "game_artwork", refKey: cover.description,
                                            gameFingerprint: r.fingerprint, generation: r.generation), progress: { _ in })
            try ensureActive(epoch)
            return nil
        }
        let id: String
        let payload: (SyncAssetName, ContentFingerprint, Int64, String)?
        let screenshotType: String
        switch record {
        case .batteryRevision(let r):
            id = r.revisionID.description; payload = (.data, r.dataFingerprint, r.dataSize, "battery_payload"); screenshotType = "battery_screenshot"
        case .state(let r):
            id = r.stateID.description; payload = (.payload, r.payloadFingerprint, r.payloadSize, "save_state_payload"); screenshotType = "save_state_screenshot"
        case .session(let r): id = r.sessionID.description; payload = nil; screenshotType = "session_screenshot"
        default: return nil
        }
        guard let gameFingerprint = record.gameFingerprint else { throw HostedHTTPError.invalidResponse }
        if let (name, fp, size, type) = payload {
            guard let source = assets[name] else { throw HostedHTTPError.invalidResponse }
            var uploadURL = source
            if name == .payload {
                guard let lease = assetsLease else { throw CancellationError() }
                let target = lease.directory.appendingPathComponent(UUID().uuidString)
                let stateRecord = record
                try await Task.detached(priority: .utility) { [lease] in
                    defer { withExtendedLifetime(lease) {} }
                    let container = try SaveStateContainer.decode(Data(contentsOf: source, options: .mappedIfSafe))
                    guard case .state(let state) = stateRecord, container.header.payloadFingerprint == state.payloadFingerprint,
                          container.payload.count == state.payloadSize,
                          container.header.gameFingerprint == state.fingerprint,
                          container.header.coreID.rawValue == state.coreID,
                          container.header.coreVersion == state.coreVersion,
                          container.header.effectiveCompatibilityVersion == state.stateCompatibilityVersion,
                          container.header.formatVersion == state.formatVersion,
                          container.header.createdAtMillis == state.createdAt,
                          container.header.kind.rawValue == state.kind else { throw HostedHTTPError.invalidResponse }
                    try AtomicFile().write(container.payload, to: target)
                }.value
                uploadURL = target
            }
            defer { if uploadURL != source { try? FileManager.default.removeItem(at: uploadURL) } }
            try await content.upload(fileURL: uploadURL, fingerprint: fp, byteCount: size, storageClass: .critical,
                target: HostedContentTarget(category: "saves_states", refType: type, refKey: id, gameFingerprint: gameFingerprint, generation: record.generation), progress: { _ in })
            try ensureActive(epoch)
        }
        if let source = assets[.screenshot] {
            let hashed = try await SHA256ContentHasher().hash(fileAt: source)
            guard hashed.sizeInBytes > 0, hashed.sizeInBytes <= SyncLimits.maxScreenshotSize else { throw HostedHTTPError.invalidResponse }
            try await content.upload(fileURL: source, fingerprint: hashed.fingerprint, byteCount: hashed.sizeInBytes, storageClass: .critical,
                target: HostedContentTarget(category: "screenshots_other", refType: screenshotType, refKey: id, gameFingerprint: gameFingerprint, generation: record.generation), progress: { _ in })
            try ensureActive(epoch)
            return hashed.fingerprint
        }
        return nil
    }

    private func downloadAssets(_ record: SyncRecord, screenshot: ContentFingerprint?, epoch: Int) async throws -> [SyncAssetName: URL] {
        var assets: [SyncAssetName: URL] = [:]
        do {
            switch record {
            case .batteryRevision(let r):
                assets[.data] = try await content.download(fingerprint: r.dataFingerprint, byteCount: r.dataSize, progress: { _ in })
            case .state(let r):
                let raw = try await content.download(fingerprint: r.payloadFingerprint, byteCount: r.payloadSize, progress: { _ in })
                defer { discardAsset(raw) }
                guard let lease = assetsLease else { throw CancellationError() }
                let destination = lease.directory.appendingPathComponent(UUID().uuidString + ".relaystate")
                try await Task.detached(priority: .utility) { [lease] in
                    defer { withExtendedLifetime(lease) {} }
                    let payload = try Data(contentsOf: raw, options: .mappedIfSafe)
                    // Header's local GameID is deliberately inert; installRemote uses the game fingerprint.
                    let header: [String: HostedJSON] = ["formatVersion": .integer(Int64(r.formatVersion)), "gameID": .string(UUID().uuidString.lowercased()),
                        "gameFingerprint": .string(r.fingerprint.description), "coreID": .string(r.coreID), "coreVersion": .string(r.coreVersion),
                        "stateCompatibilityVersion": .string(r.stateCompatibilityVersion), "kind": .string(r.kind), "createdAtMillis": .integer(r.createdAt),
                        "payloadLength": .integer(r.payloadSize), "payloadFingerprint": .string(r.payloadFingerprint.description)]
                    let typed = try JSONDecoder().decode(SaveStateContainer.Header.self, from: HostedWireCodec.encoded(header))
                    try AtomicFile().write(SaveStateContainer(header: typed, payload: payload).encoded(), to: destination)
                }.value
                assets[.payload] = destination
            case .artwork(let r):
                // Verified here for size and SHA-256; RemoteApplier also requires a decodable HEIC.
                if let cover = r.artworkFingerprint {
                    assets[.data] = try await content.download(fingerprint: cover, byteCount: r.artworkSize,
                        maximumByteCount: SyncLimits.maxArtworkSize, progress: { _ in })
                }
            default: break
            }
            try ensureActive(epoch)
            if let screenshot {
                do {
                    assets[.screenshot] = try await content.download(fingerprint: screenshot, byteCount: nil,
                        maximumByteCount: SyncLimits.maxScreenshotSize, progress: { _ in })
                } catch let error as HostedHTTPError where error.status == 404 {
                    // Screenshots are optional decoration. Later session updates can release old
                    // screenshot references without deleting any progress or the session itself.
                }
            }
            return assets
        } catch {
            for url in assets.values { discardAsset(url) }
            throw error
        }
    }

    public func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !writeBlocked, case .gameContent(let r) = record, r.partIndex == 0, r.partCount == 1,
              r.partFingerprint == r.fingerprint else { throw HostedHTTPError.invalidResponse }
        let id = UUID(), epoch = generation, content = content
        let task = Task {
            try await content.upload(fileURL: fileURL, fingerprint: r.partFingerprint, byteCount: r.partSize, storageClass: .game,
                target: HostedContentTarget(category: "games", refType: "game_content", refKey: r.fingerprint.description, gameFingerprint: r.fingerprint, generation: r.generation), progress: progress)
        }
        heavyCancellations[id] = { task.cancel() }
        defer { heavyCancellations[id] = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try ensureActive(epoch)
    }
    public func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? {
        guard let index = state.content.values.first(where: { .gameContent($0.fingerprint, part: 0, generation: $0.generation) == key }) else { return nil }
        let id = UUID(), epoch = generation, content = content
        let task = Task { try await content.download(fingerprint: index.fingerprint, byteCount: index.size, progress: progress) }
        heavyCancellations[id] = { task.cancel() }
        defer { heavyCancellations[id] = nil }
        let url = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try ensureActive(epoch) }
        catch { await content.discardDownloadedFile(url); throw error }
        let record = SyncRecord.gameContent(SyncGameContent(fingerprint: index.fingerprint, partIndex: 0, partCount: 1,
            partFingerprint: index.fingerprint, partSize: index.size, generation: index.generation))
        return InboundChange(key: key, record: record, assets: [.data: url])
    }
    public func releaseContent(_ change: InboundChange) async {
        for url in change.assets.values { await content.discardDownloadedFile(url) }
    }
    public func contentExists(_ key: RecordKey) async throws -> Bool {
        guard key.type == .gameContent else { throw HostedHTTPError.invalidResponse }
        let (fingerprint, membershipGeneration) = try contentMembership(key)
        // Physical ownership alone does not prove attachment to this incarnation.
        guard state.content.values.contains(where: { $0.fingerprint == fingerprint && $0.generation == membershipGeneration }) else { return false }
        do {
            let owned: HostedDownloadAuthorization = try await http.request(method: "GET", path: "/v1/content/downloads/" + fingerprint.hexDigest, as: HostedDownloadAuthorization.self)
            guard owned.size > 0, owned.size <= SyncLimits.maxContentSize else { throw HostedHTTPError.invalidResponse }
            _ = try owned.download.request(method: "GET")
            return true
        } catch let error as HostedHTTPError where error.status == 404 { return false }
    }
    public func deleteContent(_ key: RecordKey) async throws {
        guard !writeBlocked else { throw HostedHTTPError(status: 423, problem: .other("vaultReadOnly")) }
        let pending = Pending(key: key, journalIDs: [], operation: try availabilityRemoval(key))
        state.pending.append(pending); try persist()
        do { _ = try await submitBatch([pending], epoch: generation) }
        catch let error as HostedHTTPError where error.code == HostedHTTPError.schemaFallback {
            // Sent before this session learned the server speaks only schema 2: rebuilt once under 2.
            reconcilePendingSchema(); try persist()
            guard let rebuilt = state.pending.first(where: { $0.key == key && $0.journalIDs.isEmpty && !$0.accepted && !$0.terminal }) else { throw error }
            _ = try await submitBatch([rebuilt], epoch: generation)
        }
    }
    private func availabilityRemoval(_ key: RecordKey) throws -> HostedOperation {
        let (fp, membershipGeneration) = try contentMembership(key)
        return HostedOperation(operationId: UUID().uuidString.lowercased(), schema: http.negotiatedSchema, kind: "content_availability", action: "upsert",
                               object: ["fingerprint": .string(fp.description), "generation": .integer(membershipGeneration), "stored": .bool(false)])
    }

    private func contentMembership(_ key: RecordKey) throws -> (ContentFingerprint, Int64) {
        let pieces = key.name.split(separator: ":")
        guard key.type == .gameContent || key.type == .contentIndex, pieces.count >= 2,
              let fp = try? ContentFingerprint(parsing: "sha256:" + pieces[1]) else { throw HostedHTTPError.invalidResponse }
        let membershipGeneration: Int64
        if pieces.count >= 4, pieces[pieces.count - 2] == "generation", let value = Int64(pieces.last!) {
            membershipGeneration = value
        } else { membershipGeneration = 0 }
        guard (0...2_147_483_647).contains(membershipGeneration),
              key == .gameContent(fp, part: 0, generation: membershipGeneration) || key == .contentIndex(fp, generation: membershipGeneration) else {
            throw HostedHTTPError.invalidResponse
        }
        return (fp, membershipGeneration)
    }

    /// Read the server's preserved head set without introducing another resolver.
    public func batteryHeads(fingerprint: ContentFingerprint, generation membershipGeneration: Int64) async throws -> [BatteryRevisionID] {
        struct Page: Decodable, Sendable {
            var schema: Int; var generation: Int64; var fingerprint: String; var heads: [String]; var nextCursor: String?; var hasMore: Bool; var snapshotSequence: Int64
        }
        guard (0...2_147_483_647).contains(membershipGeneration) else { throw HostedHTTPError.invalidResponse }
        for _ in 0..<3 {
            var snapshot: Int64?, cursor: String?, heads: [BatteryRevisionID] = []
            do {
                for _ in 0..<100 {
                    var path = "/v1/sync/games/\(fingerprint.hexDigest)/battery-heads?limit=500&generation=\(membershipGeneration)"
                    if let cursor, let snapshot { path += "&cursor=\(cursor)&snapshot=\(snapshot)" }
                    let (page, served) = try await http.negotiatedRequest(method: "GET", path: path, as: Page.self)
                    guard page.schema == served, page.generation == membershipGeneration, page.fingerprint == fingerprint.description, page.snapshotSequence >= 0,
                          snapshot == nil || snapshot == page.snapshotSequence, page.heads.count <= 500 else { throw HostedHTTPError.invalidResponse }
                    snapshot = page.snapshotSequence
                    for raw in page.heads {
                        guard let id = BatteryRevisionID(raw), id.description == raw,
                              heads.last.map({ $0.description < raw }) ?? true else { throw HostedHTTPError.invalidResponse }
                        heads.append(id)
                    }
                    if !page.hasMore { return heads }
                    guard let next = page.nextCursor, next == page.heads.last, next != cursor else { throw HostedHTTPError.invalidResponse }
                    cursor = next
                }
                throw HostedHTTPError(status: 413, problem: .limitExceeded)
            } catch let error as HostedHTTPError where error.status == 409 { continue }
        }
        throw HostedHTTPError(status: 409, problem: .serverRecordChanged)
    }
}
