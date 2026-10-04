// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SystemAccent.swift
//
//  Sixteen Relay-owned hues; systems are assigned in ONE table so a
//  reassignment (trademark review, final system list) is a one-line change.
//  Ember is never a system colour.

import SwiftUI
import RelayDomain

public enum SystemHue: String, CaseIterable, Sendable {
    case amber, gold, olive, sage, jade, teal, cyan, sky, cobalt, indigo, violet, orchid, magenta, rose, brick

    /// Glyph/text/spine colour.
    public var accent: Color { RelayColor.dynamic(light: values.light, dark: values.dark) }
    /// Background tint for placeholders and grounds.
    public var tint: Color { RelayColor.dynamic(light: values.lightTint, dark: values.darkTint) }

    /// The hue at watermark strength, for the short name printed across a
    /// placeholder. A pale light tint swallows a wash that a dark ground carries,
    /// so light needs more of the hue to read as deliberate rather than as a smudge.
    public var watermark: Color {
        RelayColor.dynamic(light: values.light, dark: values.dark, lightAlpha: 0.30, darkAlpha: 0.20)
    }

    /// The hue at mark strength, for the Baton ghosted on a placeholder.
    public var ghost: Color {
        RelayColor.dynamic(light: values.light, dark: values.dark, lightAlpha: 0.62, darkAlpha: 0.50)
    }

    struct Values { let dark: UInt32; let light: UInt32; let darkTint: UInt32; let lightTint: UInt32 }

    var values: Values {
        switch self {
        case .amber:   return Values(dark: 0xE29767, light: 0x9F6036, darkTint: 0x412615, lightTint: 0xF9E3D6)
        case .gold:    return Values(dark: 0xD3A056, light: 0x936823, darkTint: 0x3C2A0E, lightTint: 0xF4E6D2)
        case .olive:   return Values(dark: 0xBEAB54, light: 0x827120, darkTint: 0x352E0D, lightTint: 0xEDE8D2)
        case .sage:    return Values(dark: 0xA2B563, light: 0x6A7A31, darkTint: 0x2B3113, lightTint: 0xE5EBD5)
        case .jade:    return Values(dark: 0x81BD7C, light: 0x4D8049, darkTint: 0x1E341D, lightTint: 0xDDEDDB)
        case .teal:    return Values(dark: 0x5FC199, light: 0x288463, darkTint: 0x103627, lightTint: 0xD6EFE3)
        case .cyan:    return Values(dark: 0x43C1B7, light: 0x00847C, darkTint: 0x043632, lightTint: 0xD3EFEB)
        case .sky:     return Values(dark: 0x41BDD1, light: 0x008192, darkTint: 0x03343C, lightTint: 0xD2EEF3)
        case .cobalt:  return Values(dark: 0x5AB7E5, light: 0x237BA2, darkTint: 0x0F3243, lightTint: 0xD5ECF9)
        case .indigo:  return Values(dark: 0x7AAEEF, light: 0x4773AB, darkTint: 0x1C2F46, lightTint: 0xDBE9FC)
        case .violet:  return Values(dark: 0x9AA4F0, light: 0x646BAB, darkTint: 0x282B47, lightTint: 0xE2E7FC)
        case .orchid:  return Values(dark: 0xB59BE6, light: 0x7B63A3, darkTint: 0x322843, lightTint: 0xEBE4FA)
        case .magenta: return Values(dark: 0xCC93D4, light: 0x8D5D94, darkTint: 0x3A253D, lightTint: 0xF2E2F4)
        case .rose:    return Values(dark: 0xDC8EBB, light: 0x9A587F, darkTint: 0x402334, lightTint: 0xF8E0EC)
        case .brick:   return Values(dark: 0xE68D9E, light: 0xA25767, darkTint: 0x432329, lightTint: 0xFBE0E4)
        }
    }
}

public enum SystemAccent {
    /// parent's hue: the family reads as one, and the chip says which.
    public static let assignments: [SystemID: SystemHue] = [
        .masterSystem: .amber,
        .megaDrive: .gold,
        .wonderSwan: .olive,
        .wonderSwanColor: .olive,
        .gameBoy: .sage,
        .nintendo64: .jade,
        .playStationPortable: .teal,
        .gameGear: .cyan,
        .nintendoDS: .sky,
        .playStation: .cobalt,
        .gameBoyAdvance: .indigo,
        .snes: .violet,
        .gameBoyColor: .orchid,
        .neoGeoPocket: .magenta,
        .neoGeoPocketColor: .magenta,
        .pcEngine: .rose,
        .pcEngineCD: .rose,
        .nes: .brick,
    ]

    /// Hue for a system; unassigned systems get a stable hue derived from their id.
    public static func hue(for system: SystemID) -> SystemHue {
        if let assigned = assignments[system] { return assigned }
        let hues = SystemHue.allCases
        var hash: UInt32 = 2_166_136_261
        for byte in system.rawValue.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hues[Int(hash % UInt32(hues.count))]
    }
}
