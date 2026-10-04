// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
@testable import RelayTransfer

private final class ReceiverProbe: @unchecked Sendable {
    let lock = NSLock()
    var messages: [[String: Any]] = [], imports: [[Data]] = []
    func send(_ data: Data) throws { let object = try TransferJSON.object(data); lock.lock(); defer { lock.unlock() }; messages.append(object) }
    func imported(_ urls: [URL]) async -> TransferImportResult {
        let bytes = urls.compactMap { try? Data(contentsOf: $0) }
        lock.lock(); imports.append(bytes); lock.unlock()
        return TransferImportResult(state: "imported", title: "Game", counts: TransferCounts(imported: 1))
    }
    func snapshot() -> ([[String: Any]], [[Data]]) { lock.lock(); defer { lock.unlock() }; return (messages, imports) }
}

private actor ImportLatch {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

final class TransferReceiverTests: XCTestCase {
    func testFrozenContractInterleavedStreams() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let vector = try TransferJSON.object(Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.3.0/testdata/transfer-v2.json")))
        XCTAssertEqual(vector["channel"] as? String, "relay-transfer/2")
        let hello = try XCTUnwrap(vector["hello"] as? [String: Any])
        let files = try XCTUnwrap(hello["files"] as? [[String: Any]])
        let frames = try XCTUnwrap(vector["framesHex"] as? [String])
        let payloads = try XCTUnwrap(vector["payloadsHex"] as? [String])
        func hex(_ value: String) throws -> Data {
            let bytes = Array(value.utf8)
            return try Data(stride(from: 0, to: bytes.count, by: 2).map {
                try XCTUnwrap(UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16))
            })
        }
        let (receiver, probe, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await text(hello, to: receiver)
        for file in files { try await text(["type": "begin", "id": try XCTUnwrap(file["id"])], to: receiver) }
        for frame in frames { try await receiver.binary(hex(frame)) }
        for file in files { try await text(["type": "end", "id": try XCTUnwrap(file["id"])], to: receiver) }
        try await complete(receiver)
        let (_, imports) = probe.snapshot()
        XCTAssertEqual(imports, try payloads.map { [try hex($0)] })
    }

    private func fixture() -> (TransferReceiver, ReceiverProbe, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-transfer-test-" + UUID().uuidString)
        let probe = ReceiverProbe()
        let receiver = TransferReceiver(root: root, availableBytes: { Int64.max }, send: { try probe.send($0) }, event: { _ in }, importFiles: { await probe.imported($0) })
        return (receiver, probe, root)
    }
    private func text(_ object: [String: Any], to receiver: TransferReceiver) async throws { try await receiver.text(JSONSerialization.data(withJSONObject: object)) }
    private func binary(_ payload: Data, to receiver: TransferReceiver, index: UInt32 = 0) async throws {
        var header = index.bigEndian
        var frame = withUnsafeBytes(of: &header) { Data($0) }; frame.append(payload)
        try await receiver.binary(frame)
    }
    private func complete(_ receiver: TransferReceiver) async throws {
        for _ in 0..<200 {
            if await receiver.isComplete { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import did not complete")
    }
    private func file(_ id: String, bytes: Data, group: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "name": id + ".bin", "size": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        if let group { value["group"] = group }; return value
    }
    func testStreamingWritesAcksThenImportsAndRemovesStaging() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 42, count: 2 * 1024 * 1024)
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: bytes)]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver)
        for offset in stride(from: 0, to: bytes.count, by: 65536) { try await binary(bytes.subdata(in: offset..<offset + 65536), to: receiver) }
        try await text(["type": "end", "id": "f1"], to: receiver)
        try await complete(receiver)
        let (messages, imports) = probe.snapshot()
        XCTAssertEqual(imports, [[bytes]])
        XCTAssertTrue(messages.contains { $0["receivedBytes"] as? Int == 1024 * 1024 })
        XCTAssertEqual(messages.last?["type"] as? String, "done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let complete = await receiver.isComplete; XCTAssertTrue(complete)
    }
    func testNineGBManifestAdmitsStreamingWithoutAllocatingDeclaredSize() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manifest: [String: Any] = ["id": "f1", "name": "Large.iso", "size": Int64(9_000_000_000), "sha256": String(repeating: "a", count: 64)]
        try await text(["type": "hello", "version": 2, "files": [manifest]], to: receiver)
        XCTAssertEqual(probe.snapshot().0.last?["ids"] as? [String], ["f1"])
        try await text(["type": "begin", "id": "f1"], to: receiver)
        try await binary(Data(repeating: 42, count: 65536), to: receiver)
        let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        let staged = try XCTUnwrap(paths.first { $0.lastPathComponent == "Large.iso" })
        for _ in 0..<200 {
            if (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value == 65536 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let size = try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 65536)
        XCTAssertTrue(probe.snapshot().1.isEmpty)
        await receiver.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let deniedRoot = root.appendingPathComponent("denied")
        let denied = TransferReceiver(root: deniedRoot, availableBytes: { 9_000_000_000 }, send: { try probe.send($0) }, event: { _ in }, importFiles: { await probe.imported($0) })
        do {
            try await text(["type": "hello", "version": 2, "files": [manifest]], to: denied)
            XCTFail("Accepted insufficient receiving/import space")
        } catch { XCTAssertEqual(error as? TransferError, .storageFull) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedRoot.path))
    }
    func testGroupWaitsForEveryMemberAndImportsTogether() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("track".utf8)
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: bytes, group: "g1"), file("f2", bytes: bytes, group: "g1")]], to: receiver)
        for id in ["f1", "f2"] {
            try await text(["type": "begin", "id": id], to: receiver); try await binary(bytes, to: receiver, index: id == "f1" ? 0 : 1)
            try await text(["type": "end", "id": id], to: receiver)
            if id == "f2" { try await complete(receiver) }
            XCTAssertEqual(probe.snapshot().1.count, id == "f1" ? 0 : 1)
        }
        XCTAssertEqual(probe.snapshot().1, [[bytes, bytes]])
    }
    func testHashMismatchFailsGroupWithoutCallingImporter() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: Data([1]), group: "g"), file("f2", bytes: Data([1]), group: "g")]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver); try await binary(Data([2]), to: receiver)
        try await text(["type": "end", "id": "f1"], to: receiver)
        XCTAssertTrue(probe.snapshot().1.isEmpty)
        XCTAssertEqual(probe.snapshot().0.filter { $0["code"] as? String == "hash_mismatch" }.count, 2)
        XCTAssertEqual(probe.snapshot().0.last?["type"] as? String, "done")
    }
    func testMixedFolderReportsEachSourceInsteadOfRepeatingAggregateFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-transfer-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReceiverProbe()
        let receiver = TransferReceiver(root: root, availableBytes: { Int64.max }, send: { try probe.send($0) }, event: { _ in }, importFiles: { _ in
            var aggregate = TransferImportResult(state: "failed", code: "partial_import", counts: TransferCounts(imported: 1, unsupported: 1))
            aggregate.sourceResults["f1.bin"] = TransferImportResult(state: "imported", title: "Game", counts: TransferCounts(imported: 1))
            aggregate.sourceResults["f2.bin"] = TransferImportResult(state: "unsupported", counts: TransferCounts(unsupported: 1))
            return aggregate
        })
        let bytes = Data([1])
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: bytes, group: "g"), file("f2", bytes: bytes, group: "g")]], to: receiver)
        for id in ["f1", "f2"] {
            try await text(["type": "begin", "id": id], to: receiver); try await binary(bytes, to: receiver, index: id == "f1" ? 0 : 1)
            try await text(["type": "end", "id": id], to: receiver)
        }
        try await complete(receiver)
        let messages = probe.snapshot().0
        XCTAssertEqual(messages.last { $0["id"] as? String == "f1" }?["state"] as? String, "imported")
        XCTAssertEqual(messages.last { $0["id"] as? String == "f2" }?["state"] as? String, "unsupported")
        XCTAssertEqual(messages.last?["type"] as? String, "done")
    }
    func testOutOfOrderAndOverrunFail() async throws {
        let (receiver, _, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: Data([1]))]], to: receiver)
        do { try await binary(Data([1]), to: receiver); XCTFail("accepted before ready") } catch {}
        do { try await text(["type": "begin", "id": "unknown"], to: receiver); XCTFail("accepted unknown file") } catch {}
        try await text(["type": "begin", "id": "f1"], to: receiver)
        do { try await binary(Data([1, 2]), to: receiver); XCTFail("accepted excess bytes") } catch {}
        await receiver.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCancelDrainsOnlyCurrentGroupThenContinuesIndependentFile() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: Data([1, 2])), file("f2", bytes: Data([3]))]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver)
        try await text(["type": "cancel", "id": "f1"], to: receiver)
        try await binary(Data([1]), to: receiver); try await text(["type": "end", "id": "f1"], to: receiver)
        try await text(["type": "begin", "id": "f2"], to: receiver); try await binary(Data([3]), to: receiver, index: 1)
        try await text(["type": "end", "id": "f2"], to: receiver)
        try await complete(receiver)
        XCTAssertEqual(probe.snapshot().1, [[Data([3])]])
        XCTAssertEqual(probe.snapshot().0.filter { $0["id"] as? String == "f1" && $0["state"] as? String == "failed" }.count, 1)
    }
    func testStrictJSONRejectsDuplicateKeysIncludingEscapes() throws {
        for value in ["{\"type\":\"begin\",\"type\":\"end\"}", "{\"type\":\"hello\",\"files\":[{\"id\":\"x\",\"\\u0069d\":\"y\"}]}", "{\"size\":2e9}", "{\"size\":1.5}"] {
            XCTAssertThrowsError(try TransferJSON.object(Data(value.utf8)))
        }
    }

    func testTwoInterleavedFilesHaveIndependentBytesAndRejectThirdOpenFile() async throws {
        let (receiver, probe, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = Data(repeating: 11, count: 2 * 1024 * 1024), b = Data(repeating: 77, count: 2 * 1024 * 1024)
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: a), file("f2", bytes: b), file("f3", bytes: Data([3]))]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver)
        try await text(["type": "begin", "id": "f2"], to: receiver)
        do { try await text(["type": "begin", "id": "f3"], to: receiver); XCTFail("Accepted third active stream") } catch { XCTAssertEqual(error as? TransferError, .invalidMessage) }
        for offset in stride(from: 0, to: a.count, by: 65536) {
            try await binary(a.subdata(in: offset..<offset + 65536), to: receiver)
            try await binary(b.subdata(in: offset..<offset + 65536), to: receiver, index: 1)
        }
        try await text(["type": "end", "id": "f2"], to: receiver)
        try await text(["type": "begin", "id": "f3"], to: receiver)
        try await binary(Data([3]), to: receiver, index: 2)
        try await text(["type": "end", "id": "f3"], to: receiver)
        try await text(["type": "end", "id": "f1"], to: receiver)
        try await complete(receiver)
        let (messages, imports) = probe.snapshot()
        XCTAssertEqual(Set(imports.compactMap(\.first)), Set([a, b, Data([3])]))
        for id in ["f1", "f2"] {
            let acknowledgments = messages.filter { $0["id"] as? String == id }.compactMap { $0["receivedBytes"] as? Int }
            XCTAssertEqual(acknowledgments, acknowledgments.sorted())
            XCTAssertEqual(acknowledgments.last, a.count)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testImportDoesNotBlockSecondFileReceptionOrCompletionOfDiscGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-transfer-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReceiverProbe(), latch = ImportLatch()
        let receiver = TransferReceiver(root: root, availableBytes: { Int64.max }, send: { try probe.send($0) }, event: { _ in }, importFiles: { urls in
            if urls.first?.lastPathComponent == "f1.bin" { await latch.wait() }
            return await probe.imported(urls)
        })
        let a = Data([1]), b = Data(repeating: 2, count: 2 * 1024 * 1024)
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: a), file("f2", bytes: b, group: "disc"), file("f3", bytes: a, group: "disc")]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver); try await binary(a, to: receiver)
        try await text(["type": "end", "id": "f1"], to: receiver)
        for _ in 0..<200 { if await latch.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        let entered = await latch.entered; XCTAssertTrue(entered)
        try await text(["type": "begin", "id": "f2"], to: receiver)
        try await text(["type": "begin", "id": "f3"], to: receiver)
        for offset in stride(from: 0, to: b.count, by: 65536) { try await binary(b.subdata(in: offset..<offset + 65536), to: receiver, index: 1) }
        try await binary(a, to: receiver, index: 2)
        try await text(["type": "end", "id": "f3"], to: receiver)
        try await text(["type": "end", "id": "f2"], to: receiver)
        XCTAssertTrue(probe.snapshot().0.contains { $0["id"] as? String == "f2" && $0["receivedBytes"] as? Int == b.count })
        XCTAssertTrue(probe.snapshot().1.isEmpty)
        let premature = await receiver.isComplete; XCTAssertFalse(premature)
        await latch.release(); try await complete(receiver)
        XCTAssertEqual(probe.snapshot().1, [[a], [b, a]])
    }

    func testMultiplexingRejectsUnframedUnknownAndClosedFilePayloads() async throws {
        let (receiver, _, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { try await text(["type": "hello", "version": 1, "files": [file("f1", bytes: Data([1]))]], to: receiver); XCTFail("Accepted obsolete version") } catch {}
        try await text(["type": "hello", "version": 2, "files": [file("f1", bytes: Data([1])), file("f2", bytes: Data([2]))]], to: receiver)
        try await text(["type": "begin", "id": "f1"], to: receiver)
        for bytes in [Data([1]), Data([0, 0, 0, 0]), Data([0, 0, 0, 64, 1])] {
            do { try await receiver.binary(bytes); XCTFail("Accepted malformed frame") } catch { XCTAssertEqual(error as? TransferError, .invalidMessage) }
        }
        try await binary(Data([1]), to: receiver); try await text(["type": "end", "id": "f1"], to: receiver)
        do { try await binary(Data([1]), to: receiver); XCTFail("Accepted payload after end") } catch { XCTAssertEqual(error as? TransferError, .invalidMessage) }
        await receiver.stop()
    }
}
