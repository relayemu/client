// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreFoundation

/// Two independently ordered disk/hash workers share one bounded payload window.
/// Import runs separately, so a large archive cannot block reception or ACKs.
actor TransferReceiver {
    typealias Import = @Sendable ([URL]) async -> TransferImportResult
    private struct OpenFile {
        let file: TransferFile, writer: TransferFileWriter
        var accepted: Int64 = 0, lastAck: Int64 = 0
        var ackTime = ContinuousClock.now
        var ending = false
    }
    private let root: URL
    private let availableBytes: @Sendable () throws -> Int64
    private let send: @Sendable (Data) throws -> Void
    private let event: @Sendable (TransferEvent) -> Void
    private let importFiles: Import
    private let duplicate: @Sendable (TransferFile) async -> TransferImportResult?
    private var files: [TransferFile] = [], wanted: [String] = []
    private var statuses: [String: TransferStatus] = [:], verified = Set<String>()
    private var groups: [String: URL] = [:], rejected = Set<String>()
    private var open: [String: OpenFile] = [:]
    private var pendingBytes = 0
    private var importQueue: [String] = [], importingGroup: String?
    private var pendingError: TransferError?
    private var lastActivity = ContinuousClock.now
    private var started = false, stopped = false, done = false

    init(root: URL, availableBytes: @escaping @Sendable () throws -> Int64,
         send: @escaping @Sendable (Data) throws -> Void,
         event: @escaping @Sendable (TransferEvent) -> Void,
         duplicate: @escaping @Sendable (TransferFile) async -> TransferImportResult? = { _ in nil },
         importFiles: @escaping Import) {
        self.root = root; self.availableBytes = availableBytes; self.send = send
        self.event = event; self.duplicate = duplicate; self.importFiles = importFiles
    }

    func text(_ data: Data) async throws {
        if let pendingError { throw pendingError }
        guard !stopped, !done, data.count <= 65536,
              let object = try? TransferJSON.object(data),
              let type = object["type"] as? String else { throw TransferError.invalidMessage }
        lastActivity = .now
        switch type {
        case "hello":
            guard !started, Set(object.keys) == ["type", "version", "files"],
                  (object["version"] as? NSNumber)?.intValue == 2,
                  let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
                  let values = object["files"] as? [[String: Any]],
                  values.allSatisfy({ value in
                      guard let size = value["size"] as? NSNumber else { return false }
                      return Set(value.keys).isSubset(of: ["id", "name", "size", "sha256", "group"]) && CFGetTypeID(size) != CFBooleanGetTypeID()
                  }) else { throw TransferError.invalidMessage }
            struct Hello: Decodable { let files: [TransferFile] }
            files = try JSONDecoder().decode(Hello.self, from: data).files
            try TransferFile.validate(files, availableBytes: Int64.max)
            started = true; event(.manifest(files))
            for file in files {
                if file.group == nil, let result = await duplicate(file), result.state == "duplicate" {
                    try finish(file, result: result)
                    event(.outcomes(result.counts))
                } else { wanted.append(file.id) }
                guard !stopped else { throw TransferError.interrupted }
            }
            let requested = files.filter { wanted.contains($0.id) }
            if !requested.isEmpty { try TransferFile.validate(requested, availableBytes: availableBytes()) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try sendObject(["type": "want", "ids": wanted]); try completeIfFinished()
        case "begin":
            let id = try identifier(object)
            guard started, open.count < 2, open[id] == nil, wanted.first == id,
                  let file = files.first(where: { $0.id == id }), statuses[id]?.isTerminal != true else { throw TransferError.invalidMessage }
            let directory: URL
            if let existing = groups[file.groupID] { directory = existing }
            else {
                directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                groups[file.groupID] = directory
            }
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { throw TransferError.storageFull }
            open[id] = OpenFile(file: file, writer: try TransferFileWriter(url: url))
            wanted.removeFirst()
            try status(TransferStatus(id: id, state: "receiving", receivedBytes: 0))
            try sendObject(["type": "ready", "id": id])
        case "end":
            let id = try identifier(object)
            guard var current = open[id], !current.ending else { throw TransferError.invalidMessage }
            current.ending = true; open[id] = current
            let result: (Int64, String)
            do { result = try await current.writer.finish() }
            catch {
                open.removeValue(forKey: id)
                if !stopped { try rejectGroup(current.file.groupID, code: "storage_full"); try completeIfFinished() }
                return
            }
            open.removeValue(forKey: id)
            guard !stopped else { return }
            if statuses[id]?.isTerminal != true { try status(TransferStatus(id: id, state: "verifying", receivedBytes: result.0)) }
            if !rejected.contains(current.file.groupID) {
                if result.0 != current.file.size { try rejectGroup(current.file.groupID, code: "size_mismatch") }
                else if result.1 != current.file.sha256 { try rejectGroup(current.file.groupID, code: "hash_mismatch") }
                else { verified.insert(id) }
            }
            let group = current.file.groupID
            if !rejected.contains(group), files.filter({ $0.groupID == group }).allSatisfy({ verified.contains($0.id) }) {
                importQueue.append(group); try startNextImport()
            } else if rejected.contains(group) { removeRejectedGroup(group) }
            try completeIfFinished()
        case "cancel":
            guard Set(object.keys).isSubset(of: ["type", "id"]), started else { throw TransferError.invalidMessage }
            if let id = object["id"] as? String, let file = files.first(where: { $0.id == id }) {
                // A commit already in progress must report its actual outcome.
                if importingGroup != file.groupID { try rejectGroup(file.groupID, code: "cancelled") }
            } else if object["id"] == nil { await stop() }
            else { throw TransferError.invalidMessage }
        default: throw TransferError.invalidMessage
        }
    }

    func binary(_ data: Data) throws {
        if let pendingError { throw pendingError }
        guard !stopped, !done, data.count > 4, data.count <= 65540 else { throw TransferError.invalidMessage }
        let index = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard index < files.count else { throw TransferError.invalidMessage }
        let id = files[Int(index)].id
        guard var current = open[id], !current.ending,
              current.accepted <= current.file.size - Int64(data.count - 4) else { throw TransferError.invalidMessage }
        let payload = Data(data.dropFirst(4))
        current.accepted += Int64(payload.count); open[id] = current; lastActivity = .now
        if rejected.contains(current.file.groupID) { return }
        guard pendingBytes <= 8 * 1024 * 1024 - payload.count else { throw TransferError.limitsExceeded }
        pendingBytes += payload.count
        current.writer.append(payload) { [weak self] result in
            Task { await self?.written(id: id, count: payload.count, result: result) }
        }
    }

    private func written(id: String, count: Int, result: Result<Int64, Error>) {
        pendingBytes -= count
        guard !stopped else { return }
        do {
            switch result {
            case .failure: if let current = open[id], !rejected.contains(current.file.groupID) { try rejectGroup(current.file.groupID, code: "storage_full") }
            case .success(let bytes):
                guard var current = open[id], bytes > current.lastAck, statuses[id]?.isTerminal != true else { return }
                if bytes - current.lastAck >= 1024 * 1024 || current.ackTime.duration(to: .now) >= .milliseconds(100) {
                    current.lastAck = bytes; current.ackTime = .now; open[id] = current
                    try status(TransferStatus(id: id, state: "receiving", receivedBytes: bytes))
                }
            }
        } catch { asynchronousFailure(error) }
    }

    private func startNextImport() throws {
        guard !stopped, importingGroup == nil else { return }
        while let next = importQueue.first, rejected.contains(next) { importQueue.removeFirst() }
        guard !importQueue.isEmpty else { return }
        let group = importQueue.removeFirst(), members = files.filter { $0.groupID == group }
        guard let directory = groups[group] else { throw TransferError.invalidMessage }
        // Recheck free space immediately before handing staged files to importer.
        // The incoming copy is already on disk; reserve the remaining two copies.
        let bytes = members.reduce(Int64(0)) { $0 + $1.size }
        if try availableBytes() < bytes * 2 + 512 * 1024 * 1024 {
            try rejectGroup(group, code: "storage_full"); try startNextImport(); return
        }
        importingGroup = group
        for member in members { try status(TransferStatus(id: member.id, state: "importing")) }
        Task { [self, importFiles] in
            let result = await importFiles(members.map { directory.appendingPathComponent($0.name) })
            importFinished(group, result: result)
        }
    }

    private func importFinished(_ group: String, result: TransferImportResult) {
        importingGroup = nil
        event(.outcomes(result.counts))
        do {
            for member in files where member.groupID == group {
                let outcome = result.sourceResults[member.name] ?? result
                if stopped { event(.status(TransferStatus(id: member.id, state: outcome.state, message: outcome.message, title: outcome.title, code: outcome.code, counts: outcome.counts))) }
                else { try finish(member, result: outcome) }
            }
            if let directory = groups.removeValue(forKey: group) { try? FileManager.default.removeItem(at: directory) }
            if stopped { try? FileManager.default.removeItem(at: root) }
            else { try startNextImport(); try completeIfFinished() }
        } catch { asynchronousFailure(error) }
    }

    private func asynchronousFailure(_ error: Error) {
        pendingError = error as? TransferError ?? .connectionFailed
        event(.failed(pendingError!))
    }

    func tick() throws {
        if let pendingError { throw pendingError }
        guard !stopped, !done else { return }
        for value in statuses.values where value.state == "importing" || value.state == "verifying" { try send(JSONEncoder().encode(value)) }
        if started, importingGroup == nil, lastActivity.duration(to: .now) >= .seconds(60) { throw TransferError.interrupted }
    }

    func stop() async {
        guard !stopped else { return }; stopped = true
        for current in open.values { await current.writer.close() }
        open.removeAll(); importQueue.removeAll()
        for (group, directory) in groups where group != importingGroup { try? FileManager.default.removeItem(at: directory) }
        if importingGroup == nil { try? FileManager.default.removeItem(at: root) }
    }
    var isComplete: Bool { done }

    private func identifier(_ object: [String: Any]) throws -> String {
        guard Set(object.keys) == ["type", "id"], let id = object["id"] as? String else { throw TransferError.invalidMessage }; return id
    }
    private func sendObject(_ object: [String: Any]) throws { try send(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
    private func status(_ value: TransferStatus) throws {
        guard statuses[value.id]?.isTerminal != true else { throw TransferError.invalidMessage }
        statuses[value.id] = value; event(.status(value)); try send(JSONEncoder().encode(value))
    }
    private func finish(_ file: TransferFile, result: TransferImportResult) throws {
        try status(TransferStatus(id: file.id, state: result.state, message: result.message, title: result.title, code: result.code, counts: result.counts))
    }
    private func rejectGroup(_ group: String, code: String) throws {
        rejected.insert(group)
        for file in files where file.groupID == group && statuses[file.id]?.isTerminal != true {
            try finish(file, result: TransferImportResult(state: "failed", code: code, counts: TransferCounts(failed: 1)))
        }
        wanted.removeAll { id in files.first(where: { $0.id == id })?.groupID == group }
        removeRejectedGroup(group)
    }
    private func removeRejectedGroup(_ group: String) {
        if !open.values.contains(where: { $0.file.groupID == group }), importingGroup != group,
           let directory = groups.removeValue(forKey: group) { try? FileManager.default.removeItem(at: directory) }
    }
    private func completeIfFinished() throws {
        guard !stopped, !done, open.isEmpty, importingGroup == nil, files.allSatisfy({ statuses[$0.id]?.isTerminal == true }) else { return }
        done = true; try sendObject(["type": "done"]); event(.completed)
        try? FileManager.default.removeItem(at: root)
    }
}
