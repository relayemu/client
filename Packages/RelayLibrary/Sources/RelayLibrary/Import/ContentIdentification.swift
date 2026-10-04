// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContentIdentification.swift
//  RelayLibrary
//
//  The identification boundary: which system a game file belongs to, decided
//  from the file's bytes where a deterministic check exists, with the file
//  extension as the fallback. Extensible per system: one `SystemContentSignature`
//  per system Relay can identify, each reading the format's own header rather
//  than trusting a file name.

import Foundation
import RelayDomain

public struct ContentIdentification: Hashable, Sendable {
    public enum Confidence: Int, Hashable, Sendable, Comparable {
        /// Only the file extension matched.
        case fileExtension = 0
        /// The file's own header validated for the system.
        case header = 1

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let systemID: SystemID
    public let confidence: Confidence
    /// A title suggested by the content itself (e.g. an internal ROM title), when meaningful.
    public let suggestedTitle: String?

    public init(systemID: SystemID, confidence: Confidence, suggestedTitle: String? = nil) {
        self.systemID = systemID
        self.confidence = confidence
        self.suggestedTitle = suggestedTitle
    }
}

public enum ContentIdentificationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Nothing recognised the file (extension unknown and no header matched).
    case unsupported(fileName: String)
    /// The extension names a system whose header check failed: the file is damaged or not a game.
    case invalid(fileName: String, systemID: SystemID)
    /// More than one system claims the file at equal confidence.
    case ambiguous(fileName: String, candidates: [SystemID])
    case unreadable(fileName: String, reason: String)

    public var description: String {
        switch self {
        case .unsupported(let f): return "'\(f)' is not a supported game file"
        case .invalid(let f, let s): return "'\(f)' is not a valid \(s) game file"
        case .ambiguous(let f, let c): return "'\(f)' matches several systems: \(c)"
        case .unreadable(let f, let r): return "'\(f)' could not be read: \(r)"
        }
    }
}

/// One system's byte-level check.
public protocol SystemContentSignature: Sendable {
    var systemID: SystemID { get }
    /// Maximum bytes needed from the start of the file to decide.
    var headerLength: Int { get }
    /// Bytes needed from the end of the file, for formats whose header is a
    /// footer (WonderSwan). Zero for most systems.
    var footerLength: Int { get }
    /// Returns an identification when `header` (at least `headerLength` bytes unless
    /// the file is shorter) is a valid game for this system; nil otherwise.
    func identify(header: Data, fileSize: Int64) -> ContentIdentification?
    /// As above, with the file's last `footerLength` bytes; the default ignores them.
    func identify(header: Data, footer: Data, fileSize: Int64) -> ContentIdentification?
    /// A last check that needs the whole file (a checksum over it). Runs only
    /// for a header match, so it costs nothing on unrelated files. Default: true.
    func confirm(fileAt url: URL) -> Bool
    /// True when the signature has no magic bytes or checksum to verify (a
    /// plausibility check only). A heuristic match never overrides a verified
    /// one. Default: false.
    var isHeuristic: Bool { get }
}

public extension SystemContentSignature {
    var footerLength: Int { 0 }
    func identify(header: Data, footer: Data, fileSize: Int64) -> ContentIdentification? {
        identify(header: header, fileSize: fileSize)
    }
    func confirm(fileAt url: URL) -> Bool { true }
    var isHeuristic: Bool { false }
}

/// Combines byte signatures with the catalog's extension table.
///
/// Rules:
/// 1. every registered signature is tried; header matches win, and a verified
///    match (magic bytes, checksum) outranks a heuristic one;
/// 2. if none matched and the extension names exactly one system: when that
///    system has a signature the file is `invalid`, otherwise it is accepted
///    at `.fileExtension` confidence;
/// 3. otherwise `unsupported` (or `ambiguous` when several systems share the extension).
public struct ContentIdentifier: Sendable {
    private let signatures: [any SystemContentSignature]

    public init(signatures: [any SystemContentSignature]) {
        self.signatures = signatures
    }

