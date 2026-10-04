// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CompositeDriverFactory.swift
//  RelayEmulation
//
//  One factory over several adapters. The shells and the launch resolver see
//  a single list of cores; which adapter owns a core is an adapter detail.

import Foundation
import RelayDomain

@MainActor
public final class CompositeDriverFactory: EmulationDriverFactory {
    private let factories: [any EmulationDriverFactory]

    public init(_ factories: [any EmulationDriverFactory]) {
        self.factories = factories
    }

    public var availableCores: [EmulatorCoreDescriptor] {
        factories.flatMap(\.availableCores)
    }

    public func makeDriver(coreID: CoreID, systemID: SystemID) throws -> any EmulationDriver {
        for factory in factories where factory.availableCores.contains(where: { $0.id == coreID }) {
            return try factory.makeDriver(coreID: coreID, systemID: systemID)
        }
        throw EmulationError.coreUnavailable(coreID)
    }
}
