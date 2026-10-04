// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import RelayDomain
import RelaySync
import RelayLibrary
import RelayPersistence
@testable import RelayHostedSync

/// A server speaking `schemas`. Like Relay Sync, it refuses any other negotiation on a semantic
/// route with 426 naming its newest schema; refusals are kept apart from `requests`.
actor TransportHTTPFixture: HostedHTTPExecuting {
    var requests: [URLRequest] = []
    var refused: [URLRequest] = []
    let schemas: Set<String>
    let response: @Sendable (URLRequest, Int) throws -> (Int, Data, [String: String])
    init(schemas: Set<String> = ["2"], _ response: @escaping @Sendable (URLRequest, Int) throws -> (Int, Data, [String: String])) {
        self.schemas = schemas; self.response = response
    }
    static func negotiates(_ request: URLRequest) -> Bool {
        let path = request.url!.path
        return path.hasPrefix("/v1/sync/") || (request.httpMethod == "POST" && (path == "/v1/content/uploads" || path == "/v1/content/claims"))
    }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if Self.negotiates(request), !schemas.contains(request.value(forHTTPHeaderField: "X-Relay-Sync-Schema") ?? "") {
            refused.append(request)
            return (Data("{\"detail\":\"schema\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 426, httpVersion: "HTTP/1.1",
                headerFields: ["X-Relay-Sync-Schema": schemas.max()!])!)
        }
        requests.append(request)
        let (status, data, headers) = try response(request, requests.count)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    func bodies() -> [Data] { requests.filter { $0.url?.path == "/v1/sync/push" }.compactMap(\.httpBody) }
    func count() -> Int { requests.count }
}
actor TransportHostFixture: SyncTransportHost {
    var outbound: [OutboundChange]
    var inFlight: Set<RecordKey> = []
    var changes: [InboundChange] = []
    var copiedPayloads: [Data] = []
    var copiedData: [Data] = []
    var cursor: Int64 = 0
    var failApply = false
    var retainAcknowledgements = false
    var retireAfterMembershipRead: (Int64, URL)?
    var outcomes: [SendResult] = []
    var status = TransportStatus()
    init(_ outbound: [OutboundChange] = []) { self.outbound = outbound }
    func nextOutboundBatch(limit: Int) -> [OutboundChange] {
        let selected = Array(outbound.filter { !inFlight.contains($0.key) }.prefix(limit))
        inFlight.formUnion(selected.map(\.key)); return selected
    }
    func nextHostedOutboundPage(afterSequence: Int64, throughSequence: Int64?, limit: Int) throws -> HostedOutboundPage {
        let ceiling = throughSequence ?? outbound.flatMap(\.journalIDs).max() ?? afterSequence
        guard afterSequence >= 0, ceiling >= afterSequence, limit > 0 else { throw HostedHTTPError.invalidResponse }
        let remaining = outbound.filter { change in
            guard let id = change.journalIDs.last else { return false }
            return id > afterSequence && id <= ceiling
        }.sorted { $0.journalIDs.last! < $1.journalIDs.last! }
        let examined = Array(remaining.prefix(limit))
        let changes = examined.filter { !inFlight.contains($0.key) }
        inFlight.formUnion(changes.map(\.key))
        return HostedOutboundPage(changes: changes, nextAfterSequence: examined.last?.journalIDs.last ?? afterSequence,
            throughSequence: ceiling, hasMore: remaining.count > limit)
    }
    func append(_ change: OutboundChange) { outbound.append(change) }
    func didSend(_ results: [SendResult]) {
        outcomes += results
        for result in results {
            inFlight.remove(result.key)
            switch result.outcome {
            case .saved, .deleted: if !retainAcknowledgements { outbound.removeAll { $0.key == result.key } }
            case .failed: break
            }
        }
    }
    func didFetch(changes: [InboundChange], deletions: [RecordKey]) { self.changes += changes }
    func accountDidChange(_ change: AccountChange) {}
    func transportDidUpdate(_ status: TransportStatus) { self.status = status }
    func zoneWasReset() {}
    func hostedCursor(scope: String) -> Int64 { cursor }
    func hostedPendingJournalIDs(in ids: [Int64]) async throws -> Set<Int64> {
        let pending = Set(outbound.flatMap(\.journalIDs)).intersection(ids)
        if let (id, url) = retireAfterMembershipRead, ids.contains(id) {
            retireAfterMembershipRead = nil
            outbound.removeAll { $0.journalIDs.contains(id) }
            try FileManager.default.removeItem(at: url)
        }
        return pending
    }
    func setRetirementAfterMembershipRead(id: Int64, url: URL) { retireAfterMembershipRead = (id, url) }
    func applyHostedPage(changes: [InboundChange], deletions: [RecordKey], cursor: Int64, scope: String) throws {
        if failApply { throw HostedHTTPError.invalidResponse }
        for change in changes {
            if let url = change.assets[.payload] { copiedPayloads.append(try Data(contentsOf: url)) }
            if let url = change.assets[.data] { copiedData.append(try Data(contentsOf: url)) }
        }
        self.changes += changes; self.cursor = cursor
    }
    func setFailApply(_ value: Bool) { failApply = value }
    func setCursor(_ value: Int64) { cursor = value }
    func setRetainAcknowledgements(_ value: Bool) { retainAcknowledgements = value }
    func pendingCount() -> Int { outbound.count }
    func lastProblem() -> TransportProblem? { status.lastProblem }
}
actor TransportDataPlaneFixture: HostedContentDataPlane {
    let payload: Data
    let beforeFirstUpload: (@Sendable () async throws -> Void)?
    var uploaded: [Data] = []
    init(_ payload: Data, beforeFirstUpload: (@Sendable () async throws -> Void)? = nil) {
        self.payload = payload; self.beforeFirstUpload = beforeFirstUpload
    }
    func upload(_ capability: HostedPresignedRequest, file: URL, byteCount: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        if uploaded.isEmpty { try await beforeFirstUpload?() }
        uploaded.append(try Data(contentsOf: file)); return "fixture-etag"
    }
    func download(_ capability: HostedPresignedRequest, to destination: URL, byteCount: Int64, progress: @escaping @Sendable (Double) -> Void) throws {
        try payload.write(to: destination)
    }
}
final class HostedTransportTests: XCTestCase {
    private let fp = try! ContentFingerprint(parsing: "sha256:" + String(repeating: "a", count: 64))
    private let install = InstallationID("30000000-0000-4000-8000-000000000001")!
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func game() -> SyncRecord {
        .game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Example Game", isFavorite: false,
                           addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil))
    }
    private func outbound() -> OutboundChange { .init(journalIDs: [1], key: game().key, payload: .save(game(), assets: [:])) }
    private func transport(_ fixture: TransportHTTPFixture, directory: URL, writable: Bool = true) throws -> RelayHostedSyncTransport {
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        return try RelayHostedSyncTransport(http: http, content: HostedContentClient(http: http, stagingDirectory: directory.appendingPathComponent("content")),
            accountIdentity: "opaque-account", installationID: install, stateDirectory: directory, automaticSync: false, vaultWritable: writable)
    }
    private static func empty(_ request: URLRequest) -> Data {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = query.first { $0.name == "cursor" }?.value ?? "0"
        let schema = request.value(forHTTPHeaderField: "X-Relay-Sync-Schema") ?? "2"
        return Data("{\"schema\":\(schema),\"changes\":[],\"nextCursor\":\(cursor),\"hasMore\":false}".utf8)
    }
    private static func pushResult(_ request: URLRequest, status: String) throws -> Data {
        struct Body: Decodable { let operations: [HostedOperation] }
        let operations = try JSONDecoder().decode(Body.self, from: request.httpBody!).operations
        struct Result: Encodable { var operationId: String; var status: String }
        struct Response: Encodable { var results: [Result] }
        return try JSONEncoder().encode(Response(results: operations.map { Result(operationId: $0.operationId, status: status) }))
    }
    private static func page(_ changes: [HostedChange], cursor: Int64, more: Bool = false, schema: Int = 2) throws -> Data {
        struct Body: Encodable { var schema: Int; var changes: [HostedChange]; var nextCursor: Int64; var hasMore: Bool }
        return try JSONEncoder().encode(Body(schema: schema, changes: changes, nextCursor: cursor, hasMore: more))
    }

    private func assetsRoot(in directory: URL) throws -> URL {
        let hash = try SHA256ContentHasher().hash(data: Data("preproduction:opaque-account".utf8)).fingerprint.hexDigest
        return directory.appendingPathComponent(hash).appendingPathComponent("Assets")
    }
    private func markedOrphan(in root: URL) throws -> URL {
        let orphan = root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = orphan.appendingPathComponent(HostedStagingDirectory.markerName)
        try Data(HostedStagingDirectory.markerContents).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try Data("interrupted private transfer".utf8).write(to: orphan.appendingPathComponent("partial"))
        return orphan
    }
    func testActiveTransportRetainsScopedHostUntilStop() async throws {
        let fixture = TransportHTTPFixture { request, _ in (200, Self.empty(request), [:]) }
        let transport = try transport(fixture, directory: directory())
        var scopedHost: TransportHostFixture? = TransportHostFixture()
        weak var observedHost = scopedHost
        try await transport.start(host: try XCTUnwrap(scopedHost))
        scopedHost = nil
        XCTAssertNotNil(observedHost, "The generation-scoped host must survive its caller's start scope")
        try await transport.synchronize()
        let requests = await fixture.count()
        XCTAssertEqual(requests, 2, "A later synchronization must still reach both pull passes")
        await transport.stop()
        XCTAssertNil(observedHost, "Stopping releases the host and its coordinator ownership")
    }
    func testStartReclaimsOwnedAssetsAndContentOrphansWithoutAuthentication() async throws {
        let dir = try directory(), assets = try assetsRoot(in: dir)
        let orphanAsset = try markedOrphan(in: assets)
        let orphanContent = try markedOrphan(in: dir.appendingPathComponent("content"))
        let unknown = assets.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let personal = unknown.appendingPathComponent("keep")
        try Data("unknown data".utf8).write(to: personal)
        let fixture = TransportHTTPFixture { _, _ in throw HostedHTTPError(status: 401, problem: .accountUnavailable) }
        let transport = try transport(fixture, directory: dir, writable: false)
        let host = TransportHostFixture()
        try await transport.start(host: host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAsset.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanContent.path))
        XCTAssertEqual(try Data(contentsOf: personal), Data("unknown data".utf8))
        let requests = await fixture.count(); XCTAssertEqual(requests, 0)
        await transport.stop()
    }
    func testStartPreservesRetainedPeerAssetsAcrossStopAndRestart() async throws {
        let dir = try directory(), assets = try assetsRoot(in: dir)
        let fixture = TransportHTTPFixture { _, _ in throw HostedHTTPError(status: 401, problem: .accountUnavailable) }
        let first = try transport(fixture, directory: dir, writable: false), firstHost = TransportHostFixture()
        try await first.start(host: firstHost)
        let initialScopes = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        let firstScope = try XCTUnwrap(initialScopes.first)
        let protected = firstScope.appendingPathComponent("host-still-copying.relaystate")
        try Data("verified private state".utf8).write(to: protected)
        await first.stop()
        let orphan = try markedOrphan(in: assets)
        let second = try transport(fixture, directory: dir, writable: false), secondHost = TransportHostFixture()
        try await second.start(host: secondHost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: protected), Data("verified private state".utf8))
        let scopes = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        XCTAssertEqual(scopes.count, 2, "A retained peer keeps its lock after stop until stale work has released it")
        let anotherOrphan = try markedOrphan(in: assets)
        try await first.start(host: firstHost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: anotherOrphan.path))
        XCTAssertEqual(try Data(contentsOf: protected), Data("verified private state".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil).count, 2)
        let requests = await fixture.count(); XCTAssertEqual(requests, 0)
        await first.stop(); await second.stop()
    }

    func testLegacyGameVectorRebuildsSchemaTwoWithFreshOperationIdentity() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.0.1/testdata/push-game.json"))
        struct Body: Decodable { var operations: [HostedOperation] }
        var expected = try JSONDecoder().decode(Body.self, from: data).operations[0]
        let original = expected
        let actual = try HostedWireCodec.encode(game(), operationID: UUID(), schema: 2)
        XCTAssertNotEqual(actual.operationId, original.operationId)
        XCTAssertEqual(original.schema, 1)
        XCTAssertNil(original.object["generation"])
        expected.schema = 2; expected.object["generation"] = .integer(0); expected.operationId = actual.operationId
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(String(decoding: try HostedWireCodec.encoded(actual), as: UTF8.self).contains("gameID"))
    }
    func testVendored111GameVectorMatchesExactSemanticEnvelope() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.1.1/testdata/push-game.json"))
        struct Body: Decodable { let operations: [HostedOperation] }
        let expected = try XCTUnwrap(JSONDecoder().decode(Body.self, from: data).operations.first)
        XCTAssertEqual(expected.schema, 2)
        let actual = try HostedWireCodec.encode(game(), operationID: XCTUnwrap(UUID(uuidString: expected.operationId)), schema: 2)
        XCTAssertEqual(actual, expected)
        let decoded = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: expected.kind,
            objectKey: fp.description, operation: expected.action, object: expected.object))
        XCTAssertEqual(decoded.record, game())
        XCTAssertEqual(decoded.record?.key, .game(fp, generation: 0))
    }
    func testVendored111SemanticCorpusPreservesEveryOperationField() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contracts/RelaySync/v1.1.1/testdata/semantic-schema-2.json"))
        struct Corpus: Decodable {
            struct Scenario: Decodable { let name: String; let operations: [HostedOperation] }
            let schema: Int; let cases: [Scenario]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertEqual(corpus.schema, 2); XCTAssertEqual(corpus.cases.count, 7)
        for scenario in corpus.cases {
            for operation in scenario.operations {
                let objectKey: String
                switch operation.kind {
                case "game": objectKey = try XCTUnwrap(operation.object["fingerprint"]?.string)
                case "play_session": objectKey = try XCTUnwrap(operation.object["sessionID"]?.string)
                case "save_state": objectKey = try XCTUnwrap(operation.object["stateID"]?.string)
                case "tombstone":
                    objectKey = try XCTUnwrap(operation.object["targetKind"]?.string) + ":" + XCTUnwrap(operation.object["targetKey"]?.string)
                default: return XCTFail("Unexpected kind in frozen corpus: \(operation.kind)")
                }
                let decoded = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: operation.kind,
                    objectKey: objectKey, operation: operation.action, object: operation.object))
                let record = try XCTUnwrap(decoded.record)
                let encoded = try HostedWireCodec.encode(record, operationID: XCTUnwrap(UUID(uuidString: operation.operationId)), schema: 2, screenshot: decoded.screenshot)
                XCTAssertEqual(encoded, operation, scenario.name)
                XCTAssertEqual(record.generation, operation.object["generation"]?.integer, scenario.name)
            }
        }
    }
    func testGenerationIsRequiredAndPreservedInWireIdentity() throws {
        var canonical = game()
        guard case .game(var entry) = canonical else { return XCTFail("Expected game") }
        entry.generation = 7; canonical = .game(entry)
        let operation = try HostedWireCodec.encode(canonical, operationID: UUID(), schema: 2)
        var change = HostedChange(sequence: 1, kind: "game", objectKey: fp.description, operation: "upsert", object: operation.object)
        XCTAssertEqual(operation.schema, 2)
        XCTAssertEqual(operation.object["generation"], .integer(7))
        XCTAssertEqual(try HostedWireCodec.decode(change).record?.key, .game(fp, generation: 7))
        change.object["generation"] = nil
        XCTAssertThrowsError(try HostedWireCodec.decode(change))
        change.object["generation"] = .integer(-1)
        XCTAssertThrowsError(try HostedWireCodec.decode(change))
        change.object["generation"] = .integer(2_147_483_648)
        XCTAssertThrowsError(try HostedWireCodec.decode(change))
    }
    func testChangesMustMatchTheNegotiatedSchemaWithoutAdvancingCursor() async throws {
        for schema in ["", "\"schema\":1,", "\"schema\":3,"] {
            let fixture = TransportHTTPFixture { _, _ in
                (200, Data("{\(schema)\"changes\":[],\"nextCursor\":0,\"hasMore\":false}".utf8), [:])
            }
            let transport = try transport(fixture, directory: directory()), host = TransportHostFixture()
            try await transport.start(host: host)
            do { try await transport.fetchNow(); XCTFail("Unsupported changes schema accepted") } catch {}
            let cursor = await host.cursor; XCTAssertEqual(cursor, 0)
        }
    }
    func testSchemaTwoLedgerRebuildsCanonicalIntentWithoutRewritingLegacyReceipt() async throws {
        let dir = try directory(), accountDirectory = try assetsRoot(in: dir).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        var oldOperation = try HostedWireCodec.encode(game(), operationID: UUID(), schema: 2)
        oldOperation.schema = 1; oldOperation.object["generation"] = nil
        struct Receipt: Encodable { let key: RecordKey; let journalIDs: [Int64]; let operation: HostedOperation; let terminal = false; let accepted = true; let deferred = false }
        struct LegacyState: Encodable { let pending: [Receipt]; let content: [String: SyncContentIndex] = [:]; let systems: [String: String] = [:] }
        let oldBytes = try HostedWireCodec.encoded(LegacyState(pending: [Receipt(key: game().key, journalIDs: [1], operation: oldOperation)]))
        let oldURL = accountDirectory.appendingPathComponent("transport.json")
        try oldBytes.write(to: oldURL)
        guard case .game(var newGame) = game() else { return XCTFail("Expected game") }
        newGame.generation = 1
        let canonical = SyncRecord.game(newGame)
        let fixture = rejectingFixture(), host = TransportHostFixture([OutboundChange(journalIDs: [1], key: canonical.key, payload: .save(canonical, assets: [:]))])
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountDirectory.appendingPathComponent("transport.schema2.json").path))
        let bodies = await fixture.bodies()
        struct Body: Decodable { let operations: [HostedOperation] }
        let sent = try JSONDecoder().decode(Body.self, from: XCTUnwrap(bodies.first)).operations[0]
        XCTAssertNotEqual(sent.operationId, oldOperation.operationId)
        XCTAssertEqual(sent.schema, 2); XCTAssertEqual(sent.object["generation"], .integer(1))
    }
    func testBatteryGraphAndScreenshotPreservedByCodec() throws {
        let revision = BatteryRevisionID(), p1 = BatteryRevisionID(), p2 = BatteryRevisionID()
        let record = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: revision, fingerprint: fp, parentIDs: [p1, p2],
            createdAt: 1_788_520_002_000, dataFingerprint: fp, dataSize: 128, installationID: install, deviceKind: "mac", hasScreenshot: true))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2, screenshot: fp)
        let inbound = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: op.kind, objectKey: revision.description, operation: "upsert", object: op.object))
        XCTAssertEqual(inbound.record, record); XCTAssertEqual(inbound.screenshot, fp)
    }
    func testStateCompatibilityAndAutoResumePairingRoundTrip() throws {
        let record = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "mesen2", coreVersion: "2.1.1",
            stateCompatibilityVersion: "mesen2-2.1.1-b9fa69dd-state4", formatVersion: 2, createdAt: 1_788_520_000_000,
            payloadFingerprint: fp, payloadSize: 128, batteryRevisionID: BatteryRevisionID(), installationID: install,
            deviceKind: "mac", label: nil, hasScreenshot: false))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2)
        XCTAssertNil(op.object["kind"]); XCTAssertEqual(op.object["stateKind"], .string("auto"))
        let result = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: op.kind, objectKey: op.object["stateID"]!.string!, operation: "upsert", object: op.object))
        XCTAssertEqual(result.record, record)
    }
    func testUnknownKindEnumSchemaAndMismatchedKeyFailClosed() throws {
        let op = try HostedWireCodec.encode(game(), operationID: UUID(), schema: 2)
        var c = HostedChange(sequence: 1, kind: "new-kind", objectKey: fp.description, operation: "upsert", object: op.object)
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
        c.kind = "game"; c.object["schema"] = .integer(3)
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
        c.object["schema"] = .integer(2); c.objectKey = "different"
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
        c.objectKey = fp.description; c.operation = "overwrite"
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
        c.operation = "upsert"; c.object["deviceKind"] = .string("future")
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
    }
    func testNonCanonicalUUIDAndDuplicateParentsRejected() throws {
        let record = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: 1_788_520_000_000, dataFingerprint: fp, dataSize: 128, installationID: install, deviceKind: "mac", hasScreenshot: false))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2)
        var c = HostedChange(sequence: 1, kind: op.kind, objectKey: op.object["revisionID"]!.string!, operation: "upsert", object: op.object)
        c.object["revisionID"] = .string(c.objectKey.uppercased())
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
        c.object["revisionID"] = .string(c.objectKey)
        c.object["parentIDs"] = .array([.string(c.objectKey), .string(c.objectKey)])
        XCTAssertThrowsError(try HostedWireCodec.decode(c))
    }
    func testContentRemovalIsMetadataDeletionWithoutGameTombstone() throws {
        let decoded = try HostedWireCodec.decode(HostedChange(sequence: 2, kind: "content_availability", objectKey: fp.description, operation: "upsert",
            object: ["fingerprint": .string(fp.description), "generation": .integer(0), "stored": .bool(false)]))
        XCTAssertNil(decoded.record); XCTAssertEqual(decoded.deletion, .contentIndex(fp))
    }
    func testContextualStateTombstonePreservesImmutableMembership() throws {
        let tombstone = SyncTombstone(targetKind: "state", targetKey: SaveStateID().description,
            deletedAt: 1_788_519_999_000, installationID: install, generation: 7, gameFingerprint: fp)
        let operation = try HostedWireCodec.encode(.tombstone(tombstone), operationID: UUID(), schema: 2)
        XCTAssertEqual(operation.object["fingerprint"], .string(fp.description))
        XCTAssertNil(operation.object["gameFingerprint"])
        XCTAssertEqual(operation.object["generation"], .integer(7))
        let decoded = try HostedWireCodec.decode(HostedChange(sequence: 1, kind: "tombstone",
            objectKey: "state:" + tombstone.targetKey, operation: "upsert", object: operation.object))
        XCTAssertEqual(decoded.record, .tombstone(tombstone))
    }
    func testContentRemovalUsesGenerationFromCanonicalKey() async throws {
        let fixture = rejectingFixture(), transport = try transport(fixture, directory: directory())
        try await transport.start(host: TransportHostFixture())
        try await transport.deleteContent(.contentIndex(fp, generation: 7))
        let bodies = await fixture.bodies()
        struct Body: Decodable { let operations: [HostedOperation] }
        let sent = try JSONDecoder().decode(Body.self, from: XCTUnwrap(bodies.first)).operations[0]
        XCTAssertEqual(sent.object["fingerprint"], .string(fp.description))
        XCTAssertEqual(sent.object["generation"], .integer(7))
        XCTAssertEqual(sent.object["stored"], .bool(false))
    }
    func testFutureContentDoesNotBlockLaterRetirementPrerequisite() async throws {
        let dir = try directory(), bytes = Data("generated battery".utf8), source = dir.appendingPathComponent("battery.sav")
        try bytes.write(to: source)
        let payloadFingerprint = try SHA256ContentHasher().hash(data: bytes).fingerprint
        let battery = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: 1_788_520_000_000, dataFingerprint: payloadFingerprint, dataSize: Int64(bytes.count), installationID: install,
            deviceKind: "mac", hasScreenshot: false, generation: 1))
        let retirement = SyncRecord.tombstone(SyncTombstone(targetKind: "game", targetKey: fp.description,
            deletedAt: 1_788_519_999_000, installationID: install, generation: 0))
        let fixture = TransportHTTPFixture { request, _ in
            if request.url!.path == "/v1/content/uploads" {
                return (409, Data("{\"detail\":\"content target generation is not available yet\"}".utf8), [:])
            }
            return (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let host = TransportHostFixture([
            OutboundChange(journalIDs: [1], key: battery.key, payload: .save(battery, assets: [.data: source])),
            OutboundChange(journalIDs: [2], key: retirement.key, payload: .save(retirement, assets: [:]))
        ])
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        let pending = await host.outbound, bodies = await fixture.bodies()
        XCTAssertEqual(pending.map(\.key), [battery.key])
        struct Body: Decodable { let operations: [HostedOperation] }
        let sent = try JSONDecoder().decode(Body.self, from: XCTUnwrap(bodies.first)).operations
        XCTAssertEqual(sent.map(\.kind), ["tombstone"])
        XCTAssertEqual(sent[0].object["generation"], .integer(0))
    }
    func testRawStateDeletionCannotForgeCanonicalTombstone() async throws {
        let key = RecordKey.state(SaveStateID())
        let fixture = rejectingFixture(), host = TransportHostFixture([OutboundChange(journalIDs: [1], key: key, payload: .delete)])
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.synchronize()
        let bodies = await fixture.bodies(), pending = await host.pendingCount(), problem = await host.lastProblem()
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(problem, .invalidRecord("state deletion requires canonical tombstone"))
    }
    func testExactOperationBytesSurviveNetworkFailureAndRestart() async throws {
        let dir = try directory()
        let failing = TransportHTTPFixture { request, _ in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, Self.empty(request), [:])
        }
        let first = try transport(failing, directory: dir); let host = TransportHostFixture([outbound()])
        try await first.start(host: host)
        do { try await first.synchronize(); XCTFail("Network failure ignored") } catch {}
        await first.stop()
        let good = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let restarted = try transport(good, directory: dir)
        try await restarted.start(host: host); try await restarted.synchronize()
        let initial = await failing.bodies(), replayed = await good.bodies()
        XCTAssertEqual(initial.count, 1); XCTAssertEqual(replayed.count, 1); XCTAssertEqual(initial, replayed)
        let count = await host.pendingCount(); XCTAssertEqual(count, 0)
    }
    func testDeferredThenAppliedRetainsIntentAndOperationID() async throws {
        let dir = try directory()
        let deferred = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "deferred") : Self.empty(request), [:])
        }
        let first = try transport(deferred, directory: dir); let host = TransportHostFixture([outbound()])
        try await first.start(host: host); try await first.synchronize()
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 1)
        await first.stop()
        let good = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let next = try transport(good, directory: dir); try await next.start(host: host); try await next.synchronize()
        let before = await deferred.bodies(), after = await good.bodies()
        XCTAssertEqual(before, after)
        let finalPending = await host.pendingCount(); XCTAssertEqual(finalPending, 0)
    }
    func testDeferredTerminalRejectionIsSurfacedAndNotRetriedForever() async throws {
        let dir = try directory()
        let deferred = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "deferred") : Self.empty(request), [:])
        }
        let first = try transport(deferred, directory: dir); let host = TransportHostFixture([outbound()])
        try await first.start(host: host); try await first.synchronize(); await first.stop()
        let rejected = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "rejected") : Self.empty(request), [:])
        }
        let next = try transport(rejected, directory: dir); try await next.start(host: host)
        try await next.synchronize(); try await next.synchronize()
        let bodies = await rejected.bodies(); XCTAssertEqual(bodies.count, 1)
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 1)
        let outcomes = await host.outcomes
        XCTAssertTrue(outcomes.contains { if case .failed(.invalidRecord, _) = $0.outcome { true } else { false } })
    }
    func testCursorCannotAdvanceAfterLocalApplyFailure() async throws {
        let op = try HostedWireCodec.encode(game(), operationID: UUID(), schema: 2), fp = fp.description
        let page = try Self.page([HostedChange(sequence: 1, kind: "game", objectKey: fp, operation: "upsert", object: op.object)], cursor: 1)
        let fixture = TransportHTTPFixture { request, _ in (200, request.url!.query!.contains("cursor=0") ? page : Self.empty(request), [:]) }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture()
        await host.setFailApply(true); try await transport.start(host: host)
        do { try await transport.fetchNow(); XCTFail("Apply failure ignored") } catch {}
        let initial = await host.cursor; XCTAssertEqual(initial, 0)
        await host.setFailApply(false); try await transport.fetchNow()
        let final = await host.cursor; XCTAssertEqual(final, 1)
    }
    func testMalformedCursorCannotAdvanceHost() async throws {
        let fixture = TransportHTTPFixture { _, _ in (200, Data("{\"schema\":2,\"changes\":[],\"nextCursor\":99,\"hasMore\":false}".utf8), [:]) }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture()
        try await transport.start(host: host)
        do { try await transport.fetchNow(); XCTFail("Cursor leap accepted") } catch {}
        let cursor = await host.cursor; XCTAssertEqual(cursor, 0)
    }
    func testReadOnlyVaultContinuesPullWithoutPushing() async throws {
        let fixture = TransportHTTPFixture { request, _ in (200, Self.empty(request), [:]) }
        let transport = try transport(fixture, directory: directory(), writable: false); let host = TransportHostFixture([outbound()])
        try await transport.start(host: host); try await transport.synchronize()
        let bodies = await fixture.bodies(); XCTAssertTrue(bodies.isEmpty)
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 1)
    }
    func test423StopsWritesButStillPulls() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            request.httpMethod == "POST" ? (423, Data("{}".utf8), [:]) : (200, Self.empty(request), [:])
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture([outbound()])
        try await transport.start(host: host); try await transport.synchronize(); try await transport.synchronize()
        let bodies = await fixture.bodies(); XCTAssertEqual(bodies.count, 1)
        let count = await fixture.count(); XCTAssertGreaterThanOrEqual(count, 5)
    }
    func testMissingLiveAssetPreservesCursor() async throws { try await missingAsset(covered: false) }
    func testMissingHistoricalAssetFindsLaterPageTombstone() async throws { try await missingAsset(covered: true) }
    private func missingAsset(covered: Bool, recordGeneration: Int64 = 0, tombstoneGeneration: Int64 = 0) async throws {
        let record = SyncRecord.batteryRevision(SyncBatteryRevision(revisionID: BatteryRevisionID(), fingerprint: fp, parentIDs: [],
            createdAt: 1_788_520_000_000, dataFingerprint: fp, dataSize: 128, installationID: install, deviceKind: "mac", hasScreenshot: false, generation: recordGeneration))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2)
        let first = try Self.page([HostedChange(sequence: 1, kind: op.kind, objectKey: op.object["revisionID"]!.string!, operation: "upsert", object: op.object)], cursor: 1, more: covered)
        let tomb = try HostedWireCodec.encode(.tombstone(SyncTombstone(targetKind: "game", targetKey: fp.description, deletedAt: 1_788_519_999_000, installationID: install, generation: tombstoneGeneration)), operationID: UUID(), schema: 2)
        let second = try Self.page([HostedChange(sequence: 2, kind: "tombstone", objectKey: "game:" + fp.description, operation: "upsert", object: tomb.object)], cursor: 2)
        let fixture = TransportHTTPFixture { request, _ in
            if request.url!.path.contains("/downloads/") { return (404, Data("{}".utf8), [:]) }
            if request.url!.query!.contains("cursor=0") { return (200, first, [:]) }
            if covered && request.url!.query!.contains("cursor=1") { return (200, second, [:]) }
            return (200, Self.empty(request), [:])
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture()
        try await transport.start(host: host)
        if covered && tombstoneGeneration >= recordGeneration {
            try await transport.fetchNow()
            let records = await host.changes.map(\.record)
            XCTAssertTrue(records.contains { if case .tombstone = $0 { true } else { false } })
            XCTAssertFalse(records.contains { if case .batteryRevision = $0 { true } else { false } })
            let cursor = await host.cursor; XCTAssertEqual(cursor, 2)
        } else {
            do { try await transport.fetchNow(); XCTFail("Missing live asset skipped") } catch {}
            let cursor = await host.cursor; XCTAssertEqual(cursor, 0)
        }
    }
    func testOlderGenerationTombstoneCannotSkipLiveMissingAsset() async throws {
        try await missingAsset(covered: true, recordGeneration: 1, tombstoneGeneration: 0)
    }
    func testForeignHistoryPreservesSourceInstallationWhenSubmitted() async throws {
        let originalInstallation = InstallationID()
        let foreign = SyncRecord.session(SyncSession(sessionID: PlaySessionID(), fingerprint: fp,
            installationID: originalInstallation, deviceKind: "ipad", coreID: "test-core", startedAt: 1_788_520_000_000,
            endedAt: 1_788_520_001_000, pausedMs: 0, hasScreenshot: false))
        let fixture = TransportHTTPFixture { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Relay-Sync-Schema"), "2")
            return (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: foreign.key, payload: .save(foreign, assets: [:]))])
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.synchronize()
        let pending = await host.pendingCount(), bodies = await fixture.bodies()
        XCTAssertEqual(pending, 0)
        struct Body: Decodable { let operations: [HostedOperation] }
        let operation = try JSONDecoder().decode(Body.self, from: XCTUnwrap(bodies.first)).operations[0]
        XCTAssertEqual(operation.schema, 2)
        XCTAssertEqual(operation.object["installationID"], .string(originalInstallation.description))
        XCTAssertNotEqual(originalInstallation, install)
    }
    func testStateUploadTransfersRawPayloadAndPreservesContainerLocally() async throws {
        let dir = try directory(), payload = Data("generated state payload".utf8)
        let core = EmulatorCoreDescriptor(id: "test-core", name: "Generated", version: "2", stateCompatibilityVersion: "format-7",
            license: "GPL-3.0-or-later", supportedSystems: ["gba"], capabilities: [.saveStates])
        let container = try SaveStateContainer(gameID: GameID(), contentFingerprint: fp, core: core, kind: .auto,
            createdAt: SyncTime.date(1_788_520_000_000), payload: payload)
        let source = dir.appendingPathComponent("source.relaystate"), original = try container.encoded()
        try original.write(to: source)
        let state = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "test-core", coreVersion: "2",
            stateCompatibilityVersion: "format-7", formatVersion: 2, createdAt: 1_788_520_000_000,
            payloadFingerprint: container.header.payloadFingerprint, payloadSize: Int64(payload.count), batteryRevisionID: nil,
            installationID: install, deviceKind: "mac", label: nil, hasScreenshot: false))
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), uploadID = UUID().uuidString.lowercased()
        let fixture = TransportHTTPFixture { request, _ in
            let path = request.url!.path
            if path == "/v1/content/uploads" {
                return (201, Data("{\"upload_id\":\"\(uploadID)\",\"mode\":\"single\",\"expires_at\":\"\(expires)\",\"upload\":{\"url\":\"https://content.example.test/object\",\"method\":\"PUT\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
            }
            if path.hasSuffix("/complete") { return (202, Data("{}".utf8), [:]) }
            if path == "/v1/content/uploads/" + uploadID {
                return (200, Data("{\"upload_id\":\"\(uploadID)\",\"status\":\"COMPLETE\"}".utf8), [:])
            }
            if path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, Self.empty(request), [:])
        }
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        let plane = TransportDataPlaneFixture(payload)
        let content = HostedContentClient(http: http, stagingDirectory: dir.appendingPathComponent("content"), dataPlane: plane)
        let transport = try RelayHostedSyncTransport(http: http, content: content, accountIdentity: "opaque-account", installationID: install,
            stateDirectory: dir, automaticSync: false)
        let host = TransportHostFixture([OutboundChange(journalIDs: [1], key: state.key, payload: .save(state, assets: [.payload: source]))])
        try await transport.start(host: host); try await transport.synchronize()
        let uploaded = await plane.uploaded
        XCTAssertEqual(uploaded, [payload]); XCTAssertEqual(try Data(contentsOf: source), original)
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 0)
    }
    func testRetentionWithdrawsAdmittedStateDuringEarlierUploadWithoutLosingTombstone() async throws {
        let dir = try directory(), now = Date()
        let location = LibraryLocation(rootURL: dir.appendingPathComponent("library"))
        try location.createDirectories()
        let store = try SQLiteLibraryStore.open(at: location.databaseURL)
        let identity = try await store.syncStore.identity()
        let game = Game(systemID: .gameBoyAdvance, title: "Retention race", contentFingerprint: fp, addedAt: now)
        try await store.games.insert(game, files: [])
        let battery = BatterySaveManager(store: store, location: location, identity: identity)
        let states = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location), identity: identity)
        let core = EmulatorCoreDescriptor(id: "test-core", name: "Generated", version: "2", stateCompatibilityVersion: "format-7",
            license: "GPL-3.0-or-later", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        _ = try await battery.snapshot(gameID: game.id, data: Data("battery".utf8), now: now)
        let old = try await states.create(kind: .auto, game: game, core: core, payload: Data("expired".utf8), now: now)
        let healthyPayload = Data("healthy manual".utf8)
        let healthy = try await states.create(kind: .manual, game: game, core: core, payload: healthyPayload, now: now)
        let expires = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)), uploadID = UUID().uuidString.lowercased()
        let fixture = TransportHTTPFixture { request, _ in
            let path = request.url!.path
            if path == "/v1/content/uploads" {
                return (201, Data("{\"upload_id\":\"\(uploadID)\",\"mode\":\"single\",\"expires_at\":\"\(expires)\",\"upload\":{\"url\":\"https://content.example.test/object\",\"method\":\"PUT\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
            }
            if path.hasSuffix("/complete") { return (202, Data("{}".utf8), [:]) }
            if path == "/v1/content/uploads/" + uploadID {
                return (200, Data("{\"upload_id\":\"\(uploadID)\",\"status\":\"COMPLETE\"}".utf8), [:])
            }
            if path == "/v1/sync/push" { return (200, try Self.pushResult(request, status: "applied"), [:]) }
            return (200, Self.empty(request), [:])
        }
        let plane = TransportDataPlaneFixture(Data()) {
            // The page has already admitted old's canonical URL. Real retention
            // deletes its row/upsert and then unlinks that file during this upload.
            for index in 1...SaveStateManager.autoResumeHistory {
                _ = try await states.create(kind: .auto, game: game, core: core, payload: Data([UInt8(index)]),
                    now: now.addingTimeInterval(Double(index)))
            }
        }
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        let content = HostedContentClient(http: http, stagingDirectory: dir.appendingPathComponent("content"), dataPlane: plane)
        let transport = try RelayHostedSyncTransport(http: http, content: content, accountIdentity: "opaque-account",
            installationID: identity.installationID, stateDirectory: dir.appendingPathComponent("transport"), automaticSync: false)
        let coordinator = SyncCoordinator(store: store, syncStore: store.syncStore, location: location,
            batterySaves: battery, saveStates: states, identity: identity, configuration: .init(capabilities: .hostedGameFilesSupported))
        await coordinator.selectProvider(.relaySync, transport: transport)
        try await transport.synchronize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: old.location).path))
        let tombstone = try await store.syncStore.tombstone(for: .saveState(old.id), generation: game.generation)
        XCTAssertNotNil(tombstone)
        struct Body: Decodable { let operations: [HostedOperation] }
        let firstOperations = try await fixture.bodies().flatMap { try JSONDecoder().decode(Body.self, from: $0).operations }
        XCTAssertFalse(firstOperations.contains { $0.object["stateID"]?.string == old.id.description })
        XCTAssertTrue(firstOperations.contains { $0.object["stateID"]?.string == healthy.id.description })
        let uploaded = await plane.uploaded
        XCTAssertTrue(uploaded.contains(healthyPayload)); XCTAssertFalse(uploaded.contains(Data("expired".utf8)))
        try await transport.synchronize()
        let allOperations = try await fixture.bodies().flatMap { try JSONDecoder().decode(Body.self, from: $0).operations }
        XCTAssertTrue(allOperations.contains { $0.kind == "tombstone" && $0.object["targetKey"]?.string == old.id.description })
        let pending = try await store.syncStore.journal.pending(limit: 100)
        XCTAssertTrue(pending.isEmpty, "Only the admitted IDs may be acknowledged; new states and the tombstone must subsequently drain")
        await coordinator.stop()
        try store.close()
    }

    func testMissingPendingStateAssetDoesNotStarveHealthyMetadata() async throws {
        let dir = try directory()
        let state = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "test-core", coreVersion: "2",
            stateCompatibilityVersion: "format-7", formatVersion: 2, createdAt: 1_788_520_000_000,
            payloadFingerprint: fp, payloadSize: 8, batteryRevisionID: nil, installationID: install, deviceKind: "mac", label: nil, hasScreenshot: false))
        let host = TransportHostFixture([
            OutboundChange(journalIDs: [1], key: state.key, payload: .save(state, assets: [.payload: dir.appendingPathComponent("missing.relaystate")])),
            OutboundChange(journalIDs: [2], key: game().key, payload: .save(game(), assets: [:]))
        ])
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.url!.path == "/v1/sync/push" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        let remaining = try await host.hostedPendingJournalIDs(in: [1, 2])
        XCTAssertEqual(remaining, [1])
        let outcomes = await host.outcomes
        XCTAssertTrue(outcomes.contains { result in
            guard result.key == state.key, case .failed(.invalidRecord, _) = result.outcome else { return false }; return true
        })
        await transport.stop()
    }

    func testStateWithdrawnBetweenMembershipCheckAndOpeningAssetIsReleased() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("retired.relaystate")
        try Data("removed before opening".utf8).write(to: source)
        let state = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "test-core", coreVersion: "2",
            stateCompatibilityVersion: "format-7", formatVersion: 2, createdAt: 1_788_520_000_000,
            payloadFingerprint: fp, payloadSize: 8, batteryRevisionID: nil, installationID: install, deviceKind: "mac", label: nil, hasScreenshot: false))
        let host = TransportHostFixture([
            OutboundChange(journalIDs: [1], key: state.key, payload: .save(state, assets: [.payload: source])),
            OutboundChange(journalIDs: [2], key: game().key, payload: .save(game(), assets: [:]))
        ])
        await host.setRetirementAfterMembershipRead(id: 1, url: source)
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.url!.path == "/v1/sync/push" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let transport = try transport(fixture, directory: dir)
        try await transport.start(host: host); try await transport.synchronize()
        let outcomes = await host.outcomes, count = await host.pendingCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(outcomes.contains { result in
            guard result.key == state.key, case .deleted = result.outcome else { return false }; return true
        })
        XCTAssertFalse(outcomes.contains { result in
            guard case .failed = result.outcome else { return false }; return true
        })
        await transport.stop()
    }

    func testStateDownloadReconstructsVerifiedCompatibleContainer() async throws {
        let dir = try directory(), payload = Data("generated state payload".utf8)
        let fingerprint = try SHA256ContentHasher().hash(data: payload).fingerprint
        let record = SyncRecord.state(SyncSaveState(stateID: SaveStateID(), fingerprint: fp, kind: "auto", coreID: "test-core", coreVersion: "2",
            stateCompatibilityVersion: "format-7", formatVersion: 2, createdAt: 1_788_520_000_000,
            payloadFingerprint: fingerprint, payloadSize: Int64(payload.count), batteryRevisionID: BatteryRevisionID(),
            installationID: install, deviceKind: "mac", label: nil, hasScreenshot: false))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2)
        let page = try Self.page([HostedChange(sequence: 1, kind: op.kind, objectKey: op.object["stateID"]!.string!, operation: "upsert", object: op.object)], cursor: 1)
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let fixture = TransportHTTPFixture { request, _ in
            if request.url!.path.contains("/downloads/") {
                return (200, Data("{\"size\":\(payload.count),\"download\":{\"url\":\"https://content.example.test/object\",\"method\":\"GET\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
            }
            return (200, page, [:])
        }
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        let content = HostedContentClient(http: http, stagingDirectory: dir.appendingPathComponent("content"), dataPlane: TransportDataPlaneFixture(payload))
        let transport = try RelayHostedSyncTransport(http: http, content: content, accountIdentity: "opaque-account", installationID: install,
            stateDirectory: dir, automaticSync: false)
        let host = TransportHostFixture(); try await transport.start(host: host); try await transport.fetchNow()
        let copies = await host.copiedPayloads, records = await host.changes.map(\.record)
        let container = try SaveStateContainer.decode(XCTUnwrap(copies.first))
        XCTAssertEqual(container.payload, payload); XCTAssertEqual(container.header.payloadFingerprint, fingerprint)
        XCTAssertEqual(container.header.gameFingerprint, fp); XCTAssertEqual(container.header.coreVersion, "2")
        XCTAssertEqual(container.header.effectiveCompatibilityVersion, "format-7"); XCTAssertEqual(container.header.kind, .auto)
        XCTAssertEqual(records, [record])
    }

    func testMissingHistoricalScreenshotDoesNotBlockSessionProgress() async throws {
        let record = SyncRecord.session(SyncSession(sessionID: PlaySessionID(), fingerprint: fp, installationID: install,
            deviceKind: "mac", coreID: "mgba", startedAt: 1_788_520_000_000, endedAt: 1_788_520_010_000, pausedMs: 100, hasScreenshot: true))
        let op = try HostedWireCodec.encode(record, operationID: UUID(), schema: 2, screenshot: fp)
        let page = try Self.page([HostedChange(sequence: 1, kind: op.kind, objectKey: op.object["sessionID"]!.string!, operation: "upsert", object: op.object)], cursor: 1)
        let fixture = TransportHTTPFixture { request, _ in
            if request.url!.path.contains("/downloads/") { return (404, Data("{}".utf8), [:]) }
            return (200, page, [:])
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture()
        try await transport.start(host: host); try await transport.fetchNow()
        let changes = await host.changes, cursor = await host.cursor, count = await fixture.count()
        XCTAssertEqual(changes.map(\.record), [record]); XCTAssertTrue(changes[0].assets.isEmpty)
        XCTAssertEqual(cursor, 1); XCTAssertEqual(count, 2, "Optional missing screenshot should not trigger a tombstone scan")
    }
    func testCompletedReceiptsCompactOnlyAfterJournalAcknowledgement() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let dir = try directory(), host = TransportHostFixture([outbound()])
        let first = try transport(fixture, directory: dir)
        try await first.start(host: host); try await first.synchronize(); await first.stop()
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let stateURL = (enumerator.allObjects as! [URL]).first { $0.lastPathComponent == "transport.schema2.json" }!
        let object = try JSONDecoder().decode([String: HostedJSON].self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(object["pending"], .array([]))
        let second = try transport(fixture, directory: dir)
        try await second.start(host: host); try await second.synchronize()
        let bodies = await fixture.bodies(); XCTAssertEqual(bodies.count, 1)
    }
    func testHeavyContentReleaseRemovesOnlyProviderOwnedStaging() async throws {
        let dir = try directory(), payload = Data("generated game content".utf8)
        let fingerprint = try SHA256ContentHasher().hash(data: payload).fingerprint
        let index = SyncContentIndex(fingerprint: fingerprint, size: Int64(payload.count), fileName: "generated.gba", systemID: "gba",
            partCount: 1, uploadedAt: 1_788_520_000_000, installationID: install, generation: 7)
        let op = try HostedWireCodec.encode(.contentIndex(index), operationID: UUID(), schema: 2)
        let page = try Self.page([HostedChange(sequence: 1, kind: op.kind, objectKey: fingerprint.description, operation: "upsert", object: op.object)], cursor: 1)
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let fixture = TransportHTTPFixture { request, _ in
            if request.url!.path.contains("/downloads/") {
                return (200, Data("{\"size\":\(payload.count),\"download\":{\"url\":\"https://content.example.test/object\",\"method\":\"GET\",\"headers\":{},\"expires_at\":\"\(expires)\"}}".utf8), [:])
            }
            return (200, page, [:])
        }
        let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
        let content = HostedContentClient(http: http, stagingDirectory: dir.appendingPathComponent("content"), dataPlane: TransportDataPlaneFixture(payload))
        let transport = try RelayHostedSyncTransport(http: http, content: content, accountIdentity: "opaque-account", installationID: install,
            stateDirectory: dir, automaticSync: false)
        let host = TransportHostFixture(); try await transport.start(host: host); try await transport.fetchNow()
        let oldKey = RecordKey.gameContent(fingerprint, part: 0, generation: 0)
        let oldOwned = try await transport.contentExists(oldKey)
        XCTAssertFalse(oldOwned, "Physical content cannot imply ownership in a different generation")
        let oldFetch = try await transport.fetchContent(oldKey, progress: { _ in })
        XCTAssertNil(oldFetch)
        let key = RecordKey.gameContent(fingerprint, part: 0, generation: 7)
        let owned = try await transport.contentExists(key); XCTAssertTrue(owned)
        let fetched = try await transport.fetchContent(key, progress: { _ in })
        let change = try XCTUnwrap(fetched), file = try XCTUnwrap(change.assets[.data])
        XCTAssertEqual(change.record.generation, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await transport.releaseContent(change)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let personal = dir.appendingPathComponent("personal-file")
        try payload.write(to: personal)
        await transport.releaseContent(InboundChange(key: key, record: change.record, assets: [.data: personal]))
        XCTAssertEqual(try Data(contentsOf: personal), payload)
    }

    func testAcceptedReceiptSurvivesFailedJournalAcknowledgement() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let dir = try directory(), host = TransportHostFixture([outbound()])
        await host.setRetainAcknowledgements(true)
        let first = try transport(fixture, directory: dir)
        try await first.start(host: host); try await first.synchronize(); await first.stop()
        let retained = await host.pendingCount(); XCTAssertEqual(retained, 1)
        await host.setRetainAcknowledgements(false)
        let second = try transport(fixture, directory: dir)
        try await second.start(host: host); try await second.synchronize()
        let bodies = await fixture.bodies(), remaining = await host.pendingCount()
        XCTAssertEqual(bodies.count, 1, "Receipt must finish journal acknowledgement without generating another operation")
        XCTAssertEqual(remaining, 0)
    }
    func testMalformedLocalRecordDoesNotStarveHealthyRecord() async throws {
        var invalid = SyncGameEntry(fingerprint: try ContentFingerprint(parsing: "sha256:" + String(repeating: "b", count: 64)),
            systemID: "gba", title: "Invalid", isFavorite: false, addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil)
        invalid.schema = 3
        let invalidRecord = SyncRecord.game(invalid)
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let host = TransportHostFixture([OutboundChange(journalIDs: [2], key: invalidRecord.key, payload: .save(invalidRecord, assets: [:])), outbound()])
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.synchronize()
        let pending = await host.pendingCount(), requests = await fixture.bodies()
        XCTAssertEqual(pending, 1); XCTAssertEqual(requests.count, 1)
    }

    func testMalformedBatchResponseAcknowledgesNoOperation() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            guard request.httpMethod == "POST" else { return (200, Self.empty(request), [:]) }
            struct Body: Decodable { var operations: [HostedOperation] }
            let id = try JSONDecoder().decode(Body.self, from: request.httpBody!).operations[0].operationId
            return (200, Data("{\"results\":[{\"operationId\":\"\(id)\",\"status\":\"future-result\"}]}".utf8), [:])
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture([outbound()])
        try await transport.start(host: host)
        do { try await transport.synchronize(); XCTFail("Unknown operation result accepted") } catch {}
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 1)
    }

    func testFairDrainMovesPastHundredRejectedRows() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            guard request.httpMethod == "POST" else { return (200, Self.empty(request), [:]) }
            struct Body: Decodable { let operations: [HostedOperation] }
            let operations = try JSONDecoder().decode(Body.self, from: request.httpBody!).operations
            let rejected = operations[0].object["title"] == .string("Reject")
            return (200, try Self.pushResult(request, status: rejected ? "rejected" : "applied"), [:])
        }
        let changes = try (1...101).map { number -> OutboundChange in
            let fingerprint = try ContentFingerprint(parsing: "sha256:" + String(format: "%064x", number))
            let record = SyncRecord.game(SyncGameEntry(fingerprint: fingerprint, systemID: "gba", title: number <= 100 ? "Reject" : "Healthy",
                isFavorite: false, addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil))
            return OutboundChange(journalIDs: [Int64(number)], key: record.key, payload: .save(record, assets: [:]))
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture(changes)
        try await transport.start(host: host); try await transport.synchronize()
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 100)
        let sent = await fixture.bodies(); XCTAssertEqual(sent.count, 2)
        try await transport.synchronize()
        let second = await fixture.bodies(); XCTAssertEqual(second.count, 2, "Terminal payloads must not trigger a network retry loop")
    }
    private func blockedJournal(_ count: Int, firstHealthyID: Int) throws -> [OutboundChange] {
        try (1...count).map { number in
            let fingerprint = try ContentFingerprint(parsing: "sha256:" + String(format: "%064x", number))
            let record = SyncRecord.game(SyncGameEntry(fingerprint: fingerprint, systemID: "gba",
                title: number < firstHealthyID ? "Reject" : "Healthy", isFavorite: false,
                addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil))
            return OutboundChange(journalIDs: [Int64(number)], key: record.key, payload: .save(record, assets: [:]))
        }
    }
    private func rejectingFixture() -> TransportHTTPFixture {
        TransportHTTPFixture { request, _ in
            guard request.httpMethod == "POST" else { return (200, Self.empty(request), [:]) }
            struct Body: Decodable { let operations: [HostedOperation] }
            let operations = try JSONDecoder().decode(Body.self, from: request.httpBody!).operations
            let rejected = operations[0].object["title"] == .string("Reject")
            return (200, try Self.pushResult(request, status: rejected ? "rejected" : "applied"), [:])
        }
    }
    func testFairDrainPassBoundaryReachesRowAfterThousandRejections() async throws {
        let fixture = rejectingFixture(), host = TransportHostFixture(try blockedJournal(1001, firstHealthyID: 1001))
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host)
        try await transport.synchronize()
        let firstRemaining = await host.pendingCount(), firstRequests = await fixture.bodies()
        XCTAssertEqual(firstRemaining, 1001); XCTAssertEqual(firstRequests.count, 10, "One pass remains bounded to ten pages")
        try await transport.synchronize()
        let secondRemaining = await host.pendingCount(), secondRequests = await fixture.bodies()
        XCTAssertEqual(secondRemaining, 1000); XCTAssertEqual(secondRequests.count, 11)
    }
    func testFairDrainCursorSurvivesStopAndTransportRecreation() async throws {
        let dir = try directory(), fixture = rejectingFixture()
        let host = TransportHostFixture(try blockedJournal(1001, firstHealthyID: 1001))
        let first = try transport(fixture, directory: dir)
        try await first.start(host: host); try await first.synchronize(); await first.stop()
        let second = try transport(fixture, directory: dir)
        try await second.start(host: host); try await second.synchronize()
        let remaining = await host.pendingCount(), sent = await fixture.bodies()
        XCTAssertEqual(remaining, 1000); XCTAssertEqual(sent.count, 11, "Restart must resume beyond the first blocked thousand")
    }
    func testFrozenRoundDefersNewTailUntilWrapWithoutLosingIt() async throws {
        let fixture = rejectingFixture(), host = TransportHostFixture(try blockedJournal(1001, firstHealthyID: 1001))
        let transport = try transport(fixture, directory: directory())
        try await transport.start(host: host); try await transport.synchronize()
        let newTail = try XCTUnwrap(blockedJournal(1002, firstHealthyID: 1001).last)
        await host.append(newTail)
        try await transport.synchronize()
        let afterOldRound = await host.outbound
        XCTAssertTrue(afterOldRound.contains { $0.journalIDs == [1002] }, "A round never moves its captured upper boundary")
        XCTAssertFalse(afterOldRound.contains { $0.journalIDs == [1001] })
        try await transport.synchronize(); try await transport.synchronize()
        let remaining = await host.pendingCount(), sent = await fixture.bodies()
        XCTAssertEqual(remaining, 1000); XCTAssertEqual(sent.count, 12)
    }
    func testSchemaTwoScanPreservesLegacyEmptyLedger() async throws {
        let dir = try directory(), fixture = rejectingFixture()
        let accountDirectory = try assetsRoot(in: dir).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try Data("{\"pending\":[],\"content\":{},\"systems\":{}}".utf8).write(to: accountDirectory.appendingPathComponent("transport.json"))
        let transport = try transport(fixture, directory: dir), host = TransportHostFixture([outbound()])
        try await transport.start(host: host); try await transport.synchronize()
        let remaining = await host.pendingCount(); XCTAssertEqual(remaining, 0)
    }

    func testMultipleFullJournalPagesDrainInOnePass() async throws {
        let fixture = TransportHTTPFixture { request, _ in
            (200, try request.httpMethod == "POST" ? Self.pushResult(request, status: "applied") : Self.empty(request), [:])
        }
        let changes = try (1...205).map { number -> OutboundChange in
            let fp = try ContentFingerprint(parsing: "sha256:" + String(format: "%064x", number))
            let record = SyncRecord.game(SyncGameEntry(fingerprint: fp, systemID: "gba", title: "Generated", isFavorite: false,
                addedAt: 1_788_520_000_000, updatedAt: 1_788_520_000_000, contentSize: nil))
            return OutboundChange(journalIDs: [Int64(number)], key: record.key, payload: .save(record, assets: [:]))
        }
        let transport = try transport(fixture, directory: directory()); let host = TransportHostFixture(changes)
        try await transport.start(host: host); try await transport.synchronize()
        let pending = await host.pendingCount(); XCTAssertEqual(pending, 0)
        let requests = await fixture.bodies(); XCTAssertEqual(requests.count, 3)
    }
    func testBatteryHeadsDiscardsStaleSnapshotPages() async throws {
        let fingerprint = fp.description
        let a = "20000000-0000-4000-8000-000000000001", b = "20000000-0000-4000-8000-000000000002"
        let c = "20000000-0000-4000-8000-000000000003", d = "20000000-0000-4000-8000-000000000004"
        let fixture = TransportHTTPFixture { request, count in
            XCTAssertTrue(request.url!.query!.contains("generation=7"))
            if count == 2 { return (409, Data("{}".utf8), [:]) }
            let id = count == 1 ? a : (count == 3 ? c : d)
            let more = count != 4, snapshot = count < 3 ? 1 : 2
            if count == 4 {
                XCTAssertTrue(request.url!.query!.contains("snapshot=2"))
                XCTAssertTrue(request.url!.query!.contains(c))
            }
            let data = Data("{\"schema\":2,\"generation\":7,\"fingerprint\":\"\(fingerprint)\",\"heads\":[\"\(id)\"],\"nextCursor\":\"\(id)\",\"hasMore\":\(more),\"snapshotSequence\":\(snapshot)}".utf8)
            return (200, data, [:])
        }
        _ = b
        let transport = try transport(fixture, directory: directory())
        let heads = try await transport.batteryHeads(fingerprint: fp, generation: 7)
        XCTAssertEqual(heads.map(\.description), [c, d])
    }

    func testRateLimitAndQuotaClassificationsRedactBody() async throws {
        for (status, detail, expected) in [(429, "secret-token", TransportProblem.rateLimited(retryAfterSeconds: 123)),
                                          (409, "logical quota exceeded", .quotaFull), (401, "secret-token", .accountUnavailable),
                                          (426, "secret-token", .other("syncUpgradeRequired")),
                                          (409, "content target belongs to a retired generation", .invalidRecord("content generation retired")),
                                          (409, "content target state is deleted", .invalidRecord("content state deleted")),
                                          (409, "content target membership does not match", .invalidRecord("content membership mismatch")),
                                          (409, "content target generation is not available yet", .rateLimited(retryAfterSeconds: 60))] {
            let fixture = TransportHTTPFixture { _, _ in (status, Data("{\"detail\":\"\(detail)\"}".utf8), ["Retry-After": "123"]) }
            let http = HostedHTTPClient(baseURL: URL(string: "https://sync.example.test")!, executor: fixture, token: { "test-secret" })
            do { _ = try await http.send(method: "GET", path: "/v1/account"); XCTFail("HTTP error ignored") }
            catch let error as HostedHTTPError {
                XCTAssertEqual(error.problem, expected)
                XCTAssertFalse(error.description.contains("secret")); XCTAssertFalse(error.description.contains("example.test"))
            }
        }
    }
}
