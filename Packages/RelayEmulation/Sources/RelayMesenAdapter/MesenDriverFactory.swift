// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MesenDriverFactory.swift
//  RelayMesenAdapter
//
//  The only place in Relay that knows the Mesen 2 core exists. Every fact
//  stated here also appears in Resources/CoreManifest.json, which the tests
//  hold this descriptor to.

import Foundation
import RelayDomain
import RelayEmulation

@MainActor
public final class MesenDriverFactory: EmulationDriverFactory {
    public static let coreID: CoreID = "mesen2"

    /// Mesen 2 at the vendored revision (Vendor/Mesen2/RELAY_VENDOR.json).
    /// WonderSwan and WonderSwan Color); Mesen runs more, and each further
    /// system goes through the whole gate in ADDING_A_CORE.md before it is
    /// named here. Capabilities are what the bridge implements:
    /// Relay's own rewind and fast-forward over Mesen's serializer and speed.
    public static let descriptor = EmulatorCoreDescriptor(
        id: coreID,
        name: "Mesen 2",
        version: "2.1.1",
        stateCompatibilityVersion: "mesen2-2.1.1-b9fa69dd-state4",
        license: "GPL-3.0",
        supportedSystems: [.nes, .snes, .masterSystem, .gameGear, .pcEngine, .wonderSwan, .wonderSwanColor],
        capabilities: [.saveStates, .rewind, .fastForward]
    )

    public let availableCores: [EmulatorCoreDescriptor] = [MesenDriverFactory.descriptor]

    public init() {}

    public func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        guard coreID == Self.coreID, Self.descriptor.supports(systemID) else {
            throw EmulationError.coreUnavailable(coreID)
        }
        return MesenDriver(systemID: systemID)
    }
}
