// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
@testable import RelayEmulation
@testable import RelayInput

/// The mappings are built from each system's own control layout. These prove
/// Game Boy is never sent a button it does not have, and that a system with a
/// real stick receives the stick's value instead of four pad presses.
final class InputMappingTests: XCTestCase {

    private let gba = SystemGamepadMapping(system: SystemCatalog.gameBoyAdvance)
    private let gb = SystemGamepadMapping(system: SystemCatalog.gameBoy)

    // MARK: Game Boy Advance — unchanged behaviour

    func testAdvanceGamepadCoversEveryButtonTheHardwareHas() {
        XCTAssertEqual(gba.reachableInputs, [.up, .down, .left, .right, .a, .b, .l, .r, .start, .select])
        XCTAssertEqual(gba.binding(for: .buttonA), .input(.a))
        XCTAssertEqual(gba.binding(for: .buttonX), .input(.b))
        XCTAssertEqual(gba.binding(for: .buttonB), .input(.b))
        XCTAssertEqual(gba.binding(for: .buttonY), .input(.a))
        XCTAssertEqual(gba.binding(for: .menu), .input(.start))
        XCTAssertEqual(gba.binding(for: .options), .input(.select))
        XCTAssertEqual(gba.binding(for: .home), .command(.pause))
        XCTAssertEqual(gba.binding(for: .leftShoulder), .input(.l))
        XCTAssertEqual(gba.binding(for: .rightTrigger), .input(.r))
    }

    func testAppleTVKeepsEveryAdvanceButtonReachable() {
        let tv = SystemGamepadMapping(system: SystemCatalog.gameBoyAdvance, appleTV: true)
        XCTAssertEqual(tv.binding(for: .menu), .command(.pause))
        XCTAssertEqual(tv.binding(for: .options), .input(.start))
        XCTAssertEqual(tv.reachableInputs, gba.reachableInputs,
                       "every Advance button stays reachable on Apple TV")
    }

    func testCustomMappingSupportsRelayActionsAndKeepsRecoveryReserved() {
        let profile = ControllerMappingProfile(bindings: [
            .buttonA: .command(.quickSave),
            .leftTrigger: .command(.rewind),
            .rightTrigger: .command(.screenshot),
            .menu: .input(.a),
            .home: .input(.b),
        ])
        let tv = SystemGamepadMapping(system: SystemCatalog.gameBoyAdvance, appleTV: true, profile: profile)

        XCTAssertEqual(tv.binding(for: .buttonA), .command(.quickSave))
        XCTAssertEqual(tv.binding(for: .leftTrigger), .command(.rewind))
        XCTAssertEqual(tv.binding(for: .rightTrigger), .command(.screenshot))
        XCTAssertEqual(tv.binding(for: .menu), .command(.pause))
        XCTAssertEqual(tv.binding(for: .home), .command(.pause))
    }

    func testInvalidCustomInputIsRepairedAndResetRestoresDefault() {
        let invalid = ControllerMappingProfile(bindings: [.leftShoulder: .input(.l)])
            .repaired(for: SystemCatalog.gameBoy.inputLayout)
        XCTAssertNil(invalid.bindings[.leftShoulder])

        let reset = SystemGamepadMapping(system: SystemCatalog.gameBoy, profile: .init())
        XCTAssertEqual(reset.binding(for: .buttonA), gb.binding(for: .buttonA))
    }

    // MARK: Game Boy — a system with fewer controls

    func testGameBoyIsNeverSentAShoulderPress() {
        XCTAssertNil(gb.binding(for: .leftShoulder))
        XCTAssertNil(gb.binding(for: .rightShoulder))
        // The triggers fall back to the shoulders, which the Game Boy lacks too.
        XCTAssertNil(gb.binding(for: .leftTrigger))
        XCTAssertNil(gb.binding(for: .rightTrigger))
        XCTAssertEqual(gb.reachableInputs, [.up, .down, .left, .right, .a, .b, .start, .select])
        XCTAssertFalse(gb.reachableInputs.contains(.l))
        XCTAssertFalse(gb.reachableInputs.contains(.r))
    }

