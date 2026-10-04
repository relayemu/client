// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import AuthenticationServices
import RelayDomain
import RelayLibrary
import RelayHostedSync
import RelayEntitlements

/// The native account presentation boundary. Views consume product copy and
/// values; authentication material stays in AuthenticationServices and the session.
@MainActor @Observable
public final class RelayAccountModel {
    public private(set) var isConnected = false
    public private(set) var isBusy = false
    public private(set) var hasLoadedAccount = false
    public private(set) var accountID: UUID?
    public private(set) var planName: String?
    public private(set) var usedBytes: Int64 = 0
    public private(set) var quotaBytes: Int64 = 0
    public private(set) var vaultStatus = L("Not connected")
    public private(set) var recoveryMessage: String?
    public private(set) var purgeAt: Date?
    public private(set) var lastSyncAt: Date?
    public private(set) var canUpload = false
    public private(set) var errorMessage: String?
    public let environment: RelayHostedEnvironment
    public private(set) var session: RelayHostedAccountSession?
    public private(set) var currentMembershipName: String?
    public private(set) var billingStatus: String?
    public private(set) var pendingMembershipName: String?
    public private(set) var billingEntitledUntil: Date?
    public private(set) var autoRenew: Bool?
    public var billingRenewalMessage: String? {
        billingPresentation?.renewalMessage(now: Date())
    }
    public var billingAttentionMessage: String? {
        billingPresentation?.attentionMessage(now: Date())
    }
    private var billingPresentation: HostedBillingPresentation?
    public let membership: RelaySyncMembershipModel
    private let configureBilling: @MainActor (RelayHostedAccountSession) -> Void
    private let billingAccountChanged: @MainActor (UUID?) -> Void
    private let entitlements: CombinedRelayEntitlementProvider
    private let sessionStoreFactory: (@Sendable (UUID) -> any HostedSessionStoring)?
    private var updates: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var authorization: NativeAppleAuthorization?
    private weak var sync: SyncModel?
    private var transport: RelayHostedSyncTransport?

    public func trackTransport(_ transport: RelayHostedSyncTransport) {
        self.transport = transport
        let writable = canUpload
        Task { await transport.setVaultWritable(writable) }
    }

    public init(environment: RelayHostedEnvironment, entitlements: CombinedRelayEntitlementProvider,
                sessionStoreFactory: (@Sendable (UUID) -> any HostedSessionStoring)? = nil,
                configureBilling: @escaping @MainActor (RelayHostedAccountSession) -> Void = { _ in },
                billingAccountChanged: @escaping @MainActor (UUID?) -> Void = { _ in }) {
        self.environment = environment
        self.entitlements = entitlements
        self.sessionStoreFactory = sessionStoreFactory
        self.membership = RelaySyncMembershipModel(provider: entitlements)
        self.configureBilling = configureBilling
        self.billingAccountChanged = billingAccountChanged
    }

    func start(identity: SyncIdentity, sync: SyncModel) {
        guard session == nil else { return }
        self.sync = sync
        let session = RelayHostedAccountSession(environment: environment,
                                               store: sessionStoreFactory?(identity.installationID.rawValue),
                                               installationID: identity.installationID.rawValue,
                                               deviceKind: Self.hostedDeviceKind(identity.deviceKind))
        self.session = session
        configureBilling(session)
        updates = Task { [weak self] in
            for await state in await session.stateUpdates() {
                guard let self, !Task.isCancelled else { return }
                let previousID = self.accountID
                self.receive(state)
                await self.receiveBillingSnapshot()
                if previousID != self.accountID { await self.sync?.relayAccountDidChange() }
            }
        }
        restoreTask = Task { [weak self] in
            do {
                try await session.restore()
                if case .connected = await session.currentState {
                    self?.receive(await session.currentState)
                    try await session.refreshAccount()
                    await self?.reconcileMembership()
                }
            }
            catch { self?.show(error) }
        }
    }

    private static func hostedDeviceKind(_ kind: DeviceKind) -> HostedDeviceKind {
        switch kind {
        case .iPhone: .iphone
        case .iPad: .ipad
        case .appleTV: .appletv
        case .mac: .mac
        default: .unknown
        }
    }

