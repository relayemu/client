// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftUI
import RelayDomain
@testable import RelayDesignSystem
import RelayEntitlements
import RelayVideo
@testable import RelayUI

final class AdaptivePlayLayoutTests: XCTestCase {
    private let ds = SystemCatalog.nintendoDS.screens

    func testVisibleButtonEdgesResolveOnlyTheirOwnControlAcrossPresets() {
        for system in SystemCatalog.playable {
            for size in [CGSize(width: 320, height: 900), CGSize(width: 900, height: 320),
                         CGSize(width: 375, height: 667), CGSize(width: 667, height: 375),
                         CGSize(width: 466, height: 644), CGSize(width: 951, height: 635),
                         CGSize(width: 744, height: 1113), CGSize(width: 1133, height: 724)] {
                let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                    controls: system.inputLayout, screens: system.screens, displayScale: 2)
                let regions = surface.touchLayout.elements.map { element in
                    let center = element.fittedCenter(in: surface.controlFrame.size)
                    let dimensions = element.shape.size
                    return TouchHitRegion(element: element, frame: CGRect(
                        x: surface.controlFrame.minX + center.x * surface.controlFrame.width - dimensions.width / 2,
                        y: surface.controlFrame.minY + center.y * surface.controlFrame.height - dimensions.height / 2,
                        width: dimensions.width, height: dimensions.height))
                }
                for region in regions {
                    if case .dpad = region.element.shape { continue }
                    let box = region.frame
                    for point in [CGPoint(x: box.midX, y: box.midY),
                                  CGPoint(x: box.minX + 2, y: box.midY), CGPoint(x: box.maxX - 2, y: box.midY),
                                  CGPoint(x: box.midX, y: box.minY + 2), CGPoint(x: box.midX, y: box.maxY - 2)] {
                        XCTAssertEqual(TouchHitTesting.controls(at: point, regions: regions), [region.element.control],
                                       "\(system.id) \(size) \(region.element.control) at\(point)")
                    }
                }
            }
        }
    }

    func testPauseNeverCoversATouchControlAcrossPhoneAndTabletBounds() {
        for system in SystemCatalog.playable {
            for size in [CGSize(width: 375, height: 667), CGSize(width: 667, height: 375),
                         CGSize(width: 466, height: 644), CGSize(width: 951, height: 635),
                         CGSize(width: 744, height: 1113), CGSize(width: 1133, height: 724)] {
                let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                    controls: system.inputLayout, screens: system.screens, displayScale: 2)
                XCTAssertTrue(surface.contentFrame.contains(surface.pauseButtonFrame))
                for (control, box) in controlBoxes(surface) {
                    XCTAssertFalse(surface.pauseButtonFrame.intersects(box.insetBy(dx: -6, dy: -6)),
                                   "\(system.id) \(size): Pause covers \(control)")
                }
            }
        }
    }

    func testDefaultOutlinesKeepVisibleBreathingSpaceIncludingNarrowWindows() {
        for system in SystemCatalog.playable {
            for size in [CGSize(width: 320, height: 900), CGSize(width: 900, height: 320), CGSize(width: 350, height: 600),
                         CGSize(width: 375, height: 667), CGSize(width: 667, height: 375),
                         CGSize(width: 466, height: 644), CGSize(width: 951, height: 635),
                         CGSize(width: 744, height: 1113), CGSize(width: 1133, height: 724)] {
                let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                    controls: system.inputLayout, screens: system.screens, displayScale: 2)
                let elements = surface.touchLayout.elements
                XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame))
                for first in elements.indices {
                    for second in elements.indices where second > first {
                        XCTAssertGreaterThanOrEqual(RelayPlaySurfaceLayout.visibleClearance(elements[first], elements[second], in: surface.controlFrame), 4 - 0.000001,
                            "\(system.id) \(size): \(elements[first].control) / \(elements[second].control)")
                    }
                }
            }
        }
    }

    func testDualScreenControlClearanceThroughIntermediateWindowSizes() {
        for width in stride(from: 320, through: 460, by: 7) {
            for height in stride(from: 568, through: 940, by: 31) {
                for size in [CGSize(width: width, height: height), CGSize(width: height, height: width)] {
                    let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                        controls: SystemCatalog.nintendoDS.inputLayout, screens: ds, displayScale: 3)
                    XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame), "\(size)")
                    let elements = surface.touchLayout.elements
                    for first in elements.indices {
                        for second in elements.indices where second > first {
                            XCTAssertGreaterThanOrEqual(RelayPlaySurfaceLayout.visibleClearance(elements[first], elements[second], in: surface.controlFrame), 4 - 0.000001,
                                "\(size): \(elements[first].control) / \(elements[second].control)")
                        }
                    }
                    for (_, box) in controlBoxes(surface) {
                        XCTAssertFalse(box.insetBy(dx: -6, dy: -6).intersects(surface.gameFrame), "\(size)")
                        XCTAssertFalse(box.insetBy(dx: -6, dy: -6).intersects(surface.pauseButtonFrame), "\(size)")
                    }
                }
            }
        }
    }

    func testAllPlayableTouchPresetsReservePicturesAcrossCompactAndExpandedGeometry() {
        let sizes: [CGSize] = [
            .init(width: 375, height: 633), .init(width: 390, height: 714),
            .init(width: 430, height: 830), .init(width: 466, height: 644),
            .init(width: 669, height: 917), .init(width: 744, height: 1049),
            .init(width: 1024, height: 1332), .init(width: 500, height: 600),
        ]
        for system in SystemCatalog.playable {
            for portrait in sizes {
                for size in [portrait, CGSize(width: portrait.height, height: portrait.width)] {
                    let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                        controls: system.inputLayout, screens: system.screens, displayScale: 3)
                    let context = "\(system.id) at \(size)"
                    XCTAssertGreaterThan(surface.gameFrame.width, 0, context)
                    XCTAssertGreaterThan(surface.gameFrame.height, 0, context)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(surface.gameFrame), context)
                    XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame), context)
                    for (control, box) in controlBoxes(surface) {
                        XCTAssertFalse(box.insetBy(dx: -6, dy: -6).intersects(surface.gameFrame),
                                       "\(context): \(control) covers the game")
                    }
                }
            }
        }
    }

    func testEveryDSArrangementKeepsTouchControlsOffBothPictures() {
        for size in [CGSize(width: 756, height: 354), CGSize(width: 951, height: 635),
                     CGSize(width: 1194, height: 790), CGSize(width: 600, height: 500)] {
            for arrangement in ScreenArrangement.allCases {
                let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                    controls: SystemCatalog.nintendoDS.inputLayout, screens: ds,
                    preferredArrangement: arrangement, displayScale: 3)
                let pictures = RelayLogicalScreenLayout(size: surface.gameFrame.size, screens: ds,
                    preferred: arrangement, gap: 8)
                XCTAssertEqual(pictures.arrangement, arrangement)
                for picture in pictures.frames {
                    let absolute = picture.offsetBy(dx: surface.gameFrame.minX, dy: surface.gameFrame.minY)
                    for (control, box) in controlBoxes(surface) {
                        XCTAssertFalse(box.insetBy(dx: -6, dy: -6).intersects(absolute),
                                       "\(arrangement) at \(size): \(control) covers a DS screen")
                    }
                }
            }
        }
    }

    func testLandscapeCustomPictureOverlapFallsBackWithoutRewritingAndEditorRejectsIt() throws {
        let size = CGSize(width: 951, height: 635)
        let system = SystemCatalog.nintendoDS
        let original = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
            controls: system.inputLayout, screens: system.screens)
        let a = try XCTUnwrap(original.touchLayout.elements.first { $0.control == .a })
        let overPicture = a.moved(to: CGPoint(
            x: (original.gameFrame.midX - original.controlFrame.minX) / original.controlFrame.width,
            y: (original.gameFrame.midY - original.controlFrame.minY) / original.controlFrame.height))
        let custom = original.touchLayout.replacing(overPicture)
        XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(custom, in: original.controlFrame))
        XCTAssertFalse(original.acceptsControls(custom))
        let suite = "RelayPictureExclusion-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        preferences.setTouchLayout(custom, for: system, portrait: false, scale: original.controlScale)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        let raw = preferences.effectiveCustomTouchLayout(for: system.id, portrait: false, policy: policy)
        let resolved = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
            controls: system.inputLayout, screens: system.screens, customTouchLayout: raw)
        XCTAssertTrue(resolved.usesCustomLayoutFallback)
        XCTAssertEqual(resolved.touchLayout, original.touchLayout)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, stored)
        var draft = RelayTouchLayoutDraft(layout: original.touchLayout)
        draft.edit(.a, on: original) { _ in overPicture }
        XCTAssertEqual(draft.layout, original.touchLayout)
    }

    func testControllerOnlySurfacesKeepTheFullSafePictureArea() {
        for size in [CGSize(width: 375, height: 633), CGSize(width: 951, height: 635),
                     CGSize(width: 1366, height: 1024), CGSize(width: 1920, height: 1080)] {
            let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: false,
                controls: SystemCatalog.playStation.inputLayout, screens: ds)
            XCTAssertEqual(surface.gameFrame, CGRect(origin: .zero, size: size))
            XCTAssertTrue(surface.touchLayout.elements.isEmpty)
        }
    }

    func testDualScreenDefaultUsesAvailablePictureAreaWithoutReplacingExplicitPreferences() throws {
        let suite = "RelayDualScreenDefault-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        XCTAssertEqual(preferences.displayOptions(for: .nintendoDS).scaling, .fit)
        XCTAssertEqual(preferences.displayOptions(for: .gameBoyAdvance).scaling, .integer)
        XCTAssertNil(defaults.object(forKey: "relay.display.scaling.nds"))
        preferences.setDisplayOptions(DisplayOptions(scaling: .integer), for: .nintendoDS)
        XCTAssertEqual(preferences.displayOptions(for: .nintendoDS).scaling, .integer)
        let free = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: []))
        XCTAssertEqual(preferences.displayOptions(for: .nintendoDS, gameID: nil, policy: free).scaling, .integer)
        XCTAssertEqual(defaults.string(forKey: "relay.display.scaling.nds"), "integer")
    }

    func testAsymmetricSafeAreasAndTallControlDeckStayInsideTheContainer() {
        let size = CGSize(width: 430, height: 900)
        let surface = RelayPlaySurfaceLayout(size: size,
            safeArea: EdgeInsets(top: 44, leading: 12, bottom: 34, trailing: 36), showsTouchControls: true)
        XCTAssertFalse(surface.isWide)
        XCTAssertEqual(surface.gameFrame.minX, 12)
        XCTAssertEqual(surface.gameFrame.maxX, 394)
        XCTAssertEqual(surface.gameFrame.minY, 44)
        XCTAssertLessThanOrEqual(surface.gameFrame.maxY, surface.controlFrame.minY)
        XCTAssertGreaterThan(surface.controlFrame.minX, surface.gameFrame.minX)
        XCTAssertLessThan(surface.controlFrame.maxX, surface.gameFrame.maxX)
        XCTAssertLessThan(surface.controlFrame.maxY, size.height - 34)
    }

    func testWideContainerUsesItsBoundsAndPointSizesRemainBounded() {
        let small = RelayPlaySurfaceLayout(size: CGSize(width: 850, height: 380), showsTouchControls: true)
        let large = RelayPlaySurfaceLayout(size: CGSize(width: 1200, height: 800), showsTouchControls: true)
        XCTAssertTrue(small.isWide)
        XCTAssertTrue(large.isWide)
        XCTAssertEqual(small.gameFrame, CGRect(x: 0, y: 0, width: 850, height: 380))
        XCTAssertEqual(small.controlScale, 1)
        XCTAssertEqual(large.controlScale, 1.2)
        XCTAssertEqual(RelayPlaySurfaceLayout(size: CGSize(width: 2000, height: 1400), showsTouchControls: true).controlScale, 1.2)
    }

    func testDSAutomaticLayoutUsesActualPictureAreaRatherThanOrientation() {
        // This is wider than tall, yet stacking gives both DS pictures more area.
        let nearlySquare = RelayLogicalScreenLayout(size: CGSize(width: 720, height: 650), screens: ds, preferred: nil, gap: 8)
        XCTAssertEqual(nearlySquare.arrangement, .stacked)
        let wide = RelayLogicalScreenLayout(size: CGSize(width: 900, height: 500), screens: ds, preferred: nil, gap: 8)
        XCTAssertEqual(wide.arrangement, .sideBySide)
        XCTAssertFalse(wide.frames[0].intersects(wide.frames[1]))
        XCTAssertEqual(wide.frames[1].minX - wide.frames[0].maxX, 8)
    }

    func testEveryExplicitDSChoiceSurvivesRepeatedSizeChanges() {
        for choice in ScreenArrangement.allCases {
            for size in [CGSize(width: 390, height: 400), CGSize(width: 900, height: 550), CGSize(width: 430, height: 390)] {
                let layout = RelayLogicalScreenLayout(size: size, screens: ds, preferred: choice, gap: 8)
                XCTAssertEqual(layout.arrangement, choice)
                XCTAssertEqual(layout.frames.count, 2)
                for frame in layout.frames {
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                }
            }
        }
    }

    func testDSPreviewUsesAllocatedGameAreaInsteadOfTheWholeScene() {
        let surface = RelayPlaySurfaceLayout(size: CGSize(width: 430, height: 900), showsTouchControls: true)
        let layout = RelayLogicalScreenLayout(size: surface.gameFrame.size, screens: ds, preferred: .primarySecondary, gap: 8)
        XCTAssertEqual(layout.frames[1].height, surface.gameFrame.height / 3)
        XCTAssertLessThan(layout.frames[1].maxY, surface.gameFrame.height)
    }

    func testDefaultGripSpacingDoesNotStretchWithAnExpandedCanvas() throws {
        let base = TouchLayout.layout(for: SystemCatalog.nintendoDS.inputLayout, portrait: false)
        func physical(_ layout: TouchLayout, _ control: TouchControl, width: CGFloat) throws -> CGFloat {
            try XCTUnwrap(layout.elements.first { $0.control == control }).center.x * width
        }
        let narrow = base.anchoredForReach(in: CGSize(width: 850, height: 480), portrait: false)
        let expanded = base.anchoredForReach(in: CGSize(width: 1400, height: 900), portrait: false)
        let narrowGap = try physical(narrow, .a, width: 850) - physical(narrow, .b, width: 850)
        let expandedGap = try physical(expanded, .a, width: 1400) - physical(expanded, .b, width: 1400)
        XCTAssertEqual(narrowGap, expandedGap, accuracy: 0.001)
        XCTAssertEqual(base.elements.map(\.shape), expanded.elements.map(\.shape))
        XCTAssertLessThan(try physical(expanded, .up, width: 1400), 200)
        XCTAssertLessThan(1400 - (try physical(expanded, .a, width: 1400)), 200)
    }

    func testReadingCustomControlsAtDifferentSizesDoesNotRewritePreferences() throws {
        let suite = "RelayAdaptiveControls-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        let original = TouchLayout.gba(portrait: true)
        let a = try XCTUnwrap(original.elements.first { $0.control == .a })
        let custom = original.replacing(a.moved(to: CGPoint(x: 0.72, y: 0.37)).scaled(by: 1.15))
        preferences.setTouchLayout(custom, for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        for size in [CGSize(width: 342, height: 280), CGSize(width: 1000, height: 500), CGSize(width: 342, height: 280)] {
            let read = preferences.touchLayout(for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1, policy: policy, fitting: size)
            XCTAssertEqual(read, custom)
            XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, stored)
        }
    }

    func testSystemButtonsRemainOneCenteredGroupOnExpandedCanvases() throws {
        let size = CGSize(width: 1400, height: 900)
        let pair = TouchLayout.gba(portrait: false).anchoredForReach(in: size, portrait: false)
        let select = try XCTUnwrap(pair.elements.first { $0.control == .select })
        let start = try XCTUnwrap(pair.elements.first { $0.control == .start })
        XCTAssertEqual((select.center.x + start.center.x) * size.width / 2, size.width / 2, accuracy: 0.001)
        XCTAssertEqual((start.center.x - select.center.x) * size.width,
                       (select.shape.size.width + start.shape.size.width) / 2 + 16, accuracy: 0.001)
        let single = TouchLayout.layout(for: SystemCatalog.wonderSwan.inputLayout, portrait: false)
            .anchoredForReach(in: size, portrait: false)
        XCTAssertEqual(try XCTUnwrap(single.elements.first { $0.control == .start }).center.x, 0.5)
    }

    func testNoOpSaveRetainsValidAnchoredEdgeCoordinates() throws {
        let suite = "RelayAdaptiveEdgeSave-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        let size = CGSize(width: 1400, height: 900)
        let anchored = TouchLayout.gba(portrait: false).anchoredForReach(in: size, portrait: false)
        XCTAssertLessThan(try XCTUnwrap(anchored.elements.first { $0.control == .l }).center.x, 0.08)
        XCTAssertGreaterThan(try XCTUnwrap(anchored.elements.first { $0.control == .a }).center.x, 0.92)
        preferences.setTouchLayout(anchored, for: SystemCatalog.gameBoyAdvance, portrait: false, scale: 1)
        let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        XCTAssertEqual(preferences.touchLayout(for: SystemCatalog.gameBoyAdvance, portrait: false,
                                               scale: 1, policy: policy, fitting: size), anchored)
    }

    func testRepairSanitizesNonfinitePositionsWithoutMovingValidEdges() throws {
        let fallback = TouchLayout.gba(portrait: true)
        let a = try XCTUnwrap(fallback.elements.first { $0.control == .a })
        let invalid = fallback.replacing(a.moved(to: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)))
        XCTAssertEqual(try XCTUnwrap(invalid.repaired(using: fallback).elements.first { $0.control == .a }).center, a.center)
        let edge = fallback.replacing(a.moved(to: CGPoint(x: 0, y: 1)))
        XCTAssertEqual(edge.repaired(using: fallback), edge)
    }

    func testSecondaryDirectionClusterHitBoxesRemainSeparateInReachableSizes() {
        let samples: [(CGSize, Bool, CGFloat)] = [
            (CGSize(width: 327, height: 384), true, 1),
            (CGSize(width: 382, height: 384), true, 1),
            (CGSize(width: 952, height: 444.8), true, 1.2),
            (CGSize(width: 802, height: 260), false, 1),
            (CGSize(width: 1400, height: 900), false, 1.2),
        ]
        for (size, portrait, scale) in samples {
            let base = TouchLayout.layout(for: SystemCatalog.wonderSwan.inputLayout, portrait: portrait, scale: scale)
            XCTAssertLessThanOrEqual(base.minimumReachHeight(portrait: portrait), size.height + 0.001)
            let layout = base.anchoredForReach(in: size, portrait: portrait)
            let boxes = layout.elements.map { element -> CGRect in
                let center = element.fittedCenter(in: size)
                return CGRect(x: center.x * size.width - element.shape.size.width / 2,
                              y: center.y * size.height - element.shape.size.height / 2,
                              width: element.shape.size.width, height: element.shape.size.height)
                    .insetBy(dx: -6, dy: -6)
            }
            for first in boxes.indices {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(boxes[first]))
                for second in boxes.indices where second > first {
                    XCTAssertFalse(boxes[first].intersects(boxes[second]),
                                   "Overlapping controls \(layout.elements[first].control) / \(layout.elements[second].control) in \(size)")
                }
            }
        }
        XCTAssertEqual(TouchLayout.gba(portrait: true).minimumReachHeight(portrait: true), 0)
    }

    func testPortraitTouchStackPreservesPicturesAndTheCanonicalControlCanvas() {
        let cases: [(CGSize, CGFloat, CGFloat, CGFloat)] = [
            (CGSize(width: 834, height: 1190), 2, 512, 131.2),
            (CGSize(width: 750, height: 1000), 3, 1280.0 / 3.0, 69.2),
        ]
        for (size, scale, width, top) in cases {
            let baseline = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                                                  controls: SystemCatalog.nintendoDS.inputLayout)
            let surface = portraitDS(size, displayScale: scale)
            XCTAssertEqual(surface.controlFrame, baseline.controlFrame)
            XCTAssertEqual(surface.controlFrame.minX, 24)
            XCTAssertEqual(surface.controlFrame.height, 360)
            XCTAssertEqual(surface.gameFrame.width, width, accuracy: 0.001)
            XCTAssertEqual(surface.gameFrame.minY, top, accuracy: 0.001)
            let pictures = RelayLogicalScreenLayout(size: surface.gameFrame.size, screens: ds, preferred: .stacked, gap: 8).frames
            XCTAssertEqual(pictures[0].height, width * 3 / 4, accuracy: 0.001)
            XCTAssertEqual(pictures[1].minY - pictures[0].maxY, 8, accuracy: 0.001)
            XCTAssertEqual(surface.touchLayout.elements.map(\.shape), baseline.touchLayout.elements.map(\.shape))
            XCTAssertEqual(surface.touchLayout.elements.map(\.label), baseline.touchLayout.elements.map(\.label))
            XCTAssertTrue(surface.touchLayout.elements.allSatisfy {
                (0...1).contains($0.center.x) && (0...1).contains($0.center.y)
            })
        }
    }

    func testPortraitStackUsesFittedShouldersAndClearExpandedHitBoxes() throws {
        for (size, scale) in [(CGSize(width: 834, height: 1190), CGFloat(2)),
                              (CGSize(width: 750, height: 1000), CGFloat(3))] {
            let surface = portraitDS(size, displayScale: scale)
            let boxes = controlBoxes(surface)
            for box in boxes.values {
                let hit = box.insetBy(dx: -6, dy: -6)
                XCTAssertTrue(surface.controlFrame.contains(hit))
                let horizontal = max(surface.gameFrame.minX - hit.maxX, hit.minX - surface.gameFrame.maxX)
                let vertical = max(surface.gameFrame.minY - hit.maxY, hit.minY - surface.gameFrame.maxY)
                XCTAssertGreaterThanOrEqual(max(horizontal, vertical), 7.5)
            }
            let left = try XCTUnwrap(boxes[.l]), right = try XCTUnwrap(boxes[.r])
            XCTAssertEqual(left.minX, 32, accuracy: 0.001)
            XCTAssertEqual(size.width - right.maxX, 32, accuracy: 0.001)
            let expectedSideGap: CGFloat = size.width == 834 ? 7.8 : 8 + 7.0 / 15.0
            XCTAssertEqual(surface.gameFrame.minX - left.maxX - 6, expectedSideGap, accuracy: 0.001)
            XCTAssertEqual(right.minX - 6 - surface.gameFrame.maxX, expectedSideGap, accuracy: 0.001)
            let lowerHitTop = try XCTUnwrap([TouchControl.up, .a, .b, .x, .y]
                .compactMap { boxes[$0]?.minY }.min()) - 6
            XCTAssertEqual(lowerHitTop - surface.gameFrame.maxY, 8, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(boxes[.up]).midY, try XCTUnwrap(boxes[.a]).midY, accuracy: 0.001)
        }
    }

    func testPortraitStackFallsBackForCompactUnsupportedAndSmallerFitPictures() {
        for (size, scale) in [(CGSize(width: 375, height: 909), CGFloat(2)),
                              (CGSize(width: 402, height: 874), CGFloat(3)),
                              (CGSize(width: 1190, height: 834), CGFloat(2))] {
            let baseline = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                                                  controls: SystemCatalog.nintendoDS.inputLayout)
            let resolved = portraitDS(size, displayScale: scale)
            XCTAssertEqual(resolved.gameFrame, baseline.gameFrame)
            XCTAssertEqual(resolved.controlFrame, baseline.controlFrame)
            XCTAssertEqual(resolved.touchLayout, baseline.touchLayout)
        }
        let size = CGSize(width: 834, height: 1190)
        let baseline = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                                              controls: SystemCatalog.nintendoDS.inputLayout)
        for arrangement in [ScreenArrangement.sideBySide, .primarySecondary, .secondaryPrimary] {
            let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                controls: SystemCatalog.nintendoDS.inputLayout, screens: ds,
                preferredArrangement: arrangement, scaling: .integer, displayScale: 2)
            XCTAssertEqual(surface.gameFrame, baseline.gameFrame)
            XCTAssertEqual(surface.touchLayout, baseline.touchLayout)
        }
        for screens in [[ds[0]], [ds[0], LogicalScreen(id: "bottom", width: 256, height: 192)],
                        [ds[0], LogicalScreen(id: "bottom", width: 320, height: 240, acceptsTouch: true)]] {
            let surface = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                controls: SystemCatalog.nintendoDS.inputLayout, screens: screens, scaling: .integer, displayScale: 2)
            XCTAssertEqual(surface.gameFrame, baseline.gameFrame)
        }
        XCTAssertEqual(portraitDS(size, displayScale: 2, scaling: .fill).gameFrame, baseline.gameFrame)
        // The safer shoulders cap fit width below A's 532 points here, so A wins.
        XCTAssertEqual(portraitDS(size, displayScale: 2, scaling: .fit).gameFrame, baseline.gameFrame)
        let narrower = portraitDS(CGSize(width: 750, height: 1000), displayScale: 3, scaling: .fit)
        XCTAssertGreaterThan(narrower.gameFrame.width, 608.0 * 2 / 3)
        let hidden = RelayPlaySurfaceLayout(size: size, showsTouchControls: false,
            controls: SystemCatalog.nintendoDS.inputLayout, screens: ds, scaling: .integer, displayScale: 2)
        XCTAssertTrue(hidden.touchLayout.elements.isEmpty)
        XCTAssertEqual(hidden.gameFrame, CGRect(origin: .zero, size: size))
    }

    func testExistingCustomCanvasAndJSONRemainUnchangedThroughPortraitResizes() throws {
        let suite = "RelayPortraitCustom-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        let original = RelayPlaySurfaceLayout(size: CGSize(width: 834, height: 1190), showsTouchControls: true,
                                              controls: SystemCatalog.nintendoDS.inputLayout).touchLayout
        preferences.setTouchLayout(original, for: SystemCatalog.nintendoDS, portrait: true, scale: 1.2)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        for (size, scale) in [(CGSize(width: 834, height: 1190), CGFloat(2)),
                              (CGSize(width: 750, height: 1000), CGFloat(3)),
                              (CGSize(width: 375, height: 909), CGFloat(2)),
                              (CGSize(width: 834, height: 1190), CGFloat(2))] {
            let custom = try XCTUnwrap(preferences.effectiveCustomTouchLayout(for: .nintendoDS, portrait: true, policy: policy))
            let resolved = portraitDS(size, displayScale: scale, custom: custom)
            let baseline = RelayPlaySurfaceLayout(size: size, showsTouchControls: true,
                                                  controls: SystemCatalog.nintendoDS.inputLayout)
            XCTAssertEqual(resolved.controlFrame, baseline.controlFrame)
            XCTAssertEqual(resolved.gameFrame, baseline.gameFrame)
            if size.width == 375 {
                XCTAssertTrue(resolved.usesCustomLayoutFallback)
                XCTAssertEqual(resolved.touchLayout, baseline.touchLayout)
            } else {
                XCTAssertFalse(resolved.usesCustomLayoutFallback)
                XCTAssertEqual(resolved.touchLayout, original)
            }
            XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, stored)
        }
        let free = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: []))
        XCTAssertNil(preferences.effectiveCustomTouchLayout(for: .nintendoDS, portrait: true, policy: free))
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, stored)
    }

    func testResolvedPortraitEditorNoOpAndEditedSaveReloadKeepPhysicalCoordinates() throws {
        for (size, scale) in [(CGSize(width: 834, height: 1190), CGFloat(2)),
                              (CGSize(width: 750, height: 1000), CGFloat(3))] {
            let suite = "RelayPortraitEditor-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = PlayPreferences(defaults: defaults)
            let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
            let initial = portraitDS(size, displayScale: scale)
            let start = try XCTUnwrap(initial.touchLayout.elements.first { $0.control == .start })
            let edited = initial.touchLayout.replacing(start.moved(to: CGPoint(x: start.center.x + 0.02, y: start.center.y - 0.01)))
            for draft in [initial.touchLayout, edited] {
                // The editor resolves its draft through exactly the player API.
                let editor = portraitDS(size, displayScale: scale, custom: draft)
                XCTAssertEqual(editor.gameFrame, initial.gameFrame)
                preferences.setTouchLayout(editor.touchLayout, for: SystemCatalog.nintendoDS,
                                           portrait: true, scale: editor.controlScale)
                let saved = try XCTUnwrap(preferences.effectiveCustomTouchLayout(for: .nintendoDS, portrait: true, policy: policy))
                let player = portraitDS(size, displayScale: scale, custom: saved)
                XCTAssertEqual(player.gameFrame, editor.gameFrame)
                XCTAssertEqual(player.controlFrame, initial.controlFrame)
                XCTAssertEqual(player.touchLayout, editor.touchLayout)
                let expected = controlBoxes(editor), actual = controlBoxes(player)
                for control in expected.keys {
                    let before = try XCTUnwrap(expected[control]), after = try XCTUnwrap(actual[control])
                    XCTAssertEqual(after.minX, before.minX, accuracy: 0.001)
                    XCTAssertEqual(after.minY, before.minY, accuracy: 0.001)
                    XCTAssertEqual(after.size, before.size)
                }
            }
            preferences.resetTouchLayout(for: .nintendoDS, portrait: true)
            let reset = portraitDS(size, displayScale: scale,
                custom: preferences.effectiveCustomTouchLayout(for: .nintendoDS, portrait: true, policy: policy))
            XCTAssertEqual(reset, initial)
        }
    }

    func testEditorPreviewScalesCanonicalFittedCentersWithoutAnotherMargin() throws {
        let surface = portraitDS(CGSize(width: 834, height: 1190), displayScale: 2)
        let left = try XCTUnwrap(surface.touchLayout.elements.first { $0.control == .l })
        let full = surface.previewCenter(for: left, in: surface.controlFrame.size)
        XCTAssertEqual(full.x, 65.6, accuracy: 0.001)
        for factor in [CGFloat(0.25), 0.5, 1.5] {
            let canvas = CGSize(width: surface.controlFrame.width * factor, height: surface.controlFrame.height * factor)
            for element in surface.touchLayout.elements {
                let original = surface.previewCenter(for: element, in: surface.controlFrame.size)
                let preview = surface.previewCenter(for: element, in: canvas)
                XCTAssertEqual(preview.x, original.x * factor, accuracy: 0.001)
                XCTAssertEqual(preview.y, original.y * factor, accuracy: 0.001)
            }
        }
    }

    func testSavedExpandedCustomFallsBackInCompactAndRestoresWithoutChangingRawJSON() throws {
        let suite = "RelayCompactCustom-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        let policy = RelayAccessPolicy(entitlement: RelayEntitlementState(activeProductIDs: [.proOnce]))
        let expanded = portraitDS(CGSize(width: 834, height: 1190), displayScale: 2)
        preferences.setTouchLayout(expanded.touchLayout, for: SystemCatalog.nintendoDS, portrait: true, scale: 1.2)
        preferences.touchOpacity = 0.7
        let rawJSON = try XCTUnwrap(defaults.data(forKey: "relay.touch.layout.nds.portrait"))
        let raw = try XCTUnwrap(preferences.effectiveCustomTouchLayout(for: .nintendoDS, portrait: true, policy: policy))
        let draft = RelayTouchLayoutDraft(layout: raw, selected: .a, opacity: preferences.touchOpacity)
        for size in [CGSize(width: 375, height: 909), CGSize(width: 834, height: 1190), CGSize(width: 375, height: 909)] {
            let presented = portraitDS(size, displayScale: 2, custom: draft.layout)
            if size.width == 375 {
                XCTAssertTrue(presented.usesCustomLayoutFallback)
                XCTAssertEqual(presented.touchLayout, portraitDS(size, displayScale: 2).touchLayout)
                XCTAssertNotEqual(presented.touchLayout, draft.layout)
            } else {
                XCTAssertFalse(presented.usesCustomLayoutFallback)
                XCTAssertEqual(presented, portraitDS(size, displayScale: 2, custom: raw))
                XCTAssertEqual(presented.gameFrame, expanded.gameFrame)
                XCTAssertEqual(presented.touchLayout, expanded.touchLayout)
            }
            // Save always receives the raw draft, even while showing a fallback.
            preferences.setTouchLayout(draft.layout, for: SystemCatalog.nintendoDS,
                                       portrait: true, scale: presented.controlScale)
            preferences.touchOpacity = draft.opacity
            XCTAssertEqual(defaults.data(forKey: "relay.touch.layout.nds.portrait"), rawJSON)
            XCTAssertEqual(draft.layout, raw)
            XCTAssertEqual(draft.selected, .a)
            XCTAssertEqual(draft.opacity, 0.7)
            XCTAssertEqual(preferences.touchOpacity, 0.7)
        }
    }

    func testCompactDefaultControlCentersAndDPadDirectionsDoNotDispatchAnotherControl() throws {
        for size in [CGSize(width: 375, height: 909), CGSize(width: 402, height: 874), CGSize(width: 834, height: 1190)] {
            let surface = portraitDS(size, displayScale: 2)
            XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame))
            let boxes = controlBoxes(surface)
            for element in surface.touchLayout.elements {
                let box = try XCTUnwrap(boxes[element.control])
                var targets = [CGPoint(x: box.midX, y: box.midY)]
                if case .dpad(let span) = element.shape {
                    targets += [CGPoint(x: box.midX - span * 0.32, y: box.midY),
                                CGPoint(x: box.midX + span * 0.32, y: box.midY),
                                CGPoint(x: box.midX, y: box.midY - span * 0.32),
                                CGPoint(x: box.midX, y: box.midY + span * 0.32)]
                }
                for target in targets {
                    let controls = Set(boxes.filter { $0.value.insetBy(dx: -6, dy: -6).contains(target) }.keys)
                    XCTAssertEqual(controls, [element.control], "Ambiguous \(element.control) target in \(size)")
                }
            }
        }
    }

    func testShortPortraitDefaultCrossClearsFaceButtons() throws {
        // Safe content bounds observed on the official closed Duo simulator.
        // The rule depends on available geometry, not the device identity.
        for width: CGFloat in [375, 382, 390] {
            for height: CGFloat in [620, 644, 666] {
                let surface = portraitDS(CGSize(width: width, height: height), displayScale: 3)
                let pad = try XCTUnwrap(surface.touchLayout.elements.first { $0.control == .up })
                let y = try XCTUnwrap(surface.touchLayout.elements.first { $0.control == .y })
                XCTAssertGreaterThanOrEqual(RelayPlaySurfaceLayout.visibleClearance(pad, y, in: surface.controlFrame), 4)
                XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame))
                let fallback = TouchLayout.layout(for: SystemCatalog.nintendoDS.inputLayout, portrait: true)
                XCTAssertEqual(surface.touchLayout.elements.map(\.shape), fallback.elements.map(\.shape))
                XCTAssertGreaterThanOrEqual(surface.gameFrame.height, height - 320)
                XCTAssertFalse(surface.usesCustomLayoutFallback)
            }
        }
        // The measured case needs only a small correction, not the full normal
        // deck or a blanket reduction of every game's picture area.
        let observed = portraitDS(CGSize(width: 382, height: 644), displayScale: 3)
        XCTAssertLessThan(observed.controlFrame.height, 296)
    }

    func testVisibleSystemCapsuleOverlapFallsBackEvenWithIndependentCenters() throws {
        let size = CGSize(width: 375, height: 909)
        let original = portraitDS(size, displayScale: 2)
        let start = try XCTUnwrap(original.touchLayout.elements.first { $0.control == .start })
        let custom = original.touchLayout.replacing(start.moved(to: CGPoint(x: start.center.x - 0.08, y: start.center.y)))
        let startCenter = try XCTUnwrap(custom.elements.first { $0.control == .start }).center.x * original.controlFrame.width
        let select = try XCTUnwrap(custom.elements.first { $0.control == .select })
        let separation = startCenter - select.center.x * original.controlFrame.width
        XCTAssertGreaterThan(separation, start.shape.size.width / 2 + 6)
        XCTAssertLessThan(separation, start.shape.size.width)
        let presented = portraitDS(size, displayScale: 2, custom: custom)
        XCTAssertTrue(presented.usesCustomLayoutFallback)
        XCTAssertEqual(presented.touchLayout, original.touchLayout)
    }

    func testCompactDefaultCrossClearsYAndFooterWithoutChangingPicturesOrOtherControls() throws {
        for size in [CGSize(width: 375, height: 909), CGSize(width: 402, height: 874)] {
            let surface = portraitDS(size, displayScale: 2)
            let old = TouchLayout.layout(for: SystemCatalog.nintendoDS.inputLayout, portrait: true)
                .anchoredForReach(in: surface.controlFrame.size, portrait: true)
            let oldPad = try XCTUnwrap(old.elements.first { $0.control == .up })
            let pad = try XCTUnwrap(surface.touchLayout.elements.first { $0.control == .up })
            let y = try XCTUnwrap(surface.touchLayout.elements.first { $0.control == .y })
            XCTAssertGreaterThanOrEqual(RelayPlaySurfaceLayout.visibleClearance(pad, y, in: surface.controlFrame), 4)
            let boxes = controlBoxes(surface)
            let padBox = try XCTUnwrap(boxes[.up])
            let footerTop = min(try XCTUnwrap(boxes[.start]).minY, try XCTUnwrap(boxes[.select]).minY)
            XCTAssertGreaterThanOrEqual(footerTop - padBox.maxY, 4)
            for element in old.elements where element.control != .up {
                XCTAssertEqual(surface.touchLayout.elements.first { $0.control == element.control }, element)
            }
            XCTAssertEqual(pad.shape, oldPad.shape)
            XCTAssertEqual(pad.center.x, oldPad.center.x)
            if size.width == 375 {
                XCTAssertLessThan(RelayPlaySurfaceLayout.visibleClearance(oldPad, y, in: surface.controlFrame), 0)
                XCTAssertEqual(padBox.midY - surface.controlFrame.minY, 175, accuracy: 0.001)
                XCTAssertFalse(RelayPlaySurfaceLayout.hasUsableControlTargets(old, in: surface.controlFrame))
            } else {
                // Separating the whole face group from R also requires this
                // small cross shift; its point size and pictures stay unchanged.
                XCTAssertEqual(padBox.midY - surface.controlFrame.minY, 153, accuracy: 0.001)
            }
            XCTAssertTrue(RelayPlaySurfaceLayout.hasUsableControlTargets(surface.touchLayout, in: surface.controlFrame))
            XCTAssertEqual(surface.controlFrame.width, size.width - 48)
            XCTAssertEqual(surface.controlFrame.height, 296)
            let expectedGame = CGSize(width: size.width, height: size.height - 320)
            XCTAssertEqual(surface.gameFrame, CGRect(origin: .zero, size: expectedGame))
            let pictures = RelayLogicalScreenLayout(size: surface.gameFrame.size, screens: ds, preferred: .stacked, gap: 8)
            XCTAssertEqual(pictures.frames.map(\.size), Array(repeating: CGSize(width: expectedGame.width, height: (expectedGame.height - 8) / 2), count: 2))
        }
    }

    func testSelectingAndNoOpEditingFallbackKeepRawButActualEditAdoptsVisibleLayout() throws {
        let raw = portraitDS(CGSize(width: 834, height: 1190), displayScale: 2).touchLayout
        let compact = portraitDS(CGSize(width: 375, height: 909), displayScale: 2, custom: raw)
        var draft = RelayTouchLayoutDraft(layout: raw, opacity: 0.75)
        draft.selected = .a
        draft.edit(.a, on: compact) { $0 }
        XCTAssertEqual(draft.layout, raw)
        XCTAssertEqual(draft.selected, .a)
        let shown = try XCTUnwrap(compact.touchLayout.elements.first { $0.control == .a })
        let changed = shown.moved(to: CGPoint(x: shown.center.x - 0.02, y: shown.center.y))
        draft.edit(.a, on: compact) { _ in changed }
        XCTAssertEqual(draft.layout, compact.touchLayout.replacing(changed))
        XCTAssertEqual(draft.opacity, 0.75)
        XCTAssertEqual(draft.selected, .a)
        let reloaded = portraitDS(CGSize(width: 375, height: 909), displayScale: 2, custom: draft.layout)
        XCTAssertFalse(reloaded.usesCustomLayoutFallback)
        XCTAssertEqual(reloaded.touchLayout, draft.layout)
        let savedDraft = draft
        let select = try XCTUnwrap(draft.layout.elements.first { $0.control == .select })
        draft.edit(.start, on: reloaded) { $0.moved(to: select.center) }
        XCTAssertEqual(draft, savedDraft, "An unusable edit must not jump the whole preview to another layout")
    }

    func testLegacyUsableCustomRemainsExactAcrossCompactAndExpandedContainers() {
        let compact = RelayPlaySurfaceLayout(size: CGSize(width: 375, height: 909), showsTouchControls: true,
                                              controls: SystemCatalog.nintendoDS.inputLayout)
        let legacy = compact.touchLayout
        for size in [CGSize(width: 375, height: 909), CGSize(width: 834, height: 1190), CGSize(width: 375, height: 909)] {
            let presented = portraitDS(size, displayScale: 2, custom: legacy)
            XCTAssertFalse(presented.usesCustomLayoutFallback)
            XCTAssertEqual(presented.touchLayout, legacy)
        }
    }

    func testActualEditCanReplaceARepairedLegacyMissingControl() throws {
        let size = CGSize(width: 375, height: 909)
        let original = portraitDS(size, displayScale: 2).touchLayout
        let raw = TouchLayout(elements: original.elements.filter { $0.control != .a })
        let presented = portraitDS(size, displayScale: 2, custom: raw)
        XCTAssertFalse(presented.usesCustomLayoutFallback)
        var draft = RelayTouchLayoutDraft(layout: raw, selected: .a, opacity: 0.8)
        draft.edit(.a, on: presented) { $0 }
        XCTAssertEqual(draft.layout, raw)
        draft.edit(.a, on: presented) { $0.moved(to: CGPoint(x: $0.center.x - 0.02, y: $0.center.y)) }
        XCTAssertEqual(draft.layout.controls, original.controls)
        let a = try XCTUnwrap(draft.layout.elements.first { $0.control == .a })
        XCTAssertEqual(a.center.x, 0.84, accuracy: 0.001)
        XCTAssertEqual(draft.opacity, 0.8)
        XCTAssertEqual(draft.selected, .a)
    }

    func testPreviewScalesVisibleShapesWithoutMinimumSizeInflationOrScaleCap() {
        let surface = portraitDS(CGSize(width: 834, height: 1190), displayScale: 2)
        for factor in [CGFloat(0.25), 548.0 / 786.0, 343.0 / 327.0, 1.5] {
            let canvas = CGSize(width: surface.controlFrame.width * factor, height: surface.controlFrame.height * factor)
            for element in surface.touchLayout.elements {
                let size = surface.previewSize(for: element, in: canvas)
                let center = surface.previewCenter(for: element, in: canvas)
                XCTAssertEqual(size.width, element.shape.size.width * factor, accuracy: 0.001)
                XCTAssertEqual(size.height, element.shape.size.height * factor, accuracy: 0.001)
                let visible = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(visible))
            }
        }
    }

    private func portraitDS(_ size: CGSize, displayScale: CGFloat, scaling: DisplayScaling = .integer,
                            custom: TouchLayout? = nil) -> RelayPlaySurfaceLayout {
        RelayPlaySurfaceLayout(size: size, showsTouchControls: true, controls: SystemCatalog.nintendoDS.inputLayout,
                               screens: ds, preferredArrangement: .stacked, scaling: scaling,
                               displayScale: displayScale, customTouchLayout: custom)
    }

    private func controlBoxes(_ surface: RelayPlaySurfaceLayout) -> [TouchControl: CGRect] {
        Dictionary(uniqueKeysWithValues: surface.touchLayout.elements.map { element in
            let center = element.fittedCenter(in: surface.controlFrame.size)
            return (element.control, CGRect(x: surface.controlFrame.minX + center.x * surface.controlFrame.width - element.shape.size.width / 2,
                                            y: surface.controlFrame.minY + center.y * surface.controlFrame.height - element.shape.size.height / 2,
                                            width: element.shape.size.width, height: element.shape.size.height))
        })
    }
}
