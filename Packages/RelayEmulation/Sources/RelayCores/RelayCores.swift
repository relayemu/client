// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayCores.swift
//  RelayCores
//
//  The cores Relay ships, assembled into one factory. This is the only module
//  the shells import for emulation; adding a core means adding its adapter

import Foundation
import RelayEmulation
import RelayProvenanceAdapter
import RelayMesenAdapter
import RelayMelonAdapter
import RelayPCSXAdapter

public enum RelayCores {
    /// mGBA (Game Boy, Game Boy Color, Game Boy Advance), Mesen 2 (NES, SNES)
    /// and melonDS (Nintendo DS).
    @MainActor
    public static func standardFactory() -> CompositeDriverFactory {
        CompositeDriverFactory([ProvenanceDriverFactory(), MesenDriverFactory(), MelonDriverFactory(), PCSXDriverFactory()])
    }
}