    /// Relay's default: a byte signature for every system it can play, plus
    /// the catalog's extension table for everything else.
    public static let standard = ContentIdentifier(signatures: [
        GBAHeaderSignature(),
        GameBoyHeaderSignature(),
        INESHeaderSignature(),
        SNESHeaderSignature(),
        NDSHeaderSignature(),
        SegaHeaderSignature(),
        PCEngineHuCardSignature(),
        WonderSwanFooterSignature(),
    ])

    public func identify(fileAt url: URL) throws -> ContentIdentification {
        let fileName = url.lastPathComponent
        let size: Int64
        let header: Data
        let footer: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let needed = max(signatures.map(\.headerLength).max() ?? 0,
                             url.pathExtension.lowercased() == "iso" ? 96 * 1024 : 0)
            header = try handle.read(upToCount: needed) ?? Data()
            let tail = signatures.map(\.footerLength).max() ?? 0
            if tail > 0, size > Int64(tail) {
                try handle.seek(toOffset: UInt64(size - Int64(tail)))
                footer = try handle.read(upToCount: tail) ?? Data()
            } else if tail > 0 {
                footer = header.suffix(Int(min(size, Int64(tail))))
            } else {
                footer = Data()
            }
        } catch {
            throw ContentIdentificationError.unreadable(fileName: fileName, reason: error.localizedDescription)
        }

        // A Sony PS3 volume is not a PSP image. Reject the known unsupported
        // disc before extension fallback or cartridge heuristics can claim it.
        // This bounded header inspection does not hash or load the whole ISO.
        if url.pathExtension.lowercased() == "iso", header.count >= 32774,
           header.subdata(in: 32769..<32774) == Data("CD001".utf8),
           header.range(of: Data("PLAYSTATION(R)3".utf8)) != nil {
            throw ContentIdentificationError.unsupported(fileName: fileName)
        }

        let matches = signatures.compactMap { signature -> (match: ContentIdentification, heuristic: Bool)? in
            guard let match = signature.identify(header: header, footer: footer, fileSize: size) else { return nil }
            return signature.confirm(fileAt: url) ? (match, signature.isHeuristic) : nil
        }
        // A verified header (magic bytes and a checksum) outranks a plausibility
        // check: the HuCard test alone accepts about one cartridge in eight.
        let verified = matches.filter { !$0.heuristic }
        let headerMatches = (verified.isEmpty ? matches : verified).map(\.match)
        if headerMatches.count == 1 { return headerMatches[0] }
        if headerMatches.count > 1 {
            throw ContentIdentificationError.ambiguous(fileName: fileName, candidates: headerMatches.map(\.systemID))
        }

        let byExtension = SystemCatalog.systems(forFileExtension: url.pathExtension)
        switch byExtension.count {
        case 0:
            throw ContentIdentificationError.unsupported(fileName: fileName)
        case 1:
            let descriptor = byExtension[0]
            if signatures.contains(where: { $0.systemID == descriptor.id }) {
                throw ContentIdentificationError.invalid(fileName: fileName, systemID: descriptor.id)
            }
            // Nothing has claimed these bytes, so the extension is the only
            // claim. A system Relay cannot play stays recognisable this way
            // (RELAY_SYSTEM_SUPPORT: recognised on import, never launched), but
            // the file still has to look like a game image: a README.md is a
            // document, not a Mega Drive cartridge (B2-IMP-001).
            guard Self.looksLikeGameImage(header) else {
                throw ContentIdentificationError.unsupported(fileName: fileName)
            }
            return ContentIdentification(systemID: descriptor.id, confidence: .fileExtension)
        default:
            throw ContentIdentificationError.ambiguous(fileName: fileName, candidates: byExtension.map(\.id))
        }
    }

    /// Bounded, format-free check for the extension fallback. Every system Relay
    /// recognises without a byte signature stores a binary image, so a file whose
    /// opening bytes are ordinary text is a document. Reads only bytes that the
    /// caller already loaded; never re-reads the file.
    static func looksLikeGameImage(_ header: Data) -> Bool {
        let sample = [UInt8](header.prefix(textSampleLength))
        guard !sample.isEmpty else { return false }
        // ROM, disc and archive images all carry NUL padding or binary headers
        // within their first bytes.
        if sample.contains(0) { return true }
        let looksLikeText = sample.allSatisfy { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D
                || (0x20...0x7E).contains(byte)   // printable ASCII
                || byte >= 0x80                   // UTF-8 continuation bytes
        }
        return !looksLikeText
    }

    /// The extension fallback only needs enough bytes to tell a document from an
    /// image; the whole file is never read.
    static let textSampleLength = 1024
}

