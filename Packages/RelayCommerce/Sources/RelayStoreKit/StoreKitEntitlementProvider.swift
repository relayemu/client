// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RelayEntitlements
import StoreKit

@MainActor
protocol StoreKitClient: AnyObject {
    func products(for identifiers: Set<String>) async throws -> [StoreProduct]
    func currentEntitlements() async -> [StoreVerification]
    func unfinishedTransactions() async -> [StoreVerification]
    func transactionUpdates() -> AsyncStream<StoreVerification>
    func synchronize() async throws
}

extension StoreKitClient {
    func unfinishedTransactions() async -> [StoreVerification] { [] }
}

struct StoreProduct: Sendable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    var subscriptionPeriod: RelaySubscriptionPeriod? = nil
    let purchase: @MainActor @Sendable (UUID?) async throws -> StorePurchaseResult
}

struct StoreTransaction: Sendable {
    enum Ownership: Sendable { case purchased, familyShared }

    let productID: String
    let ownership: Ownership
    let isActive: Bool
    var transactionJWS: String = ""
    var appAccountToken: UUID? = nil
    var signedDate: Date = .distantPast
    var expirationDate: Date? = nil
    let finish: @MainActor @Sendable () async -> Void
}

enum StoreVerification: Sendable {
    case verified(StoreTransaction)
    case unverified
}

enum StorePurchaseResult: Sendable {
    case success(StoreVerification)
    case pending
    case userCancelled
}

@MainActor
private final class LiveStoreKitClient: StoreKitClient {
    func products(for identifiers: Set<String>) async throws -> [StoreProduct] {
        try await Product.products(for: identifiers).map { product in
            StoreProduct(
                id: product.id,
                displayName: product.displayName,
                description: product.description,
                displayPrice: product.displayPrice,
                subscriptionPeriod: product.subscription.flatMap { Self.period($0.subscriptionPeriod) },
                purchase: { accountID in
                    let options: Set<Product.PurchaseOption> = accountID.map { [.appAccountToken($0)] } ?? []
                    switch try await product.purchase(options: options) {
                    case .success(let result): return .success(await Self.map(result))
                    case .pending: return .pending
                    case .userCancelled: return .userCancelled
                    @unknown default: return .pending
                    }
                }
            )
        }
    }

    private static func period(_ period: Product.SubscriptionPeriod) -> RelaySubscriptionPeriod? {
        let unit: RelaySubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return RelaySubscriptionPeriod(value: period.value, unit: unit)
    }

    func unfinishedTransactions() async -> [StoreVerification] {
        var result: [StoreVerification] = []
        for await verification in Transaction.unfinished { result.append(await Self.map(verification)) }
        return result
    }

    func currentEntitlements() async -> [StoreVerification] {
        var result: [StoreVerification] = []
        for await verification in Transaction.currentEntitlements {
            result.append(await Self.map(verification))
        }
        return result
    }

    func transactionUpdates() -> AsyncStream<StoreVerification> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(await Self.map(update))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func synchronize() async throws {
        try await AppStore.sync()
    }

    private static func map(_ verification: VerificationResult<Transaction>) async -> StoreVerification {
        guard case .verified(let transaction) = verification else { return .unverified }
        var effectiveExpiration = transaction.expirationDate
        // Apple includes grace-period subscriptions in currentEntitlements. For
        // local Pro Monthly use the verified renewal grace date; never invent a
        // configured number of free days or derive hosted grants here.
        if transaction.productID == RelayProductID.proMonthly.rawValue,
           let expiry = transaction.expirationDate, expiry <= Date(),
           transaction.revocationDate == nil, !transaction.isUpgraded,
           let groupID = transaction.subscriptionGroupID,
           let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            for status in statuses where status.state == .inGracePeriod {
                guard case .verified(let current) = status.transaction, current.id == transaction.id,
                      case .verified(let renewal) = status.renewalInfo,
                      renewal.currentProductID == transaction.productID,
                      let grace = renewal.gracePeriodExpirationDate, grace > Date() else { continue }
                effectiveExpiration = grace
            }
        }
        return .verified(StoreTransaction(
            productID: transaction.productID,
            ownership: transaction.ownershipType == .familyShared ? .familyShared : .purchased,
            isActive: transaction.revocationDate == nil
                && !transaction.isUpgraded
                && (effectiveExpiration.map { $0 > Date() } ?? true),
            transactionJWS: verification.jwsRepresentation,
            appAccountToken: transaction.appAccountToken,
            signedDate: transaction.signedDate,
            expirationDate: effectiveExpiration,
            finish: { await transaction.finish() }
        ))
    }
}

