// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import RelayDomain
import RelayDiscCodec

public enum PlayStationImportError: Error, Equatable, Sendable {
    case missingFiles
    case invalidDisc
    case unsupportedDisc
    case tooLarge
    case unsafePath
    case damagedPackage
}

/// One deterministic, streamed blob fits the existing GameFile and content-sync
/// contract. Its SHA-256 is the game identity. Original filenames never enter
/// these bytes. Track boundaries, disc order and all track bytes do.
public enum PlayStationDiscPackage {
    public static let fileExtension = "relaydisc"
    public static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
    public static let maximumDiscs = 8
    private static let magic = Data("RLYDISC1".utf8)
    private static let headerLimit = 256 * 1024
    private struct Entry: Codable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
    }
    private struct Header: Codable {
        let version: Int
        let discs: [String]
        let entries: [Entry]
    }
    private struct Member { let name: String; let source: URL }

    /// All files must already be in private staging. The caller owns access to
    /// original selected URLs; this reader never reaches into their neighbours.
    public static func build(from source: URL, in staging: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try buildSynchronously(from: source, in: staging)
        }.value
    }

    public static func playlistReferences(_ file: URL) throws -> [String] {
        let data = try limitedData(file, limit: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw PlayStationImportError.invalidDisc }
        let names = text.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !names.isEmpty, names.count <= maximumDiscs, Set(names).count == names.count else { throw PlayStationImportError.invalidDisc }
        for name in names {
            try CueSheetParser.validate(referencedName: name)
            guard ["cue", "chd"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { throw PlayStationImportError.unsupportedDisc }
        }
        return names
    }

    private static func buildSynchronously(from source: URL, in staging: URL) throws -> URL {
        let fm = FileManager.default
        let work = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let discSources: [URL]
        if source.pathExtension.lowercased() == "m3u" {
            discSources = try playlistReferences(source).map { try safeMember($0, in: source.deletingLastPathComponent()) }
        } else { discSources = [source] }
        var members: [Member] = [], discs: [String] = []
        for (index, sourceDisc) in discSources.enumerated() {
            try Task.checkCancellation()
            let prefix = String(format: "disc%02d", index + 1)
            let cue: URL
            if sourceDisc.pathExtension.lowercased() == "chd" {
                let decoded = work.appendingPathComponent(prefix, isDirectory: true)
                try fm.createDirectory(at: decoded, withIntermediateDirectories: true)
                cue = try decodeCHD(sourceDisc, into: decoded)
            } else { cue = sourceDisc }
            let sheet = try CueSheetParser.parse(limitedData(cue, limit: CueSheetParser.maxSize))
            try validate(sheet, in: cue.deletingLastPathComponent())
            var normalized = "", fileIndex = 0
            for file in sheet.files {
                fileIndex += 1
                let name = String(format: "%@-track%02d.bin", prefix, fileIndex)
                members.append(Member(name: name, source: try safeMember(file.referencedName, in: cue.deletingLastPathComponent())))
                normalized += "FILE \"\(name)\" BINARY\n"
                for track in file.tracks {
                    normalized += String(format: "  TRACK %02d %@\n", track.number, track.mode)
                    if let gap = track.pregap { normalized += "    PREGAP \(gap)\n" }
                    for entry in track.indexes { normalized += String(format: "    INDEX %02d %@\n", entry.number, entry.position) }
                    if let gap = track.postgap { normalized += "    POSTGAP \(gap)\n" }
                }
            }
            let cueName = prefix + ".cue"
            let normalizedURL = work.appendingPathComponent(cueName)
            try Data(normalized.utf8).write(to: normalizedURL, options: .atomic)
            members.append(Member(name: cueName, source: normalizedURL)); discs.append(cueName)
            let sbi = sourceDisc.deletingPathExtension().appendingPathExtension("sbi")
            if fm.fileExists(atPath: sbi.path) {
                let safe = try safeMember(sbi.lastPathComponent, in: sbi.deletingLastPathComponent())
                try validateSBI(limitedData(safe, limit: 1024 * 1024))
                members.append(Member(name: prefix + ".sbi", source: safe))
            }
        }
        var entries: [Entry] = [], total: Int64 = 0
        for member in members {
            let hash = try SHA256ContentHasher.hashSynchronously(fileAt: member.source)
            total += hash.sizeInBytes
            guard total <= maximumBytes - Int64(headerLimit) else { throw PlayStationImportError.tooLarge }
            entries.append(Entry(name: member.name, bytes: hash.sizeInBytes, sha256: hash.fingerprint.hexDigest))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(Header(version: 1, discs: discs, entries: entries))
        guard header.count <= headerLimit else { throw PlayStationImportError.tooLarge }
        let output = staging.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        guard fm.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: output)
        do {
            try handle.write(contentsOf: magic)
            var length = UInt32(header.count).littleEndian
            try withUnsafeBytes(of: &length) { try handle.write(contentsOf: $0) }
            try handle.write(contentsOf: header)
            for (member, entry) in zip(members, entries) {
                try copy(member.source, to: handle, expected: entry)
            }
            try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); try? fm.removeItem(at: output); throw error }
        return output
    }

    /// Lookup keys of a package's first disc: the SHA-1 of its first track file
    /// (Redump hashes each track) and the serial SYSTEM.CNF names. Never identity.
    public static func lookupDigests(package: URL) throws -> LookupDigests {
        let input = try FileHandle(forReadingFrom: package); defer { try? input.close() }
        let prefix = try read(input, count: 12)
        guard prefix.prefix(8) == magic else { throw PlayStationImportError.damagedPackage }
        let count = prefix[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard count > 0, count <= headerLimit else { throw PlayStationImportError.damagedPackage }
        let header = try JSONDecoder().decode(Header.self, from: read(input, count: count))
        try validateHeader(header)
        var ranges: [String: (start: Int64, bytes: Int64)] = [:], cursor = Int64(12 + count)
        for entry in header.entries { ranges[entry.name] = (cursor, entry.bytes); cursor += entry.bytes }
        guard let track = ranges["disc01-track01.bin"], let cue = ranges["disc01.cue"] else { throw PlayStationImportError.damagedPackage }
        try input.seek(toOffset: UInt64(track.start))
        var sha1 = Insecure.SHA1(), left = track.bytes
        while left > 0 {
            try autoreleasepool {
                let bytes = try read(input, count: Int(min(left, 1 << 20)))
                sha1.update(data: bytes); left -= Int64(bytes.count)
            }
        }
        try input.seek(toOffset: UInt64(cue.start))
        let sheet = try CueSheetParser.parse(read(input, count: Int(cue.bytes)))
        var serial: String?
        if let first = sheet.files.first?.tracks.first, let start = first.indexes.last,
           let boot = try? bootPath(input, base: track.start, length: track.bytes, sector: frames(start.position), mode: first.mode) {
            serial = discSerial(fromBootPath: boot)
        }
        return LookupDigests(sha1: LookupDigester.hex(sha1.finalize()), discSerial: serial)
    }

    /// Validates both the package and its SHA-256 before producing executable
    /// CUE files. The temporary directory is committed only after every member
    /// hash and every reconstructed disc pass. A partial cache is never used.
    public static func prepareForLaunch(package: URL, fingerprint: ContentFingerprint, cache: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let marker = cache.appendingPathComponent(".complete")
            let sourceAttributes = try fm.attributesOfItem(atPath: package.path)
            let stamp = "\(fingerprint.hexDigest):\(sourceAttributes[.size] ?? 0):\(sourceAttributes[.modificationDate] ?? Date.distantPast)"
            if (try? String(contentsOf: marker, encoding: .utf8)) == stamp {
                let launch = cache.appendingPathComponent("game.m3u")
                if let names = try? playlistReferences(launch),
                   names.allSatisfy({ name in
                       do {
                           let sheet = try CueSheetParser.parse(limitedData(cache.appendingPathComponent(name), limit: CueSheetParser.maxSize))
                           try validate(sheet, in: cache)
                           let sbi = cache.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("sbi")
                           if fm.fileExists(atPath: sbi.path) { try validateSBI(limitedData(sbi, limit: 1024 * 1024)) }
                           return true
                       } catch { return false }
                   }) {
                    return launch
                }
            }
            guard try SHA256ContentHasher.hashSynchronously(fileAt: package).fingerprint == fingerprint else { throw PlayStationImportError.damagedPackage }
            let temporary = cache.deletingLastPathComponent().appendingPathComponent(".disc-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }
            let input = try FileHandle(forReadingFrom: package); defer { try? input.close() }
            let prefix = try read(input, count: 12)
            guard prefix.prefix(8) == magic else { throw PlayStationImportError.damagedPackage }
            let count = prefix[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard count > 0, count <= headerLimit else { throw PlayStationImportError.damagedPackage }
            let header = try JSONDecoder().decode(Header.self, from: read(input, count: count))
            try validateHeader(header)
            for entry in header.entries {
                let output = temporary.appendingPathComponent(entry.name)
                guard fm.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let destination = try FileHandle(forWritingTo: output)
                do { try copy(input, to: destination, expected: entry); try destination.close() }
                catch { try? destination.close(); throw error }
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw PlayStationImportError.damagedPackage }
            for entry in header.entries where entry.name.hasSuffix(".sbi") {
                try validateSBI(limitedData(temporary.appendingPathComponent(entry.name), limit: 1024 * 1024))
            }
            for disc in header.discs {
                let sheet = try CueSheetParser.parse(limitedData(temporary.appendingPathComponent(disc), limit: CueSheetParser.maxSize))
                try validate(sheet, in: temporary)
            }
            try Data((header.discs.joined(separator: "\n") + "\n").utf8).write(to: temporary.appendingPathComponent("game.m3u"), options: .atomic)
            try Data(stamp.utf8).write(to: temporary.appendingPathComponent(".complete"), options: .atomic)
            if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
            try fm.moveItem(at: temporary, to: cache)
            return cache.appendingPathComponent("game.m3u")
        }.value
    }

    private static func validateHeader(_ h: Header) throws {
        guard h.version == 1, !h.discs.isEmpty, h.discs.count <= maximumDiscs,
              !h.entries.isEmpty, h.entries.count <= 800,
              Set(h.entries.map(\.name)).count == h.entries.count,
              Set(h.discs).count == h.discs.count else { throw PlayStationImportError.damagedPackage }
        var total: Int64 = 0
        for e in h.entries {
            try CueSheetParser.validate(referencedName: e.name)
            guard e.name.range(of: #"^disc[0-9]{2}(\.cue|\.sbi|-track[0-9]{2}\.bin)$"#, options: .regularExpression) != nil,
                  e.bytes > 0, e.bytes <= maximumBytes, e.sha256.count == 64,
                  e.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw PlayStationImportError.damagedPackage }
            total += e.bytes
            guard total <= maximumBytes else { throw PlayStationImportError.tooLarge }
        }
        for (i, disc) in h.discs.enumerated() {
            guard disc == String(format: "disc%02d.cue", i + 1),
                  h.entries.contains(where: { $0.name == disc && $0.bytes <= CueSheetParser.maxSize }) else { throw PlayStationImportError.damagedPackage }
        }
    }

    private static func validate(_ sheet: CueSheet, in directory: URL) throws {
        guard !sheet.files.isEmpty, sheet.files.count <= 99,
              Set(sheet.referencedNames).count == sheet.files.count else { throw PlayStationImportError.invalidDisc }
        var nextTrack = 1
        for file in sheet.files {
            guard file.type == "BINARY" else { throw PlayStationImportError.unsupportedDisc }
            let url = try safeMember(file.referencedName, in: directory)
            let size = try fileSize(url)
            guard size > 0, size <= 450000 * 2352, size % 2352 == 0 else { throw PlayStationImportError.invalidDisc }
            var previous: Int64 = -1
            for track in file.tracks {
                guard track.number == nextTrack, nextTrack <= 99,
                      (nextTrack == 1 ? ["MODE1/2352", "MODE2/2352"].contains(track.mode) : track.mode == "AUDIO"),
                      track.indexes.map(\.number) == [1] || track.indexes.map(\.number) == [0, 1] else { throw PlayStationImportError.unsupportedDisc }
                for index in track.indexes {
                    let position = try frames(index.position)
                    guard position >= previous, position < size / 2352 else { throw PlayStationImportError.invalidDisc }
                    previous = position
                }
                if let p = track.pregap { _ = try frames(p) }
                if let p = track.postgap { _ = try frames(p) }
                if nextTrack == 1 {
                    guard let start = track.indexes.last else { throw PlayStationImportError.invalidDisc }
                    try validatePlayStationISO(url, sector: frames(start.position), mode: track.mode)
                }
                nextTrack += 1
            }
        }
    }

    private static func validateSBI(_ bytes: Data) throws {
        guard bytes.count > 4, bytes.prefix(4) == Data([0x53, 0x42, 0x49, 0]) else { throw PlayStationImportError.invalidDisc }
        var cursor = 4
        while cursor < bytes.count {
            guard cursor + 4 <= bytes.count else { throw PlayStationImportError.invalidDisc }
            let bcd = bytes[cursor..<cursor+3]
            guard bcd.allSatisfy({ $0 & 15 <= 9 && $0 >> 4 <= 9 }) else { throw PlayStationImportError.invalidDisc }
            let values = bcd.map { Int($0 >> 4) * 10 + Int($0 & 15) }
            guard values[1] < 60, values[2] < 75, (values[0] * 60 + values[1]) * 75 + values[2] >= 150 else { throw PlayStationImportError.invalidDisc }
            let type = bytes[cursor+3]
            guard (1...3).contains(type) else { throw PlayStationImportError.invalidDisc }
            cursor += type == 1 ? 14 : 7
            guard cursor <= bytes.count else { throw PlayStationImportError.invalidDisc }
        }
    }

    private static func frames(_ time: String) throws -> Int64 {
        let values = time.split(separator: ":").compactMap { Int64($0) }
        guard values.count == 3, values[0] >= 0, values[0] < 100, values[1] >= 0, values[1] < 60,
              values[2] >= 0, values[2] < 75 else { throw PlayStationImportError.invalidDisc }
        return (values[0] * 60 + values[1]) * 75 + values[2]
    }
    private static func timecode(_ frames: UInt32) -> String { String(format: "%02d:%02d:%02d", frames / 4500, frames / 75 % 60, frames % 75) }
    private static func safeMember(_ name: String, in directory: URL) throws -> URL {
        try CueSheetParser.validate(referencedName: name)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == root else { throw PlayStationImportError.unsafePath }
        return url
    }
    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { throw PlayStationImportError.invalidDisc }
        return size.int64Value
    }
    private static func limitedData(_ url: URL, limit: Int) throws -> Data {
        guard try fileSize(url) <= limit else { throw PlayStationImportError.tooLarge }
        return try Data(contentsOf: url)
    }
    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else { throw PlayStationImportError.damagedPackage }
        return data
    }
    private static func copy(_ url: URL, to output: FileHandle, expected: Entry) throws {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        try copy(input, to: output, expected: expected)
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw PlayStationImportError.damagedPackage }
    }
    private static func copy(_ input: FileHandle, to output: FileHandle, expected: Entry) throws {
        var left = expected.bytes, hash = SHA256()
        while left > 0 {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try read(input, count: Int(min(left, 1024 * 1024)))
                hash.update(data: bytes); try output.write(contentsOf: bytes); left -= Int64(bytes.count)
            }
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw PlayStationImportError.damagedPackage }
    }

    private static func decodeCHD(_ source: URL, into directory: URL) throws -> URL {
        guard let reader = relay_chd_open(source.path) else { throw PlayStationImportError.unsupportedDisc }
        defer { relay_chd_close(reader) }
        var cue = ""
        for i in 0..<relay_chd_track_count(reader) {
            try Task.checkCancellation()
            var track = RelayCHDTrack()
            guard relay_chd_track(reader, i, &track) == 1 else { throw PlayStationImportError.invalidDisc }
            let name = String(format: "track%02d.bin", i + 1)
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let out = try FileHandle(forWritingTo: url)
            do {
                var buffer = [UInt8](repeating: 0, count: 2352), chunk = Data()
                chunk.reserveCapacity(2352 * 128)
                for sector in 0..<track.frames {
                    guard relay_chd_read_sector(reader, i, sector, &buffer) == 1 else { throw PlayStationImportError.invalidDisc }
                    chunk.append(contentsOf: buffer)
                    if chunk.count >= 2352 * 128 { try out.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true); try Task.checkCancellation() }
                }
                if !chunk.isEmpty { try out.write(contentsOf: chunk) }
                try out.close()
            } catch { try? out.close(); throw error }
            let mode = track.mode == 1 ? "MODE1/2352" : track.mode == 2 ? "MODE2/2352" : "AUDIO"
            cue += "FILE \"\(name)\" BINARY\n" + String(format: "  TRACK %02d %@\n", i + 1, mode)
            if track.pregap > 0 {
                cue += track.storedPregap != 0 ? "    INDEX 00 00:00:00\n" : "    PREGAP \(timecode(track.pregap))\n"
            }
            cue += "    INDEX 01 \(timecode(track.storedPregap != 0 ? track.pregap : 0))\n"
            if track.postgap > 0 { cue += "    POSTGAP \(timecode(track.postgap))\n" }
        }
        let url = directory.appendingPathComponent("disc.cue")
        try Data(cue.utf8).write(to: url, options: .atomic)
        return url
    }
}

