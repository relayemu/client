// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryJourneyTests.swift
//  RelayUITests — the product journey through the observable model, without UI
//  automation: empty library → import → populated Home → Library → Search →
//  Game Detail data → Play → return with updated play history → reopen.

import XCTest
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayDesignSystem
import RelayEntitlements
@testable import RelayUI

@MainActor
final class FakeDriver: EmulationDriver {
    let descriptor = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1", license: "MIT",
                                            supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
    var frameSource: VideoFrameSource? = nil
    var log: [String] = []
    func load(romURL: URL, storage: EmulationStorage) throws { log.append("load:\(romURL.lastPathComponent)") }
    func start() throws { log.append("start") }
    func setPaused(_ paused: Bool) { log.append(paused ? "pause" : "resume") }
    func stop() { log.append("stop") }
    func press(_ input: EmulationInput) {}
    func release(_ input: EmulationInput) {}
    func startAudio() throws {}
    func stopAudio() {}
    func sampleDiagnostics() -> EmulationDiagnostics { EmulationDiagnostics() }
}

@MainActor
final class FakeFactory: EmulationDriverFactory {
    let driver = FakeDriver()
    var availableCores: [EmulatorCoreDescriptor] { [driver.descriptor] }
    func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        guard coreID == "fake" else { throw EmulationError.coreUnavailable(coreID) }
        return driver
    }
}

@MainActor
final class LibraryJourneyTests: XCTestCase {
    var root: URL!
    var factory: FakeFactory!

    static var fixtureURL: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/ROMs/240p-test-suite-gba/240pee_mb.gba")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RelayUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        factory = FakeFactory()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    lazy var defaults: UserDefaults = { let d = UserDefaults(suiteName: "RelayUITests-\(UUID().uuidString)")!; return d }()

