// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import PVmGBACore
import PVmGBABridge
@testable import RelayProvenanceAdapter

@MainActor
final class MGBAAudioRateTests: XCTestCase {
    func testAllGBASoundBiasRatesKeepTheTonePitchAndOutputFrameCount() throws {
        let fixture = PlayExperienceProofTests.fixturesRoot.appending(path: "relay-sram-tone/relay-sram-tone.gba")
        let original = try Data(contentsOf: fixture)
        // This is the literal-pool SOUNDBIAS write in the CC0 fixture's ARM
        // prologue. Change only the hardware output-resolution bits.
        XCTAssertEqual(Array(original[0x364..<0x368]), [0x88, 0x00, 0x00, 0x04])
        for mode in 0..<4 {
            let root = FileManager.default.temporaryDirectory.appending(path: "RelayAudioRate-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var rom = original
            var bias = UInt32(0x0200 | mode << 14).littleEndian
            withUnsafeBytes(of: &bias) { rom.replaceSubrange(0x368..<0x36C, with: $0) }
            let url = root.appending(path: "tone.gba")
            try rom.write(to: url)
            let core = PVmGBACore()
            core.systemIdentifier = "com.provenance.gba"
            core.coreIdentifier = "com.provenance.core.mGBA"
            core.batterySavesPath = root.path
            core.saveStatesPath = root.path
            core.BIOSPath = root.path
            core.initialize()
            let bridge = try XCTUnwrap(core.bridge as? PVmGBAGameCoreBridge)
            try bridge.loadFile(atPath: url.path)
            let ring = try XCTUnwrap(MGBADriver.makeAudioBuffer(length: 65_536))
            core.ringBuffers = [ring]
            var left: [Int16] = []
            // Drive the real core synchronously and drain each frame. There is
            // no speaker, ReplayKit, timer pacing or commercial ROM in this test.
            for _ in 0..<120 {
                bridge.executeFrame()
                var samples = [Int16](repeating: 0, count: ring.availableBytesForReading / 2)
                samples.withUnsafeMutableBytes {
                    if let base = $0.baseAddress { _ = ring.read(base, preferredSize: $0.count) }
                }
                for index in stride(from: 0, to: samples.count, by: 2) {
                    left.append(samples[index])
                }
            }
            // Measure around the actual PCM midpoint, after boot settles. The
            // raw PSG amplitude is lower than the speaker mixer output.
            let settled = left.dropFirst(left.count / 4).map(Double.init)
            let low = settled.min() ?? 0, high = settled.max() ?? 0
            XCTAssertGreaterThan(high - low, 20, "The fixture must produce a tone")
            let midpoint = (high + low) / 2, hysteresis = (high - low) / 4
            var cycles = 0, armed = false
            for sample in settled {
                if sample < midpoint - hysteresis { armed = true }
                if armed, sample > midpoint + hysteresis { cycles += 1; armed = false }
            }
            let frequency = Double(cycles) * 32_768 / Double(max(1, settled.count))
            print("RELAY-AUDIO-TEST hardwareRate=\(32768 << mode) frames=\(left.count) toneHz=\(frequency) amplitude=\(high - low)")
            XCTAssertEqual(Double(left.count), 120 * 32_768 / core.frameInterval, accuracy: 700, "SOUNDBIAS mode \(mode)")
            XCTAssertEqual(frequency, 512, accuracy: 5, "SOUNDBIAS mode \(mode)")
        }
    }
}
