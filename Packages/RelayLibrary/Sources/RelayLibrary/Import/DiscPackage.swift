// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  DiscPackage.swift
//  RelayLibrary
//
//  Identity for multi-file (disc) games.
//
//  A disc image arrives as a cue sheet plus the track files it names. None of
//  those file names is the game: a player renames a `.cue`, a dump tool lays
//  tracks out differently, a second device stores the same tracks under
//  Relay's managed names. So a disc's `ContentFingerprint` is the SHA-256 of a
//  canonical manifest built from what the cue sheet *means* — the ordered
//  tracks, their modes and indexes, and the SHA-256 and size of every file
//  they refer to — and never from the cue sheet's bytes or its file names.
//
//  Two dumps with the same tracks and the same track bytes are the same game
//  on every device; a dump with one track's contents changed is a different
//  one, even if every file name matches.
//
//  Parsing is defensive because a cue sheet is untrusted input: it may only
//  refer to files by bare name, those names must exist among the staged
//  members, and every reference must resolve inside the staging directory.
//  No core reads the cue sheet before Relay has validated it here.

import Foundation
import RelayDomain

// MARK: - The parsed sheet

/// One `FILE` line of a cue sheet and the tracks it carries.
public struct CueFile: Hashable, Sendable {
    /// The bare file name the sheet used (validated: no path separators).
    public let referencedName: String
    /// `BINARY`, `WAVE`, `MP3`… as written, upper-cased.
    public let type: String
    public let tracks: [CueTrack]
}

public struct CueTrack: Hashable, Sendable {
    public let number: Int
    /// `MODE1/2352`, `MODE2/2352`, `AUDIO`… as written, upper-cased.
    public let mode: String
    /// `INDEX` entries in order: (index number, mm:ss:ff as written).
    public let indexes: [CueIndex]
    public let pregap: String?
    public let postgap: String?
}

public struct CueIndex: Hashable, Sendable {
    public let number: Int
    public let position: String
}

public struct CueSheet: Hashable, Sendable {
    public let files: [CueFile]

    /// Every bare file name the sheet refers to, in order of first reference.
    public var referencedNames: [String] {
        var seen: Set<String> = []
        return files.compactMap { seen.insert($0.referencedName).inserted ? $0.referencedName : nil }
    }
}

public enum CueSheetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The sheet is not text, or contains no `FILE` line.
    case malformed(reason: String)
    /// A `FILE` line names something that is not a bare file name.
    case unsafeReference(String)
    /// A `TRACK` appears twice, or out of order.
    case duplicateTrack(Int)
    /// A `FILE` line carries no track.
    case fileWithoutTracks(String)
    /// The sheet is larger than any real cue sheet.
    case tooLarge(Int)

    public var description: String {
        switch self {
        case .malformed(let r): return "cue sheet is malformed: \(r)"
        case .unsafeReference(let s): return "cue sheet refers to an unsafe path: '\(s)'"
        case .duplicateTrack(let n): return "cue sheet lists track \(n) twice"
        case .fileWithoutTracks(let f): return "cue sheet file '\(f)' has no tracks"
        case .tooLarge(let n): return "cue sheet is \(n) bytes; the limit is \(CueSheetParser.maxSize)"
        }
    }
}

/// A strict reader for the subset of cue-sheet syntax disc images use.
public enum CueSheetParser {
    /// Real cue sheets are a few hundred bytes; 64 KiB is generous.
    public static let maxSize = 64 * 1024

