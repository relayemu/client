// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  HostedCoverArtSource.swift
//  RelayHostedSync
//
//  Catalog covers from Relay's EU cover mirror (RelaySync docs/COVERS.md):
//  `GET /v1/covers/{system}/{digest}` answers 302 to a short-lived presigned
//  GET, or 404. Neither request says anything about the player: no account
//  token, cookie, schema header or identifier, and a fixed User-Agent.
//  Redirects are never followed automatically: the Location is checked, then
//  fetched with a 1 MiB response bound. URLs and keys are never logged.

import Foundation
import RelayLibrary
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HostedCoverArtSource: CoverArtSource {
    private let origin: URL
    private let executor: any HostedHTTPExecuting

    /// Nil unless `origin` is a bare HTTPS origin (the Relay Sync API of the build).
    public init?(origin: URL, executor: any HostedHTTPExecuting = HostedURLSessionExecutor(maximumResponseBytes: CoverImage.maximumBytes)) {
        guard origin.scheme == "https", origin.host?.isEmpty == false, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { return nil }
        self.origin = origin
        self.executor = executor
    }

    public func cover(forKey key: String) async -> CoverFetch {
        guard CoverKey.isValid(key), let url = URL(string: "/v1/covers/" + key, relativeTo: origin)?.absoluteURL else { return .invalid }
        let lookup: HTTPURLResponse
        do { (_, lookup) = try await executor.execute(Self.request(url)) } catch { return .unavailable }
        switch lookup.statusCode {
        case 302, 303, 307:
            guard let location = lookup.value(forHTTPHeaderField: "Location"), let target = URL(string: location),
                  target.scheme == "https", target.host?.isEmpty == false, target.user == nil, target.password == nil else { return .invalid }
            return await download(target)
        case 404:
            return .notFound
        default:
            return .unavailable
        }
    }

    private func download(_ url: URL) async -> CoverFetch {
        do {
            let (data, response) = try await executor.execute(Self.request(url))
            guard response.statusCode == 200 else { return .unavailable }
            return data.count <= CoverImage.maximumBytes ? .image(data) : .invalid
        } catch let error as HostedHTTPError where error.code == HostedHTTPError.invalidResponse.code {
            return .invalid   // over the response bound
        } catch {
            return .unavailable
        }
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("image/heic, image/jpeg", forHTTPHeaderField: "Accept")
        request.setValue("Relay", forHTTPHeaderField: "User-Agent")
        return request
    }
}