    func testGameBoyKeepsTheDiagonalFacePairing() {
        XCTAssertEqual(gb.binding(for: .buttonA), .input(.a))
        XCTAssertEqual(gb.binding(for: .buttonY), .input(.a))
        XCTAssertEqual(gb.binding(for: .buttonB), .input(.b))
        XCTAssertEqual(gb.binding(for: .buttonX), .input(.b))
    }

    // MARK: Four-button systems map positionally

    func testFourButtonSystemsMapFaceButtonsPositionally() {
        let snes = SystemGamepadMapping(system: SystemCatalog.snes)
        XCTAssertEqual(snes.binding(for: .buttonA), .input(.b))   // south
        XCTAssertEqual(snes.binding(for: .buttonB), .input(.a))   // east
        XCTAssertEqual(snes.binding(for: .buttonX), .input(.y))   // west
        XCTAssertEqual(snes.binding(for: .buttonY), .input(.x))   // north
        XCTAssertTrue(snes.reachableInputs.isSuperset(of: [.a, .b, .x, .y, .l, .r]))
    }

    // MARK: Analog

    func testASystemWithoutAStickLetsTheStickStandInForThePad() {
        XCTAssertEqual(gba.destination(of: .left), .digitalPad)
        XCTAssertEqual(gb.destination(of: .left), .digitalPad)
    }

    func testASystemWithAStickReceivesTheValue() {
        let n64 = SystemGamepadMapping(system: SystemCatalog.nintendo64)
        XCTAssertEqual(n64.destination(of: .left), .axes(x: .leftStickX, y: .leftStickY))
        let ps1 = SystemGamepadMapping(system: SystemCatalog.playStation)
        XCTAssertEqual(ps1.destination(of: .left), .axes(x: .leftStickX, y: .leftStickY))
        XCTAssertEqual(ps1.destination(of: .right), .axes(x: .rightStickX, y: .rightStickY))
    }

    func testNintendo64TriggersReachZAndTheShoulders() {
        let n64 = SystemGamepadMapping(system: SystemCatalog.nintendo64)
        XCTAssertEqual(n64.binding(for: .leftTrigger), .input(.z))
        XCTAssertEqual(n64.binding(for: .rightTrigger), .input(.r))
        XCTAssertEqual(n64.binding(for: .leftShoulder), .input(.l))
    }

    func testPlayStationAnalogTriggersAreTheSecondShoulderPair() {
        let ps1 = SystemGamepadMapping(system: SystemCatalog.playStation)
        XCTAssertEqual(ps1.binding(for: .leftTrigger), .input(.l2))
        XCTAssertEqual(ps1.binding(for: .rightTrigger), .input(.r2))
        XCTAssertEqual(ps1.binding(for: .leftShoulder), .input(.l))
        XCTAssertEqual(ps1.binding(for: .leftThumbstickButton), .input(.l3))
        XCTAssertEqual(ps1.binding(for: .rightThumbstickButton), .input(.r3))
    }

    func testAppleTVPlayStationKeepsSelectAndBothStickClicks() {
        let tv = SystemGamepadMapping(system: SystemCatalog.playStation, appleTV: true)
        XCTAssertEqual(tv.binding(for: .menu), .command(.pause))
        XCTAssertEqual(tv.binding(for: .options), .input(.start))
        XCTAssertEqual(tv.binding(for: .leftThumbstickButton), .input(.l3))
        XCTAssertEqual(tv.binding(for: .rightThumbstickButton), .input(.r3))
        XCTAssertEqual(tv.simultaneousStickClickInput, .select)
        let custom = SystemGamepadMapping(system: SystemCatalog.playStation, appleTV: true,
            profile: .init(bindings: [.leftThumbstickButton: .input(.select)]))
        XCTAssertNil(custom.simultaneousStickClickInput)
        XCTAssertNil(SystemGamepadMapping(system: SystemCatalog.playStation).simultaneousStickClickInput)
    }

    // MARK: Axis values

    func testAxisClampingKeepsSticksBipolarAndTriggersPositive() {
        XCTAssertEqual(EmulationAxis.leftStickX.clamp(-3), -1)
        XCTAssertEqual(EmulationAxis.leftStickX.clamp(3), 1)
        XCTAssertEqual(EmulationAxis.leftStickX.clamp(-0.5), -0.5)
        XCTAssertEqual(EmulationAxis.triggerL.clamp(-0.5), 0, "a trigger never reads negative")
        XCTAssertEqual(EmulationAxis.triggerL.clamp(0.4), 0.4)
        XCTAssertTrue(EmulationAxis.leftStickY.isBipolar)
        XCTAssertFalse(EmulationAxis.triggerR.isBipolar)
    }