    private func receive(_ state: HostedAccountState) {
        let previousAccountID = accountID
        defer {
            billingAccountChanged(accountID)
            membership.updateAccount(accountID, directProOnceVerified: previousAccountID == accountID && membership.hasDirectProOnceBonus)
            if let transport {
                let writable = canUpload
                Task { await transport.setVaultWritable(writable) }
            }
        }
        switch state {
        case .signedOut:
            isConnected = false; accountID = nil; hasLoadedAccount = false
            planName = nil; usedBytes = 0; quotaBytes = 0
            vaultStatus = L("Not connected"); recoveryMessage = nil; purgeAt = nil; lastSyncAt = nil; canUpload = false
            membership.updateAccount(nil)
            currentMembershipName = nil; billingStatus = nil; pendingMembershipName = nil; billingEntitledUntil = nil; autoRenew = nil; billingPresentation = nil
            entitlements.updateSyncGrant(nil)
        case .connected(let snapshot):
            isConnected = true; accountID = snapshot.accountID
            if previousAccountID != snapshot.accountID {
                planName = nil; usedBytes = 0; quotaBytes = 0
                recoveryMessage = nil; purgeAt = nil; lastSyncAt = nil
                currentMembershipName = nil; billingStatus = nil; pendingMembershipName = nil; billingEntitledUntil = nil; autoRenew = nil; billingPresentation = nil
            }
            entitlements.updateSyncGrant(snapshot.syncGrant)
            guard let overview = snapshot.overview else {
                hasLoadedAccount = false; canUpload = false
                vaultStatus = L("Account status unavailable")
                return
            }
            hasLoadedAccount = true
            planName = overview.planID == "sync" ? "Relay Sync" : overview.planID == "sync_plus" ? "Relay Sync+" : nil
            usedBytes = overview.usedBytes; quotaBytes = overview.quotaBytes
            purgeAt = overview.purgeAt; lastSyncAt = overview.lastSyncAt
            canUpload = overview.vaultState == .active && overview.entitledUntil.map { $0 > Date() } == true
            switch overview.vaultState {
            case .active:
                vaultStatus = L("Active")
                recoveryMessage = canUpload ? nil : L("No active Relay Sync plan. Your local games and saves stay available.")
            case .recovery:
                vaultStatus = L("Recovery")
                recoveryMessage = L("Download your games and saves before the recovery period ends. New uploads are paused. Your local progress stays safe.")
            case .purgePending:
                vaultStatus = L("Removal pending")
                recoveryMessage = L("Your online storage is being removed. The games and saves on this device stay yours.")
            case .purged:
                vaultStatus = L("Online storage removed")
                recoveryMessage = L("Your online storage has been removed. Your local games and saves have not been deleted.")
            case .unknown:
                vaultStatus = L("Account status unavailable")
                recoveryMessage = L("Refresh your account status or open your account portal. Your local games and saves stay available.")
            }
        }
    }

    public func refresh() async {
        guard let session, isConnected, !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await session.rotateIfNeeded()
            try await session.refreshAccount()
            await reconcileMembership()
        }
        catch { show(error) }
    }

    /// Runs outside local library/game startup. A failed backend claim retains
    /// Apple's unfinished proof and presents an explicit retry path.
    private func reconcileMembership() async {
        guard let session, isConnected else { return }
        await membership.retrySetup(announceSuccess: false)
        do { try await session.refreshBilling() }
        catch { show(error) }
        await receiveBillingSnapshot()
    }

    private func receiveBillingSnapshot() async {
        guard let session, let expectedAccount = accountID else { return }
        let snapshot = await session.billingSnapshot
        guard accountID == expectedAccount, let snapshot else { return }
        membership.updateAccount(expectedAccount, directProOnceVerified: snapshot.directProOnce)
        let presentation = HostedBillingPresentation(snapshot: snapshot, now: Date())
        billingPresentation = presentation
        billingEntitledUntil = presentation.serviceEnd
        autoRenew = snapshot.autoRenew
        currentMembershipName = snapshot.currentProductID.flatMap(Self.membershipName)
        pendingMembershipName = presentation.pendingProductID.flatMap(Self.membershipName)
        billingStatus = presentation.status
        purgeAt = presentation.visiblePurgeDate(purgeAt)
        if let message = presentation.deletionHoldMessage {
            recoveryMessage = message
        }
    }

    private static func membershipName(_ productID: String) -> String? {
        switch RelayProductID(rawValue: productID) {
        case .syncMonthly: L("Relay Sync Monthly")
        case .syncYearly: L("Relay Sync Yearly")
        case .syncPlusMonthly: L("Relay Sync+ Monthly")
        case .syncPlusYearly: L("Relay Sync+ Yearly")
        case .proMonthly: L("Relay Pro Monthly")
        default: nil
        }
    }

    public func signOut() async {
        guard let session, !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await session.logout() }
        catch { show(error) }
    }

    func signIn(anchor: ASPresentationAnchor) {
        guard let session, !isBusy else { return }
        isBusy = true; errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let challenge = try await session.beginAppleSignIn()
                let authorization = NativeAppleAuthorization(anchor: anchor, challenge: challenge) { [weak self] result in
                    guard let self else { return }
                    Task {
                        defer { self.isBusy = false; self.authorization = nil }
                        do {
                            let token = try result.get()
                            try await session.completeAppleSignIn(identityToken: token, challengeID: challenge.challengeID)
                            self.receive(await session.currentState)
                            try await session.refreshAccount()
                            await self.reconcileMembership()
                        } catch { self.show(error, duringSignIn: true) }
                    }
                }
                self.authorization = authorization
                authorization.start()
            } catch { self.isBusy = false; self.show(error, duringSignIn: true) }
        }
    }

    private func show(_ error: Error, duringSignIn: Bool = false) {
        if let message = Self.failureMessage(for: error, duringSignIn: duringSignIn) { errorMessage = message }
    }

    static func failureMessage(for error: Error, duringSignIn: Bool = false) -> String? {
        if let apple = error as? ASAuthorizationError, apple.code == .canceled { return nil }
        if error is CancellationError { return nil }
        if duringSignIn {
            return L("Apple sign-in could not be completed. Please try again.")
        } else if let http = error as? HostedHTTPError, http.status == 401 {
            return L("Your session has expired. Sign in with Apple again.")
        } else if let auth = error as? HostedAuthError, auth == .expiredSession || auth == .signedOut {
            return L("Your session has expired. Sign in with Apple again.")
        } else {
            // Never surface NSError descriptions: they can carry tokens or URLs.
            return L("Relay Sync couldn't connect. Check your connection and try again. Your local progress is safe.")
        }
    }
}

