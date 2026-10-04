// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayLibrary

/// Answers from a table, records every key and the peak number of requests in flight.
actor RecordingCoverSource: CoverArtSource {
    var answers: [String: CoverFetch]
    private(set) var requested: [String] = []
    private(set) var peakInFlight = 0
    private var inFlight = 0
    private let delay: Duration

    init(answers: [String: CoverFetch] = [:], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
    }

    func set(_ answer: CoverFetch, for key: String) { answers[key] = answer }

    func cover(forKey key: String) async -> CoverFetch {
        requested.append(key)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        if delay > .zero { try? await Task.sleep(for: delay) }
        inFlight -= 1
        return answers[key] ?? .notFound
    }
}

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(days: Double) { lock.withLock { current += days * 86_400 } }
}

final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

final class CoverQueueTests: XCTestCase {
    var root: URL!
    var store: InMemoryLibraryStore!
    var location: LibraryLocation!
    var artwork: ArtworkStore!
    let enabled = Switch(true)
    let clock = TestClock()
    let changes = ChangeCounter()

    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        store = InMemoryLibraryStore()
        location = LibraryLocation(rootURL: root.appendingPathComponent("Library"))
        try location.createDirectories()
        artwork = ArtworkStore(location: location)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private static func key(_ seed: Int) -> String { "gba/" + String(format: "%064x", seed) }
    private static let heic = CoverImageTests.encode(width: 256, height: 256, as: .heic)

    private func queue(_ source: any CoverArtSource, applier: MetadataApplier? = nil, gate: ActivityGate? = nil) -> CoverQueue {
        let enabled = enabled, clock = clock, changes = changes
        return CoverQueue(store: store, artworkStore: artwork, source: source, applier: applier, gate: gate,
                          isEnabled: { enabled.isOn }, clock: { clock.now }, onChange: { changes.increment() })
    }

    @discardableResult
    private func addGame(_ seed: UInt8, coverKey: String?, artworkLocation: ContentLocation? = nil, title: String = "Game") async throws -> Game {
        let game = Game(systemID: .gameBoyAdvance, title: title,
                        contentFingerprint: try ContentFingerprint(sha256: Array(repeating: seed, count: 32)), addedAt: Date(timeIntervalSince1970: 1))
        try await store.games.insert(game, files: [])
        if coverKey != nil || artworkLocation != nil {
            try await store.games.upsertMetadata(GameMetadata(gameID: game.id, artworkLocation: artworkLocation, coverKey: coverKey,
                                                              source: "title-catalog", matchedAt: Date(timeIntervalSince1970: 2)))
        }
        return game
    }

    private func artworkLocation(_ game: Game) async throws -> ContentLocation? {
        try await store.games.metadata(for: game.id)?.artworkLocation
    }

    func testStoresACoverAndPointsTheGameAtIt() async throws {
        let game = try await addGame(1, coverKey: Self.key(1))
        let source = RecordingCoverSource(answers: [Self.key(1): .image(Self.heic)])
        let report = await queue(source).runPass()
        XCTAssertEqual(report.stored, 1)
        let stored = try await artworkLocation(game)
        XCTAssertEqual(stored, try LibraryLocation.catalogCoverLocation(gameID: game.id, format: .heic))
        let requested = await source.requested
        XCTAssertEqual(requested, [Self.key(1)])
        // Done once: the next pass has nothing to ask.
        _ = await queue(source).runPass()
        let again = await source.requested
        XCTAssertEqual(again.count, 1)
    }

    func testNothingIsRequestedWhileDisabled() async throws {
        try await addGame(1, coverKey: Self.key(1))
        enabled.isOn = false
        let source = RecordingCoverSource(answers: [Self.key(1): .image(Self.heic)])
        let report = await queue(source).runPass()
        XCTAssertEqual(report, CoverQueue.Report())
        let requested = await source.requested
        XCTAssertTrue(requested.isEmpty)
    }

    func testNeverReplacesOtherArtwork() async throws {
        let game = GameID()
        let provider = try LibraryLocation.artworkLocation(gameID: game, fileExtension: "png")
        let other = try await addGame(1, coverKey: Self.key(1), artworkLocation: provider)
        let source = RecordingCoverSource(answers: [Self.key(1): .image(Self.heic)])
        _ = await queue(source).runPass()
        let kept = try await artworkLocation(other)
        XCTAssertEqual(kept, provider)
        let requested = await source.requested
        XCTAssertTrue(requested.isEmpty)
    }

