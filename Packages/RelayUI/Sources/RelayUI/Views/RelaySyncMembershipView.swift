// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDesignSystem
import RelayEntitlements

/// Account-first native Apple membership surface. Product prices and periods
/// come from StoreKit; current service and quota come from the Relay account.
struct RelaySyncMembershipView: View {
    let account: RelayAccountModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var membership: RelaySyncMembershipModel { account.membership }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RelaySpacing.l) {
                hero
                accountStatus
                if let notice = membership.notice { noticeView(notice) }
                if membership.isLoading && membership.products.isEmpty {
                    ProgressView().accessibilityLabel(Text("Loading memberships", bundle: .module))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: RelaySpacing.l) {
                        planCard(isPlus: false).frame(minWidth: 280)
                        planCard(isPlus: true).frame(minWidth: 280)
                    }
                    VStack(spacing: RelaySpacing.l) {
                        planCard(isPlus: false)
                        planCard(isPlus: true)
                    }
                }
                billingActions
                membershipRules
                legalLinks
            }
            .padding(RelaySpacing.layout.screenMargin)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .relayKeyboardScrollContainer()
        .background(RelayColor.canvas)
        .relaySettingsPage(L("Relay Membership"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("relayMembership.screen")
        .task { await membership.loadProducts() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text("Your library, with room to grow.", bundle: .module)
                .font(.relayShelfTitle)
                .foregroundStyle(RelayColor.textPrimary)
            Text("Hosted storage for your games and progress. Relay Pro is included while your Sync plan is active.", bundle: .module)
                .font(.relayBody)
                .foregroundStyle(RelayColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var accountStatus: some View {
        if account.isConnected {
            VStack(alignment: .leading, spacing: RelaySpacing.s) {
                if let plan = account.currentMembershipName ?? account.planName {
                    Text(plan).font(.relayShelfTitle)
                }
                if let status = account.billingAttentionMessage {
                    StatusLine(status, tone: .caution, symbol: .caution)
                }
                if let message = account.billingRenewalMessage {
                    Text(message).font(.relayStatus)
                }
                if let pending = account.pendingMembershipName {
                    Text("Then: \(pending)", bundle: .module)
                        .font(.relayStatus)
                        .accessibilityIdentifier("relayMembership.pendingPlan")
                }
                if let message = account.recoveryMessage {
                    Text(message).font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
                    if let date = account.purgeAt {
                        LabeledContent {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        } label: {
                            Text("Recovery ends", bundle: .module)
                        }
                        .font(.relayStatus)
                        .accessibilityIdentifier("relayMembership.recoveryDeadline")
                    }
                }
                if account.hasLoadedAccount && account.quotaBytes > 0 {
                    Text("Storage limit: \(Formatting.bytes(account.quotaBytes))", bundle: .module)
                        .font(.relayStatus).monospacedDigit()
                }
            }
            .accessibilityIdentifier("relayMembership.account")
        } else {
            VStack(alignment: .leading, spacing: RelaySpacing.s) {
                Text("Sign in to your Relay Account before subscribing. Your subscription will stay linked to this account.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                NativeAppleSignInButton(isEnabled: !account.isBusy && account.session != nil) {
                    account.signIn(anchor: $0)
                }
            }
            .accessibilityIdentifier("relayMembership.signIn")
        }
        if let error = account.errorMessage {
            StatusLine(error, tone: .caution, symbol: .caution)
        }
    }

    private func planCard(isPlus: Bool) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.m) {
            Text(isPlus ? L("Relay Sync+") : L("Relay Sync"))
                .font(.relayShelfTitle)
            Text("\(membership.quotaGB(isPlus: isPlus)) GB", bundle: .module)
                .font(.relayScreenTitle).monospacedDigit()
                .accessibilityIdentifier(isPlus ? "relayMembership.quota.plus" : "relayMembership.quota.sync")
            if membership.hasDirectProOnceBonus {
                Text("Includes your Pro Once storage bonus.", bundle: .module)
                    .font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
            }
            productButton(isPlus ? .syncPlusMonthly : .syncMonthly)
            productButton(isPlus ? .syncPlusYearly : .syncYearly)
            if !membership.isLoading && !hasAvailableOffer(isPlus: isPlus) {
                Text("This option isn't available in the App Store right now.", bundle: .module)
                    .font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RelaySpacing.l)
        .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.l))
        .overlay(RoundedRectangle(cornerRadius: RelayRadius.l).strokeBorder(RelayColor.separator))
    }

    @ViewBuilder private func productButton(_ id: RelayProductID) -> some View {
        if let product = membership.products[id], let period = periodText(product) {
            Button {
                Task { await membership.purchase(id); await account.refresh() }
            } label: {
                HStack(spacing: RelaySpacing.s) {
                    if membership.purchasingProductID == id { ProgressView() }
                    Text("\(product.displayPrice) / \(period)", bundle: .module)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .relayScrollToKeyboardFocus()
            .disabled(!account.isConnected || account.isBusy || membership.isWorking)
            .accessibilityIdentifier("relayMembership.purchase.\(id.rawValue)")
        }
    }

    private func hasAvailableOffer(isPlus: Bool) -> Bool {
        let ids: [RelayProductID] = isPlus ? [.syncPlusMonthly, .syncPlusYearly] : [.syncMonthly, .syncYearly]
        return ids.contains { id in
            membership.products[id].flatMap(periodText) != nil
        }
    }

    /// Unknown or absent StoreKit periods are never replaced with a catalog guess.
    private func periodText(_ product: RelayStoreProduct) -> String? {
        guard let period = product.subscriptionPeriod, period.value > 0 else { return nil }
        switch period.unit {
        case .day: return String(localized: "\(period.value) days", bundle: .module)
        case .week: return String(localized: "\(period.value) weeks", bundle: .module)
        case .month: return String(localized: "\(period.value) months", bundle: .module)
        case .year: return String(localized: "\(period.value) years", bundle: .module)
        }
    }

    private var membershipRules: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text("One membership, managed by Apple", bundle: .module).font(.relayCardTitle)
            Text("Pro Monthly, Sync and Sync+ are options in one Apple subscription group. Choose Sync to upgrade from Pro Monthly, or Sync+ for more storage. Apple shows the price and when a change takes effect before you confirm.", bundle: .module)
            Text("Subscriptions renew automatically until cancelled. You can change plans or cancel in the App Store.", bundle: .module)
            Text("Sync is for one Relay account and does not support Family Sharing. Shared Pro Once still includes Pro features, but only a direct Pro Once purchase verified for your account includes bonus storage.", bundle: .module)
        }
        .font(.relayStatus)
        .foregroundStyle(RelayColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var billingActions: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Button { Task { await membership.restore(); await account.refresh() } } label: {
                Text("Restore Purchases", bundle: .module)
            }
            .relayScrollToKeyboardFocus()
            .disabled(!account.isConnected || membership.isWorking || account.isBusy)
            .accessibilityIdentifier("relayMembership.restore")
            if membership.notice == .setupPending {
                Button { Task { await membership.retrySetup(); await account.refresh() } } label: {
                    Text("Finish membership setup", bundle: .module)
                }
                .relayScrollToKeyboardFocus()
                .disabled(!account.isConnected || membership.isWorking || account.isBusy)
                .accessibilityIdentifier("relayMembership.retry")
            }
            if !hasAvailableOffer(isPlus: false) || !hasAvailableOffer(isPlus: true) {
                Button { Task { await membership.loadProducts() } } label: {
                    Text("Try Again", bundle: .module)
                }
                .relayScrollToKeyboardFocus()
                .disabled(membership.isLoading || membership.isWorking)
            }
            #if os(tvOS)
            Text("Manage your subscription in App Store account settings on your iPhone, iPad or Mac.", bundle: .module)
                .font(.relayStatus)
            #else
            Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                Text("Manage in App Store", bundle: .module)
            }
            .relayScrollToKeyboardFocus()
            .accessibilityIdentifier("relayMembership.manage")
            #endif
        }
        .buttonStyle(.quiet)
    }

    @ViewBuilder
    private var legalLinks: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: RelaySpacing.s) {
                    termsLink
                    privacyLink
                }
            } else {
                HStack(spacing: RelaySpacing.l) {
                    termsLink
                    privacyLink
                }
            }
        }
        .font(.relayStatus)
    }

    private var termsLink: some View {
        Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
            Text("Terms of Use", bundle: .module)
        }
        .relayScrollToKeyboardFocus()
    }

    private var privacyLink: some View {
        Link(destination: URL(string: locale.language.languageCode?.identifier == "fr"
             ? "https://relayemu.app/fr/privacy" : "https://relayemu.app/privacy")!) {
            Text("Privacy", bundle: .module)
        }
        .relayScrollToKeyboardFocus()
    }

    private func noticeView(_ notice: RelaySyncPurchaseNotice) -> some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            StatusLine(notice.message, tone: notice.isProblem ? .caution : .neutral,
                       symbol: notice.isProblem ? .caution : .info)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("relayMembership.notice")
            if notice == .accountMismatch {
                Text("Sign out in Relay account settings, then sign in with the account you used for this subscription and try again. Contact support if you need help. Subscriptions cannot be transferred here.", bundle: .module)
                    .font(.relayStatus).foregroundStyle(RelayColor.textSecondary)
                Button { dismiss() } label: { Text("Back", bundle: .module) }
                    .buttonStyle(.quiet)
                    .relayScrollToKeyboardFocus()
            }
        }
    }
}

extension RelaySyncPurchaseNotice {
    var isProblem: Bool {
        switch self {
        case .accountMismatch, .setupPending, .productUnavailable, .verificationFailed, .storeUnavailable: true
        default: false
        }
    }
    var message: String {
        switch self {
        case .ready: L("Apple purchase checked. Your Relay account shows the plan currently available to you.")
        case .restored: L("Purchases checked. Your Relay account shows your current membership.")
        case .accountRequired: L("Sign in to your Relay account before continuing.")
        case .pending: L("Your purchase is pending approval. Your current plan stays unchanged until Apple approves it.")
        case .cancelled: L("Purchase cancelled. Your current plan is unchanged.")
        case .setupPending: L("Your Apple purchase is safe. Relay couldn't finish setting up your membership. Try Finish membership setup when you're back online. You don't need to buy again.")
        case .accountMismatch: L("This Relay Sync subscription is linked to another Relay account.")
        case .productUnavailable: L("This membership isn't available in the App Store right now. Try again later.")
        case .verificationFailed: L("We couldn't verify this purchase. No hosted storage was granted. Restore purchases or contact support.")
        case .storeUnavailable: L("The App Store is unavailable right now. Try again later. Your local games and saves remain available.")
        }
    }
}
