// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  HostedArtworkTransportTests.swift — custom covers over Relay Sync (protocol
//  1.2.0, semantic schema 3): negotiation and its fallback to 2, the cover
//  upload before its value, one schema per request, the artwork-only replay of
//  ranges schema-2 pages skipped, released covers and re-upload after release.
import Foundation
import XCTest
import RelayDomain
import RelayLibrary
import RelaySync
@testable import RelayHostedSync

// Immutable fixtures only; the fake server closures read them from other tasks.
final class HostedArtworkTransportTests: XCTestCase, @unchecked Sendable {
    private let game = try! ContentFingerprint(parsing: "sha256:" + String(repeating: "a", count: 64))
    private let install = InstallationID("30000000-0000-4000-8000-000000000001")!
    private let coverBytes = Data("normalized cover bytes".utf8)
    private var cover: ContentFingerprint { try! SHA256ContentHasher().hash(data: coverBytes).fingerprint }
    private let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func transport(_ fixture: TransportHTTPFixture, directory: URL, plane: TransportDataPlaneFixture? = nil) throws -> RelayHostedSyncTransport {
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        let content = HostedContentClient(http: http, stagingDirectory: directory.appendingPathComponent("content"),
                                          dataPlane: plane ?? TransportDataPlaneFixture(coverBytes))
        return try RelayHostedSyncTransport(http: http, content: content, accountIdentity: "opaque-account", installationID: install,
                                            stateDirectory: directory, automaticSync: false)
    }
    private func artwork(_ chosen: ContentFingerprint?, at updatedAt: Int64 = 1_788_520_002_000) -> SyncRecord {
        .artwork(SyncArtwork(fingerprint: game, artworkFingerprint: chosen, artworkSize: chosen == nil ? nil : Int64(coverBytes.count),
                             updatedAt: updatedAt, installationID: install))
    }
    private func gameRecord() -> SyncRecord {
        .game(SyncGameEntry(fingerprint: game, systemID: "gba", title: "Example Game", isFavorite: false,
                            addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil))
    }
    private func coverFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("cover.heic")
        try coverBytes.write(to: url)
        return url
    }
    private static func header(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "X-Relay-Sync-Schema") }
    private static func cursor(_ request: URLRequest) -> Int64 {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Int64(query.first { $0.name == "cursor" }?.value ?? "0")!
    }
    private static func page(_ changes: [HostedChange], cursor: Int64, schema: String) throws -> Data {
        struct Body: Encodable { var schema: Int; var changes: [HostedChange]; var nextCursor: Int64; var hasMore: Bool }
        return try JSONEncoder().encode(Body(schema: Int(schema)!, changes: changes, nextCursor: cursor, hasMore: false))
    }
    private static func operations(_ request: URLRequest) throws -> [HostedOperation] {
        struct Body: Decodable { let operations: [HostedOperation] }
        return try JSONDecoder().decode(Body.self, from: request.httpBody!).operations
    }
    private static func pushResult(_ request: URLRequest, status: String, error: String? = nil) throws -> Data {
        struct Result: Encodable { var operationId: String; var status: String; var error: String? }
        struct Response: Encodable { var results: [Result] }
        return try JSONEncoder().encode(Response(results: try operations(request).map { Result(operationId: $0.operationId, status: status, error: error) }))
    }
    /// A content service that completes single uploads and authorizes downloads of any owned object.
    private func content(_ request: URLRequest, uploadID: String) -> (Int, Data, [String: String])? {
        let path = request.url!.path
        if path == "/v1/content/uploads" {
            return (201, Data("{\"upload_id\":\"\(uploadID)\",\"mode\":\"single\",\"expires_at\":\"\(expires)\",\"upload\":{\"url\":\"https://content.example.test/object\",\"method\":\"PUT\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
        }
        if path.hasSuffix("/complete") { return (202, Data("{}".utf8), [:]) }
        if path == "/v1/content/uploads/" + uploadID { return (200, Data("{\"upload_id\":\"\(uploadID)\",\"status\":\"COMPLETE\"}".utf8), [:]) }
        if path.hasPrefix("/v1/content/downloads/") {
            return (200, Data("{\"size\":\(coverBytes.count),\"download\":{\"url\":\"https://content.example.test/object\",\"method\":\"GET\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
        }
        return nil
    }

    // MARK: Negotiation

    func testSchemaTwoServerKeepsCoversLocalWithoutAProblem() async throws {
        let fixture = TransportHTTPFixture(schemas: ["2"]) { request, _ in
            if request.url!.path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let transport = try transport(fixture, directory: directory())
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: gameRecord().key, payload: .save(gameRecord(), assets: [:]))])
        let before = await transport.sendsArtwork
        try await transport.start(host: host); try await transport.synchronize()
        let after = await transport.sendsArtwork, refused = await fixture.refused, requests = await fixture.requests
        let problem = await host.lastProblem(), pending = await host.pendingCount()
        XCTAssertTrue(before, "a fresh session offers schema 3")
        XCTAssertFalse(after, "a 426 naming 2 keeps covers local for the session")
        XCTAssertEqual(refused.count, 1, "one refusal, then every request negotiates 2")
        XCTAssertEqual(Set(requests.compactMap(Self.header)), ["2"])
        XCTAssertEqual(try requests.filter { $0.url!.path == "/v1/sync/push" }.flatMap(Self.operations).map(\.schema), [2])
        XCTAssertNil(problem); XCTAssertEqual(pending, 0)
    }

    func testPendingOperationsReplayUnderTheirOwnSchema() async throws {
        let dir = try directory()
        let hash = try SHA256ContentHasher().hash(data: Data("preproduction:opaque-account".utf8)).fingerprint.hexDigest
        let accountDirectory = dir.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        // Sent under schema 2, answer lost: its replay must be the same bytes under the same header.
        let uncertain = try HostedWireCodec.encode(gameRecord(), operationID: UUID(), schema: 2)
        struct Receipt: Encodable { let key: RecordKey; let journalIDs: [Int64]; let operation: HostedOperation; let terminal = false; let accepted = false; let deferred = false }
        struct State: Encodable { let pending: [Receipt]; let content: [String: SyncContentIndex] = [:]; let systems: [String: String] = [:] }
        try HostedWireCodec.encoded(State(pending: [Receipt(key: gameRecord().key, journalIDs: [1], operation: uncertain)]))
            .write(to: accountDirectory.appendingPathComponent("transport.schema2.json"))
        let uploadID = UUID().uuidString.lowercased()
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { [self] request, _ in
            if let response = content(request, uploadID: uploadID) { return response }
            if request.url!.path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let host = TransportHostFixture([
            OutboundChange(journalIDs: [1], key: gameRecord().key, payload: .save(gameRecord(), assets: [:])),
            OutboundChange(journalIDs: [2], key: artwork(cover).key, payload: .save(artwork(cover), assets: [.data: try coverFile(in: dir)])),
        ])
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        let pushes = await fixture.requests.filter { $0.url!.path == "/v1/sync/push" }
        XCTAssertEqual(pushes.map(Self.header), ["2", "3"], "one schema per request")
        XCTAssertEqual(try Self.operations(pushes[0]), [uncertain], "the uncertain operation is replayed byte for byte")
        let second = try Self.operations(pushes[1])
        XCTAssertEqual(second.map(\.kind), ["artwork"]); XCTAssertEqual(second.map(\.schema), [3])
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 0)
    }

    func testFallbackRebuildsOperationsBuiltUnderSchemaThree() async throws {
        let dir = try directory()
        let hash = try SHA256ContentHasher().hash(data: Data("preproduction:opaque-account".utf8)).fingerprint.hexDigest
        let accountDirectory = dir.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        // Built under schema 3 before the server rolled back to 2: a journaled game, a cover and a journal-less removal.
        let journaled = try HostedWireCodec.encode(gameRecord(), operationID: UUID(), schema: 3)
        let cover = try HostedWireCodec.encode(artwork(nil), operationID: UUID(), schema: 3)
        let removal = HostedOperation(operationId: UUID().uuidString.lowercased(), schema: 3, kind: "content_availability", action: "upsert",
                                      object: ["fingerprint": .string(game.description), "generation": .integer(0), "stored": .bool(false)])
        struct Receipt: Encodable { let key: RecordKey; let journalIDs: [Int64]; let operation: HostedOperation; let terminal = false; let accepted = false; let deferred = false }
        struct State: Encodable { let pending: [Receipt]; let content: [String: SyncContentIndex] = [:]; let systems: [String: String] = [:] }
        try HostedWireCodec.encoded(State(pending: [
            Receipt(key: gameRecord().key, journalIDs: [1], operation: journaled),
            Receipt(key: artwork(nil).key, journalIDs: [2], operation: cover),
            Receipt(key: .contentIndex(game, generation: 0), journalIDs: [], operation: removal),
        ])).write(to: accountDirectory.appendingPathComponent("transport.schema2.json"))
        let fixture = TransportHTTPFixture(schemas: ["2"]) { request, _ in
            if request.url!.path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: gameRecord().key, payload: .save(gameRecord(), assets: [:]))])
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        let pushes = await fixture.requests.filter { $0.url!.path == "/v1/sync/push" }
        let sent = try pushes.flatMap(Self.operations)
        XCTAssertEqual(Set(pushes.map(Self.header)), ["2"])
        XCTAssertEqual(Set(sent.map(\.schema)), [2])
        XCTAssertFalse(sent.contains { $0.kind == "artwork" }, "a cover cannot be expressed under schema 2")
        XCTAssertFalse(sent.map(\.operationId).contains(journaled.operationId), "rebuilt from its journal row")
        XCTAssertFalse(sent.map(\.operationId).contains(removal.operationId), "re-issued under a new identity")
        XCTAssertEqual(sent.filter { $0.kind == "content_availability" }.count, 1)
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 0)
    }

    // MARK: Push

    func testCoverUploadsBeforeItsValueIsPushed() async throws {
        let dir = try directory(), uploadID = UUID().uuidString.lowercased()
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { [self] request, _ in
            if let response = content(request, uploadID: uploadID) { return response }
            if request.url!.path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let plane = TransportDataPlaneFixture(coverBytes)
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: artwork(cover).key, payload: .save(artwork(cover), assets: [.data: try coverFile(in: dir)]))])
        let transport = try transport(fixture, directory: dir, plane: plane)
        try await transport.start(host: host); try await transport.synchronize()
        let requests = await fixture.requests, uploaded = await plane.uploaded
        let paths = requests.map { $0.url!.path }
        let prepare = try XCTUnwrap(requests.first { $0.url!.path == "/v1/content/uploads" })
        XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: "/v1/content/uploads")), try XCTUnwrap(paths.firstIndex(of: "/v1/sync/push")))
        XCTAssertEqual(Self.header(prepare), "3", "a game_artwork transfer requires schema 3")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepare.httpBody!) as? [String: Any])
        let target = try XCTUnwrap(body["target"] as? [String: Any])
        XCTAssertEqual(body["storageClass"] as? String, "critical")
        XCTAssertEqual(target["category"] as? String, "screenshots_other")
        XCTAssertEqual(target["ref_type"] as? String, "game_artwork")
        XCTAssertEqual(target["ref_key"] as? String, cover.description)
        XCTAssertEqual(target["game_fingerprint"] as? String, game.description)
        XCTAssertEqual(uploaded, [coverBytes])
        let operation = try XCTUnwrap(Self.operations(try XCTUnwrap(requests.first { $0.url!.path == "/v1/sync/push" })).first)
        XCTAssertEqual(operation.schema, 3); XCTAssertEqual(operation.kind, "artwork"); XCTAssertEqual(operation.action, "upsert")
        XCTAssertEqual(operation.object, ["fingerprint": .string(game.description), "generation": .integer(0), "updatedAt": .integer(1_788_520_002_000),
                                          "installationID": .string(install.description), "artworkFingerprint": .string(cover.description),
                                          "artworkSize": .integer(Int64(coverBytes.count))])
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 0)
    }

    func testResetIsADeleteWithoutUpload() async throws {
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { request, _ in
            if request.url!.path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: artwork(nil).key, payload: .save(artwork(nil), assets: [:]))])
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.synchronize()
        let requests = await fixture.requests
        XCTAssertFalse(requests.contains { $0.url!.path.hasPrefix("/v1/content/") })
        let operation = try XCTUnwrap(Self.operations(try XCTUnwrap(requests.first { $0.url!.path == "/v1/sync/push" })).first)
        XCTAssertEqual(operation.action, "delete")
        XCTAssertEqual(Set(operation.object.keys), ["fingerprint", "generation", "updatedAt", "installationID"])
    }

    func testCoverNoLongerOwnedIsUploadedAgainWithoutAProblem() async throws {
        let dir = try directory(), uploadID = UUID().uuidString.lowercased()
        let firstPush = FirstOperation()
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { [self] request, _ in
            if let response = content(request, uploadID: uploadID) { return response }
            if request.url!.path == "/v1/sync/push" {
                let refused = firstPush.isFirst(try Self.operations(request)[0].operationId)
                return (200, try Self.pushResult(request, status: refused ? "rejected" : "applied", error: refused ? "verified artwork is not owned" : nil), [:])
            }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let plane = TransportDataPlaneFixture(coverBytes)
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: artwork(cover).key, payload: .save(artwork(cover), assets: [.data: try coverFile(in: dir)]))])
        let transport = try transport(fixture, directory: dir, plane: plane)
        try await transport.start(host: host); try await transport.synchronize()
        let waiting = await host.pendingCount(), problem = await host.lastProblem()
        XCTAssertEqual(waiting, 1, "the value stays journaled"); XCTAssertNil(problem, "never a repair")
        try await transport.synchronize()
        let pushes = await fixture.requests.filter { $0.url!.path == "/v1/sync/push" }
        let identifiers = try pushes.flatMap(Self.operations).map(\.operationId)
        let uploaded = await plane.uploaded, pending = await host.pendingCount()
        XCTAssertEqual(uploaded.count, 2, "the image is uploaded again")
        XCTAssertEqual(identifiers.count, 2); XCTAssertEqual(Set(identifiers).count, 2, "under a new operation")
        XCTAssertEqual(pending, 0)
    }

    // MARK: Pull

    func testSkippedRangeIsReplayedForArtworkOnlyWithoutMovingTheCursor() async throws {
        let old = try HostedWireCodec.encode(artwork(cover), operationID: UUID(), schema: 3)
        let gameChange = try HostedWireCodec.encode(gameRecord(), operationID: UUID(), schema: 3)
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { [self] request, _ in
            if let response = content(request, uploadID: "unused") { return response }
            if Self.cursor(request) == 0 {
                return (200, try Self.page([
                    HostedChange(sequence: 3, kind: "artwork", objectKey: game.description, operation: "upsert", object: old.object),
                    HostedChange(sequence: 5, kind: "game", objectKey: game.description, operation: "upsert", object: gameChange.object),
                ], cursor: 5, schema: Self.header(request)!), [:])
            }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let host = TransportHostFixture()
        await host.setCursor(5) // Built by schema-2 pages, which skipped artwork.
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.fetchNow()
        let changes = await host.changes, cursor = await host.cursor, copied = await host.copiedData
        XCTAssertEqual(changes.map(\.record), [artwork(cover)], "only the artwork of the skipped range")
        XCTAssertEqual(copied, [coverBytes], "the verified cover reaches the host")
        XCTAssertEqual(cursor, 5, "the semantic cursor does not move")
        try await transport.fetchNow()
        let replays = await fixture.requests.filter { $0.url!.path == "/v1/sync/changes" && Self.cursor($0) == 0 }
        XCTAssertEqual(replays.count, 1, "the range is replayed once")
    }

    func testReleasedCoverIsSkippedAndTheCursorAdvances() async throws {
        let value = try HostedWireCodec.encode(artwork(cover), operationID: UUID(), schema: 3)
        let fixture = TransportHTTPFixture(schemas: ["2", "3"]) { [self] request, _ in
            if request.url!.path.hasPrefix("/v1/content/downloads/") { return (404, Data("{}".utf8), [:]) }
            if Self.cursor(request) == 0 {
                return (200, try Self.page([HostedChange(sequence: 1, kind: "artwork", objectKey: game.description, operation: "upsert", object: value.object)],
                                           cursor: 1, schema: Self.header(request)!), [:])
            }
            return (200, try Self.page([], cursor: Self.cursor(request), schema: Self.header(request)!), [:])
        }
        let host = TransportHostFixture()
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.fetchNow()
        let changes = await host.changes, cursor = await host.cursor
        XCTAssertTrue(changes.isEmpty); XCTAssertEqual(cursor, 1)
    }

    // MARK: Codec

    /// Every schema-3 operation in the frozen 1.2.0 vectors round-trips through the codec unchanged.
    func testVendored120ArtworkCorpusRoundTripsExactly() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.2.0/testdata/semantic-schema-3.json"))
        struct Corpus: Decodable {
            struct Scenario: Decodable { let name: String; let operations: [HostedOperation] }
            let schema: Int; let cases: [Scenario]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertEqual(corpus.schema, 3); XCTAssertEqual(corpus.cases.count, 5)
        var covers = 0
        for scenario in corpus.cases {
            for operation in scenario.operations where operation.schema == 3 {
                let objectKey = try XCTUnwrap(operation.object["fingerprint"]?.string)
                let decoded = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: operation.kind, objectKey: objectKey,
                                                                      operation: operation.action, object: operation.object), schema: 3)
                let record = try XCTUnwrap(decoded.record, scenario.name)
                let encoded = try HostedWireCodec.encode(record, operationID: XCTUnwrap(UUID(uuidString: operation.operationId)), schema: 3)
                XCTAssertEqual(encoded, operation, scenario.name)
                if operation.kind == "artwork" { covers += 1 }
            }
        }
        XCTAssertEqual(covers, 10, "every artwork upsert and delete in the corpus")
    }

    func testArtworkWireShapeFollowsSchemaThree() throws {
        XCTAssertThrowsError(try HostedWireCodec.encode(artwork(cover), operationID: UUID(), schema: 2), "artwork does not exist under schema 2")
        let upsert = try HostedWireCodec.encode(artwork(cover), operationID: UUID(), schema: 3)
        let reset = try HostedWireCodec.encode(artwork(nil), operationID: UUID(), schema: 3)
        func change(_ operation: HostedOperation, key: String? = nil) -> HostedChange {
            HostedChange(sequence: 1, kind: operation.kind, objectKey: key ?? game.description, operation: operation.action, object: operation.object)
        }
        XCTAssertEqual(try HostedWireCodec.decode(change(upsert), schema: 3).record, artwork(cover))
        XCTAssertEqual(try HostedWireCodec.decode(change(reset), schema: 3).record, artwork(nil))
        XCTAssertThrowsError(try HostedWireCodec.decode(change(upsert), schema: 2), "a schema-2 page never carries artwork")
        XCTAssertThrowsError(try HostedWireCodec.decode(change(upsert, key: cover.description), schema: 3))
        var mixed = change(reset); mixed.object["artworkSize"] = .integer(10)
        XCTAssertThrowsError(try HostedWireCodec.decode(mixed, schema: 3), "a delete names no cover")
        var oversized = change(upsert); oversized.object["artworkSize"] = .integer(Int64(SyncLimits.maxArtworkSize) + 1)
        XCTAssertThrowsError(try HostedWireCodec.decode(oversized, schema: 3))
        XCTAssertEqual(try HostedWireCodec.encode(gameRecord(), operationID: UUID(), schema: 3).schema, 3, "every kind carries the negotiated schema")
    }
}

/// Remembers the first operation it is asked about.
private final class FirstOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    func isFirst(_ id: String) -> Bool {
        lock.withLock {
            if first == nil { first = id }
            return first == id
        }
    }
}
