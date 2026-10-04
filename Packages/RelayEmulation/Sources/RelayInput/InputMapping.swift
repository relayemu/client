// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  InputMapping.swift
//  RelayInput
//
//  Pure, testable mappings from physical controls to `EmulationInput`,
//  `EmulationAxis` and Relay commands (pause, quick save…). Defaults are
//
//  rather than from the Game Boy Advance's shape. A system that has no
//  shoulder buttons never receives a shoulder press, and a system that has a
//  real stick receives the stick's value instead of four pad presses.

import Foundation
import RelayDomain
import RelayEmulation

/// Logical gamepad elements Relay recognises (a subset of the extended gamepad profile).
public enum GamepadElement: String, CaseIterable, Codable, Hashable, Sendable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    /// Positional names: `buttonA` is the south button, `buttonB` east,
    /// `buttonX` west and `buttonY` north, as GameController reports them.
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case menu, options, home
}

/// A physical stick on the controller.
public enum GamepadStick: String, CaseIterable, Codable, Sendable {
    case left, right
}

/// Relay-level actions a physical control can trigger besides emulated buttons.
public enum InputCommand: String, CaseIterable, Codable, Hashable, Sendable {
    case pause
    case quickSave
    case quickLoad
    case rewind        // held
    case fastForward   // held
    case screenshot
}

/// What a physical element does: an emulated button, a Relay command, or nothing.
public enum InputBinding: Codable, Hashable, Sendable {
    case input(EmulationInput)
    case command(InputCommand)
}

/// Persisted user overrides for one system (or, optionally, one game). Menu and
/// Home are intentionally not overridable: pause/back recovery must always work,
/// especially on Apple TV.
public struct ControllerMappingProfile: Codable, Equatable, Sendable {
    public var bindings: [GamepadElement: InputBinding]

    public init(bindings: [GamepadElement: InputBinding] = [:]) {
        self.bindings = bindings.filter { !Self.reservedElements.contains($0.key) }
    }

    public static let reservedElements: Set<GamepadElement> = [.menu, .home]
    public static let editableElements: [GamepadElement] = GamepadElement.allCases.filter {
        !reservedElements.contains($0) && !$0.rawValue.hasPrefix("dpad")
    }

    public func repaired(for layout: SystemInputLayout) -> ControllerMappingProfile {
        ControllerMappingProfile(bindings: bindings.filter { _, binding in
            switch binding {
            case .command: return true
            case .input(let input): return Self.supports(input, in: layout)
            }
        })
    }

    public static func supports(_ input: EmulationInput, in layout: SystemInputLayout) -> Bool {
        switch input {
        case .up, .down, .left, .right: return layout.has(.dPad)
        case .a: return layout.has(.faceA)
        case .b: return layout.has(.faceB)
        case .x: return layout.has(.faceX)
        case .y: return layout.has(.faceY)
        case .l: return layout.has(.shoulderL)
        case .r: return layout.has(.shoulderR)
        case .l2: return layout.has(.triggerL)
        case .r2: return layout.has(.triggerR)
        case .l3: return layout.has(.leftStickClick)
        case .r3: return layout.has(.rightStickClick)
        case .z: return layout.has(.triggerZ)
        case .start: return layout.has(.start)
        case .select: return layout.has(.select)
        case .mode: return layout.has(.mode)
        case .cUp, .cDown, .cLeft, .cRight: return layout.has(.cPad)
        }
    }
}

/// Where a physical stick's motion goes on a given system.
public enum StickDestination: Hashable, Sendable {
    /// The system has a real stick: the value is preserved on these two axes.
    case axes(x: EmulationAxis, y: EmulationAxis)
    /// The system has no stick, so the stick stands in for the digital pad.
    /// This is the hardware's own vocabulary, not a loss of information.
    case digitalPad
    /// The system's second four-way cluster (the Nintendo 64's C buttons, the
    /// WonderSwan's Y cluster), as four presses.
    case secondaryPad
    /// The system has nothing for this stick to drive.
    case unused
}

/// The default controller mapping for one system.
///
/// Constructed from the system's `SystemInputLayout`, which is the only place
/// that knows what controls the hardware has. Two rules carry most of it:
///
/// * two-button systems pair the face buttons diagonally, so either thumb
///   position works (south/north → A, east/west → B);
/// * four-button systems map positionally (south → B, east → A, west → Y,
///   north → X), which is where those buttons sit on the original hardware.
public struct SystemGamepadMapping: Sendable {
    public let layout: SystemInputLayout
    /// Apple TV reserves Menu for pausing, so Start moves to Options there.
    public let appleTV: Bool
    public let profile: ControllerMappingProfile

    public init(layout: SystemInputLayout, appleTV: Bool = false, profile: ControllerMappingProfile = .init()) {
        self.layout = layout
        self.appleTV = appleTV
        self.profile = profile.repaired(for: layout)
    }

