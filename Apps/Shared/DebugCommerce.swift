// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import Foundation
import RelayEntitlements

/// Explicit launch-argument seam for UI automation and screenshots. It never
/// participates in Release builds and never persists an entitlement.
@MainActor
final class DebugEntitlementProvider: RelayEntitlementProviding {
    enum Scenario: String {
        case free
        case owned
        case monthly
        case onceAndMonthly
        case restorable
    }

    private(set) var state: RelayEntitlementState
    private let scenario: Scenario
    private var continuations: [UUID: AsyncStream<RelayEntitlementState>.Continuation] = [:]

    init(scenario: Scenario) {
        self.scenario = scenario
        switch scenario {
        case .owned: state = Self.proState
        case .monthly: state = RelayEntitlementState(activeProductIDs: [.proMonthly])
        case .onceAndMonthly: state = RelayEntitlementState(activeProductIDs: [.proOnce, .proMonthly])
        case .free, .restorable: state = .free
        }
    }

    func stateUpdates() -> AsyncStream<RelayEntitlementState> {
        let identifier = UUID()
        let current = state
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[identifier] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: identifier) }
            }
        }
    }

    func loadProducts() async throws -> [RelayStoreProduct] {
        let currency = Locale.current.currency?.identifier ?? "USD"
        let oncePrice = (Decimal(999) / Decimal(100)).formatted(.currency(code: currency))
        let monthlyPrice = (Decimal(199) / Decimal(100)).formatted(.currency(code: currency))
        return [
            RelayStoreProduct(
                id: .proOnce,
                displayName: "Relay Pro Once",
                description: "Play in the native Relay app for Mac.",
                displayPrice: oncePrice
            ),
            RelayStoreProduct(
                id: .proMonthly,
                displayName: "Relay Pro Monthly",
                description: "Play in the native Relay app for Mac.",
                displayPrice: monthlyPrice
            ),
        ]
    }

    func purchase(_ productID: RelayProductID) async throws -> RelayPurchaseOutcome {
        guard RelayProductID.supported.contains(productID) else { throw RelayEntitlementError.productUnavailable(productID) }
        publish(RelayEntitlementState(activeProductIDs: state.activeProductIDs.union([productID])))
        return .purchased(state)
    }

    func restorePurchases() async throws -> RelayEntitlementState {
        if scenario == .restorable { publish(Self.proState) }
        return state
    }

    func refresh() async -> RelayEntitlementState { state }

    private func publish(_ newState: RelayEntitlementState) {
        state = newState
        for continuation in continuations.values { continuation.yield(newState) }
    }

    private static let proState = RelayEntitlementState(activeProductIDs: [.proOnce])
}
#endif
