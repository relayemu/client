// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContinuityJourneyTests.swift
//  an in-memory cloud: Continue projection across devices, cloud-only content
//  messages, Two versions problem card and resolution through the model,
//  Remove Download vs Delete Everywhere, settings switches, local-only when
//  sync is off. No UI automation; the observable models are the contract.

import XCTest
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayDesignSystem
import RelaySync
import RelayEntitlements
@testable import RelayUI

@MainActor
final class ContinuityJourneyTests: XCTestCase {
    var root: URL!
    var cloud: InMemoryCloud!
    var transports: [String: InMemoryCloudTransport] = [:]
    var factories: [String: PlayFactory] = [:]
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RelayContinuityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cloud = InMemoryCloud()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeModel(_ name: String, kind: DeviceKind,
                           capabilities: SyncCapabilities = .internalTesting,
                           gameplayRequiresPro: Bool = false,
                           entitlementProvider: (any RelayEntitlementProviding)? = nil) async -> LibraryModel {
        let factory = PlayFactory()
        factories[name] = factory
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "\(name)/saves"),
                                       saveStatesDirectory: root.appending(path: "\(name)/states"),
                                       firmwareDirectory: root.appending(path: "\(name)/firmware"))
        let session = EmulationSession(factory: factory, storage: storage)
        let defaults = UserDefaults(suiteName: "RelayContinuityTests-\(name)-\(UUID().uuidString)")!
        let clock = self.clock
        let transport = cloud.connect(device: name)
        transports[name] = transport
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: root.appending(path: "\(name)/Library")),
                                             session: session, cores: factory.availableCores, deviceKind: kind,
                                             syncCapabilities: capabilities,
                                             gameplayRequiresPro: gameplayRequiresPro,
                                             entitlementProvider: entitlementProvider,
                                             transportFactory: { _ in transport },
                                             sync: SyncModel(defaults: defaults, now: { clock.now }))
        let model = LibraryModel(environment: environment, now: { clock.now }, defaults: defaults)
        await model.load()
        await model.sync.waitForStartup()
        return model
    }

    private func sync(_ names: String..., rounds: Int = 3) async throws {
        for _ in 0..<rounds { for name in names { try await transports[name]!.pump() } }
    }

    private func importFixture(into model: LibraryModel, title: String = "game") async throws -> Game {
        let url = root.appending(path: "\(title)-\(UUID().uuidString.prefix(4)).gba")
        try Data(GBABytes.make(payload: 0x11)).write(to: url)
        await model.importFiles([url])
        return try XCTUnwrap(model.games.first)
    }

    /// Play for `seconds`, quick save (battery + state + intents), stop.
    private func playSession(_ model: LibraryModel, _ game: Game, battery: [UInt8], seconds: TimeInterval = 60) async throws {
        let name = model.deviceKind == .iPhone ? "phone" : (model.deviceKind == .appleTV ? "tv" : "mac")
        factories[name]?.driver.battery = Data(battery)
        await model.play(game.id)
        XCTAssertTrue(model.isPlaying, model.playMessage?.headline ?? "")
        clock.advance(seconds)
        await model.play.quickSave()
        await model.stop()
    }

    func testContinueFollowsTheOtherDeviceAndSavesReturnSafely() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        let tv = await makeModel("tv", kind: .appleTV)
        XCTAssertTrue(phone.sync.isAvailable)
        XCTAssertTrue(phone.sync.status.isEnabled, "save sync is on by default with an account")
        let gameA = try await importFixture(into: phone, title: "Counter")
        try await playSession(phone, gameA, battery: [1])
        try await sync("phone", "tv")
        await tv.refresh()
        // The TV sees the game with its own id and the iPhone session in Continue Playing.
        let gameB = try XCTUnwrap(tv.games.first)
        XCTAssertNotEqual(gameB.id, gameA.id)
        XCTAssertEqual(tv.continuePlaying.map(\.id), [gameB.id])
        let card = tv.continueModel(for: gameB)
        XCTAssertTrue(card.statusLine.contains("iPhone"), card.statusLine)
        XCTAssertEqual(card.deviceSymbol, .deviceIPhone)
        XCTAssertEqual(card.capsule, .howToAdd, "no game file on the TV and no cloud content: How to Add")
        XCTAssertEqual(tv.primaryAction(for: gameB), .howToAdd)
        // Pressing it explains instead of failing.
        await tv.play(gameB.id)
        XCTAssertFalse(tv.isPlaying)
        XCTAssertEqual(tv.playMessage?.action, .howToAdd)
        tv.clearPlayMessage()
        // The TV gets the file itself (save-only continuity): Continue restores the iPhone progress.
        _ = try await importFixture(into: tv, title: "Counter")
        XCTAssertTrue(tv.hasContent(gameB.id))
        XCTAssertEqual(tv.primaryAction(for: gameB), .continue)
        XCTAssertEqual(try Data(contentsOf: tv.environment.location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameB.id))), Data([1]))
        try await playSession(tv, gameB, battery: [2])
        try await sync("tv", "phone")
        await phone.refresh()
        XCTAssertEqual(try Data(contentsOf: phone.environment.location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameA.id))), Data([2]))
        let phoneCard = phone.continueModel(for: gameA)
        XCTAssertTrue(phoneCard.statusLine.contains("Apple TV"), phoneCard.statusLine)
        XCTAssertEqual(phoneCard.capsule, .continue)
        XCTAssertEqual(phone.history[gameA.id]?.sessionCount, 2)
        XCTAssertNil(phone.sync.problem, "healthy sync is quiet")
        XCTAssertEqual(phone.sync.gameStatus(gameA.id), .upToDate)
    }

    func testLaunchNeverFetchesAndALateDivergentSaveBecomesTwoVersions() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        let tv = await makeModel("tv", kind: .appleTV)
        let gameA = try await importFixture(into: phone, title: "Counter")
        try await playSession(phone, gameA, battery: [1])
        try await sync("phone", "tv")
        await tv.refresh()
        let gameB = try XCTUnwrap(tv.games.first)
        _ = try await importFixture(into: tv, title: "Counter")
        XCTAssertEqual(try Data(contentsOf: tv.environment.location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameB.id))), Data([1]))

        // The iPhone moves on and uploads; the Apple TV has not fetched that yet.
        try await playSession(phone, gameA, battery: [2])
        try await transports["phone"]!.pump()

        // Launching on the Apple TV must not fetch and must not wait (owner policy).
        let fetchesBefore = transports["tv"]!.fetchCount
        let started = Date()
        await tv.play(gameB.id)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(tv.isPlaying, tv.playMessage?.headline ?? "")
        XCTAssertEqual(transports["tv"]!.fetchCount, fetchesBefore, "launch never starts a CloudKit fetch")
        XCTAssertLessThan(elapsed, 1.0, "launch never waits for the network")

        // It played from the newest locally safe progress, and diverges from the remote branch.
        clock.advance(60)
        factories["tv"]?.driver.battery = Data([3])
        await tv.play.quickSave()
        await tv.stop()

        // The remote branch arrives afterwards: both are preserved, Two versions is surfaced.
        try await sync("tv", "phone", rounds: 4)
        await tv.refresh(); await phone.refresh()
        XCTAssertEqual(tv.sync.problem, .twoVersions(gameB.id))
        XCTAssertEqual(tv.primaryAction(for: gameB), .review)
        let conflictOptional = await tv.conflict(for: gameB.id)
        let conflict = try XCTUnwrap(conflictOptional)
        XCTAssertEqual(conflict.heads.count, 2)
        XCTAssertEqual(Set(conflict.heads.map(\.deviceKind)), [.iPhone, .appleTV])
        XCTAssertEqual(try Data(contentsOf: tv.environment.location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameB.id))), Data([3]),
                       "nothing was overwritten while the conflict stands")
    }

    func testTwoVersionsAppearsOnHomeAndResolvesThroughTheModel() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        let tv = await makeModel("tv", kind: .appleTV)
        let gameA = try await importFixture(into: phone, title: "Counter")
        try await playSession(phone, gameA, battery: [1])
        try await sync("phone", "tv")
        await tv.refresh()
        let gameB = try XCTUnwrap(tv.games.first)
        _ = try await importFixture(into: tv, title: "Counter")
        await cloud.setOffline("phone", true); await cloud.setOffline("tv", true)
        try await playSession(phone, gameA, battery: [2])
        try await playSession(tv, gameB, battery: [3])
        await cloud.setOffline("phone", false); await cloud.setOffline("tv", false)
        try await sync("phone", "tv", rounds: 4)
        await phone.refresh(); await tv.refresh()
        XCTAssertEqual(phone.sync.problem, .twoVersions(gameA.id))
        XCTAssertEqual(tv.sync.problem, .twoVersions(gameB.id))
        XCTAssertEqual(phone.primaryAction(for: gameA), .review)
        XCTAssertTrue(phone.statusLine(for: gameA).contains(L("Two versions")))
        // Continue refuses to pick silently.
        await phone.play(gameA.id)
        XCTAssertFalse(phone.isPlaying)
        XCTAssertEqual(phone.playMessage?.action, .compare(gameA.id))
        phone.clearPlayMessage()
        let conflictOptional = await phone.conflict(for: gameA.id)
        let conflict = try XCTUnwrap(conflictOptional)
        XCTAssertEqual(conflict.heads.count, 2)
        let tvHead = try XCTUnwrap(conflict.heads.first { $0.deviceKind == .appleTV })
        let ok = await phone.resolveConflict(gameID: gameA.id, keeping: tvHead.id)
        XCTAssertTrue(ok)
        XCTAssertNil(phone.sync.problem)
        XCTAssertEqual(try Data(contentsOf: phone.environment.location.url(for: try LibraryLocation.batterySaveLocation(gameID: gameA.id))), Data([3]))
        let previous = await phone.previousVersions(for: gameA.id)
        XCTAssertTrue(previous.contains { $0.dataFingerprint != tvHead.dataFingerprint }, "the iPhone version stays as a previous version")
        try await sync("phone", "tv", rounds: 4)
        await tv.refresh()
        XCTAssertNil(tv.sync.problem)
        XCTAssertEqual(tv.primaryAction(for: gameB), .continue)
        // Dismissing a problem card hides it without resolving anything.
        XCTAssertNil(phone.sync.problem)
    }

    func testCloudOnlyDownloadAndRemoveDownloadVersusDeleteEverywhere() async throws {
        let mac = await makeModel("mac", kind: .mac)
        let phone = await makeModel("phone", kind: .iPhone)
        await mac.sync.setGameFilesEnabled(true)
        await phone.sync.setGameFilesEnabled(true)
        let gameA = try await importFixture(into: mac, title: "Counter")
        try await playSession(mac, gameA, battery: [1])
        try await sync("mac", "phone")
        await phone.refresh()
        let gameB = try XCTUnwrap(phone.games.first)
        XCTAssertFalse(phone.hasContent(gameB.id))
        XCTAssertEqual(phone.sync.gameStatus(gameB.id), .cloudOnly(size: Int64(GBABytes.make(payload: 0x11).count)))
        XCTAssertEqual(phone.cardModel(for: gameB).badge, .inCloud)
        XCTAssertEqual(phone.continueModel(for: gameB).capsule, .download)
        XCTAssertTrue(phone.statusLine(for: gameB).contains(L("In iCloud")))
        // Play offers the download; Download & Play installs and launches.
        await phone.play(gameB.id)
        XCTAssertEqual(phone.playMessage?.action, .downloadAndPlay(gameB.id))
        phone.clearPlayMessage()
        await phone.downloadAndPlay(gameB.id)
        XCTAssertTrue(phone.isPlaying, phone.playMessage?.headline ?? "")
        XCTAssertTrue(phone.hasContent(gameB.id))
        await phone.stop()
        // Remove Download keeps the game, its saves and the cloud copy.
        XCTAssertTrue(phone.hasCloudContent(gameB.id))
        await phone.removeDownload(gameB.id)
        XCTAssertFalse(phone.hasContent(gameB.id))
        XCTAssertNotNil(phone.game(gameB.id))
        XCTAssertEqual(phone.sync.gameStatus(gameB.id), .cloudOnly(size: Int64(GBABytes.make(payload: 0x11).count)))
        // Delete Everywhere on the Mac removes it from the phone too.
        await mac.delete(gameA.id)
        try await sync("mac", "phone", rounds: 4)
        await phone.refresh()
        XCTAssertTrue(phone.games.isEmpty)
    }

    func testSyncOffKeepsEverythingLocalAndSettingsReflectIt() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        await phone.sync.setEnabled(false)
        XCTAssertFalse(phone.sync.status.isEnabled)
        let game = try await importFixture(into: phone, title: "Counter")
        try await playSession(phone, game, battery: [1])
        XCTAssertEqual(phone.sync.gameStatus(game.id), .localOnly)
        XCTAssertTrue(phone.statusLine(for: game).contains(Formatting.localOnly(.iPhone)), phone.statusLine(for: game))
        XCTAssertNil(phone.sync.problem)
        let uploaded = await cloud.recordCount(ofType: .game)
        XCTAssertEqual(uploaded, 0)
        await phone.sync.setEnabled(true)
        try await sync("phone")
        let after = await cloud.recordCount(ofType: .batteryRevision)
        XCTAssertEqual(after, 1)
    }

    func testTransportWithoutAssetSupportDoesNotOfferGameFileSync() async throws {
        let mac = await makeModel("mac", kind: .mac, capabilities: .savesOnly)
        XCTAssertFalse(mac.sync.status.gameFilesAllowed)
        await mac.sync.setGameFilesEnabled(true)
        XCTAssertFalse(mac.sync.status.gameFilesEnabled)
    }

    func testFreeProductCanOptIntoGameFileSync() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        XCTAssertEqual(phone.environment.relayPro.entitlement, .free)
        XCTAssertTrue(phone.sync.status.gameFilesAllowed)
        XCTAssertFalse(phone.sync.status.gameFilesEnabled, "game-file sync remains explicit opt-in")

        await phone.sync.setGameFilesEnabled(true)
        XCTAssertTrue(phone.sync.status.gameFilesEnabled)
        let game = try await importFixture(into: phone, title: "Free Cloud File")
        await phone.sync.upload(gameID: game.id)
        try await sync("phone")
        let record = await cloud.record(.gameContent(game.contentFingerprint, part: 0))
        XCTAssertNotNil(record, "Free game-file iCloud sync uploads after explicit opt-in")
    }

    func testFreeMacCanRecoverCloudOnlyGameWithoutStartingGameplay() async throws {
        let phone = await makeModel("phone", kind: .iPhone)
        let mac = await makeModel("mac", kind: .mac, gameplayRequiresPro: true)
        await phone.sync.setGameFilesEnabled(true)
        await mac.sync.setGameFilesEnabled(true)

        _ = try await importFixture(into: phone, title: "Free Recovery")
        try await sync("phone", "mac")
        await mac.refresh()
        let remoteGame = try XCTUnwrap(mac.games.first)

        XCTAssertFalse(mac.canStartGameplay)
        XCTAssertFalse(mac.hasContent(remoteGame.id))
        XCTAssertEqual(mac.primaryAction(for: remoteGame), .download(size: Int64(GBABytes.make(payload: 0x11).count)))

        await mac.primaryAction(remoteGame.id)

        XCTAssertTrue(mac.hasContent(remoteGame.id), "Free Mac users can recover their own iCloud game file")
        XCTAssertFalse(mac.isPlaying, "content recovery must not bypass the separate Mac gameplay gate")
        XCTAssertNil(mac.playMessage)
    }
}
