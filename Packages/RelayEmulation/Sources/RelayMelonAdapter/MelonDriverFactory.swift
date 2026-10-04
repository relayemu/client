// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MelonDriverFactory.swift
//  RelayMelonAdapter
//
//  The only place in Relay that knows the melonDS core exists. Every fact
//  stated here also appears in Resources/CoreManifest.json, which the tests
//  hold this descriptor to.

import Foundation
import RelayDomain
import RelayEmulation

@MainActor
public final class MelonDriverFactory: EmulationDriverFactory {
    public static let coreID: CoreID = "melonds"

    /// melonDS at the vendored revision (Vendor/melonDS/RELAY_VENDOR.json),
    /// interpreter only (no JIT), software rendering, the project's free BIOS
    /// and generated firmware: no Nintendo file is needed or read.
    public static let descriptor = EmulatorCoreDescriptor(
        id: coreID,
        name: "melonDS",
        version: "1.1",
        stateCompatibilityVersion: "melonds-1.1-906e9ebb-state1",
        license: "GPL-3.0-or-later",
        supportedSystems: [.nintendoDS],
        capabilities: [.saveStates, .rewind, .fastForward, .touchInput, .multipleScreens]
    )

    public let availableCores: [EmulatorCoreDescriptor] = [MelonDriverFactory.descriptor]

    public init() {}

    public func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        guard coreID == Self.coreID, Self.descriptor.supports(systemID) else {
            throw EmulationError.coreUnavailable(coreID)
        }
        return MelonDriver(systemID: systemID)
    }
}