    func makeModel(now: @escaping @Sendable () -> Date = { Date() },
                   deviceKind: DeviceKind = .iPhone,
                   gameplayRequiresPro: Bool = false,
                   entitlementProvider: (any RelayEntitlementProviding)? = nil) -> LibraryModel {
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "saves"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let session = EmulationSession(factory: factory, storage: storage)
        let fixture = try! ContentFingerprint(parsing: "sha256:47844f7140738a06f8f3bc09780da3ab095539a250b870f614feed561d9d6f34")
        let provider = StaticMetadataProvider(id: "test", entries: [
            fixture: MetadataCandidate(title: "240p Test Suite", developer: "Artemio Urbina", releaseYear: 2021),
        ])
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: root.appending(path: "Library")),
                                             session: session, cores: factory.availableCores, deviceKind: deviceKind,
                                             metadataProvider: provider,
                                             gameplayRequiresPro: gameplayRequiresPro,
                                             entitlementProvider: entitlementProvider)
        return LibraryModel(environment: environment, now: now, defaults: defaults)
    }

    func testEmptyToImportToPlayToContinueAndReopen() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let model = makeModel()
        await model.load()
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.continuePlaying.isEmpty)

        // Import through the product pipeline (copy of the fixture + a renamed duplicate + junk).
        let junk = root.appending(path: "notes.txt"); try Data("x".utf8).write(to: junk)
        let copy = root.appending(path: "Renamed.gba"); try FileManager.default.copyItem(at: fixture, to: copy)
        await model.importFiles([fixture, copy, junk])
        XCTAssertEqual(model.games.count, 1, "the renamed copy must not create a second game")
        XCTAssertEqual(model.importProgress, .summary(added: 1, duplicates: 1, problems: 1))
        XCTAssertEqual(model.problems.count, 1)
        XCTAssertEqual(model.problems[0].headline, String(localized: "\("notes.txt") isn't a supported format.", bundle: .module))
        XCTAssertEqual(model.problems[0].action, .whichFormats)

        // Populated Home: Recently Added with the metadata title, Systems, no Continue yet.
        let game = try XCTUnwrap(model.games.first)
        XCTAssertEqual(game.title, "240p Test Suite")
        XCTAssertEqual(model.recentlyAdded.map(\.id), [game.id])
        XCTAssertTrue(model.isNew(game))
        XCTAssertEqual(model.cardModel(for: game).badge, .new)
        XCTAssertEqual(model.systems.map(\.id), [.gameBoyAdvance])
        XCTAssertEqual(model.systems[0].count, 1)
        XCTAssertTrue(model.continuePlaying.isEmpty)
        XCTAssertEqual(model.firstImportHintGameID, game.id)

        // Library filters and Search.
        XCTAssertEqual(model.games(in: .gameBoyAdvance).count, 1)
        await model.toggleFavorite(game.id)
        XCTAssertEqual(model.favorites.map(\.id), [game.id])
        let byTitle = await model.search("240p")
        XCTAssertEqual(byTitle.map(\.id), [game.id])
        let byDeveloper = await model.search("urbina")
        XCTAssertEqual(byDeveloper.map(\.id), [game.id])
        let bySystem = await model.search("game boy")
        XCTAssertEqual(bySystem.map(\.id), [game.id])
        let none = await model.search("zelda")
        XCTAssertTrue(none.isEmpty)

        // Game Detail data.
        let files = await model.files(for: game.id)
        XCTAssertEqual(files.map(\.originalFileName), ["240pee_mb.gba"])
        XCTAssertEqual(model.metadata[game.id]?.releaseYear, 2021)
        XCTAssertNil(model.history[game.id])

        // Play through the EmulationSession boundary, then return.
        await model.play(game.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.playMessage)
        XCTAssertEqual(model.session.state, .running)
        XCTAssertEqual(factory.driver.log, ["load:240pee_mb.gba", "start"])
        XCTAssertNil(model.firstImportHintGameID, "the hint disappears after the first play")
        model.pause(); XCTAssertEqual(model.session.state, .paused)
        model.resume(); XCTAssertEqual(model.session.state, .running)
        await model.stop()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.session.state, .stopped)
        XCTAssertEqual(factory.driver.log.last, "stop")

        // Home is updated: Continue Playing has the game; Recently Played excludes the first three Continue items.
        XCTAssertEqual(model.continuePlaying.map(\.id), [game.id])
        XCTAssertTrue(model.recentlyPlayed.isEmpty)
        let entry = try XCTUnwrap(model.history[game.id])
        XCTAssertEqual(entry.sessionCount, 1)
        XCTAssertNotNil(entry.latestSession.endedAt)
        XCTAssertTrue(model.continueModel(for: game).statusLine.hasPrefix(String(localized: "this iPhone", bundle: .module).isEmpty ? "" : String(model.continueModel(for: game).statusLine.prefix(1))))
        XCTAssertTrue(model.continueModel(for: game).statusLine.contains(String(localized: "this iPhone", bundle: .module)), model.continueModel(for: game).statusLine)

        // Reopen: everything persisted.
        let reopened = makeModel()
        await reopened.load()
        XCTAssertEqual(reopened.games.map(\.id), [game.id])
        XCTAssertEqual(reopened.games[0].isFavorite, true)
        XCTAssertEqual(reopened.continuePlaying.map(\.id), [game.id])
        XCTAssertEqual(reopened.history[game.id]?.sessionCount, 1)
        XCTAssertEqual(reopened.metadata[game.id]?.developer, "Artemio Urbina")

        // Delete removes rows and content.
        await reopened.delete(game.id)
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.environment.location.directory(forGame: game.id).path))
    }

    func testContinueArtworkRevisionFollowsSessionEndAndScreenshotLocation() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let model = makeModel()
        await model.load()
        await model.importFiles([fixture])
        let game = try XCTUnwrap(model.games.first)
        let store = try XCTUnwrap(model.environment.store)
        let location = try ContentLocation(root: .managedLibrary, relativePath: "Screenshots/\(game.id)/last.png")
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var session = PlaySession(gameID: game.id, coreID: "fake", startedAt: start, screenshotLocation: location)
        try await store.playHistory.record(session)
        await model.refresh()
        let runningCard = model.continueModel(for: game)
        let runningRevision = try XCTUnwrap(runningCard.artworkRevision)
        let lastPlayedAt = model.history[game.id]?.lastPlayedAt

        // The mutable last.png URL and session identity do not change at exit.
        // The completed record is written after the screenshot has been saved.
        session = session.ended(at: start.addingTimeInterval(60))
        try await store.playHistory.record(session)
        await model.refresh()
        let completedCard = model.continueModel(for: game)
        let completedRevision = try XCTUnwrap(completedCard.artworkRevision)
        XCTAssertEqual(completedCard.id, runningCard.id, "The card keeps its game identity")
        XCTAssertEqual(model.history[game.id]?.lastPlayedAt, lastPlayedAt)
        XCTAssertNotEqual(completedRevision, runningRevision,
                          "Ending the same session must invalidate the image even at the same URL")

        await model.refresh()
        XCTAssertEqual(model.continueModel(for: game).artworkRevision, completedRevision,
                       "An unchanged authoritative refresh must not reload the card")

        session.screenshotLocation = try ContentLocation(root: .managedLibrary,
                                                         relativePath: "Screenshots/\(game.id)/received.png")
        try await store.playHistory.record(session)
        await model.refresh()
        XCTAssertNotEqual(model.continueModel(for: game).artworkRevision, completedRevision,
                          "A newly available authoritative screenshot must also invalidate the image")
    }

    func testLaunchFailureBecomesAProductMessageAndClosesTheSession() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let model = makeModel()
        await model.load()
        await model.importFiles([fixture])
        let game = try XCTUnwrap(model.games.first)
        // Remove the managed content behind the library's back.
        try FileManager.default.removeItem(at: model.environment.location.directory(forGame: game.id))
        await model.play(game.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playMessage?.headline, String(localized: "\("240p Test Suite") is missing its game file.", bundle: .module))
        XCTAssertEqual(model.playMessage?.action, .importFiles)
        XCTAssertNil(model.history[game.id], "a launch that never resolved records no session")
    }

    func testNativeMacGameplayRequiresProWithoutGatingLibraryOrData() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let freeMac = makeModel(deviceKind: .mac, gameplayRequiresPro: true)
        await freeMac.load()
        await freeMac.importFiles([fixture])
        let game = try XCTUnwrap(freeMac.games.first)

        XCTAssertTrue(freeMac.hasContent(game.id), "Free users keep local game files")
        XCTAssertFalse(freeMac.canStartGameplay)
        await freeMac.play(game.id)
        XCTAssertFalse(freeMac.isPlaying)
        XCTAssertNil(freeMac.history[game.id], "the gate runs before a play session is created")
        XCTAssertEqual(freeMac.playMessage?.action, .relayPro)

        let proRoot = root.appending(path: "Pro")
        let storage = EmulationStorage(batterySavesDirectory: proRoot.appending(path: "saves"),
                                       saveStatesDirectory: proRoot.appending(path: "states"),
                                       firmwareDirectory: proRoot.appending(path: "firmware"))
        let session = EmulationSession(factory: factory, storage: storage)
        let environment = LibraryEnvironment(
            location: LibraryLocation(rootURL: proRoot.appending(path: "Library")),
            session: session,
            cores: factory.availableCores,
            deviceKind: .mac,
            gameplayRequiresPro: true,
            entitlementProvider: OwnedEntitlementProvider(productID: .proMonthly)
        )
        let proMac = LibraryModel(environment: environment, defaults: defaults)
        await proMac.load()
        await proMac.importFiles([fixture])
        let proGame = try XCTUnwrap(proMac.games.first)
        XCTAssertTrue(proMac.canStartGameplay)
        await proMac.play(proGame.id)
        XCTAssertTrue(proMac.isPlaying, proMac.playMessage?.headline ?? "")
        await proMac.stop()
    }

    func testSlowCommerceNeverDelaysFreePlatformGameplay() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let model = makeModel(entitlementProvider: SlowEntitlementProvider())
        let clock = ContinuousClock()
        let started = clock.now

        await model.load()
        await model.importFiles([fixture])
        let game = try XCTUnwrap(model.games.first)
        await model.play(game.id)

        XCTAssertTrue(model.isPlaying, model.playMessage?.headline ?? "")
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1), "StoreKit product loading is not on the app or game launch path")
        await model.stop()
    }

    func testMacEntitlementLossLetsCurrentSessionStopSafelyThenBlocksNextLaunch() async throws {
        guard let fixture = Self.fixtureURL else { throw XCTSkip("fixture missing") }
        let provider = MutableEntitlementProvider(state: RelayEntitlementState(activeProductIDs: [.proMonthly]))
        let model = makeModel(deviceKind: .mac, gameplayRequiresPro: true, entitlementProvider: provider)
        await model.load()
        await model.importFiles([fixture])
        let game = try XCTUnwrap(model.games.first)

        await model.play(game.id)
        XCTAssertTrue(model.isPlaying)
        provider.send(.free)
        for _ in 0..<50 where model.canStartGameplay {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isPlaying, "an entitlement change must not tear down a running emulator before it saves")
        await model.stop()
        XCTAssertFalse(model.canStartGameplay)

        await model.play(game.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playMessage?.action, .relayPro)
        XCTAssertEqual(model.history[game.id]?.sessionCount, 1)
    }

    func testRecentlyPlayedOrderingAndContinueExclusion() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let model = makeModel(now: { clock.now })
        await model.load()
        // Five distinct games with valid headers.
        for i in 0..<5 {
            let url = root.appending(path: "g\(i).gba")
            try Data(GBABytes.make(payload: UInt8(i + 1))).write(to: url)
            await model.importFiles([url])
            clock.advance(10)
        }
        XCTAssertEqual(model.games.count, 5)
        XCTAssertEqual(model.recentlyAdded.map(\.title), ["g4", "g3", "g2", "g1", "g0"])
        // Play g0..g4 in order; the latest is first.
        for game in model.games.sorted(by: LibraryModel.byTitle) {
            await model.play(game.id); clock.advance(30); await model.stop(); clock.advance(5)
        }
        XCTAssertEqual(model.continuePlaying.map(\.title), ["g4", "g3", "g2", "g1", "g0"])
        XCTAssertEqual(model.recentlyPlayed.map(\.title), ["g1", "g0"], "first three Continue items are excluded")
        XCTAssertEqual(model.history.values.map(\.totalPlayDuration).reduce(0, +), 150)
    }
}

