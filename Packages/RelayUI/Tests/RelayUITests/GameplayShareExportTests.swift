// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(macOS)
import XCTest
@testable import RelayUI

final class GameplayShareExportTests: XCTestCase {
    func testSaveCopyAndConfirmedReplacementPreserveOriginalExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Relay Gameplay Clip.mp4")
        let destination = directory.appendingPathComponent("Saved Clip.mp4")
        let contents = Data(repeating: 0x6A, count: 2 * 1024 * 1024)
        try contents.write(to: source)
        try GameplayShareExport.copy(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        try Data("previous file".utf8).write(to: destination)
        try GameplayShareExport.copy(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testFailedCopyDoesNotReplaceExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Existing.png")
        let contents = Data("keep this file".utf8)
        try contents.write(to: destination)
        XCTAssertThrowsError(try GameplayShareExport.copy(from: directory.appendingPathComponent("Missing.png"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }
}
#endif
