// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import RelayDomain
@testable import RelayHostedSync

final class HostedContentTests: XCTestCase {
    private let uploadID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ data: Data, directory: URL) throws -> (URL, ContentFingerprint) {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return (file, try ContentFingerprint(sha256: Array(SHA256.hash(data: data))))
    }
    private func capability(method: String = "PUT", size: Int64? = nil) -> [String: Any] {
        ["url": "https://objects.example.test/private?signature=never-log", "method": method,
         "headers": size.map { ["Content-Length": String($0), "x-amz-meta-test": "unchanged"] } ?? [:],
         "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]
    }
    private func prepare(size: Int64) -> [String: Any] {
        var object: [String: Any] = ["upload_id": uploadID.uuidString, "mode": size > HostedContentClient.multipartPartSize ? "multipart" : "single",
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]
        if size > HostedContentClient.multipartPartSize {
            object["part_size"] = HostedContentClient.multipartPartSize
            object["part_count"] = Int((size - 1) / HostedContentClient.multipartPartSize + 1)
        } else { object["upload"] = capability(size: size) }
        return object
    }
    private func target(_ fingerprint: ContentFingerprint, generation: Int64 = 0) -> HostedContentTarget {
        .init(category: "games", refType: "game_content", refKey: fingerprint.description, gameFingerprint: fingerprint, generation: generation)
    }
    private func client(_ executor: ContentHTTPFixture, directory: URL, plane: ContentDataPlaneFixture,
                        polls: Int = 5) -> HostedContentClient {
        HostedContentClient(http: HostedHTTPClient(baseURL: URL(string: "https://api.example.test")!, executor: executor, token: { "test-token" }),
                            stagingDirectory: directory.appendingPathComponent("staging"), dataPlane: plane, maximumStatusPolls: polls, sleep: { _ in })
    }

    func testImmutableProtocolProofVector() async throws {
        struct Vector: Decodable { let nonceHex: String; let ranges: [HostedProofRange]; let expectedDigestHex: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.0.1/testdata/proof-of-possession-v1.json")))
        let directory = try temporaryDirectory()
        let (file, _) = try fixture(Data(String(repeating: "relay", count: 20_000).utf8), directory: directory)
        let digest = try await HostedProofOfPossession.digest(fileURL: file, nonceHex: vector.nonceHex, ranges: vector.ranges)
        XCTAssertEqual(digest, vector.expectedDigestHex)
    }

    func testProofRejectsMalformedOverlappingAndOutOfBoundsRanges() async throws {
        let directory = try temporaryDirectory()
        let (file, _) = try fixture(Data(repeating: 7, count: 100), directory: directory)
        for ranges in [[HostedProofRange(offset: -1, length: 1)], [.init(offset: 99, length: 2)],
                       [.init(offset: 10, length: 20), .init(offset: 20, length: 20)], [.init(offset: 0, length: Int64.max)]] {
            do {
                _ = try await HostedProofOfPossession.digest(fileURL: file, nonceHex: String(repeating: "a5", count: 32), ranges: ranges)
                XCTFail("Invalid range accepted")
            } catch { XCTAssertEqual(error as? HostedContentError, .invalidChallenge) }
        }
    }

    func testSingleUploadWaitsForVerifiedStatusAndPreservesSemanticTarget() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data("owned content".utf8), directory: directory)
        let http = ContentHTTPFixture([
            .json(201, prepare(size: 13)), .json(202, [:]),
            .json(200, ["upload_id": uploadID.uuidString, "status": "VERIFYING"]),
            .json(200, ["upload_id": uploadID.uuidString, "status": "COMPLETE"]),
        ])
        let plane = ContentDataPlaneFixture()
        try await client(http, directory: directory, plane: plane).upload(fileURL: file, fingerprint: fingerprint, byteCount: 13,
            storageClass: .game, target: target(fingerprint, generation: 7), progress: { _ in })
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/content/uploads", "/v1/content/uploads/\(uploadID.uuidString.lowercased())/complete",
            "/v1/content/uploads/\(uploadID.uuidString.lowercased())", "/v1/content/uploads/\(uploadID.uuidString.lowercased())"])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        XCTAssertEqual(body["fingerprint"] as? String, "sha256:" + fingerprint.hexDigest)
        let targetBody = try XCTUnwrap(body["target"] as? [String: Any])
        XCTAssertEqual(targetBody["ref_type"] as? String, "game_content")
        XCTAssertEqual(targetBody["game_fingerprint"] as? String, fingerprint.description)
        XCTAssertEqual(targetBody["generation"] as? Int, 7)
        // A fresh session negotiates schema 3 on every request of the transfer.
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Relay-Sync-Schema") == "3" })
        let uploads = await plane.uploadSizes
        XCTAssertEqual(uploads, [13])
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path)
        XCTAssertTrue(children.isEmpty)
    }

    func testMultipartStreamsExactPartsAndFinalizesWithETags() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("large")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let size = HostedContentClient.multipartPartSize + 17
        try handle.truncate(atOffset: UInt64(size)); try handle.close()
        let fingerprint = try await HostedContentFiles.background { try HostedContentFiles.fingerprint(file: file).0 }
        let http = ContentHTTPFixture([.json(201, prepare(size: size)),
            .json(200, capability(size: HostedContentClient.multipartPartSize)), .json(200, capability(size: 17)),
            .json(202, [:]), .json(200, ["upload_id": uploadID.uuidString, "status": "COMPLETE"])])
        let plane = ContentDataPlaneFixture()
        try await client(http, directory: directory, plane: plane).upload(fileURL: file, fingerprint: fingerprint, byteCount: size,
            storageClass: .game, target: target(fingerprint), progress: { _ in })
        let uploads = await plane.uploadSizes
        XCTAssertEqual(uploads, [HostedContentClient.multipartPartSize, 17])
        let requests = await http.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        let parts = try XCTUnwrap(body["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["number"] as? Int, 2)
        XCTAssertEqual(parts[1]["etag"] as? String, "\"etag-2\"")
    }

    func testCorruptDownloadNeverReturnsAndRemovesStaging() async throws {
        let directory = try temporaryDirectory()
        let (_, fingerprint) = try fixture(Data("good".utf8), directory: directory)
        let http = ContentHTTPFixture([.json(200, ["size": 4, "download": capability(method: "GET")])])
        let plane = ContentDataPlaneFixture(downloadBytes: Data("evil".utf8))
        do {
            _ = try await client(http, directory: directory, plane: plane).download(fingerprint: fingerprint, byteCount: 4, progress: { _ in })
            XCTFail("Corrupt content was returned")
        } catch { XCTAssertEqual(error as? HostedContentError, .integrityMismatch) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path).isEmpty)
    }

    func testAuthorizedDownloadReturnsVerifiedPrivateStaging() async throws {
        let directory = try temporaryDirectory()
        let bytes = Data("good".utf8)
        let (_, fingerprint) = try fixture(bytes, directory: directory)
        let http = ContentHTTPFixture([.json(200, ["size": 4, "download": capability(method: "GET")])])
        let service = client(http, directory: directory, plane: ContentDataPlaneFixture(downloadBytes: bytes))
        let result = try await service.download(fingerprint: fingerprint, byteCount: 4, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        let requests = await http.requests
        XCTAssertEqual(requests[0].url!.path, "/v1/content/downloads/" + fingerprint.hexDigest)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        await service.discardDownloadedFile(result)
    }

    func testInterruptedDownloadDiscardsPartialFileAndPreservesExistingGoodContent() async throws {
        let directory = try temporaryDirectory()
        let bytes = Data("good".utf8)
        let (existing, fingerprint) = try fixture(bytes, directory: directory)
        let http = ContentHTTPFixture([.json(200, ["size": 4, "download": capability(method: "GET")])])
        do {
            _ = try await client(http, directory: directory, plane: ContentDataPlaneFixture(downloadBytes: Data("go".utf8), interruptDownload: true))
                .download(fingerprint: fingerprint, byteCount: 4, progress: { _ in })
            XCTFail("Partial content was returned")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path).isEmpty)
    }

    func testDownloadAuthorizationCannotChangeExpectedSize() async throws {
        let directory = try temporaryDirectory()
        let (_, fingerprint) = try fixture(Data("good".utf8), directory: directory)
        let http = ContentHTTPFixture([.json(200, ["size": 100000, "download": capability(method: "GET")])])
        do {
            _ = try await client(http, directory: directory, plane: ContentDataPlaneFixture()).download(fingerprint: fingerprint, byteCount: 4,
                                                                                                      progress: { _ in })
            XCTFail("Conflicting remote length accepted")
        } catch { XCTAssertEqual(error as? HostedContentError, .integrityMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path))
    }

    func testScreenshotAuthorizationOverLimitNeverStartsDataPlane() async throws {
        let directory = try temporaryDirectory()
        let (_, fingerprint) = try fixture(Data("good".utf8), directory: directory)
        let screenshotLimit: Int64 = 4 * 1024 * 1024
        let http = ContentHTTPFixture([.json(200, ["size": screenshotLimit + 1, "download": capability(method: "GET")])])
        let plane = ContentDataPlaneFixture()
        do {
            _ = try await client(http, directory: directory, plane: plane).download(fingerprint: fingerprint,
                maximumByteCount: screenshotLimit, progress: { _ in })
            XCTFail("Oversized screenshot authorization accepted")
        } catch { XCTAssertEqual(error as? HostedContentError, .integrityMismatch) }
        let downloads = await plane.downloadCount
        XCTAssertEqual(downloads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path))
    }

    func testDiscardRemovesOnlyOwnedDownloadedDirectory() async throws {
        let directory = try temporaryDirectory()
        let bytes = Data("good".utf8)
        let (existing, fingerprint) = try fixture(bytes, directory: directory)
        let http = ContentHTTPFixture([.json(200, ["size": 4, "download": capability(method: "GET")])])
        let service = client(http, directory: directory, plane: ContentDataPlaneFixture(downloadBytes: bytes))
        let result = try await service.download(fingerprint: fingerprint, byteCount: 4, progress: { _ in })
        await service.discardDownloadedFile(existing)
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        await service.discardDownloadedFile(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await service.discardDownloadedFile(result)
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }

    func testStartupReclaimsMarkedOrphanWithoutAuthenticationOrTransfer() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("staging")
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: abandoned.appendingPathComponent(HostedStagingDirectory.markerName).path,
            contents: Data(HostedStagingDirectory.markerContents), attributes: [.posixPermissions: 0o600]))
        try Data("unfinished upload".utf8).write(to: abandoned.appendingPathComponent("source"))
        let http = ContentHTTPFixture([])
        let plane = ContentDataPlaneFixture()
        let service = client(http, directory: directory, plane: plane)
        try await service.prepareStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        let requests = await http.requests
        let downloads = await plane.downloadCount
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(downloads, 0)
    }

    func testWrongLocalHashNeverReservesQuota() async throws {
        let directory = try temporaryDirectory()
        let (file, _) = try fixture(Data("oops".utf8), directory: directory)
        let (_, fingerprint) = try fixture(Data("good".utf8), directory: directory)
        let http = ContentHTTPFixture([])
        do {
            try await client(http, directory: directory, plane: ContentDataPlaneFixture()).upload(fileURL: file, fingerprint: fingerprint,
                byteCount: 4, storageClass: .game, target: target(fingerprint), progress: { _ in })
            XCTFail("Unverified local file uploaded")
        } catch { XCTAssertEqual(error as? HostedContentError, .integrityMismatch) }
        let count = await http.requests.count
        XCTAssertEqual(count, 0)
    }

    func testServerFailedVerificationIsNeverAcknowledged() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data("safe".utf8), directory: directory)
        let http = ContentHTTPFixture([.json(201, prepare(size: 4)), .json(202, [:]),
            .json(200, ["upload_id": uploadID.uuidString, "status": "FAILED"])])
        do {
            try await client(http, directory: directory, plane: ContentDataPlaneFixture()).upload(fileURL: file, fingerprint: fingerprint,
                byteCount: 4, storageClass: .game, target: target(fingerprint), progress: { _ in })
            XCTFail("Failed server verification accepted")
        } catch { XCTAssertEqual(error as? HostedContentError, .verificationFailed) }
    }

    func testPresignRejectsBearerAndLengthMismatchAndInsecureURLs() throws {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let good = HostedPresignedRequest(url: URL(string: "https://objects.example.test/a?secret")!, method: "PUT",
            headers: ["Content-Length": "4", "x-amz-test": "value"], expiresAt: expires)
        let request = try good.request(method: "PUT", byteCount: 4)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-test"), "value")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try good.request(method: "PUT", byteCount: 5))
        for capability in [HostedPresignedRequest(url: good.url, method: "PUT", headers: ["Authorization": "Bearer token"], expiresAt: expires),
                           .init(url: URL(string: "http://objects.example.test")!, method: "PUT", headers: [:], expiresAt: expires)] {
            XCTAssertThrowsError(try capability.request(method: "PUT", byteCount: 4))
        }
    }

    func testExistingContentRequiresValidPossessionProofBeforeSuccess() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data(repeating: 71, count: 65536), directory: directory)
        let ranges = [HostedProofRange(offset: 0, length: 4096), .init(offset: 8192, length: 4096),
                      .init(offset: 32768, length: 4096), .init(offset: 61440, length: 4096)]
        let nonce = String(repeating: "a5", count: 32)
        let expected = try await HostedProofOfPossession.digest(fileURL: file, nonceHex: nonce, ranges: ranges)
        let http = ContentHTTPFixture([
            .json(409, ["detail": "content exists; use proof of possession"]),
            .json(201, ["challenge_id": uploadID.uuidString, "nonce": nonce,
                       "ranges": ranges.map { ["offset": $0.offset, "length": $0.length] },
                       "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))]), .json(204, [:]),
        ])
        let plane = ContentDataPlaneFixture()
        try await client(http, directory: directory, plane: plane).upload(fileURL: file, fingerprint: fingerprint, byteCount: 65536,
            storageClass: .game, target: target(fingerprint), progress: { _ in })
        let requests = await http.requests
        XCTAssertEqual(requests[1].url!.path, "/v1/content/claims")
        let proof = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String]
        XCTAssertEqual(proof, ["digest": expected])
        let uploads = await plane.uploadSizes
        XCTAssertTrue(uploads.isEmpty)
    }

    func testUnrelatedConflictDoesNotTriggerPossessionClaim() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data(repeating: 71, count: 65536), directory: directory)
        let http = ContentHTTPFixture([.json(409, ["detail": "target already bound"])])
        do {
            try await client(http, directory: directory, plane: ContentDataPlaneFixture()).upload(fileURL: file, fingerprint: fingerprint,
                byteCount: 65536, storageClass: .game, target: target(fingerprint), progress: { _ in })
            XCTFail("Conflict accepted")
        } catch { XCTAssertEqual((error as? HostedHTTPError)?.status, 409) }
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
    }

    func testFinalizeRetriesAreBoundedAndKeepSameSession() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data("safe".utf8), directory: directory)
        let http = ContentHTTPFixture([.json(201, prepare(size: 4)), .json(503, [:]), .json(429, [:]), .json(503, [:])])
        do {
            try await client(http, directory: directory, plane: ContentDataPlaneFixture()).upload(fileURL: file, fingerprint: fingerprint,
                byteCount: 4, storageClass: .game, target: target(fingerprint), progress: { _ in })
            XCTFail("Exhausted request accepted")
        } catch { XCTAssertEqual((error as? HostedHTTPError)?.status, 503) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.dropFirst().map { $0.url!.path }).count, 1)
        XCTAssertEqual(Set(requests.dropFirst().compactMap(\.httpBody)).count, 1)
    }

    func testCancellationInterruptsFileProcessingBeforeNetwork() async throws {
        let directory = try temporaryDirectory()
        let (file, fingerprint) = try fixture(Data(repeating: 1, count: 2 * 1024 * 1024), directory: directory)
        let http = ContentHTTPFixture([])
        let service = client(http, directory: directory, plane: ContentDataPlaneFixture())
        let capturedTarget = target(fingerprint)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.upload(fileURL: file, fingerprint: fingerprint, byteCount: 2 * 1024 * 1024,
                storageClass: .game, target: capturedTarget, progress: { _ in })
        }
        do { try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor ContentHTTPFixture: HostedHTTPExecuting {
    struct Response: @unchecked Sendable {
        let status: Int; let body: Data
        static func json(_ status: Int, _ object: [String: Any]) -> Self {
            Self(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }
    private var responses: [Response]
    private(set) var requests = [URLRequest]()
    init(_ responses: [Response]) { self.responses = responses }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw HostedHTTPError.invalidResponse }
        let response = responses.removeFirst()
        return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ContentDataPlaneFixture: HostedContentDataPlane {
    let downloadBytes: Data
    let interruptDownload: Bool
    private(set) var uploadSizes = [Int64]()
    private(set) var downloadCount = 0
    init(downloadBytes: Data = Data(), interruptDownload: Bool = false) {
        self.downloadBytes = downloadBytes; self.interruptDownload = interruptDownload
    }
    func upload(_ capability: HostedPresignedRequest, file: URL, byteCount: Int64,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        guard Int64(size) == byteCount else { throw HostedContentError.integrityMismatch }
        uploadSizes.append(byteCount); progress(1)
        return "\"etag-\(uploadSizes.count)\""
    }
    func download(_ capability: HostedPresignedRequest, to destination: URL, byteCount: Int64,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCount += 1
        try downloadBytes.write(to: destination); progress(1)
        if interruptDownload { throw CancellationError() }
    }
}