/// StoreKit 2 adapter for Relay Membership. Hosted products require backend claims.
/// Only verified, currently active transactions can grant access.
@MainActor
public final class StoreKitEntitlementProvider: RelayEntitlementProviding {
    public private(set) var state = RelayEntitlementState.free

    private let supportedProductIDs: Set<RelayProductID>
    private let client: any StoreKitClient
    private var productsByID: [RelayProductID: StoreProduct] = [:]
    private var billing: (any RelayBillingClaiming)?
    private var billingAccountID: UUID?
    private var billingGeneration = UUID()
    private struct ClaimKey: Hashable { let accountID: UUID; let jws: String }
    private struct PendingClaim { let id: UUID; let task: Task<Void, any Error> }
    private var pendingClaims: [ClaimKey: PendingClaim] = [:]
    private struct UpdateDelivery { let transaction: StoreTransaction; let generation: UUID }
    // At most one pending update per supported product plus one in flight.
    // Superseded hosted transactions remain in StoreKit's unfinished ledger.
    private var pendingUpdates: [RelayProductID: UpdateDelivery] = [:]
    private var deliveryTask: Task<Void, Never>?
    private var latestSignedDates: [RelayProductID: Date] = [:]
    private var expiryByProductID: [RelayProductID: Date] = [:]
    private var expiryTask: Task<Void, Never>?
    private var ownershipByProductID: [RelayProductID: StoreTransaction.Ownership] = [:]
    /// Invalidates a current-entitlement read that started before a verified
    /// purchase/update. StoreKit may briefly return its older snapshot.
    private var entitlementMutationVersion = 0
    private var continuations: [UUID: AsyncStream<RelayEntitlementState>.Continuation] = [:]
    private var transactionTask: Task<Void, Never>?

    public convenience init(productIDs: Set<RelayProductID> = RelayProductID.supported) {
        self.init(productIDs: productIDs, client: LiveStoreKitClient())
    }