extension PlayStationDiscPackage {
    /// PS1 identification requires a real ISO9660 filesystem and its boot
    /// executable. A .cue extension, generic CD signature or disc label alone
    /// is insufficient (many other consoles also used CD-ROM).
    static func validatePlayStationISO(_ url: URL, sector start: Int64, mode: String) throws {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        _ = try bootPath(input, base: 0, length: try fileSize(url), sector: start, mode: mode)
    }

    /// "SLUS_012.34" → "SLUS-01234", the form Redump lists; nil for names like PSX.EXE.
    static func discSerial(fromBootPath path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let compact = name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard compact.count == 9, compact.prefix(4).allSatisfy(\.isLetter), compact.suffix(5).allSatisfy(\.isNumber) else { return nil }
        return compact.prefix(4) + "-" + compact.suffix(5)
    }

    /// Reads the boot executable path named by SYSTEM.CNF (PSX.EXE when absent)
    /// from an ISO9660 data track stored at `base` in `input`, and verifies that
    /// it names a real PS-X executable. Returns the path without "cdrom:" or ";1".
    static func bootPath(_ input: FileHandle, base: Int64, length size: Int64, sector start: Int64, mode: String) throws -> String {
        let dataOffset: Int64 = mode == "MODE1/2352" ? 16 : 24
        func userSector(_ sector: Int64) throws -> Data {
            let offset = (start + sector) * 2352
            guard sector >= 0, offset >= 0, offset <= size - 2352 else { throw PlayStationImportError.invalidDisc }
            try input.seek(toOffset: UInt64(base + offset))
            let raw = try read(input, count: 2352)
            guard raw[0] == 0, raw[11] == 0, raw[1..<11].allSatisfy({ $0 == 255 }),
                  raw[15] == (dataOffset == 16 ? 1 : 2) else { throw PlayStationImportError.invalidDisc }
            return raw.subdata(in: Int(dataOffset)..<Int(dataOffset)+2048)
        }
        func integer(_ data: Data, _ offset: Int) throws -> Int64 {
            guard offset >= 0, offset + 8 <= data.count else { throw PlayStationImportError.invalidDisc }
            let little = (0..<4).reduce(Int64(0)) { $0 | Int64(data[offset + $1]) << ($1 * 8) }
            let big = (0..<4).reduce(Int64(0)) { $0 << 8 | Int64(data[offset + 4 + $1]) }
            guard little == big else { throw PlayStationImportError.invalidDisc }
            return little
        }
        func bytes(_ sector: Int64, _ length: Int64, limit: Int64) throws -> Data {
            guard length > 0, length <= limit else { throw PlayStationImportError.invalidDisc }
            var result = Data(), offset: Int64 = 0
            while offset < length { result.append(try userSector(sector + offset / 2048).prefix(Int(min(2048, length - offset)))); offset += 2048 }
            return result
        }
        struct Record { let name: String; let sector: Int64; let bytes: Int64; let directory: Bool }
        func records(_ sector: Int64, _ count: Int64) throws -> [Record] {
            let data = try bytes(sector, count, limit: 1024 * 1024)
            var cursor = 0, found: [Record] = []
            while cursor < data.count {
                let length = Int(data[cursor])
                if length == 0 { cursor = ((cursor / 2048) + 1) * 2048; continue }
                guard length >= 34, cursor + length <= data.count, cursor % 2048 + length <= 2048 else { throw PlayStationImportError.invalidDisc }
                let nameCount = Int(data[cursor + 32])
                guard nameCount > 0, 33 + nameCount <= length else { throw PlayStationImportError.invalidDisc }
                let raw = data.subdata(in: cursor+33..<cursor+33+nameCount)
                if raw.first != 0 && raw.first != 1, let name = String(data: raw, encoding: .ascii) {
                    found.append(Record(name: name.uppercased().components(separatedBy: ";")[0],
                                        sector: try integer(data, cursor + 2), bytes: try integer(data, cursor + 10), directory: data[cursor+25] & 2 != 0))
                }
                cursor += length
            }
            return found
        }
        let volume = try userSector(16)
        guard volume[0] == 1, volume[1..<6] == Data("CD001".utf8), volume[6] == 1,
              volume[128] == 0, volume[129] == 8, volume[130] == 8, volume[131] == 0 else { throw PlayStationImportError.invalidDisc }
        let root = try records(integer(volume, 158), integer(volume, 166))
        var boot = "PSX.EXE"
        if let cnf = root.first(where: { $0.name == "SYSTEM.CNF" && !$0.directory }) {
            let content = try bytes(cnf.sector, cnf.bytes, limit: 32 * 1024)
            guard let text = String(data: content, encoding: .ascii),
                  let line = text.split(whereSeparator: { $0.isNewline }).first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("BOOT") }),
                  let equals = line.firstIndex(of: "=") else { throw PlayStationImportError.invalidDisc }
            boot = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces).uppercased()
            guard boot.hasPrefix("CDROM:") else { throw PlayStationImportError.invalidDisc }
            boot = String(boot.dropFirst(6)).replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            boot = boot.components(separatedBy: ";")[0]
        }
        let components = boot.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.count <= 8 else { throw PlayStationImportError.invalidDisc }
        var entries = root
        for (index, component) in components.enumerated() {
            try CueSheetParser.validate(referencedName: component)
            guard let record = entries.first(where: { $0.name == component }) else { throw PlayStationImportError.invalidDisc }
            if index == components.count - 1 {
                guard !record.directory, record.bytes >= 2048,
                      try userSector(record.sector).prefix(8) == Data("PS-X EXE".utf8) else { throw PlayStationImportError.invalidDisc }
            } else {
                guard record.directory else { throw PlayStationImportError.invalidDisc }
                entries = try records(record.sector, record.bytes)
            }
        }
        return boot
    }
}
