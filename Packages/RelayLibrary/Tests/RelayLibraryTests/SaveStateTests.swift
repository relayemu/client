// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SaveStateTests.swift — container validation, kind semantics, compatibility
//  and corruption refusal, deletion, per-game isolation.

import XCTest
import CoreGraphics
import RelayDomain
@testable import RelayLibrary

final class SaveStateContainerTests: XCTestCase {
    let core = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1.0", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
    let fp = try! ContentFingerprint(sha256: [UInt8](repeating: 9, count: 32))

    func testRoundTrip() throws {
        let game = GameID()
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let container = try SaveStateContainer(gameID: game, contentFingerprint: fp, core: core, kind: .manual, createdAt: Date(timeIntervalSince1970: 1_700_000_000.123), payload: payload)
        let encoded = try container.encoded()
        XCTAssertEqual(encoded.prefix(8), SaveStateContainer.magic)
        let decoded = try SaveStateContainer.decode(encoded)
        XCTAssertEqual(decoded, container)
        XCTAssertEqual(decoded.header.createdAtMillis, 1_700_000_000_123)
        XCTAssertEqual(decoded.header.coreVersion, "1.0")
        XCTAssertEqual(decoded.header.kind, .manual)
        XCTAssertEqual(decoded.header.formatVersion, 2)
        XCTAssertEqual(decoded.header.gameFingerprint, fp)
        XCTAssertEqual(decoded.header.stateCompatibilityVersion, "1.0")
    }

    func testFormatOneFilesStillDecode() throws {
        let payload = Data(repeating: 0x5A, count: 512)
        var header = try SaveStateContainer(gameID: GameID(), contentFingerprint: fp, core: core, kind: .auto, createdAt: Date(), payload: payload).header
        header.formatVersion = 1; header.gameFingerprint = nil; header.stateCompatibilityVersion = nil
        let decoded = try SaveStateContainer.decode(try SaveStateContainer(header: header, payload: payload).encoded())
        XCTAssertEqual(decoded.header.formatVersion, 1)
        XCTAssertEqual(decoded.header.effectiveCompatibilityVersion, "1.0")
        // A format-2 header missing its new fields is malformed, not silently accepted.
        var bad = header; bad.formatVersion = 2
        XCTAssertThrowsError(try SaveStateContainer.decode(try SaveStateContainer(header: bad, payload: payload).encoded()))
    }

    func testCorruptionIsRefused() throws {
        let payload = Data(repeating: 0xAB, count: 4096)
        let encoded = try SaveStateContainer(gameID: GameID(), contentFingerprint: fp, core: core, kind: .quick, createdAt: Date(), payload: payload).encoded()
        // Truncated payload.
        XCTAssertThrowsError(try SaveStateContainer.decode(encoded.prefix(encoded.count - 1))) { XCTAssertTrue("\($0)".contains("truncated"), "\($0)") }
        // Flipped payload byte.
        var flipped = encoded; flipped[flipped.count - 10] ^= 0x01
        XCTAssertThrowsError(try SaveStateContainer.decode(flipped)) { XCTAssertEqual($0 as? SaveStateContainer.ContainerError, .fingerprintMismatch) }
        // Wrong magic.
        var wrong = encoded; wrong[0] = 0x00
        XCTAssertThrowsError(try SaveStateContainer.decode(wrong)) { XCTAssertEqual($0 as? SaveStateContainer.ContainerError, .notAContainer) }
        // Header from the future.
        var header = try SaveStateContainer.decode(encoded).header
        header.formatVersion = SaveStateContainer.currentFormatVersion + 1
        let future = try SaveStateContainer(header: header, payload: payload).encoded()
        XCTAssertThrowsError(try SaveStateContainer.decode(future)) { XCTAssertEqual($0 as? SaveStateContainer.ContainerError, .unsupportedFormatVersion(header.formatVersion)) }
        // Garbage.
        XCTAssertThrowsError(try SaveStateContainer.decode(Data(repeating: 0x41, count: 100)))
        XCTAssertThrowsError(try SaveStateContainer.decode(Data()))
    }
}

