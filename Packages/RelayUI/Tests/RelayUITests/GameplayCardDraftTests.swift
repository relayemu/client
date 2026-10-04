// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) || os(macOS)
import XCTest
import ImageIO
import RelayDomain
@testable import RelayUI

@MainActor
final class GameplayCardDraftTests: XCTestCase {
    func testCaptionChangesDisableStaleExportAndClearingCreatesANewCard() async throws {
        let image = try XCTUnwrap(GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil)
            .image(from: [ShareTestFrame()]))
        let snapshot = GameplayShareSnapshot(image: image, title: "My game", systemName: "Game Boy Advance", systemID: .gameBoyAdvance)
        let initial = try GameplayShareFile.png(XCTUnwrap(RelayShareCard.image(snapshot)), kind: .card)
        let draft = GameplayCardDraft(file: GameplayShareFile(url: initial.url, kind: .card, cardSnapshot: snapshot))
        defer {
            try? FileManager.default.removeItem(at: initial.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: draft.file.url.deletingLastPathComponent())
        }
        XCTAssertTrue(draft.canExport)
        draft.caption = "First victory 🏆\nUne victoire à partager !"
        XCTAssertFalse(draft.canExport, "An old caption must never be offered to Save or Share")
        await draft.prepare()
        XCTAssertTrue(draft.canExport)
        let custom = draft.file.url
        defer { try? FileManager.default.removeItem(at: custom.deletingLastPathComponent()) }
        XCTAssertNotEqual(try Data(contentsOf: custom), try Data(contentsOf: initial.url))
        draft.caption = ""
        XCTAssertFalse(draft.canExport)
        await draft.prepare()
        XCTAssertTrue(draft.canExport)
        XCTAssertNotEqual(try Data(contentsOf: draft.file.url), try Data(contentsOf: custom))
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial.url.path))
        let empty = draft.file.url
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        draft.caption = String(repeating: "gjvjviyvyviyviyviyviyv", count: 14)
        await draft.prepare()
        XCTAssertTrue(draft.canExport)
        if let path = ProcessInfo.processInfo.environment["RELAY_SHARE_TEST_OUTPUT"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: custom, to: folder.appendingPathComponent("custom-caption.png"))
            try FileManager.default.copyItem(at: empty, to: folder.appendingPathComponent("empty-caption.png"))
            try FileManager.default.copyItem(at: draft.file.url, to: folder.appendingPathComponent("unbroken-caption.png"))
        }
    }

    func testCaptionLimitKeepsWholeUnicodeCharacters() {
        let file = GameplayShareFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("caption-test.png"), kind: .card)
        let draft = GameplayCardDraft(file: file)
        let emoji = "👨‍👩‍👧‍👦"
        draft.caption = String(repeating: emoji, count: 281)
        XCTAssertEqual(draft.caption.count, GameplayCardDraft.captionLimit)
        XCTAssertEqual(draft.caption, String(repeating: emoji, count: 280))
    }
}
#endif
