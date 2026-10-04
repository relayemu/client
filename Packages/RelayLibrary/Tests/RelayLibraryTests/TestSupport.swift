// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest

enum TestSupport {
    /// A fresh temporary directory per test.
    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RelayLibraryTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeFile(_ bytes: [UInt8], named name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }
}