@MainActor private final class NativeAppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let anchor: ASPresentationAnchor
    let challenge: HostedAppleChallenge
    let completion: (Result<Data, Error>) -> Void
    private var controller: ASAuthorizationController?
    init(anchor: ASPresentationAnchor, challenge: HostedAppleChallenge, completion: @escaping (Result<Data, Error>) -> Void) {
        self.anchor = anchor; self.challenge = challenge; self.completion = completion
    }
    func start() {
        let controller = ASAuthorizationController(authorizationRequests: [HostedAppleAuthorization.request(for: challenge)])
        self.controller = controller
        controller.delegate = self; controller.presentationContextProvider = self
        controller.performRequests()
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        completion(Result { try HostedAppleAuthorization.identityToken(from: authorization, for: challenge) })
        self.controller = nil
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error)); self.controller = nil
    }
}

/// Presentation only: backend grants and vault write authority remain separate.
struct HostedBillingPresentation {
    let serviceEnd: Date?
    let pendingProductID: String?
    let status: String?
    let deletionHoldMessage: String?
    private let autoRenew: Bool?
    private let hasServiceStatus: Bool
    private let providerStatus: String

    init(snapshot: HostedBillingSnapshot, now: Date) {
        let state = snapshot.status.lowercased()
        providerStatus = state
        hasServiceStatus = ["active", "grace", "billing_grace"].contains(state)
        serviceEnd = ["grace", "billing_grace"].contains(state)
            ? snapshot.graceUntil ?? snapshot.entitledUntil : snapshot.entitledUntil
        let hasService = hasServiceStatus && serviceEnd.map { $0 > now } == true
        autoRenew = snapshot.autoRenew
        pendingProductID = hasService && snapshot.autoRenew == true ? snapshot.pendingProductID : nil
        switch state {
        case "active": status = hasService ? L("Active") : L("Membership expired")
        case "grace", "billing_grace": status = hasService ? L("Apple billing grace period") : L("Membership expired")
        case "retry", "billing_retry": status = L("Apple is retrying your payment")
        case "expired": status = L("Membership expired")
        case "revoked": status = L("Membership revoked")
        default: status = nil
        }
        deletionHoldMessage = snapshot.purgeAwaitingProvider == true
            ? L("Online storage deletion is paused while Apple billing is verified. This does not extend your membership or enable uploads. Your local games and saves stay safe.") : nil
    }

    func visiblePurgeDate(_ date: Date?) -> Date? {
        deletionHoldMessage == nil ? date : nil
    }

    /// Dates only describe the already verified service period. A scheduled
    /// product is not a grant, and neither renewal intent nor a deletion hold
    /// promises continued access once that period ends.
    func renewalMessage(now: Date) -> String? {
        guard hasServiceStatus, let serviceEnd, serviceEnd > now else { return nil }
        let date = serviceEnd.formatted(date: .abbreviated, time: .omitted)
        if providerStatus == "active", autoRenew == true {
            if pendingProductID != nil {
                return String(localized: "Plan changes on \(date)", bundle: .module)
            }
            return String(localized: "Renews \(date)", bundle: .module)
        }
        return String(localized: "Available until \(date)", bundle: .module)
    }

    func attentionMessage(now: Date) -> String? {
        if hasServiceStatus, serviceEnd.map({ $0 > now }) != true {
            return L("Uploads paused. Refresh your plan to check it.")
        }
        return providerStatus == "active" ? nil : status
    }
}