    func testDeadZoneCentresASlackStickAndKeepsTheRestLive() {
        let filter = AnalogStickFilter(deadZone: 0.15, saturation: 0.95)
        let centred = filter.filter(x: 0.1, y: -0.05)
        XCTAssertEqual(centred.x, 0)
        XCTAssertEqual(centred.y, 0)

        let live = filter.filter(x: 0.5, y: 0)
        XCTAssertGreaterThan(live.x, 0)
        XCTAssertLessThan(live.x, 1)
        XCTAssertEqual(live.y, 0)
    }

    /// A diagonal must not be faster than a straight push.
    func testFullDeflectionIsBoundedToTheUnitCircle() {
        let filter = AnalogStickFilter()
        let diagonal = filter.filter(x: 1, y: 1)
        let magnitude = (diagonal.x * diagonal.x + diagonal.y * diagonal.y).squareRoot()
        XCTAssertLessThanOrEqual(magnitude, 1.0001)
        XCTAssertGreaterThan(magnitude, 0.99)

        let straight = filter.filter(x: 1, y: 0)
        XCTAssertEqual(straight.x, 1, accuracy: 0.0001)
    }

    func testDeflectionJustOutsideTheDeadZoneIsNearlyCentred() {
        let filter = AnalogStickFilter(deadZone: 0.2, saturation: 0.9)
        let justLive = filter.filter(x: 0.21, y: 0)
        XCTAssertGreaterThan(justLive.x, 0)
        XCTAssertLessThan(justLive.x, 0.05, "the first live value must not jump")
    }

    // MARK: Keyboard

    func testAdvanceKeyboardMappingIsUnchanged() {
        let keys = SystemKeyboardMapping(system: SystemCatalog.gameBoyAdvance)
        XCTAssertEqual(keys.binding(for: .keyZ), .input(.b))
        XCTAssertEqual(keys.binding(for: .keyX), .input(.a))
        XCTAssertEqual(keys.binding(for: .keyQ), .input(.l))
        XCTAssertEqual(keys.binding(for: .keyW), .input(.r))
        XCTAssertEqual(keys.binding(for: .returnOrEnter), .input(.start))
        XCTAssertEqual(keys.binding(for: .leftShift), .input(.select))
        XCTAssertEqual(keys.binding(for: .F1), .command(.quickSave))
        XCTAssertEqual(keys.binding(for: .F2), .command(.quickLoad))
        XCTAssertEqual(keys.binding(for: .deleteOrBackspace), .command(.rewind))
        XCTAssertEqual(keys.binding(for: .tab), .command(.fastForward))
        XCTAssertEqual(keys.reachableInputs, [.up, .down, .left, .right, .a, .b, .l, .r, .start, .select])
    }

    func testGameBoyKeyboardOffersNoShoulderKeys() {
        let keys = SystemKeyboardMapping(system: SystemCatalog.gameBoy)
        XCTAssertNil(keys.binding(for: .keyQ))
        XCTAssertNil(keys.binding(for: .keyW))
        XCTAssertEqual(keys.reachableInputs, [.up, .down, .left, .right, .a, .b, .start, .select])
    }

    func testFourButtonKeyboardReachesTheExtraFaceButtons() {
        let keys = SystemKeyboardMapping(system: SystemCatalog.snes)
        XCTAssertEqual(keys.binding(for: .keyA), .input(.y))
        XCTAssertEqual(keys.binding(for: .keyS), .input(.x))
    }

    /// Every button of every system Relay can play must be reachable from a
    /// standard controller without the player configuring anything.

