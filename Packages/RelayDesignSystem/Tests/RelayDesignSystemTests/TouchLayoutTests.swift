// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayDesignSystem

/// Touch layouts are derived from each system's controls. The Game Boy
/// never gets a button its hardware lacks.
final class TouchLayoutTests: XCTestCase {

    func testPlayStationControlsAreCompleteAndItsLeftGripHitAreasDoNotOverlap() throws {
        let samples: [(Bool, CGFloat, CGFloat)] = [
            (true, 320, 1), (true, 390, 1), (false, 667, 1), (false, 844, 1),
            (true, 696, 1.2), (true, 976, 1.2), (false, 1146, 1.2),
        ]
        for (portrait, width, scale) in samples {
            let base = TouchLayout.layout(for: SystemCatalog.playStation.inputLayout, portrait: portrait, scale: scale)
            XCTAssertEqual(base.controls, [.up, .a, .b, .x, .y, .l, .r, .l2, .r2, .l3, .r3, .leftStick, .rightStick, .start, .select])
            XCTAssertEqual(base.elements.first { $0.control == .b }?.label, "×")
            let size = CGSize(width: width, height: base.minimumReachHeight(portrait: portrait))
            let layout = base.anchoredForReach(in: size, portrait: portrait)
            func hit(_ control: TouchControl) throws -> CGRect {
                let element = try XCTUnwrap(layout.elements.first { $0.control == control })
                let c = element.fittedCenter(in: size), box = element.shape.size
                return CGRect(x: c.x * size.width - box.width / 2 - 6, y: c.y * size.height - box.height / 2 - 6,
                              width: box.width + 12, height: box.height + 12)
            }
            for (upper, lower) in [(TouchControl.l, TouchControl.l2), (.l2, .up), (.up, .leftStick)] {
                XCTAssertLessThanOrEqual(try hit(upper).maxY, try hit(lower).minY, "\(width) / \(portrait): \(upper), \(lower)")
            }
            XCTAssertLessThanOrEqual(try hit(.leftStick).maxX, try hit(.l3).minX + 0.01)
            XCTAssertEqual(try JSONDecoder().decode(TouchLayout.self, from: JSONEncoder().encode(layout)), layout)
        }
    }

    func testAdvanceLayoutIsThePhase4Preset() {
        for portrait in [true, false] {
            let layout = TouchLayout.layout(for: SystemCatalog.gameBoyAdvance.inputLayout, portrait: portrait)
            XCTAssertEqual(layout.controls, [.l, .r, .up, .b, .a, .select, .start])
            let byControl = Dictionary(uniqueKeysWithValues: layout.elements.map { ($0.control, $0) })
            if portrait {
                XCTAssertEqual(byControl[.l]?.center, CGPoint(x: 0.18, y: 0.10))
                XCTAssertEqual(byControl[.r]?.center, CGPoint(x: 0.82, y: 0.10))
                XCTAssertEqual(byControl[.up]?.center, CGPoint(x: 0.24, y: 0.50))
                XCTAssertEqual(byControl[.b]?.center, CGPoint(x: 0.70, y: 0.58))
                XCTAssertEqual(byControl[.a]?.center, CGPoint(x: 0.86, y: 0.42))
                XCTAssertEqual(byControl[.select]?.center, CGPoint(x: 0.40, y: 0.90))
                XCTAssertEqual(byControl[.start]?.center, CGPoint(x: 0.60, y: 0.90))
            } else {
                XCTAssertEqual(byControl[.l]?.center, CGPoint(x: 0.10, y: 0.12))
                XCTAssertEqual(byControl[.r]?.center, CGPoint(x: 0.90, y: 0.12))
                XCTAssertEqual(byControl[.up]?.center, CGPoint(x: 0.12, y: 0.58))
                XCTAssertEqual(byControl[.b]?.center, CGPoint(x: 0.84, y: 0.66))
                XCTAssertEqual(byControl[.a]?.center, CGPoint(x: 0.93, y: 0.48))
                XCTAssertEqual(byControl[.select]?.center, CGPoint(x: 0.42, y: 0.92))
                XCTAssertEqual(byControl[.start]?.center, CGPoint(x: 0.58, y: 0.92))
            }
            XCTAssertEqual(TouchLayout.gba(portrait: portrait), layout, "the named preset is the derived one")
        }
    }

    func testGameBoyDrawsNoShoulderButtons() {
        for system in [SystemCatalog.gameBoy, SystemCatalog.gameBoyColor] {
            for portrait in [true, false] {
                let layout = TouchLayout.layout(for: system.inputLayout, portrait: portrait)
                XCTAssertEqual(layout.controls, [.up, .b, .a, .select, .start], "\(system.id)")
                XCTAssertFalse(layout.controls.contains(.l))
                XCTAssertFalse(layout.controls.contains(.r))
            }
        }
    }

    func testFourButtonSystemsGetADiamond() {
        let layout = TouchLayout.layout(for: SystemCatalog.snes.inputLayout, portrait: true)
        XCTAssertTrue(layout.controls.isSuperset(of: [.a, .b, .x, .y, .l, .r]))
        let byControl = Dictionary(uniqueKeysWithValues: layout.elements.map { ($0.control, $0) })
        // X sits above A and Y left of B, mirroring the A/B stagger.
        XCTAssertLessThan(byControl[.x]!.center.y, byControl[.a]!.center.y)
        XCTAssertLessThan(byControl[.y]!.center.x, byControl[.b]!.center.x)
    }