/// Game Boy Advance cartridge header (offsets 0xA0–0xBF): fixed byte 0x96 at
/// 0xB2 and the header complement checksum at 0xBD, which every bootable ROM
/// (commercial or homebrew) carries because the console's BIOS verifies it.
/// Nintendo's logo bitmap is deliberately not embedded here.
public struct GBAHeaderSignature: SystemContentSignature {
    public let systemID: SystemID = .gameBoyAdvance
    public let headerLength = 0xC0
    /// Cartridges are at most 32 MiB.
    public static let maxSize: Int64 = 32 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard header.count >= headerLength, fileSize <= Self.maxSize else { return nil }
        let bytes = [UInt8](header.prefix(headerLength))
        guard bytes[0xB2] == 0x96 else { return nil }
        // Entry point must be an ARM branch (opcode 0xEA in the top byte).
        guard bytes[3] == 0xEA else { return nil }
        var sum: UInt32 = 0
        for i in 0xA0...0xBC { sum &+= UInt32(bytes[i]) }
        let expected = UInt8(truncatingIfNeeded: (0 &- (sum &+ 0x19)) & 0xFF)
        guard bytes[0xBD] == expected else { return nil }
        let titleBytes = bytes[0xA0..<0xAC].prefix { $0 != 0 }
        let title = String(bytes: titleBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        return ContentIdentification(systemID: systemID, confidence: .header,
                                     suggestedTitle: (title?.isEmpty == false) ? title : nil)
    }
}


/// Game Boy / Game Boy Color cartridge header (0x100–0x14F).
///
/// Two deterministic checks, both of which every bootable cartridge satisfies:
///
/// * bytes 0x104–0x107 are `CE ED 66 66`, the start of the header's logo area.
///   This is the same four-byte magic mGBA's own `GBIsROM` matches, and it is
///   what distinguishes a Game Boy image from an arbitrary binary. Relay reads
///   these four bytes; it does not ship them.
/// * the header checksum at 0x14D, which the boot ROM verifies, so no
///   commercial or homebrew cartridge can have it wrong.
///
/// Colour is decided by the cartridge's own flag at 0x143, not by the file
/// name: a `.gb` file that declares Game Boy Color support is a Game Boy Color
/// game and is identified as one.
public struct GameBoyHeaderSignature: SystemContentSignature {
    /// Reported per file; the identifier below picks `gb` or `gbc`.
    public let systemID: SystemID = .gameBoy
    public let headerLength = 0x150
    /// The largest Game Boy cartridges hold 8 MiB.
    public static let maxSize: Int64 = 8 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard header.count >= headerLength, fileSize <= Self.maxSize else { return nil }
        let bytes = [UInt8](header.prefix(headerLength))
        guard bytes[0x104] == 0xCE, bytes[0x105] == 0xED,
              bytes[0x106] == 0x66, bytes[0x107] == 0x66 else { return nil }

        // Header checksum: x = x - byte - 1 across 0x134...0x14C.
        var checksum: UInt8 = 0
        for index in 0x134...0x14C { checksum = checksum &- bytes[index] &- 1 }
        guard checksum == bytes[0x14D] else { return nil }

