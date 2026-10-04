// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct AchievementHTTPResponse: Sendable {
    public let status: Int
    public let body: Data?
    public init(status: Int, body: Data?) { self.status = status; self.body = body }
    public static let unavailable = Self(status: -2, body: nil)
}

public protocol AchievementHTTPTransport: Sendable {
    func send(_ request: URLRequest) async -> AchievementHTTPResponse
}

public final class AchievementURLSessionTransport: AchievementHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: AchievementRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    static func accepts(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "retroachievements.org" && url.port == nil
            && url.path == "/dorequest.php" && url.user == nil && url.password == nil && url.query == nil
    }

    public func send(_ request: URLRequest) async -> AchievementHTTPResponse {
        guard Self.accepts(request.url), request.httpMethod == "POST" else { return .init(status: -1, body: nil) }
        do {
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, Self.accepts(response.url),
                  body.count <= 16 * 1024 * 1024 else { return .init(status: -1, body: nil) }
            return .init(status: response.statusCode, body: body)
        } catch { return .unavailable }
    }

}

private final class AchievementRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Never forward a password or session token through a redirect.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
