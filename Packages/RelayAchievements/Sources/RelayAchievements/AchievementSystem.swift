// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayAchievementInterfaces
import CRetroAchievements

/// Central mapping of Relay identities to the pinned official console IDs.
/// Unsupported systems never hash, contact RA or install a frame callback.
public enum AchievementSystem {
    public static func isEligible(_ system: SystemID) -> Bool { consoleID(system) != nil }
    static func consoleID(_ system: SystemID) -> UInt32? {
        switch system {
        case .gameBoy: return UInt32(RC_CONSOLE_GAMEBOY)
        case .gameBoyColor: return UInt32(RC_CONSOLE_GAMEBOY_COLOR)
        case .gameBoyAdvance: return UInt32(RC_CONSOLE_GAMEBOY_ADVANCE)
        case .nes: return UInt32(RC_CONSOLE_NINTENDO)
        case .snes: return UInt32(RC_CONSOLE_SUPER_NINTENDO)
        case .nintendoDS: return UInt32(RC_CONSOLE_NINTENDO_DS)
        case .masterSystem: return UInt32(RC_CONSOLE_MASTER_SYSTEM)
        case .gameGear: return UInt32(RC_CONSOLE_GAME_GEAR)
        case .pcEngine: return UInt32(RC_CONSOLE_PC_ENGINE)
        case .wonderSwan, .wonderSwanColor: return UInt32(RC_CONSOLE_WONDERSWAN)
        default: return nil
        }
    }

    /// Maps official RA addresses to core-native regions. Each span is bounded
    /// before invoking the core reader, including reads crossing region edges.
    /// Source: pinned rcheevos src/rcheevos/consoleinfo.c.
    static func read(system: SystemID, address: UInt32, buffer: UnsafeMutableRawBufferPointer,
                     using reader: AchievementMemoryReader) -> Int {
        var count = 0
        while count < buffer.count {
            let (next, overflow) = address.addingReportingOverflow(UInt32(clamping: count))
            guard !overflow, let span = span(system: system, address: next) else { break }
            let size = min(buffer.count - count, Int(span.end - next) + 1)
            let target = UnsafeMutableRawBufferPointer(rebasing: buffer[count..<(count + size)])
            let read = reader(span.region, span.offset, target)
            guard read > 0, read <= size else { break }
            count += read
            if read < size { break }
        }
        return count
    }

    private struct Span {
        let region: AchievementMemoryRegion
        let offset: UInt32
        let end: UInt32
    }
    private static func span(system: SystemID, address a: UInt32) -> Span? {
        switch system {
        case .gameBoyAdvance:
            if a < 0x8000 { return .init(region: .internalRAM, offset: a, end: 0x7fff) }
            if a < 0x48000 { return .init(region: .workRAM, offset: a - 0x8000, end: 0x47fff) }
            if a < 0x58000 { return .init(region: .saveRAM, offset: a - 0x48000, end: 0x57fff) }
        case .gameBoy, .gameBoyColor:
            if a < 0xa000 { return .init(region: .addressSpace, offset: a, end: 0x9fff) }
            if a < 0xc000 { return .init(region: .saveRAM, offset: a - 0xa000, end: 0xbfff) }
            if a < 0xe000 { return .init(region: .workRAM, offset: a - 0xc000, end: 0xdfff) }
            if a < 0xfe00 { return .init(region: .workRAM, offset: a - 0xe000, end: 0xfdff) }
            if a < 0xfea0 || (a >= 0xff00 && a < 0x10000) { return .init(region: .addressSpace, offset: a, end: a < 0xfea0 ? 0xfe9f : 0xffff) }
            if a >= 0x10000 && a < 0x16000 && system == .gameBoyColor {
                return .init(region: .workRAM, offset: a - 0x10000 + 0x2000, end: 0x15fff)
            }
            if a >= 0x16000 && a < 0x34000 { return .init(region: .saveRAM, offset: a - 0x16000 + 0x2000, end: 0x33fff) }
        case .nes:
            if a < 0x10000 { return .init(region: .addressSpace, offset: a, end: 0xffff) }
        case .snes:
            if a < 0x20000 { return .init(region: .workRAM, offset: a, end: 0x1ffff) }
            if a < 0xa0000 { return .init(region: .saveRAM, offset: a - 0x20000, end: 0x9ffff) }
            if a < 0xa0800 { return .init(region: .auxiliaryRAM, offset: a - 0xa0000, end: 0xa07ff) }
        case .nintendoDS:
            if a < 0x400000 { return .init(region: .workRAM, offset: a, end: 0x3fffff) }
            if a >= 0x1000000 && a < 0x1004000 { return .init(region: .internalRAM, offset: a - 0x1000000, end: 0x1003fff) }
        case .masterSystem, .gameGear:
            if a < 0x2000 { return .init(region: .workRAM, offset: a, end: 0x1fff) }
            if a < 0xa000 { return .init(region: .saveRAM, offset: a - 0x2000, end: 0x9fff) }
        case .pcEngine:
            if a < 0x2000 { return .init(region: .workRAM, offset: a, end: 0x1fff) }
        case .wonderSwan, .wonderSwanColor:
            if a < 0x10000 { return .init(region: .workRAM, offset: a, end: 0xffff) }
            if a < 0x90000 { return .init(region: .saveRAM, offset: a - 0x10000, end: 0x8ffff) }
        default: break
        }
        return nil
    }
}
