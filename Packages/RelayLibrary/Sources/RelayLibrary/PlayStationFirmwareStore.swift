// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

public enum PlayStationFirmware: String, CaseIterable, Codable, Sendable {
    case japan = "scph5500", northAmerica = "scph5501", europe = "scph5502"
    public var fileName: String { rawValue + ".bin" }
    // Published compatibility checksums, not content/sync identities:
    // https://docs.libretro.com/library/beetle_psx/#bios
    var md5: String {
        switch self {
        case .japan: return "8dd7d5296a650fac7319bce665a6a53c"
        case .northAmerica: return "490f666e1afb15b7362b406ed1cea246"
        case .europe: return "32736f17079d0b2b7024407c39bd3050"
        }
    }
}

public enum PlayStationFirmwareError: Error, Equatable, Sendable {
    case incompatibleFile
    case damagedInstalledFile
}

/// Firmware belongs to this device, outside game content and save payloads.
/// Nothing here downloads, bundles or redistributes firmware.
public struct PlayStationFirmwareStore: Sendable {
    public static let size = 512 * 1024
    public let directory: URL
    public init(firmwareDirectory: URL) {
        directory = firmwareDirectory.appendingPathComponent("PlayStation", isDirectory: true)
    }
    public static func identify(_ data: Data) throws -> PlayStationFirmware {
        guard data.count == size else { throw PlayStationFirmwareError.incompatibleFile }
        let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let variant = PlayStationFirmware.allCases.first(where: { $0.md5 == checksum }) else {
            throw PlayStationFirmwareError.incompatibleFile
        }
        return variant
    }
    @discardableResult
    public func importFile(_ source: URL) throws -> PlayStationFirmware {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, attributes.fileSize == Self.size else {
            throw PlayStationFirmwareError.incompatibleFile
        }
        return try importData(Data(contentsOf: source))
    }
    @discardableResult
    public func importData(_ data: Data) throws -> PlayStationFirmware {
        let variant = try Self.identify(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(variant.fileName), options: .atomic)
        return variant
    }
    public func installed() throws -> [PlayStationFirmware] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var installed: [PlayStationFirmware] = []
        for file in files {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, attributes.fileSize == Self.size,
                  let known = PlayStationFirmware.allCases.first(where: { $0.fileName == file.lastPathComponent }),
                  (try? Self.identify(Data(contentsOf: file))) == known else { throw PlayStationFirmwareError.damagedInstalledFile }
            installed.append(known)
        }
        return installed.sorted { $0.rawValue < $1.rawValue }
    }
    /// The core scans only this verified directory, never the general firmware
    /// folder or arbitrary source filenames supplied by a document picker.
    public func verifiedDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try installed()
        return directory
    }
}
