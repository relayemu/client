// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayLibrary

extension TransferImportResult {
    /// Preserve individual source outcomes when a folder contains independent
    /// games or an archive has a partial result. Companion files are attributed
    /// to the disc outcomes rather than to unrelated unsupported files.
    public static func fromImportReport(_ report: ImportReport, sourceURLs: [URL] = [],
                                        message: (ImportOutcome) -> String? = { _ in nil }) -> TransferImportResult {
        var counts = TransferCounts(), code: String?, human: String?
        for outcome in report.outcomes {
            switch outcome.result {
            case .added: counts.imported += 1
            case .duplicate: counts.duplicate += 1
            case .unsupported, .archiveEmpty: counts.unsupported += 1
            case .invalid: counts.failed += 1; code = code ?? "invalid_file"
            case .archiveRejected: counts.failed += 1; code = code ?? "archive_rejected"
            case .discRejected: counts.failed += 1; code = code ?? "disc_rejected"
            case .storageFull: counts.failed += 1; code = code ?? "storage_full"
            case .failed: counts.failed += 1; code = code ?? "import_failed"
            }
            human = human ?? message(outcome)
        }
        let state: String
        if counts.failed == 0 && counts.unsupported == 0 && counts.imported > 0 { state = "imported" }
        else if counts.failed == 0 && counts.unsupported == 0 && counts.duplicate > 0 { state = "duplicate" }
        else if counts.failed == 0 && counts.imported == 0 && counts.duplicate == 0 && counts.unsupported > 0 { state = "unsupported" }
        else {
            state = "failed"
            if counts.imported + counts.duplicate > 0 { code = "partial_import" }
            if report.outcomes.isEmpty { counts.failed = 1; code = "import_failed" }
        }
        var result = TransferImportResult(state: state, title: counts.imported == 1 && counts.failed + counts.unsupported == 0 ? report.addedGames.first?.title : nil,
            message: human, code: code, counts: counts)
        for url in sourceURLs {
            let name = url.lastPathComponent
            let outcomes = report.outcomes.filter { $0.displayName == name || $0.displayName.hasPrefix(name + "/") }
            let discOutcomes = report.outcomes.filter { ["cue", "chd", "m3u"].contains(($0.displayName as NSString).pathExtension.lowercased()) }
            let attributed = outcomes.isEmpty ? discOutcomes : outcomes
            if !attributed.isEmpty {
                result.sourceResults[name] = Self.fromImportReport(ImportReport(outcomes: attributed), message: message)
            }
        }
        return result
    }
}
