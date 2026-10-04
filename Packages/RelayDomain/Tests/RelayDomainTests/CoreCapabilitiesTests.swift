// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

final class CoreCapabilitiesTests: XCTestCase {
    func testFlagsAreDistinctBits() {
        let flags = CoreCapabilities.allKnown.map(\.0)
        XCTAssertEqual(flags.count, 12)
        XCTAssertEqual(Set(flags.map(\.rawValue)).count, flags.count)
        for f in flags { XCTAssertEqual(f.rawValue.nonzeroBitCount, 1) }
    }

    func testSetAlgebraAndNames() {
        let caps: CoreCapabilities = [.saveStates, .rewind, .cheats]
        XCTAssertTrue(caps.contains(.rewind))
        XCTAssertFalse(caps.contains(.jit))
        XCTAssertEqual(caps.names, ["saveStates", "rewind", "cheats"])
        XCTAssertEqual(caps.union([.jit]).names.last, "jit")
        XCTAssertEqual(CoreCapabilities().names, [])
    }

    func testCodableRoundTrip() throws {
        let caps: CoreCapabilities = [.fastForward, .rumble, .achievements]
        let data = try JSONEncoder().encode(caps)
        XCTAssertEqual(try JSONDecoder().decode(CoreCapabilities.self, from: data), caps)
    }

    func testDescriptorSupportsSystem() throws {
        let core = EmulatorCoreDescriptor(id: "mgba", name: "mGBA", version: "0.10.3", license: "MPL-2.0",
                                          supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
        XCTAssertTrue(core.supports(.gameBoyAdvance))
        XCTAssertFalse(core.supports("nes"))
        let data = try JSONEncoder().encode(core)
        XCTAssertEqual(try JSONDecoder().decode(EmulatorCoreDescriptor.self, from: data), core)
    }
}