        // 0x80 means the cartridge uses colour where the hardware has it;
        // 0xC0 means it needs colour. Either way it is a Game Boy Color game.
        let colourFlag = bytes[0x143]
        let system: SystemID = (colourFlag == 0x80 || colourFlag == 0xC0) ? .gameBoyColor : .gameBoy

        // The title occupies 0x134 up to the colour flag; a colour cartridge
        // may use the last four bytes for a manufacturer code, so stop at the
        // first zero either way.
        let titleBytes = bytes[0x134..<0x143].prefix { $0 >= 0x20 && $0 < 0x7F }
        let title = String(bytes: titleBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        return ContentIdentification(systemID: system, confidence: .header,
                                     suggestedTitle: (title?.isEmpty == false) ? title : nil)
    }
}

/// iNES / NES 2.0 container (the format every NES image on disk uses): the
/// four-byte magic `NES<EOF>` and a program size, followed by exactly the
/// program and character banks the header declares. Raw cartridge dumps
/// without the container do not exist in practice, so a `.nes` file whose
/// header is wrong is damaged, not "raw".
public struct INESHeaderSignature: SystemContentSignature {
    public let systemID: SystemID = .nes
    public let headerLength = 16
    /// The largest licensed cartridges are 1 MiB; homebrew mappers go further.
    public static let maxSize: Int64 = 8 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard header.count >= headerLength, fileSize <= Self.maxSize else { return nil }
        let bytes = [UInt8](header.prefix(headerLength))
        guard bytes[0] == 0x4E, bytes[1] == 0x45, bytes[2] == 0x53, bytes[3] == 0x1A else { return nil }
        let isNES2 = (bytes[7] & 0x0C) == 0x08
        var programBanks = Int(bytes[4])
        var characterBanks = Int(bytes[5])
        if isNES2 {
            // NES 2.0 keeps a fourth nibble of each size in byte 9; the exponent
            // encoding (nibble 0xF) is rare enough to leave to the core.
            guard bytes[9] & 0x0F != 0x0F, bytes[9] >> 4 != 0x0F else { return nil }
            programBanks |= Int(bytes[9] & 0x0F) << 8
            characterBanks |= Int(bytes[9] >> 4) << 8
        }
        guard programBanks > 0 else { return nil }
        let trainer: Int64 = (bytes[6] & 0x04) != 0 ? 512 : 0
        let expected = Int64(headerLength) + trainer + Int64(programBanks) * 16_384 + Int64(characterBanks) * 8_192
        // iNES 1 files sometimes carry a few trailing bytes of junk; never fewer bytes than declared.
        guard fileSize >= expected, fileSize - expected < 16_384 else { return nil }
        return ContentIdentification(systemID: systemID, confidence: .header, suggestedTitle: nil)
    }
}

/// Super NES cartridge header, at `0x7FC0` (LoROM) or `0xFFC0` (HiROM), with
/// or without a 512-byte copier header in front. The console's boot code does
/// not verify anything, so the check is the one every emulator uses to find
/// the header: the checksum and its complement at the end of the header must
/// sum to `0xFFFF`, and the map-mode and ROM-size bytes must be plausible.
public struct SNESHeaderSignature: SystemContentSignature {
    public let systemID: SystemID = .snes
    /// Enough for the HiROM header behind a copier header.
    public let headerLength = 0x200 + 0x10000
    /// Licensed cartridges reach 6 MB (ExHiROM); homebrew stays well below.
    public static let maxSize: Int64 = 16 * 1024 * 1024
    static let headerOffsets = [0x7FC0, 0xFFC0, 0x40FFC0]

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard fileSize >= 0x8000, fileSize <= Self.maxSize else { return nil }
        let copier = fileSize % 1024 == 512 ? 0x200 : 0
        let bytes = [UInt8](header)
        for base in Self.headerOffsets {
            let start = base + copier
            guard start + 0x20 <= bytes.count, Int64(start + 0x20) <= fileSize else { continue }
            let h = Array(bytes[start..<start + 0x20])
            let complement = UInt16(h[0x1C]) | UInt16(h[0x1D]) << 8
            let checksum = UInt16(h[0x1E]) | UInt16(h[0x1F]) << 8
            guard checksum ^ complement == 0xFFFF, checksum != 0, complement != 0 else { continue }
            // Map mode: bit 5 is always set; bit 4 is the speed flag.
            let mapMode = h[0x15] & ~0x10
            guard [0x20, 0x21, 0x22, 0x23, 0x25, 0x2A].contains(mapMode) else { continue }
            // ROM size is log2(KiB): 32 KiB (5) up to 8 MiB (13).
            guard (5...13).contains(h[0x17]) else { continue }
            let titleBytes = h[0..<21].prefix { $0 >= 0x20 && $0 < 0x7F }
            let title = String(bytes: titleBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            return ContentIdentification(systemID: systemID, confidence: .header,
                                         suggestedTitle: (title?.isEmpty == false) ? title : nil)
        }
        return nil
    }
}