    func testReusesAStoredCatalogCoverWithoutARequest() async throws {
        let game = try await addGame(1, coverKey: Self.key(1))
        let existing = try artwork.storeCatalogCover(Self.heic, format: .heic, for: game.id)
        let source = RecordingCoverSource()
        let report = await queue(source).runPass()
        XCTAssertEqual(report.reused, 1)
        let pointed = try await artworkLocation(game)
        XCTAssertEqual(pointed, existing)
        let requested = await source.requested
        XCTAssertTrue(requested.isEmpty)
    }

    func testMissingAndInvalidCoversWaitThirtyDays() async throws {
        try await addGame(1, coverKey: Self.key(1))
        try await addGame(2, coverKey: Self.key(2))
        try await addGame(3, coverKey: Self.key(3))
        let source = RecordingCoverSource(answers: [Self.key(1): .notFound, Self.key(2): .invalid,
                                                    Self.key(3): .image(Data("<html>".utf8))])
        let first = await queue(source).runPass()
        XCTAssertEqual(first.missing, 3)
        clock.advance(days: 29)
        _ = await queue(source).runPass()
        let quiet = await source.requested
        XCTAssertEqual(quiet.count, 3)
        clock.advance(days: 2)
        _ = await queue(source).runPass()
        let retried = await source.requested
        XCTAssertEqual(retried.count, 6)
    }

    func testUnavailableSuspendsUntilForeground() async throws {
        let game = try await addGame(1, coverKey: Self.key(1))
        let source = RecordingCoverSource(answers: [Self.key(1): .unavailable])
        let queue = queue(source)
        let failed = await queue.runPass()
        XCTAssertTrue(failed.suspended)
        _ = await queue.runPass()
        let held = await source.requested
        XCTAssertEqual(held.count, 1, "suspended until the next foreground")

        await source.set(.image(Self.heic), for: Self.key(1))
        await queue.foregroundDidResume()
        await queue.waitUntilIdle()
        let resumed = await source.requested
        XCTAssertEqual(resumed.count, 2)
        let stored = try await artworkLocation(game)
        XCTAssertNotNil(stored)
        XCTAssertEqual(changes.count, 1)
    }

    func testAtMostFourRequestsInFlight() async throws {
        var answers: [String: CoverFetch] = [:]
        for seed in 1...10 {
            try await addGame(UInt8(seed), coverKey: Self.key(seed))
            answers[Self.key(seed)] = .notFound
        }
        let source = RecordingCoverSource(answers: answers, delay: .milliseconds(30))
        let report = await queue(source).runPass()
        XCTAssertEqual(report.missing, 10)
        let peak = await source.peakInFlight
        XCTAssertEqual(peak, 4)
    }

    func testHoldsWhileTheGateIsPaused() async throws {
        let game = try await addGame(1, coverKey: Self.key(1))
        let gate = ActivityGate()
        await gate.setPaused(true)
        let source = RecordingCoverSource(answers: [Self.key(1): .image(Self.heic)])
        let queue = queue(source, gate: gate)
        await queue.schedule()
        try await Task.sleep(for: .milliseconds(100))
        let held = await source.requested
        XCTAssertTrue(held.isEmpty)
        await gate.setPaused(false)
        await queue.waitUntilIdle()
        let stored = try await artworkLocation(game)
        XCTAssertNotNil(stored)
    }

    func testMatchesAGameWithoutContentByTitleThenDownloads() async throws {
        let game = try await addGame(1, coverKey: nil, title: "Counter")
        let provider = TitleProvider(entries: ["Counter": MetadataCandidate(title: "Counter", coverKey: Self.key(9))])
        let applier = MetadataApplier(store: store, location: location, provider: provider, artworkStore: artwork)
        let source = RecordingCoverSource(answers: [Self.key(9): .image(Self.heic)])
        let report = await queue(source, applier: applier).runPass()
        XCTAssertEqual(report.matched, 1)
        XCTAssertEqual(report.stored, 1)
        let stored = try await artworkLocation(game)
        XCTAssertNotNil(stored)
    }

    func testRemoveDownloadedCoversKeepsOtherArtwork() async throws {
        let downloaded = try await addGame(1, coverKey: Self.key(1))
        let providerLocation = try LibraryLocation.artworkLocation(gameID: GameID(), fileExtension: "png")
        let other = try await addGame(2, coverKey: Self.key(2), artworkLocation: providerLocation)
        let source = RecordingCoverSource(answers: [Self.key(1): .image(Self.heic)])
        let queue = queue(source)
        _ = await queue.runPass()
        XCTAssertNotNil(artwork.catalogCover(for: downloaded.id))

        await queue.removeDownloadedCovers()
        XCTAssertNil(artwork.catalogCover(for: downloaded.id))
        let cleared = try await artworkLocation(downloaded)
        XCTAssertNil(cleared)
        let kept = try await artworkLocation(other)
        XCTAssertEqual(kept, providerLocation)
        XCTAssertEqual(changes.count, 1)
    }
}
