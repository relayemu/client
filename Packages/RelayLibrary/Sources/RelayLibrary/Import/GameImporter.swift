// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  GameImporter.swift
//  RelayLibrary
//
//
//    receive file(s) → copy into a private staging directory
//      → if ZIP: validate + extract into staging (limits, safe paths)
//      → identify each candidate (header signature, then extension)
//      → hash → duplicate check → move atomically into Games/<GameID>/
//      → insert game + file (one transaction)
//      → optional metadata match (never blocks; failures are ignored)
//      → remove staging
//
//  Every outcome is reported per source file in plain product terms; technical
//  detail stays in `ImportOutcome.Failure.detail` for diagnostics only.
//  Interrupted imports leave only a staging directory, which `sweepStaging()`
//  removes on the next launch; library rows are written last, so a crash can
//  never produce a row without content.

import Foundation
import RelayDomain

public struct ImportReport: Sendable, Equatable {
    public var outcomes: [ImportOutcome]

    public init(outcomes: [ImportOutcome] = []) {
        self.outcomes = outcomes
    }

    public var addedGames: [Game] { outcomes.compactMap { if case .added(let g, _) = $0.result { g } else { nil } } }
    public var duplicateCount: Int { outcomes.filter { if case .duplicate = $0.result { true } else { false } }.count }
    public var problemCount: Int { outcomes.filter(\.result.isProblem).count }
}

public struct ImportOutcome: Sendable, Equatable, Identifiable {
    public enum Result: Sendable, Equatable {
        case added(Game, identifiedBy: ContentIdentification.Confidence)
        case duplicate(existing: Game)
        case unsupported
        case invalid(systemID: SystemID)
        case archiveRejected(reason: String)
        case discRejected(PlayStationImportError)
        case archiveEmpty
        case storageFull
        case failed(detail: String)

        public var isProblem: Bool {
            switch self {
            case .added, .duplicate: return false
            default: return true
            }
        }
    }

    public let id: UUID
    /// The name the user saw (source file, or `archive.zip/inner.gba` for archive members).
    public let displayName: String
    public let result: Result

    public init(id: UUID = UUID(), displayName: String, result: Result) {
        self.id = id
        self.displayName = displayName
        self.result = result
    }
}

public struct GameImporter: Sendable {
    private let store: any LibraryStore
    private let location: LibraryLocation
    private let identifier: ContentIdentifier
    private let zipReader: ZipReader
    private let metadataProvider: any MetadataProvider
    private let artworkStore: ArtworkStore
    private let clock: @Sendable () -> Date

    public init(store: any LibraryStore, location: LibraryLocation,
                identifier: ContentIdentifier = .standard,
                archiveLimits: ArchiveLimits = .standard,
                metadataProvider: any MetadataProvider = NoMetadataProvider(),
                artworkStore: ArtworkStore? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.location = location
        self.identifier = identifier
        self.zipReader = ZipReader(limits: archiveLimits)
        self.metadataProvider = metadataProvider
        self.artworkStore = artworkStore ?? ArtworkStore(location: location)
        self.clock = clock
    }

    /// Imports every URL in order. Security-scoped access, if needed, is the caller's job.
    /// Progress is reported per source file through `progress` (index, total, current outcome).
    public func importFiles(_ urls: [URL],
                            progress: (@Sendable (Int, Int, ImportOutcome) -> Void)? = nil) async -> ImportReport {
        if urls.contains(where: { ["cue", "chd", "m3u"].contains($0.pathExtension.lowercased()) }) {
            return await importDiscSelection(urls, progress: progress)
        }
        var report = ImportReport()
        for (index, url) in urls.enumerated() {
            let outcomes = await importFile(at: url)
            report.outcomes.append(contentsOf: outcomes)
            if let progress, let last = outcomes.last { progress(index + 1, urls.count, last) }
        }
        return report
    }