    public static func parse(_ data: Data) throws -> CueSheet {
        guard data.count <= maxSize else { throw CueSheetError.tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CueSheetError.malformed(reason: "not text")
        }
        var files: [CueFile] = []
        var currentFile: (name: String, type: String)?
        var currentTracks: [CueTrack] = []
        var currentTrack: (number: Int, mode: String, indexes: [CueIndex], pregap: String?, postgap: String?)?
        var seenTracks: Set<Int> = []

        func closeTrack() {
            if let track = currentTrack {
                currentTracks.append(CueTrack(number: track.number, mode: track.mode, indexes: track.indexes,
                                              pregap: track.pregap, postgap: track.postgap))
                currentTrack = nil
            }
        }
        func closeFile() throws {
            closeTrack()
            if let file = currentFile {
                guard !currentTracks.isEmpty else { throw CueSheetError.fileWithoutTracks(file.name) }
                files.append(CueFile(referencedName: file.name, type: file.type, tracks: currentTracks))
                currentFile = nil
                currentTracks = []
            }
        }

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (keyword, rest) = splitKeyword(line)
            switch keyword {
            case "FILE":
                try closeFile()
                let (name, type) = try parseFileLine(rest)
                currentFile = (name, type)
            case "TRACK":
                guard currentFile != nil else { throw CueSheetError.malformed(reason: "TRACK before FILE") }
                closeTrack()
                let parts = rest.split(whereSeparator: { $0.isWhitespace })
                guard parts.count >= 2, let number = Int(parts[0]) else {
                    throw CueSheetError.malformed(reason: "bad TRACK line")
                }
                guard seenTracks.insert(number).inserted else { throw CueSheetError.duplicateTrack(number) }
                currentTrack = (number, String(parts[1]).uppercased(), [], nil, nil)
            case "INDEX":
                guard currentTrack != nil else { throw CueSheetError.malformed(reason: "INDEX before TRACK") }
                let parts = rest.split(whereSeparator: { $0.isWhitespace })
                guard parts.count == 2, let number = Int(parts[0]), isTimecode(parts[1]) else {
                    throw CueSheetError.malformed(reason: "bad INDEX line")
                }
                currentTrack?.indexes.append(CueIndex(number: number, position: String(parts[1])))
            case "PREGAP":
                guard currentTrack != nil, isTimecode(Substring(rest)) else { throw CueSheetError.malformed(reason: "bad PREGAP") }
                currentTrack?.pregap = rest
            case "POSTGAP":
                guard currentTrack != nil, isTimecode(Substring(rest)) else { throw CueSheetError.malformed(reason: "bad POSTGAP") }
                currentTrack?.postgap = rest
            case "REM", "TITLE", "PERFORMER", "SONGWRITER", "CATALOG", "ISRC", "FLAGS", "CDTEXTFILE":
                continue   // descriptive; never part of identity
            default:
                throw CueSheetError.malformed(reason: "unknown keyword '\(keyword)'")
            }
        }
        try closeFile()
        guard !files.isEmpty else { throw CueSheetError.malformed(reason: "no FILE line") }
        return CueSheet(files: files)
    }

    private static func splitKeyword(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(where: { $0.isWhitespace }) else { return (line.uppercased(), "") }
        return (String(line[..<space]).uppercased(), String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `FILE "name" TYPE` or `FILE name TYPE`. The name must be a bare file
    /// name: no separators, no parent references, no control characters.
    private static func parseFileLine(_ rest: String) throws -> (String, String) {
        var name: String
        var remainder: String
        if rest.hasPrefix("\"") {
            let afterQuote = rest.index(after: rest.startIndex)
            guard let close = rest[afterQuote...].firstIndex(of: "\"") else {
                throw CueSheetError.malformed(reason: "unterminated FILE name")
            }
            name = String(rest[afterQuote..<close])
            remainder = String(rest[rest.index(after: close)...])
        } else if let space = rest.lastIndex(where: { $0.isWhitespace }) {
            name = String(rest[..<space])
            remainder = String(rest[space...])
        } else {
            throw CueSheetError.malformed(reason: "FILE line without a type")
        }
        let type = remainder.trimmingCharacters(in: .whitespaces).uppercased()
        guard !type.isEmpty else { throw CueSheetError.malformed(reason: "FILE line without a type") }
        try validate(referencedName: name)
        return (name, type)
    }

    /// The rules a referenced name must meet before it is looked up anywhere.
    public static func validate(referencedName name: String) throws {
        guard !name.isEmpty, name.count <= 255 else { throw CueSheetError.unsafeReference(name) }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":") else { throw CueSheetError.unsafeReference(name) }
        guard name != ".", name != "..", !name.hasPrefix("..") else { throw CueSheetError.unsafeReference(name) }
        guard name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw CueSheetError.unsafeReference(name)
        }
    }

    private static func isTimecode(_ s: Substring) -> Bool {
        let parts = s.split(separator: ":")
        return parts.count == 3 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) }
    }
}

// MARK: - The package

