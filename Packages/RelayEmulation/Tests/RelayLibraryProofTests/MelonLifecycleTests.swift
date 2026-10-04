// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MelonLifecycleTests.swift — the DS through the lifecycle the app drives.

import XCTest
import RelayDomain
import RelayEmulation
import RelayCores

@MainActor
final class MelonLifecycleTests: XCTestCase {
    private func launch() throws -> EmulationSession {
        let rom = SystemSmokeProofTests.fixturesRoot.appending(path: "relay-ds-counter/relay-ds-counter.nds")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: rom.path), "fixture missing")
        let root = FileManager.default.temporaryDirectory.appending(path: "MelonLife-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = EmulationStorage(batterySavesDirectory: root.appending(path: "battery"),
                                       saveStatesDirectory: root.appending(path: "states"),
                                       firmwareDirectory: root.appending(path: "firmware"))
        let session = EmulationSession(factory: RelayCores.standardFactory(), storage: storage, rewindConfiguration: .standard)
        try session.play(romURL: rom, coreID: "melonds", systemID: .nintendoDS, audio: false)
        return session
    }

    /// The fixture paints a red column on touch. Check the pixels consumed by
    /// both Metal and save thumbnails, not just a changing frame checksum.
    func testTouchColumnKeepsItsRGBColorThroughTheBridge() async throws {
        let session = try launch()
        defer { session.stop() }
        try await Task.sleep(for: .milliseconds(800))
        session.touch(screenIndex: 1, x: 100, y: 60)
        try await Task.sleep(for: .milliseconds(300))
        session.releaseTouch()
        session.pause()

        let bottom = try XCTUnwrap(session.screenFrameSources.last)
        var colors = Set<UInt32>()
        var allPixelsOpaque = true
        bottom.withCurrentFrame { pointer, descriptor in
            let bytes = pointer.assumingMemoryBound(to: UInt8.self)
            for y in 0..<descriptor.height {
                for x in 0..<descriptor.width {
                    let offset = y * descriptor.bytesPerRow + x * 4
                    colors.insert(UInt32(bytes[offset]) << 16
                                  | UInt32(bytes[offset + 1]) << 8
                                  | UInt32(bytes[offset + 2]))
                    allPixelsOpaque = allPixelsOpaque && bytes[offset + 3] == 255
                }
            }
        }
        // make_rom.py specifies WHITE=0xFFFF, BLACK=0x8000, RED=0x801F
        // in BGR555. Upstream DrawPixel shifts 31 to 62, and ExpandColor maps
        // that to 251. Preserve those completed channel values exactly.
        XCTAssertEqual(colors, [0xFBFBFB, 0x000000, 0xFB0000])
        XCTAssertTrue(allPixelsOpaque)
    }

    /// Speed up, come back, pause and stop — the sequence the pause overlay and
    /// the app's lifecycle produce, which is where the certification run died.
    func testFastForwardThenPauseThenStopIsClean() async throws {
        let session = try launch()
        try await Task.sleep(for: .milliseconds(800))
        session.setSpeed(.double)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(session.diagnostics.emulationFramesPerSecond, 0)
        session.setSpeed(.normal)
        try await Task.sleep(for: .milliseconds(500))
        session.pause()
        try await Task.sleep(for: .milliseconds(300))
        let state = try session.captureState()
        XCTAssertFalse(state.isEmpty)
        session.stop()
        XCTAssertEqual(session.state, .stopped)
    }

    /// Rewind captures a DS state ten times a second while the game runs; the
    /// ring must stay bounded and the session must still stop cleanly.
    func testRewindCaptureThenStopIsClean() async throws {
        let session = try launch()
        try await Task.sleep(for: .milliseconds(2500))
        let stats = try XCTUnwrap(session.rewindStatistics)
        XCTAssertGreaterThan(stats.entries, 0, "the DS produced no rewind history")
        XCTAssertLessThan(stats.bytes, 48 * 1024 * 1024, "the rewind ring must stay inside its budget")
        print("RELAY-MEASURE ds.rewind.entries=\(stats.entries) bytes=\(stats.bytes)")
        session.stop()
        XCTAssertEqual(session.state, .stopped)
    }

    /// The presenter keeps the frame source and the rewind engine keeps the
    /// state serializer; both outlive the driver by design. After the game
    /// stops they must be inert, not calls into freed memory — which is what
    /// aborted the app with "mutex lock failed: Invalid argument" before the
    func testTheFrameSourceAndSerializerAreInertAfterStop() async throws {
        let session = try launch()
        try await Task.sleep(for: .milliseconds(600))
        let frames = try XCTUnwrap(session.frameSource)
        let screens = session.screenFrameSources
        let serializer = try XCTUnwrap(session.stateSerializer)
        let capturedWhileRunning = try serializer.serializeState()
        XCTAssertFalse(capturedWhileRunning.isEmpty)
        print("RELAY-MEASURE ds.state.bytes=\(capturedWhileRunning.count)")
        XCTAssertNotEqual(frames.sampledChecksum(), 0)

        session.stop()

        // Everything the presenter, the audio engine and the rewind engine can
        // still call, called after the core is gone.
        XCTAssertEqual(frames.sampledChecksum(), 0, "a stopped core draws nothing")
        for screen in screens { XCTAssertEqual(screen.sampledChecksum(), 0) }
        _ = frames.frameDescriptor
        XCTAssertThrowsError(try serializer.serializeState(), "a stopped core has no state to give")
        XCTAssertThrowsError(try serializer.restoreState(capturedWhileRunning))
        serializer.runSingleFrame()
    }

    /// Two games in one process: the second must start after the first stopped.
    func testASecondGameStartsAfterTheFirstStops() async throws {
        let first = try launch()
        try await Task.sleep(for: .milliseconds(600))
        first.stop()
        let second = try launch()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(second.state, .running)
        XCTAssertNotEqual(second.frameSource?.sampledChecksum() ?? 0, 0)
        second.stop()
    }
}