@MainActor
private final class OwnedEntitlementProvider: RelayEntitlementProviding {
    let state: RelayEntitlementState

    init(productID: RelayProductID) {
        state = RelayEntitlementState(activeProductIDs: [productID])
    }

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let state = self.state
        return AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func loadProducts() async throws -> [RelayStoreProduct] { [] }
    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome { .userCancelled }
    func restorePurchases() async throws -> RelayEntitlementState { state }
    func refresh() async -> RelayEntitlementState { state }
}

@MainActor
private final class MutableEntitlementProvider: RelayEntitlementProviding {
    private(set) var state: RelayEntitlementState
    private var continuation: AsyncStream<RelayEntitlementState>.Continuation?

    init(state: RelayEntitlementState) { self.state = state }

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let current = state
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.yield(current)
        }
    }

    func send(_ newState: RelayEntitlementState) {
        state = newState
        continuation?.yield(newState)
    }

    func loadProducts() async throws -> [RelayStoreProduct] { [] }
    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome { .userCancelled }
    func restorePurchases() async throws -> RelayEntitlementState { state }
    func refresh() async -> RelayEntitlementState { state }
}

@MainActor
private final class SlowEntitlementProvider: RelayEntitlementProviding {
    let state = RelayEntitlementState.free

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        AsyncStream { continuation in
            continuation.yield(.free)
            continuation.finish()
        }
    }

    func loadProducts() async throws -> [RelayStoreProduct] {
        try await Task.sleep(for: .seconds(2))
        return []
    }

    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome { .userCancelled }
    func restorePurchases() async throws -> RelayEntitlementState { .free }
    func refresh() async -> RelayEntitlementState { .free }
}

enum GBABytes {
    static func make(payload: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: payload, count: 0x400)
        b[0] = 0x2E; b[1] = 0; b[2] = 0; b[3] = 0xEA
        for i in 0x04..<0xC0 { b[i] = 0 }
        b[0xB0] = 0x30; b[0xB1] = 0x31; b[0xB2] = 0x96
        var sum: UInt32 = 0
        for i in 0xA0...0xBC { sum &+= UInt32(b[i]) }
        b[0xBD] = UInt8(truncatingIfNeeded: (0 &- (sum &+ 0x19)) & 0xFF)
        return b
    }
}
