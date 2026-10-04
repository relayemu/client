// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  EmulationTypes.swift
//  RelayEmulation
//
//  Platform-neutral value types shared between the Relay shells and the
//  No Apple UI framework types may appear here (spec §6.1, §54).

import Foundation
import RelayDomain

// Core identity and description come from RelayDomain (`CoreID`,

/// Logical buttons understood by the emulated system.
///
/// Relay's own vocabulary, wide enough for the systems in `SystemCatalog`; a
/// system only ever receives the buttons its `SystemInputLayout` declares, so
/// a Game Boy is never sent a shoulder press. Never an emulator button code:
public enum EmulationInput: String, CaseIterable, Hashable, Codable, Sendable {
    case up, down, left, right
    case a, b, x, y
    case l, r
    /// Second shoulder pair, as digital presses.
    case l2, r2
    /// DualShock stick clicks.
    case l3, r3
    /// The Nintendo 64's Z trigger.
    case z
    case start, select
    /// Mega Drive's Mode button.
    case mode
    /// The Nintendo 64's four yellow C directions, which behave as buttons.
    case cUp, cDown, cLeft, cRight
}

/// A control that carries a continuous value rather than a press.
///
/// Analog input is never quantised into digital presses on a system that has a
/// brief §18). Systems without a stick fall back to the digital pad, which is
/// the hardware's own behaviour, not a loss of information.
public enum EmulationAxis: String, CaseIterable, Hashable, Codable, Sendable {
    case leftStickX, leftStickY
    case rightStickX, rightStickY
    case triggerL, triggerR

    /// Range of legal values: sticks are centred at zero, triggers rest at zero.
    public var isBipolar: Bool {
        switch self {
        case .leftStickX, .leftStickY, .rightStickX, .rightStickY: return true
        case .triggerL, .triggerR: return false
        }
    }

    /// Clamps `value` into this axis's legal range.
    public func clamp(_ value: Float) -> Float {
        let lower: Float = isBipolar ? -1 : 0
        return min(max(value, lower), 1)
    }
}

/// Lifecycle state of an `EmulationSession`.
public enum EmulationState: Equatable, Sendable {
    case idle
    case loading
    case running
    case paused
    case stopped
    case failed(EmulationError)
}

public enum EmulationError: Error, Equatable, Sendable, CustomStringConvertible {
    case coreUnavailable(CoreID)
    case romNotFound(String)
    case loadFailed(String)
    case firmwareInvalid
    case stateFirmwareMismatch
    case startFailed(String)
    case audioFailed(String)
    case invalidState(String)
    /// The running core lacks the capability (`CoreCapabilities`) the caller asked for.
    case unsupported(String)
    /// The core could not serialize or restore its machine state.
    case stateFailed(String)

    public var description: String {
        switch self {
        case .coreUnavailable(let s): return "Emulator core unavailable: \(s)"
        case .romNotFound(let s): return "Game file not found: \(s)"
        case .firmwareInvalid: return "The installed system firmware is incompatible or damaged"
        case .stateFirmwareMismatch: return "This save state requires the same system firmware as its source device"
        case .loadFailed(let s): return "The game could not be loaded: \(s)"
        case .startFailed(let s): return "Emulation could not start: \(s)"
        case .audioFailed(let s): return "Audio could not start: \(s)"
        case .invalidState(let s): return "Invalid state: \(s)"
        case .unsupported(let s): return "Unsupported by this core: \(s)"
        case .stateFailed(let s): return "Save state failure: \(s)"
        }
    }
}

/// User-facing speed presets (spec §18: simple product choices, no raw multipliers).
public enum EmulationSpeed: String, CaseIterable, Hashable, Codable, Sendable {
    /// Quarter speed. Exposed only when the active adapter declares support.
    case quarter
    /// Half speed.
    case half
    case normal
    /// Twice real time.
    case double
    /// Three times real time.
    case triple
    /// Four times real time.
    case quadruple
    /// As fast as the core runs (bounded by the driver).
    case maximum

    /// Nominal multiplier, for indicators and diagnostics only.
    public var nominalMultiplier: Double {
        switch self {
        case .quarter: return 0.25
        case .half: return 0.5
        case .normal: return 1
        case .double: return 2
        case .triple: return 3
        case .quadruple: return 4
        case .maximum: return 5
        }
    }
}

/// Human-facing cheat formats. Adapters translate these stable Relay values at
/// the core boundary; views never handle vendor enums or memory editors.
public enum CheatFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case gameShark
    case codeBreaker
    case proActionReplay
}

/// A user-authored cheat kept per game. Definitions survive entitlement loss;
/// only their runtime application is gated by product policy.
public struct CheatDefinition: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public var code: String
    public var format: CheatFormat
    public var isEnabled: Bool

    public init(id: UUID = UUID(), label: String, code: String, format: CheatFormat, isEnabled: Bool = false) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        self.format = format
        self.isEnabled = isEnabled
    }
}

public enum CheatValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case emptyCode
    case unsupportedFormat
    case malformedCode
}

/// Pixel layout of a software framebuffer exposed by a driver.
public enum FramePixelFormat: Sendable {
    /// 32 bits per pixel, bytes in memory order R, G, B, X (alpha undefined).
    case rgbx8
}

/// Read-only description of a framebuffer produced by the core.
public struct FrameDescriptor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: FramePixelFormat
    /// Display aspect ratio (width / height) the presenter should honour.
    public let aspectRatio: Double

    public init(width: Int, height: Int, bytesPerRow: Int, pixelFormat: FramePixelFormat, aspectRatio: Double) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.aspectRatio = aspectRatio
    }
}

/// Per-second diagnostics sampled by the session (temporary UI only).
public struct EmulationDiagnostics: Equatable, Sendable {
    public var emulationFramesPerSecond: Double = 0
    public var presentedFramesPerSecond: Double = 0
    public var audioSampleRate: Double = 0
    public var audioRunning: Bool = false
    /// Bytes currently queued in the core's audio ring buffer (bounded when the engine consumes).
    public var audioBufferedBytes: Int = 0
    public var audioFramesProduced: UInt64 = 0
    public var audioFramesRequested: UInt64 = 0
    public var audioFramesMissing: UInt64 = 0
    public var audioFramesDiscarded: UInt64 = 0
    public var targetFramesPerSecond: Double = 0
    public var longestFrameMilliseconds: Double = 0
    /// Cheap sampled checksum of the current framebuffer (changes while video is live).
    public var frameChecksum: UInt32 = 0
    public var controllerName: String? = nil
    public var speed: EmulationSpeed = .normal
    /// Rewind ring: entries kept and bytes held (0 when rewind is off or unsupported).
    public var rewindEntries: Int = 0
    public var rewindBytes: Int = 0
    public var rewindRetainedSeconds: TimeInterval = 0
    /// Wall-clock cost of the last state capture (serialize only), in milliseconds.
    public var lastStateCaptureMillis: Double = 0
    /// Wall-clock cost of the last state restore, in milliseconds.
    public var lastStateRestoreMillis: Double = 0

    public init() {}
}
