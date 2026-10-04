// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ArtworkSyncTests.swift — custom covers across devices (cover-art Plan E):
//  one last-writer-wins value per game, ties broken by cover fingerprint, a
//  reset travels as a value, received covers are verified before install and
//  never journalled again, and a cover waits for its game.

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
import RelayLibrary
import RelayPersistence
@testable import RelaySync

final class ArtworkSyncTests: XCTestCase {
    var cloud: InMemoryCloud!
    var clock: TestClock!
    var a: SimulatedDevice!
    var b: SimulatedDevice!
    let content = gbaBytes(seed: 0x21)

    override func setUp() async throws {
        cloud = InMemoryCloud()
        clock = TestClock()
        a = try await SimulatedDevice(name: "iphone", kind: .iPhone, cloud: cloud, clock: clock)
        b = try await SimulatedDevice(name: "mac", kind: .mac, cloud: cloud, clock: clock)
        await a.start(); await b.start()
    }

    override func tearDown() { a.destroy(); b.destroy() }

    private func converge(rounds: Int = 4) async throws {
        for _ in 0..<rounds { for device in [a!, b!] { try await device.sync() } }
    }

    /// A small image whose colour depends on `seed` (distinct covers have distinct fingerprints).
    static func image(_ seed: UInt8) -> Data {
        let context = CGContext(data: nil, width: 96, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(seed) / 255, green: 0.4, blue: 1 - CGFloat(seed) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 128))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @discardableResult
    private func choose(_ device: SimulatedDevice, _ game: Game, _ seed: UInt8) async throws -> CustomCover {
        let clock = clock!
        let cover = try await CustomCoverEditor(store: device.store, artworkStore: ArtworkStore(location: device.location), clock: { clock.now })
            .choose(Self.image(seed), for: game.id)
        await device.coordinator.flushSoon()
        return cover
    }

    private func reset(_ device: SimulatedDevice, _ game: Game) async throws {
        let clock = clock!
        try await CustomCoverEditor(store: device.store, artworkStore: ArtworkStore(location: device.location), clock: { clock.now })
            .reset(gameID: game.id)
        await device.coordinator.flushSoon()
    }

    /// The device's cover value for the game, and whether its file is installed and decodes.
    private func cover(on device: SimulatedDevice, _ fingerprint: ContentFingerprint) async throws -> (CustomCover?, installed: Bool) {
        guard let game = try await device.game(fingerprint) else { return (nil, false) }
        let value = try await device.store.games.customCover(for: game.id)
        guard let value, let file = ArtworkStore(location: device.location).customCover(value) else { return (value, false) }
        return (value, ArtworkStore.decode(device.location.url(for: file), maxPixelSize: 64) != nil)
    }