final class SaveStateManagerTests: XCTestCase {
    var root: URL!
    var location: LibraryLocation!
    var store: InMemoryLibraryStore!
    var manager: SaveStateManager!
    var game: Game!
    let core = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1.0", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates, .rewind])
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        root = try TestSupport.temporaryDirectory()
        location = LibraryLocation(rootURL: root)
        try location.createDirectories()
        store = InMemoryLibraryStore()
        manager = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location))
        game = try await insertGame(seed: 1)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func insertGame(seed: UInt8) async throws -> Game {
        let g = Game(systemID: .gameBoyAdvance, title: "G\(seed)", contentFingerprint: try ContentFingerprint(sha256: [UInt8](repeating: seed, count: 32)), addedAt: Date())
        try await store.games.insert(g, files: [GameFile(gameID: g.id, role: .primary, fingerprint: g.contentFingerprint, sizeInBytes: 10, originalFileName: "g.gba", location: try LibraryLocation.gameFileLocation(gameID: g.id, fileName: "g.gba"))])
        return g
    }

    private func payload(_ seed: UInt8) -> Data { Data(repeating: seed, count: 2048) }

    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        return ctx.makeImage()!
    }

    func testManualStateRoundTripWithScreenshot() async throws {
        let state = try await manager.create(kind: .manual, game: game, core: core, payload: payload(1), screenshot: image(), now: t0)
        XCTAssertEqual(state.kind, .manual)
        XCTAssertEqual(state.coreID, core.id)
        XCTAssertEqual(state.coreVersion, "1.0")
        XCTAssertEqual(state.formatVersion, SaveState.currentFormatVersion)
        XCTAssertEqual(state.location.relativePath, "Saves/\(game.id)/states/\(state.id).relaystate")
        XCTAssertEqual(state.screenshotLocation?.relativePath, "Saves/\(game.id)/screenshots/\(state.id).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: state.location).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: state.screenshotLocation!).path))
        let rows = try await manager.states(for: game.id)
        XCTAssertEqual(rows, [state])
        XCTAssertEqual(try manager.load(state, game: game, for: core), payload(1))
        let thumb = await ArtworkStore(location: location).image(at: state.screenshotLocation!, maxPixelSize: 120)
        XCTAssertNotNil(thumb)
    }

    func testManualStatesAreNeverReplaced() async throws {
        for i in 0..<5 { _ = try await manager.create(kind: .manual, game: game, core: core, payload: payload(UInt8(i)), now: t0.addingTimeInterval(Double(i))) }
        let browser = try await manager.browserStates(for: game.id, now: t0.addingTimeInterval(10))
        XCTAssertEqual(browser.manual.count, 5)
        XCTAssertEqual(browser.manual.map(\.createdAt), (0..<5).reversed().map { t0.addingTimeInterval(Double($0)) }, "newest first")
    }

    func testQuickSaveReplacesAndKeepsPreviousForADay() async throws {
        let q1 = try await manager.create(kind: .quick, game: game, core: core, payload: payload(1), now: t0)
        let q2 = try await manager.create(kind: .quick, game: game, core: core, payload: payload(2), now: t0.addingTimeInterval(60))
        let q3 = try await manager.create(kind: .quick, game: game, core: core, payload: payload(3), now: t0.addingTimeInterval(120))
        var quick = try await manager.browserStates(for: game.id, now: t0.addingTimeInterval(130)).quick
        XCTAssertEqual(quick.map(\.id), [q3.id, q2.id], "current + previous")
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: q1.location).path), "oldest quick file removed")
        let latestQuick = try await manager.latestQuickSave(for: game.id)
        XCTAssertEqual(latestQuick, q3)
        // A day later the previous one expires.
        quick = try await manager.browserStates(for: game.id, now: t0.addingTimeInterval(120 + 25 * 3600)).quick
        XCTAssertEqual(quick.map(\.id), [q3.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: q2.location).path))
    }

    func testAutoResumeKeepsSmallHistoryAndStaysOutOfTheBrowser() async throws {
        var autos: [SaveState] = []
        for i in 0..<5 { autos.append(try await manager.create(kind: .auto, game: game, core: core, payload: payload(UInt8(i)), now: t0.addingTimeInterval(Double(i)))) }
        _ = try await manager.create(kind: .manual, game: game, core: core, payload: payload(9), now: t0.addingTimeInterval(100))
        let all = try await manager.states(for: game.id)
        XCTAssertEqual(all.filter { $0.kind == .auto }.map(\.id), [autos[4].id, autos[3].id, autos[2].id])
        let latestAuto = try await manager.latestAutoResume(for: game.id)
        XCTAssertEqual(latestAuto?.id, autos[4].id)
        let browser = try await manager.browserStates(for: game.id, now: t0.addingTimeInterval(200))
        XCTAssertTrue(browser.quick.isEmpty)
        XCTAssertEqual(browser.manual.count, 1)
        for old in autos.prefix(2) { XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: old.location).path)) }
    }

    func testIncompatibleStateIsRefusedBeforeReadingTheFile() async throws {
        let state = try await manager.create(kind: .manual, game: game, core: core, payload: payload(1), now: t0)
        let newer = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1.1", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertThrowsError(try manager.load(state, game: game, for: newer)) { XCTAssertEqual($0 as? SaveStateLoadError, .incompatible(state)) }
        let other = EmulatorCoreDescriptor(id: "other", name: "Other", version: "1.0", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertThrowsError(try manager.load(state, game: game, for: other)) { XCTAssertEqual($0 as? SaveStateLoadError, .incompatible(state)) }
        XCTAssertFalse(state.isRestorable(by: newer))
        XCTAssertTrue(state.isRestorable(by: core))
    }

    func testCorruptAndMissingStatesAreRefused() async throws {
        let state = try await manager.create(kind: .manual, game: game, core: core, payload: payload(1), now: t0)
        let url = location.url(for: state.location)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: url)
        XCTAssertThrowsError(try manager.load(state, game: game, for: core)) { error in
            guard case .corrupt(let s, _)? = error as? SaveStateLoadError else { return XCTFail("\(error)") }
            XCTAssertEqual(s, state)
        }
        try Data("junk".utf8).write(to: url)
        XCTAssertThrowsError(try manager.load(state, game: game, for: core)) { XCTAssertNotNil($0 as? SaveStateLoadError) }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try manager.load(state, game: game, for: core)) { XCTAssertEqual($0 as? SaveStateLoadError, .missing(state)) }
        // A file whose header names another game is refused even if its bytes validate.
        let otherGame = try await insertGame(seed: 2)
        let foreign = try await manager.create(kind: .manual, game: otherGame, core: core, payload: payload(2), now: t0)
        try FileManager.default.copyItem(at: location.url(for: foreign.location), to: url)
        XCTAssertThrowsError(try manager.load(state, game: game, for: core)) { error in
            guard case .corrupt? = error as? SaveStateLoadError else { return XCTFail("\(error)") }
        }
    }

    func testFailedStateWriteLeavesNoRowAndNoFile() async throws {
        let failing = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location),
                                       atomicFile: AtomicFile { s in if s == .rename { throw AtomicFile.Failure.injected(.rename) } })
        await XCTAssertThrowsErrorAsync(try await failing.create(kind: .manual, game: game, core: core, payload: payload(1), now: t0)) { _ in }
        let rows = try await manager.states(for: game.id)
        XCTAssertTrue(rows.isEmpty)
        let dir = location.saveStatesDirectory(forGame: game.id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty, "\(files)")
    }

    func testDeleteRemovesRowThenFiles() async throws {
        let state = try await manager.create(kind: .manual, game: game, core: core, payload: payload(1), screenshot: image(), now: t0)
        try await manager.delete(state)
        let rows = try await manager.states(for: game.id)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: state.location).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: state.screenshotLocation!).path))
    }

    func testGamesAreIsolated() async throws {
        let other = try await insertGame(seed: 3)
        let a = try await manager.create(kind: .quick, game: game, core: core, payload: payload(1), now: t0)
        let b = try await manager.create(kind: .quick, game: other, core: core, payload: payload(2), now: t0)
        let mine = try await manager.states(for: game.id)
        let theirs = try await manager.states(for: other.id)
        XCTAssertEqual(mine, [a])
        XCTAssertEqual(theirs, [b])
        XCTAssertNotEqual(location.saveStatesDirectory(forGame: game.id), location.saveStatesDirectory(forGame: other.id))
        manager.removeAll(for: other.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url(for: a.location).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.url(for: b.location).path))
    }
}
