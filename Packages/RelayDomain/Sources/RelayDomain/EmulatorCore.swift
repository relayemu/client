// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  EmulatorCore.swift
//  RelayDomain
//
//  Relay-owned description of an emulator core and what it can do. The UI and
//  the library must ask `capabilities`, never compare core names.

import Foundation

/// What an emulator core (or a session running it) can do. Flags describe the
/// core implementation Relay integrates; a feature is only offered to the user
/// once the Relay layer above the core also implements it.
public struct CoreCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let saveStates = CoreCapabilities(rawValue: 1 << 0)
    public static let rewind = CoreCapabilities(rawValue: 1 << 1)
    public static let cheats = CoreCapabilities(rawValue: 1 << 2)
    public static let fastForward = CoreCapabilities(rawValue: 1 << 3)
    public static let analogInput = CoreCapabilities(rawValue: 1 << 4)
    public static let touchInput = CoreCapabilities(rawValue: 1 << 5)
    public static let microphone = CoreCapabilities(rawValue: 1 << 6)
    public static let rumble = CoreCapabilities(rawValue: 1 << 7)
    public static let multipleScreens = CoreCapabilities(rawValue: 1 << 8)
    public static let diskSwap = CoreCapabilities(rawValue: 1 << 9)
    public static let achievements = CoreCapabilities(rawValue: 1 << 10)
    public static let jit = CoreCapabilities(rawValue: 1 << 11)

    /// Every defined flag, in bit order.
    public static let allKnown: [(CoreCapabilities, String)] = [
        (.saveStates, "saveStates"), (.rewind, "rewind"), (.cheats, "cheats"),
        (.fastForward, "fastForward"), (.analogInput, "analogInput"), (.touchInput, "touchInput"),
        (.microphone, "microphone"), (.rumble, "rumble"), (.multipleScreens, "multipleScreens"),
        (.diskSwap, "diskSwap"), (.achievements, "achievements"), (.jit, "jit"),
    ]

    /// Names of the set flags (diagnostics only).
    public var names: [String] {
        Self.allKnown.filter { contains($0.0) }.map(\.1)
    }
}

/// Describes one emulator core implementation available to Relay.
public struct EmulatorCoreDescriptor: Hashable, Codable, Sendable, Identifiable {
    public let id: CoreID
    /// Human-readable name (diagnostics and Settings → Advanced only).
    public let name: String
    /// Upstream version string of the integrated core. Save states record it.
    public let version: String
    /// Identifier of the core's save-state format compatibility class. Two
    /// builds of a core that restore each other's states safely may declare
    /// the same value; by default every core version is its own class. A
    /// state is restorable only by a core with the same id and the same
    /// compatibility version (never assumed, always declared).
    public let stateCompatibilityVersion: String
    public let license: String
    /// Systems the core can run.
    public let supportedSystems: [SystemID]
    public let capabilities: CoreCapabilities

    public init(id: CoreID, name: String, version: String, stateCompatibilityVersion: String? = nil, license: String,
                supportedSystems: [SystemID], capabilities: CoreCapabilities) {
        self.id = id
        self.name = name
        self.version = version
        self.stateCompatibilityVersion = stateCompatibilityVersion ?? version
        self.license = license
        self.supportedSystems = supportedSystems
        self.capabilities = capabilities
    }

    public func supports(_ system: SystemID) -> Bool { supportedSystems.contains(system) }
}