    public init(system: SystemDescriptor, appleTV: Bool = false, profile: ControllerMappingProfile = .init()) {
        self.init(layout: system.inputLayout, appleTV: appleTV, profile: profile)
    }

    private var isFourButton: Bool { layout.faceButtonCount >= 4 }

    public func binding(for element: GamepadElement) -> InputBinding? {
        if !ControllerMappingProfile.reservedElements.contains(element), let override = profile.bindings[element] {
            return override
        }
        switch element {
        case .dpadUp: return layout.has(.dPad) ? .input(.up) : nil
        case .dpadDown: return layout.has(.dPad) ? .input(.down) : nil
        case .dpadLeft: return layout.has(.dPad) ? .input(.left) : nil
        case .dpadRight: return layout.has(.dPad) ? .input(.right) : nil

        case .buttonA: return .input(isFourButton ? .b : .a)   // south
        case .buttonB: return .input(isFourButton ? .a : .b)   // east
        case .buttonX: return isFourButton ? face(.y) : .input(.b)  // west
        case .buttonY: return isFourButton ? face(.x) : .input(.a)  // north

        case .leftShoulder: return shoulder(.l)
        case .rightShoulder: return shoulder(.r)
        case .leftTrigger: return trigger(left: true)
        case .rightTrigger: return trigger(left: false)

        case .leftThumbstickButton:
            if layout.has(.leftStickClick) { return .input(.l3) }
            return layout.has(.select) ? .input(.select) : nil
        case .rightThumbstickButton:
            if layout.has(.rightStickClick) { return .input(.r3) }
            if appleTV { return layout.has(.select) ? .input(.select) : nil }
            return layout.has(.start) ? .input(.start) : nil

        case .menu:
            if appleTV { return .command(.pause) }
            return layout.has(.start) ? .input(.start) : .command(.pause)
        case .options:
            if appleTV { return layout.has(.start) ? .input(.start) : nil }
            return layout.has(.select) ? .input(.select) : (layout.has(.mode) ? .input(.mode) : nil)
        case .home: return .command(.pause)
        }
    }

    private func face(_ input: EmulationInput) -> InputBinding? {
        switch input {
        case .x: return layout.has(.faceX) ? .input(.x) : nil
        case .y: return layout.has(.faceY) ? .input(.y) : nil
        default: return .input(input)
        }
    }

    private func shoulder(_ input: EmulationInput) -> InputBinding? {
        let control: SystemControl = (input == .l) ? .shoulderL : .shoulderR
        return layout.has(control) ? .input(input) : nil
    }

    /// Triggers stand in for the shoulder buttons on systems whose shoulders
    /// are digital, and drive the Nintendo 64's Z on the left.
    private func trigger(left: Bool) -> InputBinding? {
        if left, layout.has(.triggerZ) { return .input(.z) }
        let analog: SystemControl = left ? .triggerL : .triggerR
        if layout.has(analog) { return .input(left ? .l2 : .r2) }
        return shoulder(left ? .l : .r)
    }

    /// Where a physical stick's motion goes. `digitalPad` means the caller
    /// converts the stick to pad presses; `axes` means the value is preserved.
    public func destination(of stick: GamepadStick) -> StickDestination {
        switch stick {
        case .left:
            if layout.has(.leftStick) { return .axes(x: .leftStickX, y: .leftStickY) }
            return layout.has(.dPad) ? .digitalPad : .unused
        case .right:
            if layout.has(.rightStick) { return .axes(x: .rightStickX, y: .rightStickY) }
            // A second four-way cluster is the natural home of a second stick.
            return layout.has(.cPad) ? .secondaryPad : .unused
        }
    }

    /// Apple TV reserves Menu for Pause. With both stick clicks occupied by
    /// L3/R3, pressing them together provides Select without losing either click.
    /// A custom direct Select binding makes the fallback unnecessary.
    public var simultaneousStickClickInput: EmulationInput? {
        guard appleTV, layout.has(.leftStickClick), layout.has(.rightStickClick), layout.has(.select),
              !GamepadElement.allCases.contains(where: { binding(for: $0) == .input(.select) }) else { return nil }
        return .select
    }

    /// Every emulated button this mapping can produce, including its chord.
    public var reachableInputs: Set<EmulationInput> {
        var found: Set<EmulationInput> = []
        for element in GamepadElement.allCases {
            if case .input(let input)? = binding(for: element) { found.insert(input) }
        }
        if let input = simultaneousStickClickInput { found.insert(input) }
        return found
    }
}

/// Keyboard key identifiers Relay maps (names follow GCKeyCode where they exist).
public enum KeyboardKey: String, CaseIterable, Sendable {
    case upArrow, downArrow, leftArrow, rightArrow
    case keyZ, keyX, keyA, keyS, keyQ, keyW, keyE, keyR, keyD, keyF
    /// The second four-way cluster, on systems that have one (I J K L).
    case keyI, keyJ, keyK, keyL
    case returnOrEnter, rightShift, leftShift
    case F1, F2, deleteOrBackspace, tab
}

