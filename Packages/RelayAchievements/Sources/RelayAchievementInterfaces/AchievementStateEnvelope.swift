// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// A backwards-readable suffix keeps the core's original state bytes intact.
/// Relay removes it before restoring the core. Legacy states reset hit counts.
/// No credentials or RA account identity are stored in a state or synced file.
public enum AchievementStateEnvelope {
    private static let magic = Data("RelayAchState0001".utf8)
    private static let maxProgressBytes = 4 * 1024 * 1024
    public enum Failure: Error { case invalidTrailer }

    public static func append(to coreState: Data, progress: Data?) -> Data {
        guard let progress, !progress.isEmpty, progress.count <= maxProgressBytes else { return coreState }
        var result = coreState
        result.append(progress)
        result.append(contentsOf: SHA256.hash(data: progress))
        var size = UInt32(progress.count).littleEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(magic)
        return result
    }

    public static func split(_ data: Data) throws -> (core: Data, progress: Data?) {
        guard data.count >= magic.count, data.suffix(magic.count) == magic else { return (data, nil) }
        let footer = magic.count + 4 + 32
        guard data.count >= footer else { throw Failure.invalidTrailer }
        let lengthOffset = data.count - magic.count - 4
        let size = data[lengthOffset..<(lengthOffset + 4)].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard size > 0, size <= maxProgressBytes, size <= data.count - footer else { throw Failure.invalidTrailer }
        let progressStart = data.count - footer - size
        let progress = data.subdata(in: progressStart..<(progressStart + size))
        guard Data(SHA256.hash(data: progress)) == data[(progressStart + size)..<lengthOffset] else { throw Failure.invalidTrailer }
        return (data.prefix(progressStart), progress)
    }
}