/// Nintendo DS cartridge header (the first 0x160 bytes of every image): the
/// CRC-16 at 0x15E covers the bytes before it, and the console's boot code
/// refuses a cartridge whose value is wrong, so every bootable image carries
/// it. The ARM9 and ARM7 binary offsets must also lie inside the file.
public struct NDSHeaderSignature: SystemContentSignature {
    public let systemID: SystemID = .nintendoDS
    public let headerLength = 0x160
    /// Cartridges reach 512 MB.
    public static let maxSize: Int64 = 512 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard header.count >= headerLength, fileSize <= Self.maxSize else { return nil }
        let bytes = [UInt8](header.prefix(headerLength))
        var crc: UInt16 = 0xFFFF
        for byte in bytes[0..<0x15E] {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        let stored = UInt16(bytes[0x15E]) | UInt16(bytes[0x15F]) << 8
        guard crc == stored else { return nil }
        func word(_ offset: Int) -> Int64 {
            Int64(bytes[offset]) | Int64(bytes[offset + 1]) << 8 | Int64(bytes[offset + 2]) << 16 | Int64(bytes[offset + 3]) << 24
        }
        let arm9Offset = word(0x20), arm9Size = word(0x2C), arm7Offset = word(0x30), arm7Size = word(0x3C)
        guard arm9Offset >= 0x200, arm9Offset + arm9Size <= fileSize,
              arm7Offset >= 0x200, arm7Offset + arm7Size <= fileSize else { return nil }
        let titleBytes = bytes[0..<12].prefix { $0 >= 0x20 && $0 < 0x7F }
        let title = String(bytes: titleBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        return ContentIdentification(systemID: systemID, confidence: .header,
                                     suggestedTitle: (title?.isEmpty == false) ? title : nil)
    }
}

/// Sega Master System and Game Gear cartridge header ("TMR SEGA" at 0x7FF0,
/// or 0x3FF0 / 0x1FF0 on small cartridges). The export console's BIOS refuses
/// a cartridge without it, so every bootable image carries the magic; the
/// region code in the last byte says which console: 3 and 4 are Master System
/// (Japan, export), 5, 6 and 7 are Game Gear. Nothing else is trusted: the
/// header checksum is wrong on many real cartridges and never verified by the
/// Game Gear.
public struct SegaHeaderSignature: SystemContentSignature {
    /// Reported per file; the identifier below picks `sms` or `gg`.
    public let systemID: SystemID = .masterSystem
    public let headerLength = 0x8000
    /// The largest cartridges are 1 MiB; homebrew mappers reach 4 MiB.
    public static let maxSize: Int64 = 4 * 1024 * 1024
    static let headerOffsets = [0x7FF0, 0x3FF0, 0x1FF0]

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard fileSize >= 0x2000, fileSize <= Self.maxSize else { return nil }
        let bytes = [UInt8](header)
        let magic: [UInt8] = Array("TMR SEGA".utf8)
        for offset in Self.headerOffsets where offset + 16 <= bytes.count {
            guard Array(bytes[offset..<offset + 8]) == magic else { continue }
            let region = bytes[offset + 15] >> 4
            switch region {
            case 3, 4: return ContentIdentification(systemID: .masterSystem, confidence: .header)
            case 5, 6, 7: return ContentIdentification(systemID: .gameGear, confidence: .header)
            default: return nil
            }
        }
        return nil
    }
}

