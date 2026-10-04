// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import RelayDomain
import RelayLibrary
import RelaySync
@testable import RelayCloudKit

final class CloudContentPartsTests: XCTestCase {
    actor Remote {
        var records: [RecordKey: (SyncRecord, Data)] = [:]
        var published: [Int] = []
        var failAt: Int?
        let scratch: URL
        init(_ scratch: URL) { self.scratch = scratch }
        func setFailure(_ index: Int?) { failAt = index }
        func put(_ record: SyncRecord, _ url: URL, _ progress: @escaping @Sendable (Double) -> Void) throws {
            guard case .gameContent(let part) = record else { throw SyncContentError.verificationFailed }
            if part.partIndex == failAt { throw SyncContentError.unavailable }
            records[record.key] = (record, try Data(contentsOf: url)); published.append(part.partIndex); progress(1)
        }
        func get(_ key: RecordKey, _ progress: @escaping @Sendable (Double) -> Void) throws -> InboundChange? {
            guard let (record, data) = records[key] else { return nil }
            let file = scratch.appendingPathComponent(UUID().uuidString); try data.write(to: file)
            progress(1); return InboundChange(key: key, record: record, assets: [.data: file])
        }
        func corrupt(_ key: RecordKey, metadata: Bool) {
            guard let (record, bytes) = records[key], case .gameContent(var part) = record else { return }
            if metadata { part.generation += 1; records[key] = (.gameContent(part), bytes) }
            else { var broken = bytes; broken[0] ^= 1; records[key] = (record, broken) }
        }
        func remove(_ key: RecordKey) { records[key] = nil }
        func order() -> [Int] { published }
    }
    func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayCloudParts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func fixture(_ root: URL) async throws -> (URL, SyncRecord) {
        let url = root.appendingPathComponent("source")
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: url)
        let hash = try await SHA256ContentHasher().hash(fileAt: url)
        return (url, .gameContent(.init(fingerprint: hash.fingerprint, partIndex: 0, partCount: 1,
            partFingerprint: hash.fingerprint, partSize: hash.sizeInBytes, generation: 3)))
    }
    let release: CloudContentParts.Release = { change in
        for url in change.assets.values { try? FileManager.default.removeItem(at: url) }
    }
    func testInterruptedUploadPublishesRootLastAndRetryAssemblesExactLogicalFile() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let (source, record) = try await fixture(root), remote = Remote(root)
        let parts = CloudContentParts(directory: root, partBytes: 256, singleAssetBytes: 512)
        await remote.setFailure(2)
        do { try await parts.upload(record, file: source, progress: { _ in }, put: { try await remote.put($0, $1, $2) }); XCTFail("interrupted upload") }
        catch { XCTAssertEqual(error as? SyncContentError, .unavailable) }
        let absent = try await remote.get(record.key, { _ in }); XCTAssertNil(absent)
        await remote.setFailure(nil)
        try await parts.upload(record, file: source, progress: { _ in }, put: { try await remote.put($0, $1, $2) })
        let order = await remote.order(); XCTAssertEqual(order, [1, 1, 2, 3, 0])
        let fetched = try await parts.fetch(record.key, progress: { _ in }, get: { try await remote.get($0, $1) }, release: release)
        let result = try XCTUnwrap(fetched)
        XCTAssertEqual(result.record, record)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets[.data])), try Data(contentsOf: source))
        await release(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }
    func testCorruptionMixedGenerationAndMissingPartAreRejectedWithoutLeakingFiles() async throws {
        for mode in 0..<3 {
            let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
            let (source, record) = try await fixture(root), remote = Remote(root)
            let parts = CloudContentParts(directory: root, partBytes: 256, singleAssetBytes: 512)
            try await parts.upload(record, file: source, progress: { _ in }, put: { try await remote.put($0, $1, $2) })
            let membership = try XCTUnwrap(record.key.contentMembership)
            let key = RecordKey.gameContent(membership.fingerprint, part: 2, generation: membership.generation)
            if mode == 2 { await remote.remove(key) } else { await remote.corrupt(key, metadata: mode == 1) }
            do { _ = try await parts.fetch(record.key, progress: { _ in }, get: { try await remote.get($0, $1) }, release: release); XCTFail("bad content mode \(mode)") }
            catch { XCTAssertTrue(error is SyncContentError) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
        }
    }
    func testSmallLegacyFileAndChangedSource() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let (source, record) = try await fixture(root), remote = Remote(root)
        // Above the chunk size but below the old single-asset limit.
        let parts = CloudContentParts(directory: root, partBytes: 600, singleAssetBytes: 1024)
        try await parts.upload(record, file: source, progress: { _ in }, put: { try await remote.put($0, $1, $2) })
        let order = await remote.order(); XCTAssertEqual(order, [0])
        let fetched = try await parts.fetch(record.key, progress: { _ in }, get: { try await remote.get($0, $1) }, release: release)
        XCTAssertEqual(fetched?.record, record)
        if let fetched { await release(fetched) }
        try Data([1]).write(to: source)
        do { try await parts.upload(record, file: source, progress: { _ in }, put: { try await remote.put($0, $1, $2) }); XCTFail("source changed") }
        catch { XCTAssertEqual(error as? SyncContentError, .verificationFailed) }
    }
}