    func testASystemWithoutSelectCentresStart() {
        let layout = TouchLayout.layout(for: SystemCatalog.gameGear.inputLayout, portrait: true)
        XCTAssertFalse(layout.controls.contains(.select))
        XCTAssertEqual(layout.elements.first { $0.control == .start }?.center.x, 0.50)
    }

    func testScaleGrowsEveryElement() {
        let base = TouchLayout.layout(for: SystemCatalog.gameBoy.inputLayout, portrait: true, scale: 1)
        let pad = TouchLayout.layout(for: SystemCatalog.gameBoy.inputLayout, portrait: true, scale: 1.2)
        for (a, b) in zip(base.elements, pad.elements) {
            XCTAssertEqual(a.control, b.control)
            XCTAssertGreaterThan(b.shape.size.width, a.shape.size.width)
        }
    }

    func testCustomLayoutRoundTripsAndRepairsUnreachableControls() throws {
        let fallback = TouchLayout.gba(portrait: true)
        let a = try XCTUnwrap(fallback.elements.first { $0.control == .a })
        let malformed = TouchLayout(elements: [
            a.moved(to: CGPoint(x: -4, y: 8)).scaled(by: 20),
            a.moved(to: CGPoint(x: 0.5, y: 0.5)),
        ])
        let data = try JSONEncoder().encode(malformed)
        let decoded = try JSONDecoder().decode(TouchLayout.self, from: data)
        let repaired = decoded.repaired(using: fallback)

        XCTAssertEqual(repaired.controls, fallback.controls, "missing controls are restored")
        XCTAssertEqual(repaired.elements.filter { $0.control == .a }.count, 1, "duplicates are removed")
        let repairedA = try XCTUnwrap(repaired.elements.first { $0.control == .a })
        XCTAssertEqual(repairedA.center, CGPoint(x: 0.08, y: 0.92))
        XCTAssertLessThanOrEqual(repairedA.shape.size.width, 112)
    }

    func testRepairFitsPointSizedControlsInsideConcretePhoneArea() throws {
        let fallback = TouchLayout.gba(portrait: true)
        let pad = try XCTUnwrap(fallback.elements.first { $0.control == .up })
        let malformed = TouchLayout(elements: [pad.moved(to: CGPoint(x: 0, y: 1)).scaled(by: 1.6)])
        let size = CGSize(width: 300, height: 500)
        let repaired = malformed.repaired(using: fallback, fitting: size)
        let fittedPad = try XCTUnwrap(repaired.elements.first { $0.control == .up })
        let half = fittedPad.shape.size.width / 2 + 8

        XCTAssertGreaterThanOrEqual(fittedPad.center.x * size.width, half)
        XCTAssertLessThanOrEqual(fittedPad.center.y * size.height, size.height - half)
    }

    /// Every playable system's layout keeps its elements inside the unit
    /// square, so nothing is drawn off the control area.
    func testSystemsShowTheirOwnButtonNames() {
        let sms = TouchLayout.layout(for: SystemCatalog.masterSystem.inputLayout, portrait: true)
        XCTAssertEqual(sms.elements.first { $0.control == .a }?.label, "2")
        XCTAssertEqual(sms.elements.first { $0.control == .b }?.label, "1")
        XCTAssertEqual(sms.elements.first { $0.control == .start }?.label, "PAUSE")
        let pce = TouchLayout.layout(for: SystemCatalog.pcEngine.inputLayout, portrait: false)
        XCTAssertEqual(pce.elements.first { $0.control == .a }?.label, "I")
        XCTAssertEqual(pce.elements.first { $0.control == .start }?.label, "RUN")
        XCTAssertEqual(pce.elements.first { $0.control == .select }?.label, "SELECT")
        // Systems without their own names keep the defaults.
        let nes = TouchLayout.layout(for: SystemCatalog.nes.inputLayout, portrait: true)
        XCTAssertEqual(nes.elements.first { $0.control == .a }?.label, "A")
    }

    func testWonderSwanDrawsItsSecondClusterBelowThePad() {
        let ws = TouchLayout.layout(for: SystemCatalog.wonderSwan.inputLayout, portrait: true)
        let cluster = ws.elements.filter { [.cUp, .cDown, .cLeft, .cRight].contains($0.control) }
        XCTAssertEqual(cluster.count, 4)
        XCTAssertEqual(Set(cluster.map(\.label)), ["Y1", "Y2", "Y3", "Y4"])
        let pad = try! XCTUnwrap(ws.elements.first { $0.control == .up })
        for button in cluster {
            XCTAssertGreaterThan(button.center.y, pad.center.y, "the Y cluster sits below the X pad")
            XCTAssertLessThan(abs(button.center.x - pad.center.x), 0.2, "and under it, not under the face buttons")
        }
        XCTAssertNil(ws.elements.first { $0.control == .select })
        XCTAssertTrue(TouchLayout.layout(for: SystemCatalog.nes.inputLayout, portrait: true).elements.allSatisfy { $0.control != .cUp })
    }

    func testEveryPlayableLayoutStaysInsideTheControlArea() {
        for system in SystemCatalog.playable {
            for portrait in [true, false] {
                for element in TouchLayout.layout(for: system.inputLayout, portrait: portrait).elements {
                    XCTAssertTrue((0...1).contains(element.center.x) && (0...1).contains(element.center.y),
                                  "\(system.id) \(element.control) at \(element.center)")
                }
            }
        }
    }
}
