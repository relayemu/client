// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDesignSystem

final class TouchHitTestingTests: XCTestCase {
    private func region(_ control: TouchControl, _ shape: TouchLayoutElement.Shape,
                        _ x: CGFloat, _ y: CGFloat) -> TouchHitRegion {
        TouchHitRegion(element: .init(control, shape, at: .zero, label: control.rawValue),
                       frame: CGRect(origin: CGPoint(x: x, y: y), size: shape.size))
    }

    func testVisibleYEdgeDoesNotPressTheDPadInvisibleCorner() {
        // Measured native SE3 frames at source675c97e, capture156.
        let regions = [region(.up, .dpad(span: 152), 32, 446),
                       region(.y, .round(diameter: 56), 172.6, 448)]
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 177.6, y: 476), regions: regions), [.y])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 171.9, y: 476), regions: regions), [.y],
                       "The visible high-contrast outline belongs to Y too")
    }

    func testVisibleXTopDoesNotPressTheShoulderMargin() {
        let regions = [region(.r, .capsule(width: 96, height: 40), 244.1, 356.6),
                       region(.x, .round(diameter: 56), 224.9, 400.6)]
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 252.9, y: 401.6), regions: regions), [.x])
    }

    func testRollingGapBetweenFaceButtonsKeepsCombinedInput() {
        let regions = [region(.a, .round(diameter: 56), 0, 0),
                       region(.b, .round(diameter: 56), 60, 0)]
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 58, y: 28), regions: regions), [.a, .b])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 28, y: 28), regions: regions), [.a])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 88, y: 28), regions: regions), [.b])
    }

    func testVisibleStickClickWinsOverTheAnalogInvisibleCorner() {
        let regions = [region(.leftStick, .stick(diameter: 80), 0, 0),
                       region(.l3, .round(diameter: 36), 74, 0)]
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 77, y: 18), regions: regions), [.l3])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 40, y: 40), regions: regions), [.leftStick])
    }

    func testDPadKeepsDiagonalsDeadZoneAndExpandedReach() {
        let regions = [region(.up, .dpad(span: 152), 0, 0)]
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 76, y: 76), regions: regions), [])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: 132, y: 20), regions: regions), [.up, .right])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: -4, y: 76), regions: regions), [.left])
        XCTAssertEqual(TouchHitTesting.controls(at: CGPoint(x: -8, y: 76), regions: regions), [])
    }
}