    /// Imports one source file (a game file or a ZIP archive of game files).
    public func importFile(at url: URL) async -> [ImportOutcome] {
        if ["cue", "chd", "m3u"].contains(url.pathExtension.lowercased()) {
            return await importDiscSelection([url], progress: nil).outcomes
        }
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "pbp" {
            return [ImportOutcome(displayName: name, result: .discRejected(.unsupportedDisc))]
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return [ImportOutcome(displayName: name, result: .failed(detail: "source file not found"))]
        }
        let staging: URL
        do { staging = try location.makeStagingDirectory() } catch {
            return [ImportOutcome(displayName: name, result: Self.storageResult(error))]
        }
        defer { try? fm.removeItem(at: staging) }

        let staged = staging.appending(path: LibraryLocation.sanitizedFileName(name))
        do { try fm.copyItem(at: url, to: staged) } catch {
            return [ImportOutcome(displayName: name, result: Self.storageResult(error))]
        }

        if ZipReader.looksLikeZip(staged) || staged.pathExtension.lowercased() == "zip" {
            return await importArchive(at: staged, displayName: name, staging: staging)
        }
        return [await ingestStaged(staged, displayName: name, originalFileName: name)]
    }

    private func importArchive(at archive: URL, displayName: String, staging: URL) async -> [ImportOutcome] {
        let extracted: [URL]
        do {
            let target = staging.appending(path: "extracted-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            extracted = try zipReader.extract(archive, into: target)
        } catch let error as ArchiveError {
            return [ImportOutcome(displayName: displayName, result: .archiveRejected(reason: error.description))]
        } catch {
            return [ImportOutcome(displayName: displayName, result: Self.storageResult(error))]
        }
        // Only files that look like games; skip metadata files without reporting noise.
        let candidates = extracted.filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") }
        guard !candidates.isEmpty else { return [ImportOutcome(displayName: displayName, result: .archiveEmpty)] }
        return await ingestPrepared(candidates, staging: staging, prefix: displayName + "/", allowArchives: false)
    }

    private func importDiscSelection(_ urls: [URL], progress: (@Sendable (Int, Int, ImportOutcome) -> Void)?) async -> ImportReport {
        let fm = FileManager.default
        do {
            let staging = try location.makeStagingDirectory()
            defer { try? fm.removeItem(at: staging) }
            var names: Set<String> = [], total: Int64 = 0, staged: [URL] = []
            for url in urls {
                try CueSheetParser.validate(referencedName: url.lastPathComponent)
                guard names.insert(url.lastPathComponent.lowercased()).inserted else { throw PlayStationImportError.unsafePath }
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let bytes = attributes.fileSize, bytes > 0 else { throw PlayStationImportError.unsafePath }
                total += Int64(bytes)
                guard total <= PlayStationDiscPackage.maximumBytes else { throw PlayStationImportError.tooLarge }
            }
            // FileProvider reads can block; copying selected content is kept
            // off the UI actor and never follows a cue reference at the source.
            for url in urls {
                let target = staging.appendingPathComponent(url.lastPathComponent)
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: target) }.value
                staged.append(target)
            }
            let outcomes = await ingestPrepared(staged, staging: staging)
            if let last = outcomes.last { progress?(urls.count, urls.count, last) }
            return ImportReport(outcomes: outcomes)
        } catch {
            let reason = (error as? PlayStationImportError) ?? .missingFiles
            return ImportReport(outcomes: urls.filter { ["cue", "chd", "m3u"].contains($0.pathExtension.lowercased()) }
                .map { ImportOutcome(displayName: $0.lastPathComponent, result: .discRejected(reason)) })
        }
    }

    private func ingestPrepared(_ files: [URL], staging: URL, prefix: String = "", allowArchives: Bool = true) async -> [ImportOutcome] {
        var claimed: Set<URL> = []
        // Related files are one game. Suppress member rows even when the
        // owning disc is invalid, so raw tracks never appear as extra games.
        for file in files {
            if ["cue", "chd"].contains(file.pathExtension.lowercased()) {
                claimed.insert(file.deletingPathExtension().appendingPathExtension("sbi").standardizedFileURL)
            }
            let names: [String]
            if file.pathExtension.lowercased() == "m3u" { names = (try? PlayStationDiscPackage.playlistReferences(file)) ?? [] }
            else if file.pathExtension.lowercased() == "cue" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                names = size <= CueSheetParser.maxSize ? ((try? CueSheetParser.parse(Data(contentsOf: file)).referencedNames) ?? []) : []
            } else { continue }
            for name in names { claimed.insert(file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL) }
        }
        var outcomes: [ImportOutcome] = []
        for file in files.sorted(by: { $0.path < $1.path }) where !claimed.contains(file.standardizedFileURL) {
            let name = prefix + file.lastPathComponent
            if ["cue", "chd", "m3u"].contains(file.pathExtension.lowercased()) {
                do {
                    let package = try await PlayStationDiscPackage.build(from: file, in: staging)
                    let storedName = file.deletingPathExtension().lastPathComponent + "." + PlayStationDiscPackage.fileExtension
                    outcomes.append(await ingestStaged(package, displayName: name, originalFileName: storedName,
                        forcedIdentification: ContentIdentification(systemID: .playStation, confidence: .header)))
                } catch {
                    let reason: PlayStationImportError
                    if let known = error as? PlayStationImportError { reason = known }
                    else if (error as NSError).code == NSFileReadNoSuchFileError { reason = .missingFiles }
                    else { reason = .invalidDisc }
                    outcomes.append(ImportOutcome(displayName: name, result: .discRejected(reason)))
                }
            } else if allowArchives && (file.pathExtension.lowercased() == "zip" || ZipReader.looksLikeZip(file)) {
                outcomes.append(contentsOf: await importArchive(at: file, displayName: name, staging: staging))
            } else if file.pathExtension.lowercased() == "pbp" {
                outcomes.append(ImportOutcome(displayName: name, result: .discRejected(.unsupportedDisc)))
            } else { outcomes.append(await ingestStaged(file, displayName: name, originalFileName: file.lastPathComponent)) }
        }
        return outcomes
    }

    /// Identifies, moves and records one staged file.
    private func ingestStaged(_ file: URL, displayName: String, originalFileName: String, forcedIdentification: ContentIdentification? = nil) async -> ImportOutcome {
        let identification: ContentIdentification
        do {
            identification = try forcedIdentification ?? identifier.identify(fileAt: file)
        } catch let error as ContentIdentificationError {
            switch error {
            case .unsupported:
                // A recognized cartridge header still wins even if an owner
                // named it .bin. Only unidentified raw tracks need a CUE.
                return ImportOutcome(displayName: displayName, result: file.pathExtension.lowercased() == "bin" ? .discRejected(.missingFiles) : .unsupported)
            case .invalid(_, let system): return ImportOutcome(displayName: displayName, result: .invalid(systemID: system))
            case .ambiguous: return ImportOutcome(displayName: displayName, result: .unsupported)
            case .unreadable(_, let reason): return ImportOutcome(displayName: displayName, result: .failed(detail: reason))
            }
        } catch {
            return ImportOutcome(displayName: displayName, result: .failed(detail: String(describing: error)))
        }

        if file.pathExtension.lowercased() == "bin", identification.confidence == .fileExtension,
           let input = try? FileHandle(forReadingFrom: file) {
            defer { try? input.close() }
            let sync = Data([0] + Array(repeating: UInt8(0xff), count: 10) + [0])
            if (try? input.read(upToCount: 12)) == sync {
                return ImportOutcome(displayName: displayName, result: .discRejected(.missingFiles))
            }
        }
        let ingestion = GameIngestion(store: store, location: location, clock: clock)
        let title = Self.displayTitle(fileName: originalFileName)
        let outcome: GameIngestion.Outcome
        do {
            outcome = try await ingestion.ingestLocalFile(at: file, systemID: identification.systemID, title: title,
                                                          originalFileName: originalFileName, transfer: .move)
        } catch {
            return ImportOutcome(displayName: displayName, result: Self.storageResult(error))
        }

        switch outcome {
        case .duplicate(let existing):
            return ImportOutcome(displayName: displayName, result: .duplicate(existing: existing))
        case .attached(let game):
            return ImportOutcome(displayName: displayName, result: .added(game, identifiedBy: identification.confidence))
        case .inserted(let game):
            let enriched = await enrich(game)
            return ImportOutcome(displayName: displayName, result: .added(enriched, identifiedBy: identification.confidence))
        }
    }

    /// Asks the metadata provider; applies the best candidate. Never fails the import.
    private func enrich(_ game: Game) async -> Game {
        await MetadataApplier(store: store, location: location, provider: metadataProvider,
                              artworkStore: artworkStore, clock: clock).apply(to: game).game
    }

    /// Removes a game, its files, artwork and screenshots. Rows first (see GameIngestion.remove).
    public func removeGame(id: GameID) async throws {
        try await GameIngestion(store: store, location: location).remove(gameID: id)
        artworkStore.removeAll(for: id)
    }

    /// "My Game (USA).gba" → "My Game (USA)"; underscores become spaces.
    static func displayTitle(fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? base : cleaned
    }

    private static func storageResult(_ error: Error) -> ImportOutcome.Result {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return .storageFull }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return .storageFull }
        return .failed(detail: String(describing: error))
    }
}
