// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import SwiftUI
import RelayDomain
@testable import RelayDesignSystem

/// The brand layer is geometry and drawing, so it is testable like geometry and
/// drawing: the mark must sit where the canonical construction says, the pen must be
/// reproducible, and no illustration may fall outside the box it is scaled by.
final class RelayMarkTests: XCTestCase {
    private let box = CGRect(x: 0, y: 0, width: 200, height: 200)

    func testBothCapsulesStayInsideTheFrame() {
        for part in [RelayMarkPart.lead, .trail] {
            let bounds = RelayMarkShape(part).path(in: box).boundingRect
            XCTAssertTrue(box.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(part) escaped its frame: \(bounds)")
        }
    }

    func testTheMarkFillsTheCanonicalShareOfItsBox() {
        let lead = RelayMarkShape(.lead).path(in: box).boundingRect
        let trail = RelayMarkShape(.trail).path(in: box).boundingRect
        let together = lead.union(trail)
        // Rotated, the construction measures 90.5 × 59.4 units in a 100-unit box:
        // wider than tall, because the two capsules are passed along the diagonal.
        XCTAssertEqual(together.width / box.width, 0.905, accuracy: 0.01)
        XCTAssertEqual(together.height / box.height, 0.594, accuracy: 0.01)
    }

    func testTheTrailCapsuleIsPassedUpAndToTheRightOfTheLead() {
        let lead = RelayMarkShape(.lead).path(in: box).boundingRect
        let trail = RelayMarkShape(.trail).path(in: box).boundingRect
        XCTAssertGreaterThan(trail.midX, lead.midX, "the trail capsule continues to the right")
        XCTAssertLessThan(trail.midY, lead.midY, "along a −45° diagonal, so it also sits higher")
    }

    func testTheCapsulesNeverTouch() {
        let lead = RelayMarkShape(.lead).path(in: box).boundingRect
        let trail = RelayMarkShape(.trail).path(in: box).boundingRect
        // Bounding boxes overlap on a diagonal; the shapes themselves must not, which
        // is what makes the mark read as a pass rather than as one bar.
        let gap = hypot(trail.midX - lead.midX, trail.midY - lead.midY)
        XCTAssertGreaterThan(gap, box.width * 0.3)
    }

    func testTheOpticalCentreSitsBelowTheGeometricCentre() {
        let together = RelayMarkShape(.lead).path(in: box).boundingRect
            .union(RelayMarkShape(.trail).path(in: box).boundingRect)
        XCTAssertEqual(together.midX, box.midX, accuracy: 0.5)
        XCTAssertGreaterThan(together.midY, box.midY, "the group is shifted down 2 units in 100")
    }
}

final class SystemIdentityTests: XCTestCase {
    func testShippedAndPlannedSystemsHaveRelayShortNames() {
        XCTAssertEqual(SystemID.gameBoyAdvance.abbreviation, "GBA")
        XCTAssertEqual(SystemID("snes").abbreviation, "SNES")
        XCTAssertEqual(SystemID.megaDrive.abbreviation, "MD")
    }

    func testAnUnknownSystemStillGetsSomethingPrintable() {
        let short = SystemID("some-future-system").abbreviation
        XCTAssertFalse(short.isEmpty)
        XCTAssertLessThanOrEqual(short.count, 5)
        XCTAssertEqual(short, short.uppercased(), "a raw lower-case identifier never reaches a card")
    }

    func testEveryShortNameIsShortEnoughForACardCorner() {
        for (_, short) in SystemAbbreviation.table {
            XCTAssertLessThanOrEqual(short.count, 5, "\(short) is too long for a placeholder or a chip")
        }
    }
}

final class SketchTests: XCTestCase {
    private var square: Path {
        Path(roundedRect: CGRect(x: 10, y: 10, width: 80, height: 60), cornerRadius: 6)
    }

    func testTheSameSeedAlwaysDrawsTheSameLine() {
        let a = square.sketched(seed: 42).boundingRect
        let b = square.sketched(seed: 42).boundingRect
        XCTAssertEqual(a.origin.x, b.origin.x, accuracy: 0.0001)
        XCTAssertEqual(a.origin.y, b.origin.y, accuracy: 0.0001)
        XCTAssertEqual(a.width, b.width, accuracy: 0.0001)
    }

    func testDifferentSeedsDrawDifferentLines() {
        XCTAssertNotEqual(square.sketched(seed: 1).boundingRect, square.sketched(seed: 2).boundingRect)
    }

    func testThePenStaysCloseToTheShapeItIsTracing() {
        let original = square.boundingRect
        let drawn = square.sketched(seed: 7, amplitude: 1.2).boundingRect
        // A hand wanders; it does not redraw the shape somewhere else.
        XCTAssertEqual(drawn.midX, original.midX, accuracy: 4)
        XCTAssertEqual(drawn.midY, original.midY, accuracy: 4)
        XCTAssertEqual(drawn.width, original.width, accuracy: 6)
        XCTAssertEqual(drawn.height, original.height, accuracy: 6)
    }

    func testAnEmptyPathStaysEmpty() {
        XCTAssertTrue(Path().sketched(seed: 3).isEmpty)
    }
}

final class PenSceneTests: XCTestCase {
    func testEverySceneDrawsSomething() {
        for scene in PenScene.allCases {
            XCTAssertFalse(scene.strokes.isEmpty, "\(scene.rawValue) is empty")
        }
    }

    func testNoSceneDrawsOutsideItsDesignBox() {
        let box = CGRect(x: 0, y: 0, width: PenSceneGeometry.designWidth, height: PenSceneGeometry.designHeight)
        // Strokes are scaled by the frame, so anything outside the box is clipped at
        // render time — a scene that overflows here is a scene that loses a line.
        let room = box.insetBy(dx: -4, dy: -4)
        for scene in PenScene.allCases {
            for (index, stroke) in scene.strokes.enumerated() {
                XCTAssertTrue(room.contains(stroke.path.boundingRect),
                              "\(scene.rawValue) stroke \(index) at \(stroke.path.boundingRect) leaves the box")
            }
        }
    }

    func testEverySceneIsInkFirstWithAtMostOneAccentIdea() {
        for scene in PenScene.allCases {
            let strokes = scene.strokes
            let pen = strokes.filter(\.isPen).count
            XCTAssertGreaterThan(strokes.count - pen, 0, "\(scene.rawValue) has no ink line")
            XCTAssertLessThanOrEqual(pen, strokes.count / 2, "\(scene.rawValue) uses Ember as decoration")
        }
    }
}
