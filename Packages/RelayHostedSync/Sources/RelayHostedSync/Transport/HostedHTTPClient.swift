// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelaySync
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HostedHTTPExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// No cookies, caches or redirects: an account bearer never follows a redirect.
public final class HostedURLSessionExecutor: NSObject, HostedHTTPExecuting, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumResponseBytes: Int
    public init(maximumResponseBytes: Int = 8 * 1024 * 1024) {
        self.maximumResponseBytes = maximumResponseBytes
        super.init()
    }
    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Control responses are bounded before buffering, including hostile peers.
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw HostedHTTPError.invalidResponse }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw HostedHTTPError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw HostedHTTPError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Safe classifications only; response bodies and request URLs never enter diagnostics.
public struct HostedHTTPError: Error, Sendable, CustomStringConvertible {
    public let status: Int?
    public let retryAfterSeconds: Int?
    public let code: String?
    public var problem: TransportProblem
    public init(status: Int? = nil, retryAfterSeconds: Int? = nil, code: String? = nil, problem: TransportProblem) {
        self.status = status; self.retryAfterSeconds = retryAfterSeconds; self.code = code; self.problem = problem
    }
    public var description: String { "Relay Sync request failed (\(status.map(String.init) ?? "transport"))" }
    public static let invalidResponse = HostedHTTPError(code: "invalid_response", problem: .invalidRecord("hosted response"))
    /// A schema-2 server refused schema 3; the session now speaks 2.
    public static let schemaFallback = "schema_fallback"
}

public final class HostedHTTPClient: Sendable {
    /// Semantic schema 3 is schema 2 plus custom-cover artwork (protocol 1.2.0).
    public static let artworkSchema = 3
    static let schemaHeader = "X-Relay-Sync-Schema"
    private let baseURL: URL
    private let executor: any HostedHTTPExecuting
    private let token: @Sendable () async throws -> String?
    private let negotiated: Mutex<Int>
    public init(baseURL: URL, executor: any HostedHTTPExecuting = HostedURLSessionExecutor(),
                token: @escaping @Sendable () async throws -> String? = { nil }) {
        self.baseURL = baseURL; self.executor = executor; self.token = token
        self.negotiated = Mutex(Self.artworkSchema)
    }

    /// The schema this session speaks: 3 until a server answers 426 naming 2, then 2 for the session.
    public var negotiatedSchema: Int { negotiated.withLock { $0 } }

    public func send(method: String, path: String, body: Data? = nil, authenticated: Bool = true, schema: Int? = nil) async throws -> Data {
        try await exchange(method: method, path: path, body: body, authenticated: authenticated, schema: schema).data
    }

    /// The body and the schema it was served under. An unpinned request that meets a
    /// schema-2 server lowers the session and is retried once under 2; a pinned one
    /// (a push whose operations carry their own schema) lowers it and fails.
    public func exchange(method: String, path: String, body: Data? = nil, authenticated: Bool = true,
                         schema pinned: Int? = nil) async throws -> (data: Data, schema: Int) {
        let schema = pinned ?? negotiatedSchema
        do { return (try await perform(method: method, path: path, body: body, authenticated: authenticated, schema: schema), schema) }
        catch let error as HostedHTTPError where error.code == HostedHTTPError.schemaFallback && pinned == nil {
            let lowered = negotiatedSchema
            return (try await perform(method: method, path: path, body: body, authenticated: authenticated, schema: lowered), lowered)
        }
    }

