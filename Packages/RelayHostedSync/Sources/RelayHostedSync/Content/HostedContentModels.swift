// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain

public enum HostedStorageClass: String, Codable, Sendable { case game, critical }

public struct HostedContentTarget: Encodable, Sendable {
    public let category: String
    public let refType: String
    public let refKey: String
    public let gameFingerprint: ContentFingerprint
    public let generation: Int64
    public init(category: String, refType: String, refKey: String, gameFingerprint: ContentFingerprint, generation: Int64) {
        self.category = category; self.refType = refType; self.refKey = refKey
        self.gameFingerprint = gameFingerprint; self.generation = generation
    }
    enum CodingKeys: String, CodingKey {
        case category, refType = "ref_type", refKey = "ref_key", gameFingerprint = "game_fingerprint", generation
    }
}

public enum HostedContentError: Error, Equatable, Sendable {
    case invalidCapability, invalidChallenge, invalidUpload, integrityMismatch, verificationFailed, verificationTimedOut
    case transferFailed(status: Int?), missingETag
}

/// Capabilities are never included in diagnostic descriptions or persisted session state.
public struct HostedPresignedRequest: Codable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let expiresAt: String
    public init(url: URL, method: String, headers: [String: String], expiresAt: String) {
        self.url = url; self.method = method; self.headers = headers; self.expiresAt = expiresAt
    }
    enum CodingKeys: String, CodingKey { case url, method, headers, expiresAt = "expires_at" }

    func request(method expected: String, byteCount: Int64? = nil) throws -> URLRequest {
        guard method == expected, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              hostedDate(expiresAt).map({ $0 > Date() }) == true else { throw HostedContentError.invalidCapability }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        for (name, value) in headers {
            guard !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n"),
                  !["authorization", "cookie", "proxy-authorization"].contains(name.lowercased()) else {
                throw HostedContentError.invalidCapability
            }
            if name.lowercased() == "content-length", let byteCount {
                guard Int64(value) == byteCount else { throw HostedContentError.invalidCapability }
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

struct HostedPreparedUpload: Decodable, Sendable {
    let uploadID: UUID
    let mode: String
    let partSize: Int64?
    let partCount: Int?
    let upload: HostedPresignedRequest?
    let expiresAt: String
    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id", mode, partSize = "part_size", partCount = "part_count", upload, expiresAt = "expires_at"
    }
}
struct HostedUploadStatus: Decodable, Sendable {
    let uploadID: UUID
    let status: String
    enum CodingKeys: String, CodingKey { case uploadID = "upload_id", status }
}
struct HostedDownloadAuthorization: Decodable, Sendable { let download: HostedPresignedRequest; let size: Int64 }

public struct HostedProofRange: Codable, Sendable {
    public let offset: Int64
    public let length: Int64
    public init(offset: Int64, length: Int64) { self.offset = offset; self.length = length }
}
struct HostedProofChallenge: Decodable, Sendable {
    let challengeID: UUID
    let nonce: String
    let ranges: [HostedProofRange]
    let expiresAt: String
    enum CodingKeys: String, CodingKey { case challengeID = "challenge_id", nonce, ranges, expiresAt = "expires_at" }
}

func hostedDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
