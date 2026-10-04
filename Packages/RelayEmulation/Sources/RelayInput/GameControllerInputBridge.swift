// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  GameControllerInputBridge.swift
//  RelayInput
//
//  Routes GameController framework input (gamepads and keyboards) into an
//  EmulationSession and reports Relay commands and connection changes to the
//  owner. One implementation for iOS, tvOS and macOS. Detection is immediate
//  (notifications), defaults need no setup, and a disconnect releases every

import Foundation
import GameController
import RelayDomain
import RelayEmulation

/// `NotificationCenter.addObserver(..., queue: .main)` guarantees main-queue
/// delivery, but the imported callback does not express that isolation to
/// Swift 6. Carry only the notification object across the compiler boundary;
/// every read remains inside `MainActor.assumeIsolated` below.
private struct MainQueueNotificationObject: @unchecked Sendable {
    let value: Any?
}

/// Connection changes and commands, delivered on the main actor.
@MainActor
public protocol GameControllerInputBridgeDelegate: AnyObject {
    /// The hardware name is nil for an unnamed controller; product UI supplies its label.
    func inputBridge(_ bridge: GameControllerInputBridge, controllerDidConnect name: String?)
    func inputBridgeControllerDidDisconnect(_ bridge: GameControllerInputBridge)
    /// `pressed` false for the end of a held command (rewind, fast-forward).
    func inputBridge(_ bridge: GameControllerInputBridge, command: InputCommand, pressed: Bool)
}

@MainActor
public final class GameControllerInputBridge {
    private weak var session: EmulationSession?
    public weak var delegate: (any GameControllerInputBridgeDelegate)?
    private var edges = ButtonEdgeTracker()
    private var heldCommands: Set<InputCommand> = []
    private var observers: [NSObjectProtocol] = []
    private var activeController: GCController?
    private var menuHoldTask: Task<Void, Never>?
    private let appleTV: Bool
    /// The mappings for the system being played. Built once from the system's
    /// own control layout: nothing below this line knows what a Game Boy is.
    private var gamepad: SystemGamepadMapping
    private let system: SystemDescriptor
    private let keyboard: SystemKeyboardMapping
    private let stickFilter = AnalogStickFilter()
    /// Last value sent per axis, so an unchanged stick sends nothing.
    private var lastAxisValues: [EmulationAxis: Float] = [:]

    public private(set) var connectedControllerName: String?
    /// Unmodified hardware name; UI owns the localized name for an unnamed controller.
    public var controllerVendorName: String? { activeController?.vendorName }
    public var hasController: Bool { activeController != nil }
    /// Gameplay keys are ignored while a command modifier is held so menu
    /// shortcuts (⌘S…) never reach the game (MACOS_UX §5).
    public var ignoresKeysWithCommandModifier = true

    /// - Parameter system: the system being played. Its `SystemInputLayout`
    ///   decides which buttons exist and whether a physical stick carries a
    ///   real value or stands in for the digital pad.
    public init(session: EmulationSession, system: SystemDescriptor, profile: ControllerMappingProfile = .init()) {
        self.session = session
        self.system = system
        #if os(tvOS)
        let isTV = true
        #else
        let isTV = false
        #endif
        appleTV = isTV
        gamepad = SystemGamepadMapping(system: system, appleTV: isTV, profile: profile)
        keyboard = SystemKeyboardMapping(system: system)
    }

    /// Applies a live entitlement/profile change without reconnecting the pad.
    /// Held controls are released first so remapping cannot leave a stuck input.
    public func updateProfile(_ profile: ControllerMappingProfile) {
        releaseAll()
        gamepad = SystemGamepadMapping(system: system, appleTV: appleTV, profile: profile)
    }