    func testMasterSystemHasTwoButtonsAndPauseAsStart() {
        let sms = SystemGamepadMapping(system: SystemCatalog.masterSystem)
        XCTAssertEqual(sms.reachableInputs, [.up, .down, .left, .right, .a, .b, .start])
        XCTAssertEqual(sms.binding(for: .buttonA), .input(.a), "button 2 is the right-hand one")
        XCTAssertEqual(sms.binding(for: .buttonB), .input(.b))
        XCTAssertNil(sms.binding(for: .options), "nothing stands for a Select the console lacks")
        XCTAssertEqual(SystemCatalog.masterSystem.inputLayout.label(for: .faceA), "2")
        XCTAssertEqual(SystemCatalog.masterSystem.inputLayout.label(for: .start), "PAUSE")
    }

    func testPCEngineHasRunAndSelect() {
        let pce = SystemGamepadMapping(system: SystemCatalog.pcEngine)
        XCTAssertEqual(pce.reachableInputs, [.up, .down, .left, .right, .a, .b, .start, .select])
        XCTAssertEqual(pce.binding(for: .menu), .input(.start), "Run is Start")
        XCTAssertEqual(pce.binding(for: .options), .input(.select))
        XCTAssertEqual(SystemCatalog.pcEngine.inputLayout.label(for: .faceA), "I")
        XCTAssertEqual(SystemCatalog.pcEngine.inputLayout.label(for: .faceB), "II")
    }

    func testWonderSwanSecondClusterRidesTheRightStickAndIJKL() {
        let ws = SystemGamepadMapping(system: SystemCatalog.wonderSwan)
        XCTAssertEqual(ws.destination(of: .left), .digitalPad)
        XCTAssertEqual(ws.destination(of: .right), .secondaryPad, "the Y cluster is the second stick's job")
        XCTAssertFalse(ws.reachableInputs.contains(.select), "the WonderSwan has no Select")
        let keys = SystemKeyboardMapping(system: SystemCatalog.wonderSwan)
        XCTAssertEqual(keys.input(for: .keyI), .cUp)
        XCTAssertEqual(keys.input(for: .keyJ), .cLeft)
        XCTAssertEqual(keys.input(for: .keyK), .cDown)
        XCTAssertEqual(keys.input(for: .keyL), .cRight)
        // A system without a second cluster never sees those keys.
        XCTAssertNil(SystemKeyboardMapping(system: SystemCatalog.gameGear).input(for: .keyI))
        XCTAssertEqual(SystemGamepadMapping(system: SystemCatalog.gameGear).destination(of: .right), .unused)
    }

    func testEveryPlayableSystemIsFullyReachableFromAStandardController() {
        for system in SystemCatalog.playable {
            for appleTV in [false, true] {
                let mapping = SystemGamepadMapping(system: system, appleTV: appleTV)
                let expected = Self.expectedInputs(for: system.inputLayout)
                XCTAssertEqual(mapping.reachableInputs, expected,
                               "\(system.id), TV=\(appleTV): controller cannot reach every button")
            }
        }
    }

    private static func expectedInputs(for layout: SystemInputLayout) -> Set<EmulationInput> {
        var expected: Set<EmulationInput> = []
        if layout.has(.dPad) { expected.formUnion([.up, .down, .left, .right]) }
        if layout.has(.faceA) { expected.insert(.a) }
        if layout.has(.faceB) { expected.insert(.b) }
        if layout.has(.faceX) { expected.insert(.x) }
        if layout.has(.faceY) { expected.insert(.y) }
        if layout.has(.shoulderL) { expected.insert(.l) }
        if layout.has(.shoulderR) { expected.insert(.r) }
        if layout.has(.triggerL) { expected.insert(.l2) }
        if layout.has(.triggerR) { expected.insert(.r2) }
        if layout.has(.leftStickClick) { expected.insert(.l3) }
        if layout.has(.rightStickClick) { expected.insert(.r3) }
        if layout.has(.start) { expected.insert(.start) }
        if layout.has(.select) { expected.insert(.select) }
        return expected
    }

    // MARK: Edge tracking

    func testEdgeTrackerReportsOnlyChanges() {
        var tracker = ButtonEdgeTracker()
        XCTAssertNotNil(tracker.update(.a, isPressed: true))
        XCTAssertNil(tracker.update(.a, isPressed: true))
        XCTAssertEqual(tracker.activeInputs, [.a])
        XCTAssertNotNil(tracker.update(.a, isPressed: false))
        XCTAssertNil(tracker.update(.a, isPressed: false))
        XCTAssertTrue(tracker.activeInputs.isEmpty)
    }
}