    init(productIDs: Set<RelayProductID> = RelayProductID.supported, client: any StoreKitClient) {
        supportedProductIDs = productIDs.intersection(RelayProductID.supported)
        self.client = client
        transactionTask = Task { [weak self] in
            guard let updates = self?.client.transactionUpdates() else { return }
            for await verification in updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = verification else { continue }
                guard let self else { return }
                self.consume(transaction)
            }
        }
        Task { [weak self] in
            _ = await self?.refresh()
        }
    }

    deinit {
        transactionTask?.cancel()
        deliveryTask?.cancel()
        expiryTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    public func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let identifier = UUID()
        let currentState = state

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[identifier] = continuation
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    public func loadProducts() async throws -> [RelayStoreProduct] {
        let storeProducts = try await client.products(for: Set(supportedProductIDs.map(\.rawValue)))

        productsByID = Dictionary(
            uniqueKeysWithValues: storeProducts.compactMap { product in
                let id = RelayProductID(rawValue: product.id)
                guard supportedProductIDs.contains(id) else { return nil }
                return (id, product)
            }
        )

        return productsByID
            .map { id, product in
                RelayStoreProduct(
                    id: id,
                    displayName: product.displayName,
                    description: product.description,
                    displayPrice: product.displayPrice,
                    subscriptionPeriod: product.subscriptionPeriod
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func setBillingBridge(_ bridge: (any RelayBillingClaiming)?) {
        billing = bridge
        billingGeneration = UUID()
    }

    public func setBillingAccountID(_ accountID: UUID?) {
        guard accountID != billingAccountID else { return }
        billingAccountID = accountID
        billingGeneration = UUID()
    }

    public func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        guard supportedProductIDs.contains(productID) else {
            throw RelayEntitlementError.productUnavailable(productID)
        }

        let purchaseAccountID = billingAccountID
        let purchaseGeneration = billingGeneration
        if productID.requiresRelayAccount, purchaseAccountID == nil { throw RelayEntitlementError.accountRequired }
        if productID.requiresRelayAccount, billing == nil { throw RelayEntitlementError.accountRequired }
        if productsByID[productID] == nil {
            _ = try await loadProducts()
        }
        guard let product = productsByID[productID] else {
            throw RelayEntitlementError.productUnavailable(productID)
        }

        if purchaseGeneration != billingGeneration && (productID.requiresRelayAccount || purchaseAccountID != nil) {
            throw RelayEntitlementError.accountRequired
        }
        switch try await product.purchase(purchaseAccountID) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw RelayEntitlementError.failedVerification
            }
            let purchasedID = RelayProductID(rawValue: transaction.productID)
            guard (purchasedID == productID || (purchasedID.subscriptionLevel != nil && productID.subscriptionLevel != nil)),
                  supportedProductIDs.contains(purchasedID), transaction.isActive else {
                throw RelayEntitlementError.failedVerification
            }
            applyLocal(transaction)
            if purchasedID.requiresRelayAccount {
                guard purchaseGeneration == billingGeneration, billingAccountID == purchaseAccountID else {
                    return .setupPending
                }
                do {
                    try await claim(transaction)
                    await transaction.finish()
                    return .purchased(state)
                } catch RelayEntitlementError.accountMismatch { throw RelayEntitlementError.accountMismatch }
                catch { return .setupPending }
            }
            await transaction.finish()
            // Local Pro is usable even if loyalty verification is temporarily unavailable.
            try? await claim(transaction)
            return .purchased(state)
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        }
    }

    public func restorePurchases() async throws -> RelayEntitlementState {
        try await client.synchronize()
        return await refresh()
    }

    @discardableResult
    public func refresh() async -> RelayEntitlementState {
        let startingMutationVersion = entitlementMutationVersion
        let transactions = await client.currentEntitlements()
        if startingMutationVersion == entitlementMutationVersion {
            let previousOwnership = ownershipByProductID
            let previousExpiry = expiryByProductID
            ownershipByProductID = [:]
            expiryByProductID = [:]
            let verified = transactions.compactMap { result -> StoreTransaction? in
                guard case .verified(let transaction) = result else { return nil }
                return transaction
            }.sorted { $0.signedDate < $1.signedDate }
            for transaction in verified {
                let id = RelayProductID(rawValue: transaction.productID)
                if transaction.signedDate < (latestSignedDates[id] ?? .distantPast) {
                    // A read started after the latest update can still carry an
                    // older signed snapshot. Preserve that newer local decision.
                    ownershipByProductID[id] = previousOwnership[id]
                    expiryByProductID[id] = previousExpiry[id]
                } else { applyLocal(transaction, publishing: false) }
            }
            publish(stateFromOwnership())
            scheduleLocalExpiry()
        }
        // Background refresh never invokes AppStore.sync or blocks a state read.
        try? await reconcile(transactions)
        return state
    }

    /// Reacquires Apple's signed evidence on reinstall/new device and retries
    /// unfinished purchases after backend failure. Only explicit Restore calls sync.
    public func reconcileBilling() async throws {
        let unfinished = await client.unfinishedTransactions()
        let current = await client.currentEntitlements()
        try await reconcile(unfinished + current)
    }

    private func reconcile(_ transactions: [StoreVerification]) async throws {
        let generation = billingGeneration
        var submitted = Set<String>()
        var firstError: (any Error)?
        for verification in transactions {
            guard generation == billingGeneration else { throw RelayEntitlementError.accountRequired }
            guard case .verified(let transaction) = verification,
                  submitted.insert(transaction.transactionJWS).inserted else { continue }
            do {
                try await claim(transaction)
                if RelayProductID.hosted.contains(RelayProductID(rawValue: transaction.productID)) {
                    await transaction.finish()
                }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func claim(_ transaction: StoreTransaction) async throws {
        let id = RelayProductID(rawValue: transaction.productID)
        guard supportedProductIDs.contains(id) else { return }
        // Family Shared lifetime grants local Pro only and must never be rebound.
        guard transaction.ownership == .purchased else {
            if id.requiresRelayAccount { throw RelayEntitlementError.failedVerification }
            return
        }
        guard let accountID = billingAccountID, let billing else {
            if id.requiresRelayAccount { throw RelayEntitlementError.accountRequired }
            return
        }
        if let token = transaction.appAccountToken, token != accountID { throw RelayEntitlementError.accountMismatch }
        guard !transaction.transactionJWS.isEmpty else { throw RelayEntitlementError.failedVerification }
        let generation = billingGeneration
        let key = ClaimKey(accountID: accountID, jws: transaction.transactionJWS)
        let pending: PendingClaim
        if let existing = pendingClaims[key] { pending = existing }
        else {
            let proof = transaction.transactionJWS
            pending = PendingClaim(id: UUID(), task: Task {
                try await billing.claim(transactionJWS: proof, accountID: accountID)
            })
            pendingClaims[key] = pending
        }
        defer { if pendingClaims[key]?.id == pending.id { pendingClaims.removeValue(forKey: key) } }
        try await pending.task.value
        guard generation == billingGeneration else { throw RelayEntitlementError.accountRequired }
    }

    private func consume(_ transaction: StoreTransaction) {
        let id = RelayProductID(rawValue: transaction.productID)
        guard supportedProductIDs.contains(id) else { return }
        // Never await billing on the StoreKit updates reader: a stalled server
        // must not delay an independent local purchase, expiry or refund.
        applyLocal(transaction)
        if let pending = pendingUpdates[id], pending.transaction.signedDate > transaction.signedDate { return }
        pendingUpdates[id] = UpdateDelivery(transaction: transaction, generation: billingGeneration)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            while !Task.isCancelled, let self, let id = self.pendingUpdates.keys.sorted(by: { $0.rawValue < $1.rawValue }).first,
                  let delivery = self.pendingUpdates.removeValue(forKey: id) {
                await self.deliverUpdate(delivery)
            }
            self?.deliveryTask = nil
        }
    }

    private func deliverUpdate(_ delivery: UpdateDelivery) async {
        let transaction = delivery.transaction
        let id = RelayProductID(rawValue: transaction.productID)
        if !id.requiresRelayAccount { await transaction.finish() }
        // A queued unbound transaction must never silently follow an account
        // switch. Reconciliation reacquires its proof for the current account.
        guard !Task.isCancelled, delivery.generation == billingGeneration else { return }
        do {
            try await claim(transaction)
            guard !Task.isCancelled, delivery.generation == billingGeneration else { return }
            if id.requiresRelayAccount { await transaction.finish() }
        } catch { /* Unfinished hosted proof is available on the next reconciliation. */ }
    }

    private func applyLocal(_ transaction: StoreTransaction, publishing: Bool = true) {
        let id = RelayProductID(rawValue: transaction.productID)
        guard supportedProductIDs.contains(id) else { return }
        if id.requiresRelayAccount {
            // All recurring products share one Apple group. An effective hosted
            // upgrade supersedes local Pro Monthly, but never lifetime ownership.
            if transaction.isActive, transaction.signedDate >= (latestSignedDates[.proMonthly] ?? .distantPast) {
                latestSignedDates[.proMonthly] = transaction.signedDate
                ownershipByProductID.removeValue(forKey: .proMonthly)
                expiryByProductID.removeValue(forKey: .proMonthly)
                entitlementMutationVersion += 1
                if publishing { publish(stateFromOwnership()); scheduleLocalExpiry() }
            }
            return
        }
        guard transaction.signedDate >= (latestSignedDates[id] ?? .distantPast) else { return }
        latestSignedDates[id] = transaction.signedDate
        entitlementMutationVersion += 1
        if transaction.isActive, transaction.expirationDate.map({ $0 > Date() }) ?? true {
            ownershipByProductID[id] = transaction.ownership
            expiryByProductID[id] = transaction.expirationDate
        } else {
            ownershipByProductID.removeValue(forKey: id)
            expiryByProductID.removeValue(forKey: id)
        }
        if publishing { publish(stateFromOwnership()); scheduleLocalExpiry() }
    }

    private func scheduleLocalExpiry() {
        expiryTask?.cancel()
        guard let expiry = expiryByProductID.values.min() else { return }
        let delay = max(0, min(expiry.timeIntervalSinceNow, 31_536_000))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            for (id, expiry) in self.expiryByProductID where expiry <= Date() {
                self.ownershipByProductID.removeValue(forKey: id)
                self.expiryByProductID.removeValue(forKey: id)
            }
            self.entitlementMutationVersion += 1
            self.publish(self.stateFromOwnership())
            self.scheduleLocalExpiry()
        }
    }

    private func stateFromOwnership() -> RelayEntitlementState {
        RelayEntitlementState(
            activeProductIDs: Set(ownershipByProductID.keys),
            familySharedProductIDs: Set(
                ownershipByProductID.compactMap { id, ownership in
                    ownership == .familyShared ? id : nil
                }
            )
        )
    }

    private func publish(_ newState: RelayEntitlementState) {
        guard newState != state else { return }
        state = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }
}
