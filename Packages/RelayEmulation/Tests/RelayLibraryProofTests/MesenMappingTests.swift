// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MesenMappingTests.swift
//  RelayLibraryProofTests — the Relay-to-Mesen button tables, no core needed.

import XCTest
import RelayDomain
import RelayEmulation
import RelayCores
@testable import RelayMesenAdapter

@MainActor
final class MesenMappingTests: XCTestCase {
    /// Mesen's `WsController::Buttons`: X cluster 0–3, Y cluster 4–7, Sound 8, Start 9, B 10, A 11.
    func testWonderSwanUprightSwapsAndTurnsTheClusters() {
        // Held sideways (the usual way): the pad is the X cluster, the second cluster the Y one.
        XCTAssertEqual(MesenDriver.button(for: .up, system: .wonderSwan), 0)
        XCTAssertEqual(MesenDriver.button(for: .right, system: .wonderSwan), 3)
        XCTAssertEqual(MesenDriver.button(for: .cUp, system: .wonderSwan), 4)
        XCTAssertEqual(MesenDriver.button(for: .cRight, system: .wonderSwan), 7)
        // Held upright: what the thumb calls "up" is the Y cluster's right button,
        // and the X cluster becomes the second cluster, a quarter turn the same way.
        XCTAssertEqual(MesenDriver.button(for: .up, system: .wonderSwan, upright: true), 7)
        XCTAssertEqual(MesenDriver.button(for: .down, system: .wonderSwan, upright: true), 6)
        XCTAssertEqual(MesenDriver.button(for: .left, system: .wonderSwan, upright: true), 4)
        XCTAssertEqual(MesenDriver.button(for: .right, system: .wonderSwan, upright: true), 5)
        XCTAssertEqual(MesenDriver.button(for: .cUp, system: .wonderSwan, upright: true), 3)
        XCTAssertEqual(MesenDriver.button(for: .cLeft, system: .wonderSwan, upright: true), 0)
        // Buttons never turn.
        XCTAssertEqual(MesenDriver.button(for: .a, system: .wonderSwan, upright: true), 11)
        XCTAssertEqual(MesenDriver.button(for: .start, system: .wonderSwanColor, upright: true), 9)
        XCTAssertNil(MesenDriver.button(for: .select, system: .wonderSwan), "the WonderSwan has no Select")
    }

    func testSegaAndPCEngineTables() {
        XCTAssertEqual(MesenDriver.button(for: .a, system: .masterSystem), 5, "button 2")
        XCTAssertEqual(MesenDriver.button(for: .b, system: .gameGear), 4, "button 1")
        XCTAssertEqual(MesenDriver.button(for: .start, system: .masterSystem), 6, "Pause")
        XCTAssertNil(MesenDriver.button(for: .select, system: .masterSystem))
        XCTAssertEqual(MesenDriver.button(for: .a, system: .pcEngine), 6, "I")
        XCTAssertEqual(MesenDriver.button(for: .b, system: .pcEngine), 7, "II")
        XCTAssertEqual(MesenDriver.button(for: .start, system: .pcEngine), 5, "Run")
        XCTAssertEqual(MesenDriver.button(for: .select, system: .pcEngine), 4)
        XCTAssertNil(MesenDriver.button(for: .x, system: .pcEngine))
    }

    /// The same lifetime rule on the Mesen side: what the presenter and the
    /// rewind engine keep is inert once the game stops.
    func testMesenFrameSourceIsInertAfterStop() async throws {
        let rom = SystemSmokeProofTests.fixturesRoot.appending(path: "relay-nes-counter/relay-nes-counter.nes")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: rom.path), "fixture missing")
        let root = FileManager.default.temporaryDirectory.appending(path: "MesenLife-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "battery"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let session = EmulationSession(factory: RelayCores.standardFactory(), storage: storage, rewindConfiguration: .standard)
        try session.play(romURL: rom, coreID: "mesen2", systemID: .nes, audio: false)
        try await Task.sleep(for: .milliseconds(700))
        let frames = try XCTUnwrap(session.frameSource)
        let serializer = try XCTUnwrap(session.stateSerializer)
        XCTAssertNotEqual(frames.sampledChecksum(), 0)
        session.stop()
        XCTAssertEqual(frames.sampledChecksum(), 0)
        XCTAssertThrowsError(try serializer.serializeState())
        serializer.runSingleFrame()
    }

    func testGamesLoadThroughTheirSystemsExtension() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MesenLoad-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rom = folder.appending(path: "Something.sms")
        try Data([1, 2, 3]).write(to: rom)
        // A Game Gear game that arrived as .sms is presented to Mesen as .gg, same base name.
        let link = MesenDriver.loadURL(for: rom, system: .gameGear, in: folder)
        XCTAssertEqual(link.lastPathComponent, "Something.gg")
        XCTAssertEqual(try Data(contentsOf: link), Data([1, 2, 3]))
        // A file already named for its system is loaded as is.
        XCTAssertEqual(MesenDriver.loadURL(for: rom, system: .masterSystem, in: folder), rom)
    }
}
