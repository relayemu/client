// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  FileCloudTransport.swift
//  RelaySync
//
//  A shared directory as the "server" so two Relay processes on one Mac (or
//  two simulators) exercise the whole product path without CloudKit
//  credentials. Debug tooling only: the app enables it with
//  `--relay-file-cloud <dir>`. Same semantics as the in-memory cloud —
//  versioned records, a change log with cursors, change-tag saves — with
//  cross-process locking (flock) and a polling loop.
//
//  Layout:
//    <root>/lock                          advisory lock for every mutation
//    <root>/account                       opaque account identity (edit to simulate a change)
//    <root>/records/<type>/<name>.json    { record, version, assets: { name: relative asset path } }
//    <root>/assets/<uuid>                 asset bytes
//    <root>/log.jsonl                     one line per change: { seq, type, name, deleted }
//    <state>/file-cloud-cursor.txt        this device's cursor (transport state)

import Foundation
import RelayDomain

public final class FileCloudTransport: SyncTransport, @unchecked Sendable {
    /// A test cloud stores any record type, custom covers included.
    public var sendsArtwork: Bool { true }
    public let root: URL
    private let stateDirectory: URL
    private let pollInterval: TimeInterval
    private let lock = NSLock()
    private var host: (any SyncTransportHost)?
    private var running = false
    private var loop: Task<Void, Never>?
    private var knownVersions: [RecordKey: Int] = [:]
    private var pumping = false

    private struct Stored: Codable { var record: SyncRecord; var version: Int; var assets: [SyncAssetName: String] }
    private struct LogLine: Codable { var seq: Int; var type: String; var name: String; var deleted: Bool }

    public init(root: URL, stateDirectory: URL, pollInterval: TimeInterval = 2) {
        self.root = root
        self.stateDirectory = stateDirectory
        self.pollInterval = pollInterval
        let fm = FileManager.default
        for dir in [root, root.appending(path: "records"), root.appending(path: "assets"), stateDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: root.appending(path: "account").path) {
            try? Data("file-cloud".utf8).write(to: root.appending(path: "account"))
        }
    }

    // MARK: SyncTransport