    private func perform(method: String, path: String, body: Data?, authenticated: Bool, schema: Int) async throws -> Data {
        var permittedScheme = baseURL.scheme == "https"
        #if DEBUG
        permittedScheme = permittedScheme || (baseURL.scheme == "http" && baseURL.host == "127.0.0.1" && baseURL.port != nil)
        #endif
        guard permittedScheme, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              path.hasPrefix("/v1/"), !path.contains("#"), !path.contains("\\"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port,
              (body?.count ?? 0) <= 1_048_576 else { throw HostedHTTPError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(schema), forHTTPHeaderField: Self.schemaHeader)
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            guard let bearer = try await token(), !bearer.isEmpty,
                  !bearer.contains("\r"), !bearer.contains("\n") else {
                throw HostedHTTPError(status: 401, problem: .accountUnavailable)
            }
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await executor.execute(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as HostedHTTPError { throw error }
        catch { throw HostedHTTPError(problem: .network) }
        guard data.count <= 8 * 1024 * 1024 else { throw HostedHTTPError.invalidResponse }
        let served = response.value(forHTTPHeaderField: Self.schemaHeader)
        if response.statusCode == 426, schema > SyncSchema.version, served == String(SyncSchema.version) {
            // A schema-2 server: this session continues under 2, without artwork.
            negotiated.withLock { $0 = min($0, SyncSchema.version) }
            throw HostedHTTPError(status: 426, code: HostedHTTPError.schemaFallback, problem: .network)
        }
        guard (200..<300).contains(response.statusCode) else {
            let status = response.statusCode
            let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            var problem: TransportProblem
            switch status {
            case 401, 403: problem = .accountUnavailable
            case 404: problem = .unknownItem
            case 409: problem = .serverRecordChanged
            case 413: problem = .limitExceeded
            case 423: problem = .other("vaultReadOnly")
            case 426: problem = .other("syncUpgradeRequired")
            case 429, 503: problem = .rateLimited(retryAfterSeconds: delay)
            case 500...599: problem = .network
            default: problem = .invalidRecord("hosted request")
            }
            struct ProblemBody: Decodable { let detail: String? }
            let problemBody = try? JSONDecoder().decode(ProblemBody.self, from: data)
            let detail = problemBody?.detail
            if status == 409 {
                switch detail {
                case "logical quota exceeded": problem = .quotaFull
                case "content target belongs to a retired generation": problem = .invalidRecord("content generation retired")
                case "content target state is deleted": problem = .invalidRecord("content state deleted")
                case "content target membership does not match": problem = .invalidRecord("content membership mismatch")
                case "content target generation is not available yet": problem = .rateLimited(retryAfterSeconds: 60)
                default: break
                }
            }
            let code: String?
            if status == 409 && detail == "content exists; use proof of possession" { code = "content_exists" }
            else if status == 409 && detail == "content target generation is not available yet" { code = "content_generation_future" }
            else if status == 409 && detail == "account_mismatch" { code = "account_mismatch" }
            else { code = nil }
            throw HostedHTTPError(status: status, retryAfterSeconds: delay, code: code, problem: problem)
        }
        // Semantic routes echo the negotiated schema; a different echo is not this conversation.
        if let served, served != String(schema) { throw HostedHTTPError.invalidResponse }
        return data
    }

    private static func retryDelay(_ value: String?) -> Int? {
        guard let value else { return nil }
        if let seconds = Int(value) { return min(86_400, max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(86_400, max(0, Int(ceil(date.timeIntervalSinceNow))))
    }

    public func request<Response: Decodable & Sendable>(method: String, path: String, body: Data? = nil,
                                                        authenticated: Bool = true, schema: Int? = nil, as: Response.Type) async throws -> Response {
        try await negotiatedRequest(method: method, path: path, body: body, authenticated: authenticated, schema: schema, as: Response.self).response
    }

    /// A decoded response and the schema it was served under.
    public func negotiatedRequest<Response: Decodable & Sendable>(method: String, path: String, body: Data? = nil, authenticated: Bool = true,
                                                                  schema: Int? = nil, as: Response.Type) async throws -> (response: Response, schema: Int) {
        let (data, served) = try await exchange(method: method, path: path, body: body, authenticated: authenticated, schema: schema)
        do { return (try JSONDecoder().decode(Response.self, from: data), served) }
        catch { throw HostedHTTPError.invalidResponse }
    }
}