/// Default keyboard mapping (MACOS_UX §5 / IPAD_UX §6): arrows = D-pad;
/// Z/X = B/A; A/S = Y/X where the system has them; Q/W = L/R; I/J/K/L = the
/// second four-way cluster where the system has one; Return = Start;
/// Shift = Select; F1 Quick Save; F2 Quick Load; hold ⌫ = Rewind;
/// hold Tab = Fast Forward. Escape (pause) is a view-level shortcut so it
/// never doubles as a game button.
public struct SystemKeyboardMapping: Sendable {
    public let layout: SystemInputLayout

    public init(layout: SystemInputLayout) { self.layout = layout }
    public init(system: SystemDescriptor) { self.init(layout: system.inputLayout) }

    public func binding(for key: KeyboardKey) -> InputBinding? {
        switch key {
        case .upArrow: return layout.has(.dPad) ? .input(.up) : nil
        case .downArrow: return layout.has(.dPad) ? .input(.down) : nil
        case .leftArrow: return layout.has(.dPad) ? .input(.left) : nil
        case .rightArrow: return layout.has(.dPad) ? .input(.right) : nil
        case .keyZ: return .input(.b)
        case .keyX: return .input(.a)
        case .keyA: return layout.has(.faceY) ? .input(.y) : nil
        case .keyS: return layout.has(.faceX) ? .input(.x) : nil
        case .keyQ: return layout.has(.shoulderL) ? .input(.l) : nil
        case .keyW: return layout.has(.shoulderR) ? .input(.r) : nil
        case .keyE: return layout.has(.triggerL) ? .input(.l2) : nil
        case .keyR: return layout.has(.triggerR) ? .input(.r2) : nil
        case .keyD: return layout.has(.leftStickClick) ? .input(.l3) : nil
        case .keyF: return layout.has(.rightStickClick) ? .input(.r3) : nil
        case .keyI: return layout.has(.cPad) ? .input(.cUp) : nil
        case .keyJ: return layout.has(.cPad) ? .input(.cLeft) : nil
        case .keyK: return layout.has(.cPad) ? .input(.cDown) : nil
        case .keyL: return layout.has(.cPad) ? .input(.cRight) : nil
        case .returnOrEnter: return layout.has(.start) ? .input(.start) : nil
        case .rightShift, .leftShift: return layout.has(.select) ? .input(.select) : nil
        case .F1: return .command(.quickSave)
        case .F2: return .command(.quickLoad)
        case .deleteOrBackspace: return .command(.rewind)
        case .tab: return .command(.fastForward)
        }
    }

    public func input(for key: KeyboardKey) -> EmulationInput? {
        if case .input(let i)? = binding(for: key) { return i }
        return nil
    }

    public var reachableInputs: Set<EmulationInput> {
        Set(KeyboardKey.allCases.compactMap(input(for:)))
    }
}

/// Edge detector turning repeated "pressed" samples into press/release events.
public struct ButtonEdgeTracker: Sendable {
    private var pressed: Set<EmulationInput> = []
    public init() {}

    /// Returns the input to send as pressed or released, or nil when unchanged.
    public mutating func update(_ input: EmulationInput, isPressed: Bool) -> (input: EmulationInput, pressed: Bool)? {
        if isPressed {
            guard !pressed.contains(input) else { return nil }
            pressed.insert(input)
            return (input, true)
        } else {
            guard pressed.contains(input) else { return nil }
            pressed.remove(input)
            return (input, false)
        }
    }

    public var activeInputs: Set<EmulationInput> { pressed }
}

/// Cleans a physical stick reading before it reaches a core.
///
/// A stick that never quite returns to zero would otherwise walk the character
/// across the room; a stick whose diagonal reads past 1.0 would be faster on
/// the diagonal than on the axis. Both are the frontend's job, not the core's.
public struct AnalogStickFilter: Sendable {
    /// Readings inside this radius are treated as centred.
    public let deadZone: Float
    /// Readings outside this radius are treated as fully deflected.
    public let saturation: Float

    public init(deadZone: Float = 0.15, saturation: Float = 0.95) {
        self.deadZone = max(0, min(deadZone, 0.9))
        self.saturation = max(self.deadZone + 0.01, min(saturation, 1))
    }

    /// Maps a raw (x, y) reading to the value a core should see: centred inside
    /// the dead zone, rescaled so the first live value is just off centre, and
    /// bounded to the unit circle so no diagonal exceeds full deflection.
    public func filter(x: Float, y: Float) -> (x: Float, y: Float) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadZone else { return (0, 0) }
        let scaled = min((magnitude - deadZone) / (saturation - deadZone), 1)
        return (x / magnitude * scaled, y / magnitude * scaled)
    }
}
