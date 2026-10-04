// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayLibrary

public enum TransferError: Error, Equatable, Sendable {
    case invalidMessage, unsafeName, limitsExceeded, storageFull, integrityMismatch, connectionFailed, interrupted
}

public struct TransferFile: Codable, Equatable, Sendable, Identifiable {
    /// JSON byte counters must remain exact in the browser's Number type.
    /// This is a wire representation bound, not a product file-size quota.
    static let maximumExactByteCount: Int64 = 9_007_199_254_740_991
    public let id: String
    public let name: String
    public let size: Int64
    public let sha256: String
    public let group: String?
    public var groupID: String { group ?? "independent-" + id }

    public init(id: String, name: String, size: Int64, sha256: String, group: String? = nil) {
        self.id = id; self.name = name; self.size = size; self.sha256 = sha256; self.group = group
    }

    public static func validate(_ files: [TransferFile], availableBytes: Int64) throws {
        guard !files.isEmpty, files.count <= 64 else { throw TransferError.limitsExceeded }
        var total: Int64 = 0, ids = Set<String>(), names = Set<String>()
        for file in files {
            guard validID(file.id), ids.insert(file.id).inserted,
                  file.group.map(validID) ?? true,
                  file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw TransferError.invalidMessage }
            guard !file.name.isEmpty, file.name.utf8.count <= 255,
                  file.name == LibraryLocation.sanitizedFileName(file.name),
                  !file.name.hasPrefix(".."),
                  !file.name.contains(where: { "/\\:".contains($0) }),
                  file.name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
                  names.insert(file.groupID + "/" + file.name.lowercased()).inserted else { throw TransferError.unsafeName }
            guard file.size >= 0, file.size <= maximumExactByteCount - total else { throw TransferError.limitsExceeded }
            total += file.size
        }
        // The exact-wire bound also keeps this conservative admission arithmetic
        // below Int64.max, even for hostile declarations near its upper bound.
        guard availableBytes >= total * 3 + 512 * 1024 * 1024 else { throw TransferError.storageFull }
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }
}

public struct TransferCounts: Codable, Equatable, Sendable {
    public var imported = 0, duplicate = 0, unsupported = 0, failed = 0
    public init(imported: Int = 0, duplicate: Int = 0, unsupported: Int = 0, failed: Int = 0) {
        self.imported = imported; self.duplicate = duplicate; self.unsupported = unsupported; self.failed = failed
    }
}

public struct TransferStatus: Codable, Equatable, Sendable {
    public let type = "status"
    public let id: String
    public let state: String
    public var message: String?
    public var title: String?
    public var code: String?
    public var receivedBytes: Int64?
    public var counts: TransferCounts?
    public init(id: String, state: String, message: String? = nil, title: String? = nil, code: String? = nil,
                receivedBytes: Int64? = nil, counts: TransferCounts? = nil) {
        self.id = id; self.state = state; self.message = message; self.title = title; self.code = code
        self.receivedBytes = receivedBytes; self.counts = counts
    }
    public var isTerminal: Bool { ["imported", "duplicate", "unsupported", "failed"].contains(state) }
}

public struct TransferImportResult: Sendable {
    public let state: String
    public let title: String?
    public let message: String?
    public let code: String?
    public let counts: TransferCounts
    /// Private importer attribution by safe basename; never encoded on the wire.
    /// Disc companions without an independent outcome use the group result.
    public var sourceResults: [String: TransferImportResult] = [:]
    public init(state: String, title: String? = nil, message: String? = nil, code: String? = nil, counts: TransferCounts) {
        self.state = state; self.title = title; self.message = message; self.code = code; self.counts = counts
    }
}

public enum TransferRoute: Equatable, Sendable {
    case direct, relay

    static func selected(localType: String?, remoteType: String?) -> TransferRoute? {
        let known = ["host", "srflx", "prflx", "relay"]
        guard let localType, let remoteType, known.contains(localType), known.contains(remoteType) else { return nil }
        return localType == "relay" || remoteType == "relay" ? .relay : .direct
    }
}

public enum TransferEvent: Sendable {
    case waiting, connecting, connected
    case route(TransferRoute)
    case manifest([TransferFile])
    case status(TransferStatus)
    /// Count each importer report once, even when several disc files share it.
    case outcomes(TransferCounts)
    case completed
    case failed(TransferError)
}

public struct TransferICEServer: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let urls: [String]
    public let username: String
    public let credential: String
    public init(urls: [String], username: String, credential: String) {
        self.urls = urls; self.username = username; self.credential = credential
    }
    public var description: String { "TransferICEServer(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "redacted"]) }
    // libdatachannel parses and URL-decodes userinfo; ':' in an expiring username
    // must not become the username/password separator. Never log these URLs.
    func nativeURLs() -> [String] {
        let user = username.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let password = credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return urls.compactMap { url in
            if url.hasPrefix("stun:") { return url }
            guard url.hasPrefix("turn:"), !url.contains("transport=tcp") else { return nil }
            return "turn:" + user + ":" + password + "@" + url.dropFirst(5)
        }
    }
}
