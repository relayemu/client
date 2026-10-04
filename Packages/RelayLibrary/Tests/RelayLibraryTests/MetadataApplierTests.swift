// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CryptoKit
import RelayDomain
@testable import RelayLibrary

/// Matches by SHA-1 only, like the title catalog.
struct DigestProvider: MetadataProvider {
    let id = "test-catalog"
    let revision: String? = "r1"
    let usesLookupDigests = true
    let entries: [String: MetadataCandidate]
    func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] {
        request.lookupDigests.flatMap { entries[$0.sha1] }.map { [$0] } ?? []
    }
}

/// Matches by title only and records every request it receives.
final class TitleProvider: MetadataProvider, @unchecked Sendable {
    let id = "test-catalog"
    let usesLookupDigests = true
    private let entries: [String: MetadataCandidate]
    private let lock = NSLock()
    private var received: [MetadataRequest] = []
    init(entries: [String: MetadataCandidate]) { self.entries = entries }
    var requests: [MetadataRequest] { lock.withLock { received } }
    func match(_ request: MetadataRequest) async throws -> [MetadataCandidate] {
        lock.withLock { received.append(request) }
        return request.title.flatMap { entries[$0] }.map { [$0] } ?? []
    }
}

final class MetadataApplierTests: XCTestCase {
    var root: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: root.appendingPathComponent("Library"))
        try location.createDirectories()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func fixtureURL() -> URL {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("Tests/Fixtures/ROMs/relay-gb-counter/relay-gb-counter.gb")
    }
    private func fixtureSHA1() throws -> String {
        Insecure.SHA1.hash(data: try Data(contentsOf: fixtureURL())).map { String(format: "%02x", $0) }.joined()
    }
    private func candidate() -> MetadataCandidate {
        MetadataCandidate(title: "Counter", region: "World", coverKey: "gb/" + String(repeating: "c", count: 64))
    }
    private func importFixture(provider: any MetadataProvider = NoMetadataProvider()) async throws -> Game {
        let importer = GameImporter(store: store, location: location, metadataProvider: provider)
        let report = await importer.importFiles([fixtureURL()])
        return try XCTUnwrap(report.addedGames.first)
    }

    func testImportMatchesByDigestRenamesAndCachesDigests() async throws {
        let provider = DigestProvider(entries: [try fixtureSHA1(): candidate()])
        let game = try await importFixture(provider: provider)
        XCTAssertEqual(game.title, "Counter")
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertEqual(metadata?.coverKey, "gb/" + String(repeating: "c", count: 64))
        XCTAssertEqual(metadata?.region, "World")
        XCTAssertEqual(metadata?.source, "test-catalog")
        let cached = try await store.games.lookupDigests(for: game.contentFingerprint)
        XCTAssertEqual(cached?.sha1, try fixtureSHA1())
    }

    func testPlayerRenameAndOtherProvidersAreNeverOverwritten() async throws {
        var game = try await importFixture()
        game.title = "My Counter"
        try await store.games.update(game)
        let applier = MetadataApplier(store: store, location: location,
                                      provider: DigestProvider(entries: [try fixtureSHA1(): candidate()]), artworkStore: ArtworkStore(location: location))
        let renamedByPlayer = await applier.apply(to: game)
        XCTAssertEqual(renamedByPlayer.outcome, .matched(renamed: false))
        XCTAssertEqual(renamedByPlayer.game.title, "My Counter")

        try await store.games.upsertMetadata(GameMetadata(gameID: game.id, region: "Other", source: "other", matchedAt: Date()))
        let foreign = await applier.apply(to: game)
        XCTAssertEqual(foreign.outcome, .skipped)
        let kept = try await store.games.metadata(for: game.id)
        XCTAssertEqual(kept?.region, "Other")
    }

    func testCatalogRenameNeverAdvancesTheEditTimestamp() async throws {
        // A player's rename stamps now(); a catalog default keeps the old stamp,
        // so any player rename, on any device, wins last-write-wins sync.
        let game = try await importFixture()
        let applier = MetadataApplier(store: store, location: location,
                                      provider: DigestProvider(entries: [try fixtureSHA1(): candidate()]), artworkStore: ArtworkStore(location: location))
        let result = await applier.apply(to: game)
        XCTAssertEqual(result.outcome, .matched(renamed: true))
        let stored = try await store.games.game(id: game.id)
        XCTAssertEqual(stored?.title, "Counter")
        XCTAssertEqual(stored?.updatedAt, game.updatedAt)
    }

    func testRenameStartsFromTheStoredGameNotAStaleSnapshot() async throws {
        let snapshot = try await importFixture()
        var favourite = snapshot
        favourite.isFavorite = true
        favourite.updatedAt = snapshot.updatedAt.addingTimeInterval(5)
        try await store.games.update(favourite)
        let applier = MetadataApplier(store: store, location: location,
                                      provider: DigestProvider(entries: [try fixtureSHA1(): candidate()]), artworkStore: ArtworkStore(location: location))
        _ = await applier.apply(to: snapshot)
        let stored = try await store.games.game(id: snapshot.id)
        XCTAssertEqual(stored?.title, "Counter")
        XCTAssertEqual(stored?.isFavorite, true, "a change made after the snapshot survives")
        XCTAssertEqual(stored?.updatedAt, favourite.updatedAt)
    }

    func testChainedProviderRecordsTheProviderThatMatched() async throws {
        let chained = ChainedMetadataProvider([NoMetadataProvider(), DigestProvider(entries: [try fixtureSHA1(): candidate()])])
        XCTAssertEqual(chained.revision, "r1")
        let game = try await importFixture(provider: chained)
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertEqual(metadata?.source, "test-catalog")
    }

    func testProvidersThatIgnoreDigestsNeverReadTheFile() async throws {
        let game = try await importFixture(provider: NoMetadataProvider())
        let cached = try await store.games.lookupDigests(for: game.contentFingerprint)
        XCTAssertNil(cached)
    }

    func testGameWithoutLocalContentMatchesBySyncedTitleAndKeepsIt() async throws {
        var game = try await importFixture()
        try await store.games.removeLocalContent(gameID: game.id)
        game.title = "Counter Deluxe"
        try await store.games.update(game)
        let provider = TitleProvider(entries: ["Counter Deluxe": candidate()])
        let applier = MetadataApplier(store: store, location: location, provider: provider, artworkStore: ArtworkStore(location: location))

        let result = await applier.apply(to: game)
        XCTAssertEqual(result.outcome, .matched(renamed: false))
        XCTAssertEqual(result.game.title, "Counter Deluxe")
        let stored = try await store.games.game(id: game.id)
        XCTAssertEqual(stored?.title, "Counter Deluxe", "a synced title came from another device and is never changed here")
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertEqual(metadata?.coverKey, candidate().coverKey)
        XCTAssertEqual(provider.requests.last?.title, "Counter Deluxe")
        XCTAssertNil(provider.requests.last?.lookupDigests)

        // A title match never replaces an existing match (an exact one is better).
        let again = await applier.apply(to: game)
        XCTAssertEqual(again.outcome, .skipped)
    }

    func testLocalGameNeverSendsItsTitle() async throws {
        let provider = TitleProvider(entries: [:])
        _ = try await importFixture(provider: provider)
        XCTAssertFalse(provider.requests.isEmpty)
        XCTAssertTrue(provider.requests.allSatisfy { $0.title == nil && $0.lookupDigests != nil })
    }

    func testUnmatchedGameIsUnchanged() async throws {
        let game = try await importFixture(provider: DigestProvider(entries: [:]))
        XCTAssertEqual(game.title, "relay-gb-counter")
        let metadata = try await store.games.metadata(for: game.id)
        XCTAssertNil(metadata)
    }
}
