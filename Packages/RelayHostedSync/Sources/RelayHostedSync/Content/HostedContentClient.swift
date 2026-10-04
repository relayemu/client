// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain

/// Content capabilities stay inside this boundary. Callers receive only verified local files.
public actor HostedContentClient {
    public static let multipartPartSize: Int64 = 64 * 1024 * 1024
    public static let maximumObjectSize: Int64 = 600_000_000_000
    private let http: HostedHTTPClient
    private let stagingDirectory: URL
    private let dataPlane: any HostedContentDataPlane
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let maximumStatusPolls: Int
    private var activeTransfers = 0
    private var downloadedFiles: [URL: HostedStagingDirectory] = [:]

    public init(http: HostedHTTPClient, stagingDirectory: URL,
                dataPlane: any HostedContentDataPlane = HostedURLSessionDataPlane(),
                maximumStatusPolls: Int = 120,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.http = http; self.stagingDirectory = stagingDirectory; self.dataPlane = dataPlane
        self.maximumStatusPolls = max(1, maximumStatusPolls); self.sleep = sleep
    }

    /// Called on transport startup, including read-only or unavailable vaults, without network access.
    func prepareStaging() async throws {
        let root = stagingDirectory
        _ = try await HostedContentFiles.background { try HostedStagingDirectory.reclaimAbandoned(in: root) }
    }

    public func upload(fileURL: URL, fingerprint: ContentFingerprint, byteCount: Int64,
                       storageClass: HostedStorageClass, target: HostedContentTarget,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try beginTransfer()
        defer { activeTransfers -= 1 }
        guard (0...2_147_483_647).contains(target.generation), byteCount > 0, byteCount <= Self.maximumObjectSize else { throw HostedContentError.invalidUpload }
        let lease = try await makeDirectory()
        defer { lease.remove() }
        let directory = lease.directory
        let snapshot = directory.appendingPathComponent("source")
        // Snapshot before hashing: concurrent emulator writes cannot change the bytes being uploaded.
        try await HostedContentFiles.background {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize.map(Int64.init) == byteCount else {
                throw HostedContentError.integrityMismatch
            }
            try HostedContentFiles.copy(file: fileURL, to: snapshot, offset: 0, count: byteCount)
            let actual = try HostedContentFiles.fingerprint(file: snapshot)
            guard actual.0 == fingerprint, actual.1 == byteCount else { throw HostedContentError.integrityMismatch }
        }
        try Task.checkCancellation()
        progress(0)
        struct Prepare: Encodable { let fingerprint: String; let size: Int64; let storageClass: HostedStorageClass; let target: HostedContentTarget }
        let body = try JSONEncoder().encode(Prepare(fingerprint: "sha256:" + fingerprint.hexDigest,
            size: byteCount, storageClass: storageClass, target: target))
        let prepared: HostedPreparedUpload
        do {
            prepared = try await http.request(method: "POST", path: "/v1/content/uploads", body: body, as: HostedPreparedUpload.self)
        } catch let error as HostedHTTPError where error.status == 409 && error.code == "content_exists" {
            try await provePossession(file: snapshot, byteCount: byteCount, prepareBody: body)
            progress(1)
            return
        }
        guard hostedDate(prepared.expiresAt).map({ $0 > Date() }) == true else { throw HostedContentError.invalidUpload }
        let basePath = "/v1/content/uploads/" + prepared.uploadID.uuidString.lowercased()
        struct Part: Encodable { let number: Int; let etag: String }
        var parts = [Part]()
        switch prepared.mode {
        case "single":
            guard byteCount <= Self.multipartPartSize, let capability = prepared.upload else { throw HostedContentError.invalidUpload }
            _ = try await dataPlane.upload(capability, file: snapshot, byteCount: byteCount, progress: { progress($0 * 0.95) })
        case "multipart":
            let expectedCount = Int((byteCount - 1) / Self.multipartPartSize + 1)
            guard byteCount > Self.multipartPartSize, prepared.partSize == Self.multipartPartSize,
                  prepared.partCount == expectedCount, expectedCount <= 10_000 else { throw HostedContentError.invalidUpload }
            for number in 1...expectedCount {
                try Task.checkCancellation()
                let offset = Int64(number - 1) * Self.multipartPartSize
                let count = min(Self.multipartPartSize, byteCount - offset)
                let partFile = directory.appendingPathComponent("part-\(number)")
                try await HostedContentFiles.background {
                    try HostedContentFiles.copy(file: snapshot, to: partFile, offset: offset, count: count)
                }
                defer { try? FileManager.default.removeItem(at: partFile) }
                let capability: HostedPresignedRequest = try await retry {
                    try await self.http.request(method: "POST", path: basePath + "/parts/\(number)", as: HostedPresignedRequest.self)
                }
                // Signature length is mandatory for every multipart request.
                guard capability.headers.first(where: { $0.key.lowercased() == "content-length" }).flatMap({ Int64($0.value) }) == count else {
                    throw HostedContentError.invalidCapability
                }
                let etag = try await dataPlane.upload(capability, file: partFile, byteCount: count, progress: { fraction in
                    progress(0.95 * (Double(offset) + fraction * Double(count)) / Double(byteCount))
                })
                guard let etag, !etag.isEmpty, etag.utf8.count <= 128 else { throw HostedContentError.missingETag }
                parts.append(Part(number: number, etag: etag))
            }
        default: throw HostedContentError.invalidUpload
        }
        struct Complete: Encodable { let parts: [Part] }
        let completionBody = try JSONEncoder().encode(Complete(parts: parts))
        _ = try await retry { try await self.http.send(method: "POST", path: basePath + "/complete", body: completionBody) }
        // A queued worker is not content availability. Never acknowledge before authoritative verification.
        for poll in 0..<maximumStatusPolls {
            try Task.checkCancellation()
            let status: HostedUploadStatus = try await retry {
                try await self.http.request(method: "GET", path: basePath, as: HostedUploadStatus.self)
            }
            guard status.uploadID == prepared.uploadID else { throw HostedContentError.invalidUpload }
            switch status.status {
            case "COMPLETE": progress(1); return
            case "FAILED", "EXPIRED": throw HostedContentError.verificationFailed
            case "PREPARED", "UPLOADING", "VERIFYING": break
            default: throw HostedContentError.invalidUpload
            }
            if poll + 1 < maximumStatusPolls { try await sleep(min(15, 1 + Double(poll))) }
        }
        throw HostedContentError.verificationTimedOut
    }

    public func download(fingerprint: ContentFingerprint, byteCount: Int64? = nil,
                         maximumByteCount: Int64 = HostedContentClient.maximumObjectSize,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try beginTransfer()
        defer { activeTransfers -= 1 }
        guard maximumByteCount > 0 else { throw HostedContentError.integrityMismatch }
        let authorization: HostedDownloadAuthorization = try await http.request(method: "GET",
            path: "/v1/content/downloads/" + fingerprint.hexDigest, as: HostedDownloadAuthorization.self)
        guard authorization.size > 0, authorization.size <= min(Self.maximumObjectSize, maximumByteCount),
              byteCount == nil || byteCount == authorization.size else { throw HostedContentError.integrityMismatch }
        let lease = try await makeDirectory()
        let directory = lease.directory
        let destination = directory.appendingPathComponent("verified-content")
        do {
            try await dataPlane.download(authorization.download, to: destination, byteCount: authorization.size,
                                         progress: { progress($0 * 0.95) })
            try await HostedContentFiles.background {
                let actual = try HostedContentFiles.fingerprint(file: destination)
                guard actual.0 == fingerprint, actual.1 == authorization.size else { throw HostedContentError.integrityMismatch }
            }
            try Task.checkCancellation()
            downloadedFiles[destination.standardizedFileURL] = lease
            progress(1)
            return destination
        } catch {
            lease.remove()
            throw error
        }
    }

    /// Release only a verified file returned by this client, after the semantic layer copied it.
    /// A caller-supplied path cannot authorize deleting arbitrary staging or managed content.
    public func discardDownloadedFile(_ file: URL) {
        let file = file.standardizedFileURL
        guard let lease = downloadedFiles.removeValue(forKey: file) else { return }
        lease.remove()
    }

    private func provePossession(file: URL, byteCount: Int64, prepareBody: Data) async throws {
        guard byteCount >= 65536 else { throw HostedContentError.invalidChallenge }
        let challenge: HostedProofChallenge = try await http.request(method: "POST", path: "/v1/content/claims", body: prepareBody,
                                                                    as: HostedProofChallenge.self)
        guard challenge.ranges.count == 4, challenge.ranges.allSatisfy({ $0.length == 4096 }),
              hostedDate(challenge.expiresAt).map({ $0 > Date() }) == true else { throw HostedContentError.invalidChallenge }
        let digest = try await HostedProofOfPossession.digest(fileURL: file, nonceHex: challenge.nonce, ranges: challenge.ranges)
        struct Proof: Encodable { let digest: String }
        _ = try await http.send(method: "POST", path: "/v1/content/claims/" + challenge.challengeID.uuidString.lowercased() + "/verify",
                                body: JSONEncoder().encode(Proof(digest: digest)))
    }

    private func makeDirectory() async throws -> HostedStagingDirectory {
        let root = stagingDirectory
        return try await HostedContentFiles.background { try HostedStagingDirectory.acquire(in: root) }
    }

    private func beginTransfer() throws {
        try Task.checkCancellation()
        guard activeTransfers < 2 else { throw HostedHTTPError(problem: .limitExceeded) }
        activeTransfers += 1
    }

    private func retry<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch let error as HostedHTTPError where (error.status == 429 || error.status == 503) && attempt < 2 {
                // Long server cooldowns belong to the caller's scheduler; never retry before Retry-After.
                guard (error.retryAfterSeconds ?? 0) <= 60 else { throw error }
                try await sleep(max(pow(2, Double(attempt)), Double(error.retryAfterSeconds ?? 0)))
            }
        }
        throw HostedContentError.verificationTimedOut
    }
}
