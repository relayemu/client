// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  AtomicFileTests.swift — an interrupted write never damages the previous file.

import XCTest
@testable import RelayLibrary

final class AtomicFileTests: XCTestCase {
    func testWriteCreatesAndReplaces() throws {
        let dir = try TestSupport.temporaryDirectory()
        let target = dir.appending(path: "nested/current.sav")
        try AtomicFile().write(Data([1, 2, 3]), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        try AtomicFile().write(Data([9, 9]), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data([9, 9]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["current.sav"], "no temporary files remain")
    }

    func testFailureAtEveryStagePreservesThePreviousFile() throws {
        let dir = try TestSupport.temporaryDirectory()
        let target = dir.appending(path: "current.sav")
        let good = Data((0..<4096).map { UInt8($0 & 0xFF) })
        try AtomicFile().write(good, to: target)
        for stage in AtomicFile.Stage.allCases {
            let failing = AtomicFile { s in if s == stage { throw AtomicFile.Failure.injected(stage) } }
            XCTAssertThrowsError(try failing.write(Data(repeating: 0xFF, count: 4096), to: target), "stage \(stage)") { error in
                XCTAssertEqual(error as? AtomicFile.Failure, .injected(stage))
            }
            XCTAssertEqual(try Data(contentsOf: target), good, "previous file intact after failure at \(stage)")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(leftovers, ["current.sav"], "temporary removed after failure at \(stage)")
        }
    }

    func testDestinationInsideUnwritableDirectoryFailsCleanly() throws {
        let dir = try TestSupport.temporaryDirectory()
        let locked = dir.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appending(path: "x.sav")
        try AtomicFile().write(Data([1]), to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try AtomicFile().write(Data([2]), to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
    }
}