    public func start(host: any SyncTransportHost) async throws {
        lock.lock(); self.host = host; running = true; lock.unlock()
        await host.accountDidChange(AccountChange(availability: .available, identity: accountIdentity()))
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 2))
                guard let self else { return }
                lock.lock(); let running = self.running; lock.unlock()
                guard running else { continue }
                _ = try? await self.pump()
            }
        }
    }

    public func stop() async {
        lock.lock(); running = false; lock.unlock()
        loop?.cancel(); loop = nil
    }

    public func resetState() async {
        try? FileManager.default.removeItem(at: cursorURL)
        lock.lock(); knownVersions.removeAll(); lock.unlock()
    }

    public func requestSync(reason: SyncReason) async {
        Task { _ = try? await pump() }
    }

    public func fetchNow() async throws { try await fetch() }

    /// Sends pending batches then fetches; safe to call from the poll loop and from requests.
    @discardableResult
    public func pump(maxBatches: Int = 10) async throws -> Int {
        lock.lock()
        guard !pumping, running, let host else { lock.unlock(); return 0 }
        pumping = true
        lock.unlock()
        defer { lock.lock(); pumping = false; lock.unlock() }
        var sent = 0
        for _ in 0..<maxBatches {
            let batch = await host.nextOutboundBatch(limit: 20)
            if batch.isEmpty { break }
            var results: [SendResult] = []
            for change in batch { results.append(save(change)) }
            sent += batch.count
            await host.didSend(results)
        }
        try await fetch()
        return sent
    }

    // MARK: Server operations (locked)

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(root.appending(path: "lock").path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    private func recordURL(_ key: RecordKey) -> URL {
        root.appending(path: "records/\(key.type.rawValue)/\(key.name).json")
    }

    private func readStored(_ key: RecordKey) -> Stored? {
        guard let data = try? Data(contentsOf: recordURL(key)) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func appendLog(_ key: RecordKey, deleted: Bool) {
        let logURL = root.appending(path: "log.jsonl")
        let seq = nextSequence()
        guard let line = try? JSONEncoder().encode(LogLine(seq: seq, type: key.type.rawValue, name: key.name, deleted: deleted)) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data("\n".utf8)); try? handle.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: logURL)
        }
    }

    private func nextSequence() -> Int {
        (readLog().last?.seq ?? 0) + 1
    }

    private func readLog() -> [LogLine] {
        guard let text = try? String(contentsOf: root.appending(path: "log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(LogLine.self, from: Data($0.utf8)) }
    }

    private func save(_ change: OutboundChange) -> SendResult {
        withLock {
            lock.lock(); let base = knownVersions[change.key]; lock.unlock()
            switch change.payload {
            case .save(let record, let assetURLs):
                if let existing = readStored(change.key) {
                    guard base == existing.version else {
                        lock.lock(); knownVersions[change.key] = existing.version; lock.unlock()
                        return SendResult(key: change.key, outcome: .failed(.serverRecordChanged, serverRecord: existing.record))
                    }
                    if existing.record == record, assetURLs.isEmpty {
                        return SendResult(key: change.key, outcome: .saved)
                    }
                }
                var assets: [SyncAssetName: String] = [:]
                for (name, url) in assetURLs {
                    let relative = "assets/\(UUID().uuidString)"
                    do { try FileManager.default.copyItem(at: url, to: root.appending(path: relative)) } catch {
                        return SendResult(key: change.key, outcome: .failed(.other("asset copy"), serverRecord: nil))
                    }
                    assets[name] = relative
                }
                let version = (readStored(change.key)?.version ?? 0) + 1
                let stored = Stored(record: record, version: version, assets: assets)
                do {
                    try FileManager.default.createDirectory(at: recordURL(change.key).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(stored).write(to: recordURL(change.key), options: .atomic)
                } catch {
                    return SendResult(key: change.key, outcome: .failed(.other("write"), serverRecord: nil))
                }
                appendLog(change.key, deleted: false)
                lock.lock(); knownVersions[change.key] = version; lock.unlock()
                return SendResult(key: change.key, outcome: .saved)
            case .delete:
                guard FileManager.default.fileExists(atPath: recordURL(change.key).path) else {
                    return SendResult(key: change.key, outcome: .failed(.unknownItem, serverRecord: nil))
                }
                try? FileManager.default.removeItem(at: recordURL(change.key))
                appendLog(change.key, deleted: true)
                lock.lock(); knownVersions[change.key] = nil; lock.unlock()
                return SendResult(key: change.key, outcome: .deleted)
            }
        }
    }

    private var cursorURL: URL { stateDirectory.appending(path: "file-cloud-cursor.txt") }

    private func fetch() async throws {
        lock.lock(); let host = self.host; let running = self.running; lock.unlock()
        guard let host, running else { return }
        let cursor = Int((try? String(contentsOf: cursorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        let (items, newCursor): ([(RecordKey, Stored?)], Int) = withLock {
            var latest: [RecordKey: (Int, Bool)] = [:]
            var newest = cursor
            for line in readLog() where line.seq > cursor {
                guard let type = SyncRecordType(rawValue: line.type), type.zone == .sync else { newest = max(newest, line.seq); continue }
                latest[RecordKey(type: type, name: line.name)] = (line.seq, line.deleted)
                newest = max(newest, line.seq)
            }
            let ordered = latest.sorted { $0.value.0 < $1.value.0 }.map { ($0.key, $0.value.1 ? nil : readStored($0.key)) }
            return (ordered, newest)
        }
        var changes: [InboundChange] = []
        var deletions: [RecordKey] = []
        for (key, stored) in items {
            lock.lock(); knownVersions[key] = stored?.version; lock.unlock()
            guard let stored else { deletions.append(key); continue }
            var urls: [SyncAssetName: URL] = [:]
            for (name, relative) in stored.assets {
                let temp = stateDirectory.appending(path: "inbound-\(UUID().uuidString)-\(name.rawValue)")
                try? FileManager.default.copyItem(at: root.appending(path: relative), to: temp)
                urls[name] = temp
            }
            changes.append(InboundChange(key: key, record: stored.record, assets: urls))
        }
        if !changes.isEmpty || !deletions.isEmpty { await host.didFetch(changes: changes, deletions: deletions) }
        for change in changes { for (_, url) in change.assets { try? FileManager.default.removeItem(at: url) } }
        try? String(newCursor).write(to: cursorURL, atomically: true, encoding: .utf8)
        await host.transportDidUpdate(TransportStatus(isSyncing: false, lastProblem: nil, lastPullAt: Date(), detail: "file cloud \(root.lastPathComponent) cursor \(newCursor)"))
        let identity = accountIdentity()
        await host.accountDidChange(AccountChange(availability: .available, identity: identity))
    }

    private func accountIdentity() -> String {
        (try? String(contentsOf: root.appending(path: "account"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "file-cloud"
    }

    // MARK: Content

    public func uploadContent(_ record: SyncRecord, fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let change = OutboundChange(journalIDs: [], key: record.key, payload: .save(record, assets: [.data: fileURL]))
        progress(0.5)
        let result = save(change)
        if case .failed(let problem, _) = result.outcome, problem != .serverRecordChanged { throw SyncTransportError.offline }
        progress(1)
    }

    public func fetchContent(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void) async throws -> InboundChange? {
        guard let stored = withLock({ readStored(key) }) else { return nil }
        var urls: [SyncAssetName: URL] = [:]
        for (name, relative) in stored.assets {
            let temp = stateDirectory.appending(path: "content-\(UUID().uuidString)-\(name.rawValue)")
            try FileManager.default.copyItem(at: root.appending(path: relative), to: temp)
            urls[name] = temp
        }
        progress(1)
        return InboundChange(key: key, record: stored.record, assets: urls)
    }

    public func contentExists(_ key: RecordKey) async throws -> Bool {
        FileManager.default.fileExists(atPath: recordURL(key).path)
    }

    public func deleteContent(_ key: RecordKey) async throws {
        withLock {
            try? FileManager.default.removeItem(at: recordURL(key))
            appendLog(key, deleted: true)
        }
    }
}