/// PC Engine HuCard. HuCards carry no header at all, so the check is the one
/// the hardware performs implicitly: the image is whole 8 KiB banks (with or
/// without a 512-byte copier header), and the reset vector at the end of the
/// first bank, which the CPU maps at $E000–$FFFF on power-up, points into that
/// bank. A random binary usually fails, but about one image in eight of
/// another system passes by chance, so this signature is heuristic: any
/// verified header wins over it. A `.pce` file that fails is damaged, not "raw".
public struct PCEngineHuCardSignature: SystemContentSignature {
    public let systemID: SystemID = .pcEngine
    public let isHeuristic = true
    public let headerLength = 0x200 + 0x2000
    /// The largest HuCards (Street Fighter II') are 2.5 MB.
    public static let maxSize: Int64 = 4 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? {
        guard fileSize >= 0x2000, fileSize <= Self.maxSize else { return nil }
        let copier: Int
        switch fileSize % 0x2000 {
        case 0: copier = 0
        case 0x200: copier = 0x200
        default: return nil
        }
        let bytes = [UInt8](header)
        let vector = copier + 0x1FFE
        guard vector + 1 < bytes.count else { return nil }
        let target = UInt16(bytes[vector]) | UInt16(bytes[vector + 1]) << 8
        guard target >= 0xE000 else { return nil }
        return ContentIdentification(systemID: systemID, confidence: .header)
    }
}

/// WonderSwan cartridge footer: the last sixteen bytes of the image, which the
/// console's boot ROM reads and whose checksum it verifies (the sum of every
/// byte before the last two, little-endian). Byte 7 of the footer says whether
/// the game needs the Color hardware; that, not the file name, decides between
/// WonderSwan and WonderSwan Color.
public struct WonderSwanFooterSignature: SystemContentSignature {
    /// Reported per file; the identifier below picks `ws` or `wsc`.
    public let systemID: SystemID = .wonderSwan
    public let headerLength = 0
    public let footerLength = 16
    /// Cartridges reach 16 MB (128 Mbit).
    public static let maxSize: Int64 = 16 * 1024 * 1024

    public init() {}

    public func identify(header: Data, fileSize: Int64) -> ContentIdentification? { nil }

    public func identify(header: Data, footer: Data, fileSize: Int64) -> ContentIdentification? {
        guard footer.count == 16, fileSize >= 0x20000, fileSize <= Self.maxSize,
              fileSize & (fileSize - 1) == 0 else { return nil }
        return Self.identify(footer: [UInt8](footer))
    }

    /// The checksum covers the whole image, so it is verified here, once the
    /// footer's fields already look like a cartridge.
    public func confirm(fileAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 16 else { return false }
        var sum: UInt16 = 0
        data.withUnsafeBytes { raw in
            for byte in raw[0..<(raw.count - 2)] { sum &+= UInt16(byte) }
        }
        let stored = UInt16(data[data.count - 2]) | UInt16(data[data.count - 1]) << 8
        return sum == stored
    }

    static func identify(footer f: [UInt8]) -> ContentIdentification? {
        // Byte 0 must be the far jump the CPU starts on at FFFF:0000.
        guard f[0] == 0xEA else { return nil }
        let romSizeCode = f[10], saveType = f[11], flags = f[12]
        guard (0x00...0x09).contains(romSizeCode) else { return nil }
        guard [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x20, 0x50].contains(saveType) else { return nil }
        guard flags & 0xF0 == 0 else { return nil }
        let colour = f[7] & 0x01 == 1
        return ContentIdentification(systemID: colour ? .wonderSwanColor : .wonderSwan, confidence: .header)
    }
}
