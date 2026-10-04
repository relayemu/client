// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RelayEntitlements
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns only account/session state. A generation fences in-flight work after
/// logout, account replacement or revocation; no late response reconnects it.
public actor RelayHostedAccountSession: RelayBillingClaiming {
    public private(set) var billingSnapshot: HostedBillingSnapshot?
    public nonisolated let environment: RelayHostedEnvironment
    private let store: any HostedSessionStoring
    private let installationID: UUID
    private let deviceKind: HostedDeviceKind
    private let executor: any HostedHTTPExecuting
    private let now: @Sendable () -> Date
    private var credential: HostedSessionCredential?
    private var overview: HostedAccountOverview?
    private var grant: RelaySyncEntitlementGrant?
    private var challenge: HostedAppleChallenge?
    private var generation = UUID()
    private var authenticationBusy = false
    private var observers: [UUID: AsyncStream<HostedAccountState>.Continuation] = [:]
    private var expiryTask: Task<Void, Never>?

    public init(environment: RelayHostedEnvironment, store: (any HostedSessionStoring)? = nil,
                installationID: UUID, deviceKind: HostedDeviceKind,
                executor: any HostedHTTPExecuting = HostedURLSessionExecutor(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.environment = environment
        self.store = store ?? HostedKeychainSessionStore(environment: environment, installationID: installationID)
        self.installationID = installationID; self.deviceKind = deviceKind
        self.executor = executor; self.now = now
    }

    deinit { expiryTask?.cancel() }

    public func stateUpdates() -> AsyncStream<HostedAccountState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    public var currentState: HostedAccountState {
        guard let credential, credential.expiresAt > now() else { return .signedOut }
        return .connected(HostedAccountSnapshot(accountID: credential.relayAccountID,
            expiresAt: credential.expiresAt, overview: overview, syncGrant: grant))
    }

    /// Keychain-only restore. A launch never performs a network request here.
    /// Cached observations keep their original expiry; foreground refresh is separate.
    public func restore() throws {
        guard credential == nil, !authenticationBusy else { return }
        let restored: HostedSessionCredential?
        do { restored = try store.load() }
        catch HostedAuthError.invalidResponse { try store.remove(); throw HostedAuthError.invalidResponse }
        guard let restored else { return }
        guard valid(restored) else { try store.remove(); throw HostedAuthError.expiredSession }
        credential = restored
        if let cached = try? store.loadObservation(), cached.overview.accountID == restored.relayAccountID,
           cached.observedAt <= now(), cached.observedAt.addingTimeInterval(86_400) > now() {
            overview = cached.overview
            grant = grantFor(cached.overview, credential: restored, observedAt: cached.observedAt)
        }
        generation = UUID()
        scheduleExpiry(); publish()
    }

    /// Access tokens never leave the transport/auth layer in application wiring.
    public func accessToken() throws -> String? {
        guard let credential else { return nil }
        guard credential.expiresAt > now() else {
            try clearLocal(); throw HostedAuthError.expiredSession
        }
        return credential.accessToken
    }

    /// A transport is permanently bound to the account that created it. Async
    /// UI/provider shutdown cannot make an old transport use a new account's bearer.
    public nonisolated func makeHTTPClient(expectedAccountID: UUID) -> HostedHTTPClient {
        HostedHTTPClient(baseURL: environment.apiOrigin,
            executor: SessionExecutor(underlying: executor, session: self),
            token: { [weak self] in try await self?.accessToken(expectedAccountID: expectedAccountID) })
    }

    private func accessToken(expectedAccountID: UUID) throws -> String? {
        guard credential?.relayAccountID == expectedAccountID else { throw HostedAuthError.signedOut }
        return try accessToken()
    }

    /// Transfer signaling uses the same account-bound authority as HTTP. The
    /// caller receives a task, never a bearer or an arbitrary authenticated URL.
    public func makeTransferWebSocket(expectedAccountID: UUID, presenceID: UUID,
                                     urlSession: URLSession) throws -> URLSessionWebSocketTask {
        guard let token = try accessToken(expectedAccountID: expectedAccountID) else { throw HostedAuthError.signedOut }
        var parts = URLComponents(url: environment.apiOrigin, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/transfer/signal"
        parts.queryItems = [URLQueryItem(name: "presenceID", value: presenceID.uuidString.lowercased())]
        guard let url = parts.url else { throw HostedAuthError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return urlSession.webSocketTask(with: request)
    }

    public func validateAccount(expectedAccountID: UUID) throws {
        guard try accessToken(expectedAccountID: expectedAccountID) != nil else { throw HostedAuthError.signedOut }
    }

    public func beginAppleSignIn() async throws -> HostedAppleChallenge {
        guard !authenticationBusy else { throw HostedAuthError.operationInProgress }
        authenticationBusy = true
        defer { authenticationBusy = false }
        let started = generation
        let data = try await publicClient.send(method: "POST", path: "/v1/auth/apple/challenges", authenticated: false)
        let result = try HostedAuthJSON.decode(HostedAppleChallenge.self, from: data)
        guard generation == started else { throw HostedAuthError.staleOperation }
        guard result.expiresAt > now(), result.expiresAt.timeIntervalSince(now()) <= 360,
              result.nonce.utf8.count == 43,
              result.nonce.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw HostedAuthError.invalidChallenge
        }
        challenge = result
        return result
    }

    public func completeAppleSignIn(identityToken: Data, challengeID: UUID) async throws {
        guard !authenticationBusy else { throw HostedAuthError.operationInProgress }
        guard let challenge, challenge.challengeID == challengeID, challenge.expiresAt > now(),
              !identityToken.isEmpty, identityToken.count <= 32_768,
              let token = String(data: identityToken, encoding: .utf8) else { throw HostedAuthError.invalidChallenge }
        self.challenge = nil // Each native result gets exactly one exchange attempt.
        authenticationBusy = true
        defer { authenticationBusy = false }
        let started = generation
        struct Exchange: Encodable {
            let identityToken: String; let challengeID: String; let installationID: String; let deviceKind: HostedDeviceKind
        }
        let body = try JSONEncoder().encode(Exchange(identityToken: token,
            challengeID: challengeID.uuidString.lowercased(), installationID: installationID.uuidString.lowercased(), deviceKind: deviceKind))
        let data = try await publicClient.send(method: "POST", path: "/v1/auth/apple", body: body, authenticated: false)
        let replacement = try HostedAuthJSON.decode(HostedSessionCredential.self, from: data)
        guard generation == started else {
            _ = try? await client(for: replacement).send(method: "POST", path: "/v1/auth/logout")
            throw HostedAuthError.staleOperation
        }
        guard valid(replacement) else { throw HostedAuthError.invalidResponse }
        do { try store.save(replacement) }
        catch {
            _ = try? await client(for: replacement).send(method: "POST", path: "/v1/auth/logout")
            throw error
        }
        let previous = credential
        credential = replacement; overview = nil; grant = nil; billingSnapshot = nil; generation = UUID()
        scheduleExpiry(); publish()
        if let previous { _ = try? await client(for: previous).send(method: "POST", path: "/v1/auth/logout") }
    }

    public func refreshAccount() async throws {
        guard let current = credential, current.expiresAt > now() else { throw HostedAuthError.signedOut }
        let started = generation
        struct Response: Decodable { let overview: HostedAccountOverview }
        let data = try await makeHTTPClient(expectedAccountID: current.relayAccountID).send(method: "GET", path: "/v1/account")
        let response = try HostedAuthJSON.decode(Response.self, from: data)
        guard generation == started else { throw HostedAuthError.staleOperation }
        guard response.overview.accountID == current.relayAccountID else { throw HostedAuthError.invalidResponse }
        overview = response.overview
        let observation = HostedAccountObservation(overview: response.overview, observedAt: now())
        grant = grantFor(response.overview, credential: current, observedAt: observation.observedAt)
        publish()
        try store.saveObservation(observation)
    }

    /// Only StoreKit's verified compact JWS crosses this boundary. The account
    /// is checked before and after awaits; a late claim cannot reconnect logout.
    public func claim(transactionJWS: String, accountID: UUID) async throws {
        guard let current = credential, current.expiresAt > now(), current.relayAccountID == accountID else {
            throw RelayEntitlementError.accountRequired
        }
        guard !transactionJWS.isEmpty, transactionJWS.utf8.count <= 65_536 else {
            throw RelayEntitlementError.failedVerification
        }
        let started = generation
        struct Claim: Encodable { let signedTransaction: String }
        let body = try JSONEncoder().encode(Claim(signedTransaction: transactionJWS))
        let data: Data
        do {
            data = try await makeHTTPClient(expectedAccountID: accountID).send(
                method: "POST", path: "/v1/billing/apple/claim", body: body)
        } catch let error as HostedHTTPError where error.status == 409 && error.code == "account_mismatch" {
            throw RelayEntitlementError.accountMismatch
        }
        guard generation == started else { throw HostedAuthError.staleOperation }
        billingSnapshot = try HostedAuthJSON.decode(HostedBillingSnapshot.self, from: data)
        try await refreshAccount()
        guard generation == started else { throw HostedAuthError.staleOperation }
    }

    public func refreshBilling() async throws {
        guard let current = credential, current.expiresAt > now() else { throw HostedAuthError.signedOut }
        let started = generation
        let data = try await makeHTTPClient(expectedAccountID: current.relayAccountID).send(
            method: "POST", path: "/v1/billing/refresh", body: Data("{}".utf8))
        guard generation == started else { throw HostedAuthError.staleOperation }
        billingSnapshot = try HostedAuthJSON.decode(HostedBillingSnapshot.self, from: data)
        try await refreshAccount()
    }

    /// Call on foreground before expiry. Concurrent rotations are rejected;
    /// an expired/401 session always requires a new native Apple authorization.
    public func rotateIfNeeded() async throws {
        guard let current = credential else { return }
        guard current.expiresAt > now() else { try clearLocal(); throw HostedAuthError.expiredSession }
        guard current.expiresAt.timeIntervalSince(now()) < 24 * 60 * 60 else { return }
        guard !authenticationBusy else { throw HostedAuthError.operationInProgress }
        authenticationBusy = true
        defer { authenticationBusy = false }
        let started = generation
        let data = try await makeHTTPClient(expectedAccountID: current.relayAccountID).send(method: "POST", path: "/v1/auth/rotate")
        let replacement = try HostedAuthJSON.decode(HostedSessionCredential.self, from: data)
        guard generation == started else {
            _ = try? await client(for: replacement).send(method: "POST", path: "/v1/auth/logout")
            throw HostedAuthError.staleOperation
        }
        guard valid(replacement), replacement.relayAccountID == current.relayAccountID else {
            try clearLocal(); throw HostedAuthError.invalidResponse
        }
        do { try store.save(replacement) }
        catch {
            try? clearLocal()
            _ = try? await client(for: replacement).send(method: "POST", path: "/v1/auth/logout")
            throw error
        }
        credential = replacement; generation = UUID()
        scheduleExpiry(); publish()
    }

    /// Local sign-out happens before the network await. Failure to reach the
    /// server is surfaced so UI can distinguish local removal from revocation.
    public func logout() async throws {
        let previous = credential
        try clearLocal()
        guard let previous else { return }
        do { _ = try await client(for: previous).send(method: "POST", path: "/v1/auth/logout") }
        catch let error as HostedHTTPError where error.status == 401 { return }
    }

    fileprivate func invalidate(bearer: String?) throws {
        guard let credential, bearer == "Bearer " + credential.accessToken else { return }
        try clearLocal()
    }
    private var publicClient: HostedHTTPClient { HostedHTTPClient(baseURL: environment.apiOrigin, executor: executor) }
    private func client(for credential: HostedSessionCredential) -> HostedHTTPClient {
        HostedHTTPClient(baseURL: environment.apiOrigin, executor: executor, token: { credential.accessToken })
    }
    private func valid(_ credential: HostedSessionCredential) -> Bool {
        credential.expiresAt > now() && credential.accessToken.utf8.count == 43 &&
        credential.accessToken.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    private func grantFor(_ overview: HostedAccountOverview, credential: HostedSessionCredential, observedAt: Date) -> RelaySyncEntitlementGrant? {
        RelaySyncEntitlementGrant(accountID: credential.relayAccountID, planID: overview.planID,
            vaultState: overview.vaultState.rawValue, entitledUntil: overview.entitledUntil,
            observedAt: observedAt, sessionExpiresAt: credential.expiresAt)
    }
    private func clearLocal() throws {
        generation = UUID(); credential = nil; overview = nil; grant = nil; billingSnapshot = nil; challenge = nil
        expiryTask?.cancel(); expiryTask = nil
        publish()
        try store.remove()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let credential else { return }
        let seconds = max(0, credential.expiresAt.timeIntervalSince(now()))
        let started = generation
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 31_536_000) * 1_000_000_000)) }
            catch { return }
            await self?.expire(generation: started)
        }
    }
    private func expire(generation expected: UUID) {
        guard generation == expected else { return }
        if credential?.expiresAt ?? .distantPast <= now() { try? clearLocal() }
        else { scheduleExpiry() }
    }
    private func publish() { for continuation in observers.values { continuation.yield(currentState) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

private struct SessionExecutor: HostedHTTPExecuting {
    let underlying: any HostedHTTPExecuting
    let session: RelayHostedAccountSession
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await underlying.execute(request)
        if response.1.statusCode == 401 { try await session.invalidate(bearer: request.value(forHTTPHeaderField: "Authorization")) }
        return response
    }
}
