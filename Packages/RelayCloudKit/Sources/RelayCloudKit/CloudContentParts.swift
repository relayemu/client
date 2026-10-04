// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayLibrary
import RelaySync

/// CloudKit storage detail. The coordinator still sends and receives one logical
/// file. Existing schema fields describe bounded assets; part zero is published
/// last so an interrupted upload is never advertised as complete.
struct CloudContentParts: Sendable {
    static let assetBytes = 32 * 1024 * 1024
    let directory: URL
    let partBytes: Int
    let singleAssetBytes: Int
    init(directory: URL, partBytes: Int = Self.assetBytes, singleAssetBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory; self.partBytes = partBytes; self.singleAssetBytes = singleAssetBytes
    }
    typealias Put = @Sendable (SyncRecord, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    typealias Get = @Sendable (RecordKey, @escaping @Sendable (Double) -> Void) async throws -> InboundChange?
    typealias Release = @Sendable (InboundChange) async -> Void

    func upload(_ record: SyncRecord, file: URL, progress: @escaping @Sendable (Double) -> Void, put: Put) async throws {
        guard partBytes > 0, partBytes <= Self.assetBytes, partBytes <= singleAssetBytes,
              Int64(singleAssetBytes) <= SyncLimits.maxContentPartSize,
              case .gameContent(let logical) = try SyncRecordValidator().validate(record),
              logical.partIndex == 0, logical.partCount == 1, logical.partFingerprint == logical.fingerprint,
              logical.partSize > 0, logical.partSize <= SyncLimits.maxContentSize else { throw SyncContentError.verificationFailed }
        let hash = try await SHA256ContentHasher().hash(fileAt: file)
        guard hash.fingerprint == logical.fingerprint, hash.sizeInBytes == logical.partSize else { throw SyncContentError.verificationFailed }
        // Preserve the existing single-asset layout through its full 64 MiB
        // limit so older clients can still fetch previously supported games.
        if logical.partSize <= Int64(singleAssetBytes) { try await put(record, file, progress); return }
        let count = Int((logical.partSize + Int64(partBytes) - 1) / Int64(partBytes))
        guard count <= SyncLimits.maxPartCount else { throw SyncContentError.unsupportedLayout }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        // Publish the root only after every remaining asset has succeeded. Retrying
        // writes the same immutable content keys, including any orphaned parts.
        for (completed, index) in (Array(1..<count) + [0]).enumerated() {
            try Task.checkCancellation()
            try input.seek(toOffset: UInt64(index) * UInt64(partBytes))
            let expected = Int(min(Int64(partBytes), logical.partSize - Int64(index) * Int64(partBytes)))
            guard let bytes = try input.read(upToCount: expected), bytes.count == expected else { throw SyncContentError.verificationFailed }
            let temporary = directory.appendingPathComponent("\(UUID())-upload")
            try bytes.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let fingerprint = try await SHA256ContentHasher().hash(fileAt: temporary).fingerprint
            var part = SyncGameContent(fingerprint: logical.fingerprint, partIndex: index, partCount: count,
                partFingerprint: fingerprint, partSize: Int64(bytes.count), generation: logical.generation)
            part.schema = logical.schema
            try await put(.gameContent(part), temporary) { value in progress((Double(completed) + value) / Double(count)) }
        }
        progress(1)
    }

    func fetch(_ key: RecordKey, progress: @escaping @Sendable (Double) -> Void, get: Get, release: Release) async throws -> InboundChange? {
        guard let membership = key.contentMembership,
              key == .gameContent(membership.fingerprint, part: 0, generation: membership.generation) else { throw SyncContentError.unsupportedLayout }
        guard let first = try await get(key, { _ in }) else { return nil }
        let root: SyncGameContent
        do {
            root = try validate(first, key: key)
            guard root.partIndex == 0, root.partCount <= SyncLimits.maxPartCount else { throw SyncContentError.verificationFailed }
        } catch { await release(first); throw error }
        if root.partCount == 1 {
            guard root.partFingerprint == root.fingerprint else { await release(first); throw SyncContentError.verificationFailed }
            progress(1); return first
        }
        let output = directory.appendingPathComponent("\(UUID())-content")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: output) } }
        do {
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
            var size: Int64 = 0
            for index in 0..<root.partCount {
                try Task.checkCancellation()
                let expectedKey = RecordKey.gameContent(root.fingerprint, part: index, generation: root.generation)
                let inbound: InboundChange
                if index == 0 { inbound = first }
                else {
                    guard let next = try await get(expectedKey, { value in progress((Double(index) + value) / Double(root.partCount)) }) else { throw SyncContentError.notInCloud }
                    inbound = next
                }
                do {
                    let part = try validate(inbound, key: expectedKey)
                    guard part.partCount == root.partCount, part.partIndex == index,
                          part.partSize <= Int64(Self.assetBytes),
                          index == root.partCount - 1 || part.partSize == root.partSize,
                          part.partSize <= root.partSize,
                          size + part.partSize <= SyncLimits.maxContentSize,
                          let file = inbound.assets[.data] else { throw SyncContentError.verificationFailed }
                    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try handle.write(contentsOf: data) }
                    size += part.partSize
                } catch { await release(inbound); throw error }
                await release(inbound)
            }
            try handle.synchronize()
            let hash = try await SHA256ContentHasher().hash(fileAt: output)
            guard hash.sizeInBytes == size, hash.fingerprint == root.fingerprint else { throw SyncContentError.verificationFailed }
            var logical = SyncGameContent(fingerprint: root.fingerprint, partIndex: 0, partCount: 1,
                partFingerprint: root.fingerprint, partSize: size, generation: root.generation)
            logical.schema = root.schema
            keep = true; progress(1)
            return InboundChange(key: key, record: .gameContent(logical), assets: [.data: output])
        } catch {
            await release(first)
            throw error
        }
    }

    private func validate(_ inbound: InboundChange, key: RecordKey) throws -> SyncGameContent {
        guard inbound.key == key, inbound.record.key == key,
              case .gameContent(let part) = try SyncRecordValidator().validate(inbound.record),
              part.partSize > 0, part.partSize <= SyncLimits.maxContentPartSize,
              let file = inbound.assets[.data] else { throw SyncContentError.verificationFailed }
        let hash = try SHA256ContentHasher.hashSynchronously(fileAt: file)
        guard hash.sizeInBytes == part.partSize, hash.fingerprint == part.partFingerprint else { throw SyncContentError.verificationFailed }
        return part
    }
}