    public func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let object = MainQueueNotificationObject(value: note.object)
            MainActor.assumeIsolated {
                guard let self, let controller = object.value as? GCController else { return }
                if self.activeController == nil || self.activeController === controller { self.attach(controller, announce: true) }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let object = MainQueueNotificationObject(value: note.object)
            MainActor.assumeIsolated {
                guard let self, let gone = object.value as? GCController, gone === self.activeController else { return }
                self.releaseAll()
                self.activeController = nil
                self.connectedControllerName = nil
                self.session?.setControllerName(nil)
                if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
                    self.attach(next, announce: true)
                } else {
                    self.delegate?.inputBridgeControllerDidDisconnect(self)
                }
            }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            let object = MainQueueNotificationObject(value: note.object)
            MainActor.assumeIsolated {
                self?.attachKeyboard(object.value as? GCKeyboard)
            }
        })
        attach(GCController.controllers().first(where: { $0.extendedGamepad != nil }), announce: false)
        attachKeyboard(GCKeyboard.coalesced)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    public func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        releaseAll()
        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = nil
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        menuHoldTask?.cancel()
    }

    // MARK: Gamepads

    private func attach(_ controller: GCController?, announce: Bool) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = controller
        connectedControllerName = controller.vendorName ?? "Controller"
        session?.setControllerName(connectedControllerName)
        pad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated {
                self?.handle(pad)
            }
        }
        if announce { delegate?.inputBridge(self, controllerDidConnect: controller.vendorName) }
    }

    private func handle(_ pad: GCExtendedGamepad) {
        // A system with a real stick receives the stick's value; a system
        // without one lets the stick stand in for its digital pad.
        let leftIsAnalog = send(pad.leftThumbstick, to: gamepad.destination(of: .left))
        _ = send(pad.rightThumbstick, to: gamepad.destination(of: .right))
        if case .secondaryPad = gamepad.destination(of: .right) {
            press(.cUp, pad.rightThumbstick.up.isPressed)
            press(.cDown, pad.rightThumbstick.down.isPressed)
            press(.cLeft, pad.rightThumbstick.left.isPressed)
            press(.cRight, pad.rightThumbstick.right.isPressed)
        }
        apply(.dpadUp, pad.dpad.up.isPressed || (!leftIsAnalog && pad.leftThumbstick.up.isPressed))
        apply(.dpadDown, pad.dpad.down.isPressed || (!leftIsAnalog && pad.leftThumbstick.down.isPressed))
        apply(.dpadLeft, pad.dpad.left.isPressed || (!leftIsAnalog && pad.leftThumbstick.left.isPressed))
        apply(.dpadRight, pad.dpad.right.isPressed || (!leftIsAnalog && pad.leftThumbstick.right.isPressed))
        apply(.buttonA, pad.buttonA.isPressed)
        apply(.buttonB, pad.buttonB.isPressed)
        apply(.buttonX, pad.buttonX.isPressed)
        apply(.buttonY, pad.buttonY.isPressed)
        apply(.leftShoulder, pad.leftShoulder.isPressed)
        apply(.rightShoulder, pad.rightShoulder.isPressed)
        apply(.leftTrigger, pad.leftTrigger.isPressed)
        apply(.rightTrigger, pad.rightTrigger.isPressed)
        let leftClick = pad.leftThumbstickButton?.isPressed ?? false
        let rightClick = pad.rightThumbstickButton?.isPressed ?? false
        let selectChord = gamepad.simultaneousStickClickInput != nil && leftClick && rightClick
        apply(.leftThumbstickButton, leftClick && !selectChord)
        apply(.rightThumbstickButton, rightClick && !selectChord)
        if let input = gamepad.simultaneousStickClickInput { press(input, selectChord) }
        apply(.options, pad.buttonOptions?.isPressed ?? false)
        apply(.home, pad.buttonHome?.isPressed ?? false)
        handleMenu(pad.buttonMenu.isPressed)
    }

    /// Menu: its binding on press; on iPhone/iPad/Mac a long hold (0.7 s) also
    /// pauses, for controllers without a Home button.
    private var menuPressed = false
    private func handleMenu(_ pressed: Bool) {
        guard pressed != menuPressed else { return }
        menuPressed = pressed
        apply(.menu, pressed)
        menuHoldTask?.cancel()
        guard pressed, !appleTV else { return }
        menuHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.menuPressed else { return }
            self.send(.input(.start), false)
            self.delegate?.inputBridge(self, command: .pause, pressed: true)
        }
    }

    private func apply(_ element: GamepadElement, _ isPressed: Bool) {
        guard let binding = gamepad.binding(for: element) else { return }
        send(binding, isPressed)
    }

    private func press(_ input: EmulationInput, _ isPressed: Bool) {
        send(.input(input), isPressed)
    }

    /// Forwards a stick to the axes it drives. Returns true when the stick was
    /// consumed as analog, so the caller knows not to also press the pad.
    @discardableResult
    private func send(_ stick: GCControllerDirectionPad, to destination: StickDestination) -> Bool {
        guard case .axes(let xAxis, let yAxis) = destination else { return false }
        let filtered = stickFilter.filter(x: stick.xAxis.value, y: stick.yAxis.value)
        move(xAxis, filtered.x)
        move(yAxis, filtered.y)
        return true
    }

    private func move(_ axis: EmulationAxis, _ value: Float) {
        guard lastAxisValues[axis] != value else { return }
        lastAxisValues[axis] = value
        session?.move(axis, to: value)
    }

    // MARK: Keyboard

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] keyboardInput, _, keyCode, pressed in
            MainActor.assumeIsolated {
                guard let self, let key = Self.key(for: keyCode), let binding = self.keyboard.binding(for: key) else { return }
                if pressed, self.ignoresKeysWithCommandModifier,
                   keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true || keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true {
                    return
                }
                self.send(binding, pressed)
            }
        }
    }

    private static func key(for code: GCKeyCode) -> KeyboardKey? {
        switch code {
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .keyZ: return .keyZ
        case .keyX: return .keyX
        case .keyA: return .keyA
        case .keyS: return .keyS
        case .keyQ: return .keyQ
        case .keyW: return .keyW
        case .keyE: return .keyE
        case .keyR: return .keyR
        case .keyD: return .keyD
        case .keyF: return .keyF
        case .keyI: return .keyI
        case .keyJ: return .keyJ
        case .keyK: return .keyK
        case .keyL: return .keyL
        case .returnOrEnter, .keypadEnter: return .returnOrEnter
        case .rightShift: return .rightShift
        case .leftShift: return .leftShift
        case .F1: return .F1
        case .F2: return .F2
        case .deleteOrBackspace: return .deleteOrBackspace
        case .tab: return .tab
        default: return nil
        }
    }

    // MARK: Dispatch

    private func send(_ binding: InputBinding, _ isPressed: Bool) {
        switch binding {
        case .input(let input):
            guard let change = edges.update(input, isPressed: isPressed), let session else { return }
            if change.pressed { session.press(change.input) } else { session.release(change.input) }
        case .command(let command):
            if isPressed {
                guard !heldCommands.contains(command) else { return }
                heldCommands.insert(command)
                delegate?.inputBridge(self, command: command, pressed: true)
            } else {
                guard heldCommands.contains(command) else { return }
                heldCommands.remove(command)
                delegate?.inputBridge(self, command: command, pressed: false)
            }
        }
    }

    /// Releases every held emulated button and held command (disconnect, pause, background).
    public func releaseAll() {
        for input in edges.activeInputs {
            _ = edges.update(input, isPressed: false)
            session?.release(input)
        }
        for command in heldCommands {
            delegate?.inputBridge(self, command: command, pressed: false)
        }
        heldCommands.removeAll()
        // A stick left deflected when a controller vanishes would keep walking.
        for axis in lastAxisValues.keys where lastAxisValues[axis] != 0 {
            lastAxisValues[axis] = 0
            session?.move(axis, to: 0)
        }
    }
}
