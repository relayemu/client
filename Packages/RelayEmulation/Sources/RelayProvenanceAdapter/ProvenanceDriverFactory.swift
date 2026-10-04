// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ProvenanceDriverFactory.swift
//  RelayProvenanceAdapter
//
//  The only place in Relay that knows concrete Provenance core classes.
//  Relay registers exactly one core: mGBA (MPL-2.0), built from the
//  Game Boy and Game Boy Color support alongside the Game Boy Advance; every
//  fact stated here also appears in Resources/CoreManifest.json, which the
//  tests hold this descriptor to.

import Foundation
import RelayDomain
import RelayEmulation

@MainActor
public final class ProvenanceDriverFactory: EmulationDriverFactory {
    public static let mgbaCoreID: CoreID = "mgba"

    /// What the integrated mGBA core implements, read from the vendored
    /// package: `Core.plist` `PVCapabilities` (rumble, rewind), the ObjC bridge
    /// (`saveStateToFileAtPath:`/`loadStateFromFileAtPath:`, `setCheat:`), the
    /// RetroAchievements extension, and the generic speed multiplier of
    /// load/run/pause/input; the flags describe the core so higher layers can
    /// plan, not what the shell already offers.
    public static let mgbaDescriptor = EmulatorCoreDescriptor(
        id: mgbaCoreID,
        name: "mGBA",
        version: MGBADriver.upstreamVersion,
        license: "MPL-2.0",
        supportedSystems: [.gameBoy, .gameBoyColor, .gameBoyAdvance],
        capabilities: [.saveStates, .rewind, .cheats, .fastForward, .rumble]
    )

    /// The Provenance system identifier the vendored core expects for each
    /// Relay system. This is the whole of Relay's knowledge of vendor system
    /// names, and it lives here rather than in a driver or a view.
    static func provenanceSystemIdentifier(for system: SystemID) -> String {
        switch system {
        case .gameBoy: return "com.provenance.gb"
        case .gameBoyColor: return "com.provenance.gbc"
        default: return "com.provenance.gba"
        }
    }

    public let availableCores: [EmulatorCoreDescriptor] = [ProvenanceDriverFactory.mgbaDescriptor]

    public init() {}

    public func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        switch coreID {
        case ProvenanceDriverFactory.mgbaCoreID:
            guard ProvenanceDriverFactory.mgbaDescriptor.supports(systemID) else {
                throw EmulationError.coreUnavailable(coreID)
            }
            return MGBADriver(systemID: systemID)
        default:
            throw EmulationError.coreUnavailable(coreID)
        }
    }
}
