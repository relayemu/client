// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayHostedSync
import RelayEntitlements
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HostedAccountSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testProductionRequestsAndCredentialsStaySeparateFromClosedBeta() async throws {
        let production = RelayHostedEnvironment.production
        XCTAssertEqual(production.portalOrigin.absoluteString, "https://account.relayemu.app")
        XCTAssertNotEqual(production.keychainService, RelayHostedEnvironment.preproduction.keychainService)
        let executor = AuthExecutor([(200, Data("{}".utf8))])
        let client = HostedHTTPClient(baseURL: production.apiOrigin, executor: executor, token: { "fixture-token" })
        _ = try await client.send(method: "GET", path: "/v1/account")
        let requests = await executor.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://sync.relayemu.app/v1/account")
    }

    #if DEBUG
    func testPublicAddressPreviewKeepsAuthenticatedRequestsOnLoopback() async throws {
        let origin = URL(string: "http://127.0.0.1:60617")!
        let environment = try RelayHostedEnvironment.transferTestEnvironment(origin: origin, showPublicPortal: true)
        XCTAssertEqual(environment.portalOrigin.absoluteString, "https://account.relayemu.app")
        let executor = AuthExecutor([(200, Data("{}".utf8))])
        let client = HostedHTTPClient(baseURL: environment.apiOrigin, executor: executor, token: { "fixture-token" })
        _ = try await client.send(method: "GET", path: "/v1/account")
        let requests = await executor.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "http://127.0.0.1:60617/v1/account")
    }

    func testPublicAddressPreviewCannotExpandFixtureNetworkScope() throws {
        for address in ["https://account.relayemu.app", "http://192.168.1.1:60617", "http://127.0.0.1:60617/path"] {
            XCTAssertThrowsError(try RelayHostedEnvironment.transferTestEnvironment(
                origin: URL(string: address)!, showPublicPortal: true))
        }
    }
    #endif

    func testNativeExchangeUsesServerChallengeAndPersistsOnlyOpaqueSession() async throws {
        let challengeID = UUID()
        let executor = AuthExecutor([
            (201, json(["challengeID": challengeID.uuidString, "nonce": String(repeating: "n", count: 43), "expiresAt": date(300)])),
            (200, credentialData())
        ])
        let store = AuthMemoryStore()
        let session = makeSession(store: store, executor: executor)
        let challenge = try await session.beginAppleSignIn()
        try await session.completeAppleSignIn(identityToken: Data("synthetic.apple.jwt".utf8), challengeID: challenge.challengeID)
        XCTAssertEqual(try store.load()?.relayAccountID, account)
        let requests = await executor.requests
        let body = try XCTUnwrap(requests.last?.httpBody)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(input["challengeID"], challengeID.uuidString.lowercased())
        XCTAssertEqual(input["installationID"], installation.uuidString.lowercased())
        XCTAssertEqual(input["deviceKind"], "mac")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(describing: try store.load()).contains("synthetic.apple.jwt"))
    }

    func testExpiredAndMalformedCredentialNeverRestores() async throws {
        for token in [String(repeating: "a", count: 43), "bad\ncredential"] {
            let store = AuthMemoryStore(HostedSessionCredential(accessToken: token, expiresAt: now.addingTimeInterval(-1), relayAccountID: account))
            let session = makeSession(store: store, executor: AuthExecutor([]))
            do { try await session.restore(); XCTFail("Expired credential restored") }
            catch { XCTAssertEqual(error as? HostedAuthError, .expiredSession) }
            XCTAssertNil(try store.load())
            let state = await session.currentState
            XCTAssertEqual(state, .signedOut)
        }
    }

    func testInvalidExchangeCannotInstallSession() async throws {
        for invalid in [Data("not-json".utf8),
                        json(["accessToken": "bad\nheader", "expiresAt": date(300), "relayAccountID": account.uuidString]),
                        json(["accessToken": String(repeating: "a", count: 43), "expiresAt": date(-1), "relayAccountID": account.uuidString])] {
            let challengeID = UUID()
            let executor = AuthExecutor([(201, json(["challengeID": challengeID.uuidString,
                "nonce": String(repeating: "n", count: 43), "expiresAt": date(300)])), (200, invalid)])
            let store = AuthMemoryStore()
            let session = makeSession(store: store, executor: executor)
            _ = try await session.beginAppleSignIn()
            do {
                try await session.completeAppleSignIn(identityToken: Data("synthetic.jwt".utf8), challengeID: challengeID)
                XCTFail("Invalid exchange accepted")
            } catch { XCTAssertEqual(error as? HostedAuthError, .invalidResponse) }
            XCTAssertNil(try store.load())
        }
    }

    func testExpiredOrMalformedChallengeIsNotPassedToApple() async throws {
        for (nonce, expiry) in [("not-a-nonce", 300.0), (String(repeating: "n", count: 43), -1.0), (String(repeating: "n", count: 43), 3600.0)] {
            let executor = AuthExecutor([(201, json(["challengeID": UUID().uuidString, "nonce": nonce, "expiresAt": date(expiry)]))])
            let session = makeSession(store: AuthMemoryStore(), executor: executor)
            do { _ = try await session.beginAppleSignIn(); XCTFail("Invalid challenge accepted") }
            catch { XCTAssertEqual(error as? HostedAuthError, .invalidChallenge) }
        }
    }

    func testUnauthorizedTransportRevokesLocalCredentialAndGrant() async throws {
        let store = AuthMemoryStore(credential())
        let executor = AuthExecutor([(401, Data())])
        let session = makeSession(store: store, executor: executor)
        try await session.restore()
        do { _ = try await session.makeHTTPClient(expectedAccountID: account).send(method: "GET", path: "/v1/account"); XCTFail("401 accepted") }
        catch { XCTAssertEqual((error as? HostedHTTPError)?.status, 401) }
        XCTAssertNil(try store.load())
        let state = await session.currentState
        XCTAssertEqual(state, .signedOut)
    }

    func testFailedLogoutStillRemovesLocalCredential() async throws {
        let store = AuthMemoryStore(credential())
        let session = makeSession(store: store, executor: AuthExecutor([(503, Data())]))
        try await session.restore()
        do { try await session.logout(); XCTFail("Unconfirmed revocation hidden") }
        catch { XCTAssertEqual((error as? HostedHTTPError)?.status, 503) }
        XCTAssertNil(try store.load())
        let state = await session.currentState
        XCTAssertEqual(state, .signedOut)
    }

    func testAccountObservationBindsGrantToAccountAndBoundsCache() async throws {
        let store = AuthMemoryStore(credential(expires: 172_800))
        let executor = AuthExecutor([(200, accountData(accountID: account, state: "ACTIVE"))])
        let session = makeSession(store: store, executor: executor)
        try await session.restore()
        try await session.refreshAccount()
        guard case let .connected(snapshot) = await session.currentState else { return XCTFail("Not connected") }
        XCTAssertEqual(snapshot.overview?.planID, "sync_plus")
        XCTAssertEqual(snapshot.syncGrant?.validUntil, now.addingTimeInterval(86_400))
    }

    func testCrossAccountAndUnknownStateFailClosed() async throws {
        for (id, state) in [(UUID(), "ACTIVE"), (account, "FUTURE_STATE"), (account, "RECOVERY")] {
            let session = makeSession(store: AuthMemoryStore(credential()), executor: AuthExecutor([(200, accountData(accountID: id, state: state))]))
            try await session.restore()
            if id != account {
                do { try await session.refreshAccount(); XCTFail("Cross-account overview accepted") }
                catch { XCTAssertEqual(error as? HostedAuthError, .invalidResponse) }
            } else { try await session.refreshAccount() }
            guard case let .connected(snapshot) = await session.currentState else { return XCTFail("Not connected") }
            XCTAssertNil(snapshot.syncGrant)
        }
    }

    func testSecretDescriptionsAndMirrorsAreRedacted() throws {
        let secret = credential()
        XCTAssertFalse(String(describing: secret).contains(secret.accessToken))
        XCTAssertFalse(String(reflecting: secret).contains(secret.accessToken))
        XCTAssertTrue(Mirror(reflecting: secret).children.isEmpty)
    }

    func testRotationPersistsReplacementAndUsesCurrentBearer() async throws {
        let store = AuthMemoryStore(credential(expires: 60))
        let replacement = HostedSessionCredential(accessToken: String(repeating: "b", count: 43), expiresAt: now.addingTimeInterval(172_800), relayAccountID: account)
        let executor = AuthExecutor([(200, json(["accessToken": replacement.accessToken, "expiresAt": date(172_800), "relayAccountID": account.uuidString]))])
        let session = makeSession(store: store, executor: executor)
        try await session.restore(); try await session.rotateIfNeeded()
        XCTAssertEqual(try store.load()?.accessToken, replacement.accessToken)
        let requests = await executor.requests
        XCTAssertEqual(requests.first?.url?.path, "/v1/auth/rotate")
        XCTAssertEqual(requests.count, 1)
    }

    func testCachedAccountObservationSurvivesRestartWithoutRenewingLease() async throws {
        let store = AuthMemoryStore(credential(expires: 172_800))
        let session = makeSession(store: store, executor: AuthExecutor([(200, accountData(accountID: account, state: "ACTIVE"))]))
        try await session.restore(); try await session.refreshAccount()
        let advancedNow = now.addingTimeInterval(86_399)
        let restarted = RelayHostedAccountSession(environment: .preproduction, store: store,
            installationID: installation, deviceKind: .mac, executor: AuthExecutor([]), now: { advancedNow })
        try await restarted.restore()
        guard case let .connected(snapshot) = await restarted.currentState else { return XCTFail("Not connected") }
        XCTAssertEqual(snapshot.syncGrant?.validUntil, now.addingTimeInterval(86_400))
        XCTAssertTrue(snapshot.syncGrant?.isActive(at: advancedNow) == true)
        XCTAssertFalse(snapshot.syncGrant?.isActive(at: advancedNow.addingTimeInterval(2)) == true)
    }

    func testOldUnauthorizedResponseCannotClearNewSession() async throws {
        let challengeID = UUID()
        let executor = RacingAuthExecutor(challenge: json(["challengeID": challengeID.uuidString,
            "nonce": String(repeating: "n", count: 43), "expiresAt": date(300)]),
            exchange: json(["accessToken": String(repeating: "b", count: 43), "expiresAt": date(3600), "relayAccountID": account.uuidString]))
        let store = AuthMemoryStore(credential())
        let capturedNow = now
        let session = RelayHostedAccountSession(environment: .preproduction, store: store,
            installationID: installation, deviceKind: .mac, executor: executor, now: { capturedNow })
        try await session.restore()
        let oldClient = session.makeHTTPClient(expectedAccountID: account)
        let oldRequest = Task { try await oldClient.send(method: "GET", path: "/v1/account") }
        await executor.waitForOldRequest()
        try await session.logout()
        _ = try await session.beginAppleSignIn()
        try await session.completeAppleSignIn(identityToken: Data("synthetic.jwt".utf8), challengeID: challengeID)
        await executor.releaseOldRequest()
        _ = try? await oldRequest.value
        XCTAssertEqual(try store.load()?.accessToken, String(repeating: "b", count: 43))
        guard case .connected = await session.currentState else { return XCTFail("Retired request cleared the new session") }
    }

    func testRetainedAccountClientCannotSendIntoReplacementAccount() async throws {
        let challengeID = UUID(), replacementAccount = UUID()
        let executor = AuthExecutor([
            (201, json(["challengeID": challengeID.uuidString, "nonce": String(repeating: "n", count: 43), "expiresAt": date(300)])),
            (200, json(["accessToken": String(repeating: "b", count: 43), "expiresAt": date(3600), "relayAccountID": replacementAccount.uuidString])),
            (204, Data()), // Retire the old account's session after installing the new one.
            (200, Data())
        ])
        let session = makeSession(store: AuthMemoryStore(credential()), executor: executor)
        try await session.restore()
        let retained = session.makeHTTPClient(expectedAccountID: account)
        _ = try await session.beginAppleSignIn()
        try await session.completeAppleSignIn(identityToken: Data("synthetic.jwt".utf8), challengeID: challengeID)
        for path in ["/v1/sync/push", "/v1/content/uploads"] {
            do {
                _ = try await retained.send(method: "POST", path: path, body: Data("private-account-A-payload".utf8))
                XCTFail("Retired account client used replacement bearer")
            } catch { XCTAssertEqual(error as? HostedAuthError, .signedOut) }
        }
        let requestsAfterBlockedSends = await executor.requests
        XCTAssertEqual(requestsAfterBlockedSends.count, 3)
        _ = try await session.makeHTTPClient(expectedAccountID: replacementAccount).send(method: "GET", path: "/v1/account")
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "b", count: 43))
    }

    #if canImport(Security)
    func testKeychainScopesCredentialsAndCacheToExactInstallation() {
        let first = HostedKeychainSessionStore(environment: .preproduction, installationID: installation)
        let second = HostedKeychainSessionStore(environment: .preproduction, installationID: UUID())
        XCTAssertNotEqual(first.query()[kSecAttrAccount as String] as? String,
                          second.query()[kSecAttrAccount as String] as? String)
        XCTAssertEqual(first.query()[kSecAttrAccount as String] as? String,
                       installation.uuidString.lowercased() + "/api-session")
        XCTAssertEqual(first.query(account: "account-observation")[kSecAttrAccount as String] as? String,
                       installation.uuidString.lowercased() + "/account-observation")
        XCTAssertEqual(first.query()[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(first.query()[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }
    #endif

    func testBillingClaimSendsOnlySignedProofAndRefreshesBoundedBackendGrant() async throws {
        let billing = json(["status": "active", "directProOnce": false, "effectiveQuotaBytes": 500_000_000_000,
            "vaultState": "ACTIVE", "currentProductID": "app.relayemu.relay.syncplus.monthly"])
        let executor = AuthExecutor([(200, billing), (200, accountData(accountID: account, state: "ACTIVE"))])
        let session = makeSession(store: AuthMemoryStore(credential()), executor: executor)
        try await session.restore()
        try await session.claim(transactionJWS: "verified.synthetic.jws", accountID: account)
        let requests = await executor.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/billing/apple/claim", "/v1/account"])
        let payload = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(payload, ["signedTransaction": "verified.synthetic.jws"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + credential().accessToken)
        let snapshot = await session.billingSnapshot
        XCTAssertEqual(snapshot?.effectiveQuotaBytes, 500_000_000_000)
        guard case .connected(let state) = await session.currentState else { return XCTFail("Signed out") }
        XCTAssertNotNil(state.syncGrant)
    }

    func testBillingClaimRejectsDifferentAccountBeforeNetwork() async throws {
        let executor = AuthExecutor([])
        let session = makeSession(store: AuthMemoryStore(credential()), executor: executor)
        try await session.restore()
        do { try await session.claim(transactionJWS: "signed.proof", accountID: UUID()); XCTFail("Wrong account accepted") }
        catch { XCTAssertEqual(error as? RelayEntitlementError, .accountRequired) }
        let requests = await executor.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBillingAccountMismatchHasSafeTypedErrorAndNoGrant() async throws {
        let executor = AuthExecutor([(409, json(["type": "about:blank", "title": "Conflict", "status": 409, "detail": "account_mismatch"]))])
        let session = makeSession(store: AuthMemoryStore(credential()), executor: executor)
        try await session.restore()
        do { try await session.claim(transactionJWS: "signed.proof", accountID: account); XCTFail("Mismatch accepted") }
        catch { XCTAssertEqual(error as? RelayEntitlementError, .accountMismatch) }
        let snapshot = await session.billingSnapshot
        XCTAssertNil(snapshot)
        guard case .connected(let state) = await session.currentState else { return XCTFail("Signed out") }
        XCTAssertNil(state.syncGrant)
    }

    func testBillingRefreshDecodesFutureProductWithoutGrantingFromThatIntent() async throws {
        let billing = json(["status": "retry", "directProOnce": true, "effectiveQuotaBytes": 125_000_000_000,
            "vaultState": "RECOVERY", "currentProductID": "app.relayemu.relay.sync.monthly",
            "pendingProductID": "app.relayemu.relay.syncplus.yearly", "autoRenew": true])
        let session = makeSession(store: AuthMemoryStore(credential()), executor:
            AuthExecutor([(200, billing), (200, accountData(accountID: account, state: "RECOVERY"))]))
        try await session.restore(); try await session.refreshBilling()
        let snapshot = await session.billingSnapshot
        XCTAssertEqual(snapshot?.pendingProductID, "app.relayemu.relay.syncplus.yearly")
        XCTAssertEqual(snapshot?.directProOnce, true)
        guard case .connected(let state) = await session.currentState else { return XCTFail("Signed out") }
        XCTAssertNil(state.syncGrant)
    }

    private func makeSession(store: AuthMemoryStore, executor: AuthExecutor) -> RelayHostedAccountSession {
        let capturedNow = now
        return RelayHostedAccountSession(environment: .preproduction, store: store, installationID: installation,
            deviceKind: .mac, executor: executor, now: { capturedNow })
    }
    private func credential(expires: TimeInterval = 3600) -> HostedSessionCredential {
        HostedSessionCredential(accessToken: String(repeating: "a", count: 43), expiresAt: now.addingTimeInterval(expires), relayAccountID: account)
    }
    private func credentialData() -> Data { json(["accessToken": String(repeating: "a", count: 43), "expiresAt": date(3600), "relayAccountID": account.uuidString]) }
    private func accountData(accountID: UUID, state: String) -> Data {
        json(["overview": ["AccountID": accountID.uuidString, "VaultState": state, "PlanID": "sync_plus",
            "UsedBytes": 5, "QuotaBytes": 100, "EntitledUntil": date(200_000), "DeviceCount": 2, "ConflictCount": 0]])
    }
    private func date(_ offset: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}

private final class AuthMemoryStore: HostedSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HostedSessionCredential?
    private var observation: HostedAccountObservation?
    init(_ credential: HostedSessionCredential? = nil) { self.credential = credential }
    func load() throws -> HostedSessionCredential? { lock.lock(); defer { lock.unlock() }; return credential }
    func save(_ credential: HostedSessionCredential) throws { lock.lock(); defer { lock.unlock() }; self.credential = credential }
    func remove() throws { lock.lock(); defer { lock.unlock() }; credential = nil; observation = nil }
    func loadObservation() throws -> HostedAccountObservation? { lock.lock(); defer { lock.unlock() }; return observation }
    func saveObservation(_ observation: HostedAccountObservation) throws { lock.lock(); defer { lock.unlock() }; self.observation = observation }
}

private actor RacingAuthExecutor: HostedHTTPExecuting {
    let challenge: Data
    let exchange: Data
    private var old: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var started: CheckedContinuation<Void, Never>?
    init(challenge: Data, exchange: Data) { self.challenge = challenge; self.exchange = exchange }
    func waitForOldRequest() async {
        if old != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseOldRequest() {
        old?.resume(returning: (Data(), HTTPURLResponse(url: URL(string: "https://sync-preprod.relayemu.app/v1/account")!, statusCode: 401, httpVersion: nil, headerFields: nil)!))
        old = nil
    }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status: Int
        let data: Data
        switch request.url?.path {
        case "/v1/account":
            return try await withCheckedThrowingContinuation { continuation in
                old = continuation; started?.resume(); started = nil
            }
        case "/v1/auth/apple/challenges": status = 201; data = challenge
        case "/v1/auth/apple": status = 200; data = exchange
        case "/v1/auth/logout": status = 204; data = Data()
        default: throw URLError(.unsupportedURL)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor AuthExecutor: HostedHTTPExecuting {
    private var responses: [(Int, Data)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, Data)]) { self.responses = responses }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        let response = responses.removeFirst()
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
}