    private func customFiles(on device: SimulatedDevice, _ game: Game) -> [String] {
        let directory = device.location.artworkDirectory.appending(path: game.id.description)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("custom-") }
    }

    func testACoverChosenOnOneDeviceReachesTheOther() async throws {
        let game = try await a.importGame(content, title: "Covered")
        try await converge()
        let chosen = try await choose(a, game, 10)
        try await converge()

        let (received, installed) = try await cover(on: b, game.contentFingerprint)
        XCTAssertEqual(received?.fingerprint, chosen.fingerprint)
        XCTAssertEqual(received.map { SyncTime.millis($0.updatedAt) }, SyncTime.millis(chosen.updatedAt))
        XCTAssertTrue(installed, "the received cover is installed and decodes")
        let journalB = try await b.store.syncStore.journal.pending(limit: 100).map(\.intent.kind)
        XCTAssertFalse(journalB.contains(.artwork), "a received cover is never journalled again")
        let pendingA = try await a.pendingCount(), pendingB = try await b.pendingCount()
        XCTAssertEqual([pendingA, pendingB], [0, 0])
    }

    func testTheLaterValueWinsBothWaysAndAResetTravels() async throws {
        let game = try await a.importGame(content, title: "Contested")
        try await converge()
        let receivedGame = try await b.game(game.contentFingerprint)
        let gameB = try XCTUnwrap(receivedGame)
        try await choose(a, game, 20)
        clock.advance(5)
        let later = try await choose(b, gameB, 30)
        try await converge()
        for device in [a!, b!] {
            let (value, installed) = try await cover(on: device, game.contentFingerprint)
            XCTAssertEqual(value?.fingerprint, later.fingerprint, device.name)
            XCTAssertTrue(installed, device.name)
        }
        XCTAssertEqual(customFiles(on: a, game).count, 1, "the superseded cover file is removed")

        clock.advance(5)
        try await reset(a, game)
        try await converge()
        for device in [a!, b!] {
            let (value, _) = try await cover(on: device, game.contentFingerprint)
            XCTAssertEqual(value?.isCleared, true, device.name)
        }
        XCTAssertEqual(customFiles(on: b, gameB), [], "a reset removes the received cover")
    }

    func testEqualTimesKeepTheGreaterFingerprintEverywhere() async throws {
        let game = try await a.importGame(content, title: "Tie")
        try await converge()
        let receivedGame = try await b.game(game.contentFingerprint)
        let gameB = try XCTUnwrap(receivedGame)
        let first = try await choose(a, game, 40)
        let second = try await choose(b, gameB, 50)
        XCTAssertEqual(SyncTime.millis(first.updatedAt), SyncTime.millis(second.updatedAt))
        let winner = [first.fingerprint!, second.fingerprint!].max { $0.canonicalString < $1.canonicalString }
        try await converge()
        for device in [a!, b!] {
            let (value, installed) = try await cover(on: device, game.contentFingerprint)
            XCTAssertEqual(value?.fingerprint, winner, device.name)
            XCTAssertTrue(installed, device.name)
        }
    }

    func testARefusedCoverNeverHoldsBackTheHostedPage() async throws {
        let game = try await b.importGame(content, title: "Local")
        let jpeg = Self.image(70), url = b.root.appending(path: "cover-\(UUID().uuidString)")
        try jpeg.write(to: url)
        let cover = SyncRecord.artwork(SyncArtwork(fingerprint: game.contentFingerprint, artworkFingerprint: try SHA256ContentHasher().hash(data: jpeg).fingerprint,
                                                   artworkSize: Int64(jpeg.count), updatedAt: SyncTime.millis(clock.now), installationID: InstallationID()))
        let renamed = SyncRecord.game(SyncGameEntry(fingerprint: game.contentFingerprint, systemID: game.systemID.rawValue, title: "Renamed", isFavorite: false,
                                                    addedAt: SyncTime.millis(game.addedAt), updatedAt: SyncTime.millis(clock.now) + 1_000, contentSize: nil))
        try await b.coordinator.applyHostedPage(changes: [InboundChange(key: cover.key, record: cover, assets: [.data: url]),
                                                          InboundChange(key: renamed.key, record: renamed)], deletions: [], cursor: 2, scope: "test")
        let title = try await b.game(game.contentFingerprint)?.title
        let stored = try await b.store.games.customCover(for: game.id)
        let cursor = try await b.coordinator.hostedCursor(scope: "test")
        XCTAssertEqual(title, "Renamed", "the progress on the page applies")
        XCTAssertNil(stored, "a JPEG is not a Relay cover")
        XCTAssertEqual(cursor, 2)
    }

    func testARefusedCoverThatWaitedForItsGameLeavesTheDeferredStore() async throws {
        let fingerprint = try SHA256ContentHasher().hash(data: gbaBytes(seed: 0x44)).fingerprint
        let jpeg = Self.image(71), url = b.root.appending(path: "cover-\(UUID().uuidString)")
        try jpeg.write(to: url)
        let cover = SyncRecord.artwork(SyncArtwork(fingerprint: fingerprint, artworkFingerprint: try SHA256ContentHasher().hash(data: jpeg).fingerprint,
                                                   artworkSize: Int64(jpeg.count), updatedAt: SyncTime.millis(clock.now), installationID: InstallationID()))
        try await b.coordinator.applyHostedPage(changes: [InboundChange(key: cover.key, record: cover, assets: [.data: url])], deletions: [], cursor: 1, scope: "test")
        let waiting = try await b.store.syncStore.deferredRecords()
        XCTAssertEqual(waiting.count, 1, "the cover waits for its game")
        let game = SyncRecord.game(SyncGameEntry(fingerprint: fingerprint, systemID: "gba", title: "Arrives later", isFavorite: false,
                                                 addedAt: SyncTime.millis(clock.now), updatedAt: SyncTime.millis(clock.now), contentSize: nil))
        try await b.coordinator.applyHostedPage(changes: [InboundChange(key: game.key, record: game)], deletions: [], cursor: 2, scope: "test")
        let arrived = try await b.game(fingerprint)
        XCTAssertNotNil(arrived)
        let remaining = try await b.store.syncStore.deferredRecords()
        XCTAssertTrue(remaining.isEmpty, "a refused cover is dropped, never retried forever")
        if let arrived { let stored = try await b.store.games.customCover(for: arrived.id); XCTAssertNil(stored) }
    }

    func testAReceivedCoverIsVerifiedAndWaitsForItsGame() async throws {
        let game = try await b.importGame(content, title: "Local")
        let applier = RemoteApplier(store: b.store, syncStore: b.store.syncStore, location: b.location, saveStates: b.saveStates, identity: b.identity)
        let scratch = b.root.appending(path: "scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        func change(_ fingerprint: ContentFingerprint, _ bytes: Data, declared: ContentFingerprint, size: Int64) throws -> InboundChange {
            let url = scratch.appending(path: UUID().uuidString)
            try bytes.write(to: url)
            let record = SyncRecord.artwork(SyncArtwork(fingerprint: fingerprint, artworkFingerprint: declared, artworkSize: size,
                                                        updatedAt: SyncTime.millis(clock.now), installationID: InstallationID()))
            return InboundChange(key: record.key, record: record, assets: [.data: url])
        }
        let heic = try CustomCoverImage.normalize(Self.image(60))
        let heicFingerprint = try ContentFingerprint(sha256: Array(SHA256ContentHasher().hash(data: heic).fingerprint.digest))
        let jpeg = Self.image(61)
        let jpegFingerprint = try SHA256ContentHasher().hash(data: jpeg).fingerprint

        let tampered = try change(game.contentFingerprint, heic, declared: jpegFingerprint, size: Int64(heic.count))
        let notHEIC = try change(game.contentFingerprint, jpeg, declared: jpegFingerprint, size: Int64(jpeg.count))
        let oversized = try change(game.contentFingerprint, heic, declared: heicFingerprint, size: Int64(CoverImage.maximumBytes) + 1)
        let unknownGame = try change(try ContentFingerprint(sha256: Array(repeating: 9, count: 32)), heic, declared: heicFingerprint, size: Int64(heic.count))
        let prepared = try await applier.prepare(changes: [tampered, notHEIC, oversized, unknownGame], deletions: [], now: clock.now)
        XCTAssertEqual(prepared.rejected.count, 3, "a wrong fingerprint, a non-HEIC image and an oversized cover are refused")
        XCTAssertEqual(prepared.deferredCount, 1, "a cover for a game not here yet waits")
        XCTAssertTrue(prepared.batch.customCovers.isEmpty)
        for file in prepared.installedFiles { try? FileManager.default.removeItem(at: file) }
    }
}