/// One validated member of a disc package: a track file the sheet refers to,
/// hashed. The referenced name is kept for storage bookkeeping only.
public struct DiscPackageMember: Hashable, Sendable {
    public let referencedName: String
    public let hashed: HashedContent
}

public struct DiscPackage: Hashable, Sendable {
    public static let formatVersion = 1

    public let sheet: CueSheet
    /// Members in the order the sheet first refers to them.
    public let members: [DiscPackageMember]
    /// The package's cross-device identity.
    public let fingerprint: ContentFingerprint

    /// The bytes the fingerprint is computed over. Deterministic and free of
    /// file names: the same tracks with the same contents produce the same
    /// text however the files were called or laid out.
    public static func canonicalManifest(sheet: CueSheet, members: [DiscPackageMember]) -> String {
        let byName = Dictionary(uniqueKeysWithValues: members.map { ($0.referencedName, $0.hashed) })
        var lines = ["relay-disc/\(formatVersion)"]
        for (fileIndex, file) in sheet.files.enumerated() {
            let hashed = byName[file.referencedName]!
            lines.append("file \(fileIndex) \(file.type) \(hashed.fingerprint.canonicalString) \(hashed.sizeInBytes)")
            for track in file.tracks {
                var line = "track \(track.number) \(track.mode)"
                if let pregap = track.pregap { line += " pregap=\(pregap)" }
                if let postgap = track.postgap { line += " postgap=\(postgap)" }
                lines.append(line)
                for index in track.indexes { lines.append("index \(index.number) \(index.position)") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum DiscPackageError: Error, Equatable, Sendable, CustomStringConvertible {
    case sheet(CueSheetError)
    /// The sheet refers to a file that is not among the staged members.
    case missingMember(String)
    /// A referenced name resolves to something outside the staging directory,
    /// or to a directory rather than a file.
    case memberOutsideStaging(String)
    case hashing(String)

    public var description: String {
        switch self {
        case .sheet(let e): return e.description
        case .missingMember(let n): return "the disc is missing '\(n)'"
        case .memberOutsideStaging(let n): return "'\(n)' is not inside the staged disc"
        case .hashing(let s): return "could not hash a disc member: \(s)"
        }
    }
}

/// Builds a `DiscPackage` from a staged cue sheet and the files beside it.
public struct DiscPackageBuilder: Sendable {
    private let hasher: any ContentHasher

    public init(hasher: any ContentHasher = SHA256ContentHasher()) {
        self.hasher = hasher
    }

    /// - Parameters:
    ///   - cueURL: the staged cue sheet.
    ///   - stagingDirectory: the directory every referenced member must live in.
    ///     References are resolved as bare names inside it and never elsewhere.
    public func build(cueURL: URL, stagingDirectory: URL) async throws -> DiscPackage {
        let data: Data
        do { data = try Data(contentsOf: cueURL) } catch {
            throw DiscPackageError.sheet(.malformed(reason: error.localizedDescription))
        }
        let sheet: CueSheet
        do { sheet = try CueSheetParser.parse(data) } catch let error as CueSheetError {
            throw DiscPackageError.sheet(error)
        }

        let staging = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var members: [DiscPackageMember] = []
        for name in sheet.referencedNames {
            let candidate = staging.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            // Belt and braces: the parser already refused separators, but the
            // resolved location must still be a plain file directly inside staging.
            guard candidate.deletingLastPathComponent().path == staging.path else {
                throw DiscPackageError.memberOutsideStaging(name)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                throw DiscPackageError.missingMember(name)
            }
            guard !isDirectory.boolValue else { throw DiscPackageError.memberOutsideStaging(name) }
            do {
                members.append(DiscPackageMember(referencedName: name, hashed: try await hasher.hash(fileAt: candidate)))
            } catch {
                throw DiscPackageError.hashing(String(describing: error))
            }
        }

        let manifest = DiscPackage.canonicalManifest(sheet: sheet, members: members)
        let fingerprint: ContentFingerprint
        do { fingerprint = try hasher.hash(data: Data(manifest.utf8)).fingerprint } catch {
            throw DiscPackageError.hashing(String(describing: error))
        }
        return DiscPackage(sheet: sheet, members: members, fingerprint: fingerprint)
    }
}
