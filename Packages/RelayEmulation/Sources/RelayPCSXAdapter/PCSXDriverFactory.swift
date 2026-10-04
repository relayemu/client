// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import RelayDomain
import RelayEmulation

@MainActor
public final class PCSXDriverFactory: EmulationDriverFactory {
    public static let coreID: CoreID = "pcsx-rearmed"
    public static let descriptor = EmulatorCoreDescriptor(
        id: coreID, name: "PCSX-ReARMed", version: "r26-da2cb8e",
        stateCompatibilityVersion: "pcsx-da2cb8e-relay1",
        license: "GPL-2.0-or-later", supportedSystems: [.playStation],
        capabilities: [.saveStates, .fastForward, .analogInput, .diskSwap])
    public let availableCores = [PCSXDriverFactory.descriptor]
    public init() {}
    public func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        guard coreID == Self.coreID, systemID == .playStation else { throw EmulationError.coreUnavailable(coreID) }
        return PCSXDriver()
    }
}
