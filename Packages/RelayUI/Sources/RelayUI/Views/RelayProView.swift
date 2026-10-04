// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDesignSystem
import RelayEntitlements

/// Intentional Relay Pro purchase surface. Every listed benefit exists in the
/// running client and both prices arrive through RelayEntitlements.
public struct RelayProView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    @FocusState private var onceFocused: Bool
    #endif

    private var pro: RelayProModel { library.environment.relayPro }
    private let requestedFeature: RelayProFeature?
    private let isPresentedModally: Bool
    private let dismissPresentation: (() -> Void)?

    public init(feature: RelayProFeature? = nil, isPresentedModally: Bool = false, dismissPresentation: (() -> Void)? = nil) {
        requestedFeature = feature
        self.isPresentedModally = isPresentedModally
        self.dismissPresentation = dismissPresentation
    }

    @ViewBuilder
    public var body: some View {
        #if os(tvOS)
        televisionBody
        #elseif os(macOS)
        if isPresentedModally {
            // GeometryReader needs an explicit sheet size. A pushed Pro page must
            // instead accept the split-view detail width, including narrow windows.
            compactBody
                .frame(minWidth: 480, idealWidth: 760, minHeight: 520, idealHeight: 650)
        } else {
            compactBody
        }
        #else
        compactBody
        #endif
    }

    private var compactBody: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 760 && !dynamicType.isAccessibilitySize {
                        horizontalPurchaseBody
                    } else {
                        verticalPurchaseBody
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(RelaySpacing.layout.screenMargin)
                .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: pro.isPro)
            }
            .relayKeyboardScrollContainer()
        }
        .modifier(RelayProGround())
        .navigationTitle(Text("Relay Pro", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(macOS)
        .toolbar {
            if isPresentedModally {
                ToolbarItem(placement: .cancellationAction) {
                    Button { closePresentation() } label: { Text("Done", bundle: .module) }
                        #if !os(tvOS)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .accessibilityIdentifier("relayPro.dismiss")
                }
            }
        }
        #endif
        .task { if pro.products.isEmpty { await pro.loadProduct() } }
    }

    private var horizontalPurchaseBody: some View {
        HStack(alignment: .center, spacing: RelaySpacing.xxl) {
            VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                hero(alignment: .leading)
                featureCard
            }
            .frame(width: 320, alignment: .leading)

            VStack(spacing: RelaySpacing.m) {
                entitlementControls
                membershipLink
                freeStatement
                restoreButton
                legalLinks
                noticeLine
                macDismissButton
            }
            .frame(width: 330)
        }
        .frame(width: 682)
    }

    private var verticalPurchaseBody: some View {
        VStack(spacing: RelaySpacing.xl) {
            hero(alignment: .center)
            featureCard
            entitlementControls
            membershipLink
            freeStatement
            restoreButton
            legalLinks
            noticeLine
            macDismissButton
        }
        .frame(maxWidth: 620)
    }

    private func closePresentation() {
        if let dismissPresentation { dismissPresentation() } else { dismiss() }
    }

    @ViewBuilder private var macDismissButton: some View {
        #if os(macOS)
        if isPresentedModally {
            // Keep dismissal in the same native focus scope as the purchase
            // controls; the sheet toolbar forms an unreachable reverse boundary.
            Button { closePresentation() } label: { Text("Done", bundle: .module) }
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
                .relayScrollToKeyboardFocus()
                .accessibilityIdentifier("relayPro.dismiss")
        }
        #endif
    }

    #if os(tvOS)
    /// A television purchase surface must fit above the fold and establish a
    /// deterministic controller target. The compact vertical sheet leaves its
    /// first button off-screen once tvOS navigation chrome is accounted for.
    private var televisionBody: some View {
        HStack(alignment: .center, spacing: RelaySpacing.giant) {
            VStack(alignment: .leading, spacing: RelaySpacing.xxl) {
                hero(alignment: .leading)
                featureCard
            }
            .frame(maxWidth: 560, alignment: .leading)

            VStack(spacing: RelaySpacing.m) {
                entitlementControls
                membershipLink
                freeStatement
                restoreButton
                legalLinks
                noticeLine
            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, RelaySpacing.layout.screenMargin)
        .padding(.vertical, RelaySpacing.xxl)
        .background(RelayColor.canvas)
        .navigationTitle(Text(verbatim: ""))
        .task {
            if pro.products.isEmpty { await pro.loadProduct() }
            onceFocused = !pro.isPro
        }
    }
    #endif

    private func hero(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: RelaySpacing.xs) {
            RelayMark()
                .frame(width: 76, height: 76)
            Text("Relay Pro", bundle: .module)
                .font(.relayScreenTitle)
                .foregroundStyle(RelayColor.textPrimary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            Text(requestedFeature?.productTitle ?? L("Play on every Apple screen."))
                .font(.relaySubheader)
                .foregroundStyle(RelayColor.textSecondary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var freeStatement: some View {
        Text("All 12 systems are free on iPhone, iPad and Apple TV. Your library, saves and iCloud sync are free on every device.", bundle: .module)
            .font(.relayStatus)
            .foregroundStyle(RelayColor.textTertiary)
            .multilineTextAlignment(.center)
    }

    private var restoreButton: some View {
        Button { Task { await pro.restore() } } label: {
            if pro.isRestoring {
                ProgressView().accessibilityLabel(Text("Restoring purchases", bundle: .module))
            } else {
                Text("Restore Purchases", bundle: .module)
            }
        }
        .buttonStyle(.quiet)
        .relayScrollToKeyboardFocus()
        .disabled(pro.isPurchasing || pro.isRestoring)
        .accessibilityIdentifier("relayPro.restore")
    }

    @ViewBuilder
    private var legalLinks: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: RelaySpacing.s) {
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
        // Legal links are secondary: neutral, underlined where they read as text.
        .tint(RelayColor.textSecondary)
    }

    private var termsLink: some View {
        Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
            Text("Terms of Use", bundle: .module).relayLegalLinkUnderline()
        }
        .relayScrollToKeyboardFocus()
        .accessibilityIdentifier("relayPro.terms")
    }

    private var privacyLink: some View {
        Link(destination: privacyURL) {
            Text("Privacy", bundle: .module).relayLegalLinkUnderline()
        }
        .relayScrollToKeyboardFocus()
        .accessibilityIdentifier("relayPro.privacy")
    }

    @ViewBuilder
    private var noticeLine: some View {
        if let notice = pro.notice {
            StatusLine(noticeText(notice), tone: noticeTone(notice), symbol: noticeSymbol(notice))
                .accessibilityIdentifier("relayPro.notice")
        }
    }

    private var privacyURL: URL {
        let isFrench = locale.language.languageCode?.identifier == "fr"
        return URL(string: isFrench ? "https://relayemu.app/fr/privacy" : "https://relayemu.app/privacy")!
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.m) {
            ForEach(displayedFeatures, id: \.rawValue) { feature in
                HStack(alignment: .top, spacing: RelaySpacing.m) {
                    if !dynamicType.isAccessibilitySize {
                        feature.symbol.image
                            .font(.title3)
                            #if os(tvOS)
                            // Native television glyphs need their actual text-size
                            // width; the compact 24-point column overlaps the title.
                            .frame(width: 72)
                            #else
                            .frame(width: 24)
                            #endif
                            .foregroundStyle(RelayColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
                        Text(feature.productTitle)
                            .font(.relayCardTitle)
                            .foregroundStyle(RelayColor.textPrimary)
                        Text(feature.productDescription)
                            .font(.relayBody)
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                    #if os(tvOS)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var displayedFeatures: [RelayProFeature] {
        if let requestedFeature { return [requestedFeature] }
#if os(tvOS)
        // Keep the television surface readable and describe the benefits a
        // person can act on here. Touch editing and manual cheat entry remain
        // discoverable on the iPhone/iPad/Mac surfaces where they exist.
        return [.macGameplay, .extendedRewind, .advancedSpeeds,
                .advancedControllerMapping, .advancedDisplay]
#else
        return [.macGameplay, .extendedRewind, .advancedSpeeds, .touchLayoutEditing,
                .advancedControllerMapping, .cheats, .advancedDisplay, .extendedRecording]
#endif
    }

    @ViewBuilder
    private var entitlementControls: some View {
        if pro.entitlement.ownsProOnce {
            VStack(spacing: RelaySpacing.s) {
                StatusLine(L("Relay Pro is yours for good."), tone: .positive, symbol: .positive)
                if pro.entitlement.hasActiveProMonthly {
                    Text("Your monthly subscription is still active.", bundle: .module)
                        .font(.relayBody)
                        .foregroundStyle(RelayColor.textPrimary)
                        .multilineTextAlignment(.center)
                    manageSubscriptionLink
                }
            }
        } else if pro.entitlement.hasActiveProMonthly {
            VStack(spacing: RelaySpacing.m) {
                StatusLine(L("Relay Pro Monthly is active"), tone: .positive, symbol: .positive)
                if let once = pro.onceProduct {
                    oncePurchaseButton(once)
                    Text("Choose Once to keep Relay Pro without a monthly renewal.", bundle: .module)
                        .font(.relayStatus)
                        .foregroundStyle(RelayColor.textTertiary)
                        .multilineTextAlignment(.center)
                }
                manageSubscriptionLink
            }
        } else if pro.entitlement.sources.contains(.relaySyncBundle) {
            StatusLine(L("Relay Pro is included with your active Relay Sync plan."), tone: .positive, symbol: .positive)
        } else if pro.isPro {
            StatusLine(L("Relay Pro is active"), tone: .positive, symbol: .positive)
        } else {
            purchaseControls
        }
    }

    @ViewBuilder private var membershipLink: some View {
        if library.environment.relayAccount != nil {
            NavigationLink(value: Route.relayMembership) {
                Text("Explore Sync memberships", bundle: .module)
            }
            .buttonStyle(.quiet)
            .relayScrollToKeyboardFocus()
            .accessibilityIdentifier("relayPro.memberships")
        }
    }

    private var manageSubscriptionLink: some View {
        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
            Text("Manage Monthly Subscription", bundle: .module)
        }
        .buttonStyle(.quiet)
        .relayScrollToKeyboardFocus()
        .accessibilityIdentifier("relayPro.manageMonthly")
    }

    private func oncePurchaseButton(_ once: RelayStoreProduct) -> some View {
        Button { Task { await pro.purchase(.proOnce) } } label: {
            if pro.purchasingProductID == .proOnce {
                ProgressView().tint(RelayColor.textOnEmber)
                    .accessibilityLabel(Text("Purchasing Relay Pro Once", bundle: .module))
            } else {
                Text("Once · \(once.displayPrice)", bundle: .module)
            }
        }
        .buttonStyle(.ember)
        .relayScrollToKeyboardFocus()
        .disabled(pro.isPurchasing || pro.isRestoring)
        .accessibilityIdentifier("relayPro.purchase.once")
    }

    @ViewBuilder
    private var purchaseControls: some View {
        if let once = pro.onceProduct, let monthly = pro.monthlyProduct {
            VStack(spacing: RelaySpacing.m) {
                VStack(spacing: RelaySpacing.xs) {
                    // Ember is spent once, on the Once button itself (BRAND_IDENTITY §3).
                    Text("Recommended", bundle: .module)
                        .font(.relayStatusEmphasis)
                        .foregroundStyle(RelayColor.textSecondary)
                    oncePurchaseButton(once)
                    #if os(tvOS)
                    .focused($onceFocused)
                    #endif
                    Text("One payment. Keep Relay Pro.", bundle: .module)
                        .font(.relayStatus)
                        .foregroundStyle(RelayColor.textTertiary)
                }

                Text("or", bundle: .module)
                    .font(.relayStatus)
                    .foregroundStyle(RelayColor.textTertiary)

                Button { Task { await pro.purchase(.proMonthly) } } label: {
                    if pro.purchasingProductID == .proMonthly {
                        ProgressView()
                            .accessibilityLabel(Text("Purchasing Relay Pro Monthly", bundle: .module))
                    } else {
                        Text("Monthly · \(monthly.displayPrice)", bundle: .module)
                    }
                }
                .buttonStyle(.quiet)
                .relayScrollToKeyboardFocus()
                .disabled(pro.isPurchasing || pro.isRestoring)
                .accessibilityIdentifier("relayPro.purchase.monthly")
                Text("Renews monthly until cancelled.", bundle: .module)
                    .font(.relayStatus)
                    .foregroundStyle(RelayColor.textTertiary)
            }
        } else if pro.isLoadingProduct {
            ProgressView()
                .accessibilityLabel(Text("Loading Relay Pro", bundle: .module))
        } else {
            Button { Task { await pro.loadProduct() } } label: {
                Text("Try Again", bundle: .module)
            }
            .buttonStyle(.ember)
            .relayScrollToKeyboardFocus()
        }
    }

    private func noticeText(_ notice: RelayProNotice) -> String {
        switch notice {
        case .setupPending: return L("Your Apple purchase is safe. Open Relay account settings to finish membership setup. You don't need to buy again.")
        case .accountMismatch: return L("This Relay Sync subscription is linked to another Relay account.")
        case .purchased: return L("Relay Pro unlocked")
        case .restored: return L("Relay Pro restored")
        case .nothingToRestore: return L("No Relay Pro purchase was found for this Apple Account.")
        case .pending: return L("Your purchase is pending approval.")
        case .cancelled: return L("Purchase cancelled.")
        case .productUnavailable: return L("Relay Pro isn't available right now. Try again later.")
        case .verificationFailed: return L("We couldn't verify this purchase. Nothing was unlocked.")
        case .storeUnavailable: return L("The App Store is unavailable right now. Try again later.")
        }
    }

    private func noticeTone(_ notice: RelayProNotice) -> StatusTone {
        switch notice {
        case .purchased, .restored: return .positive
        case .pending, .cancelled, .nothingToRestore: return .neutral
        case .productUnavailable, .verificationFailed, .storeUnavailable, .setupPending, .accountMismatch: return .caution
        }
    }

    private func noticeSymbol(_ notice: RelayProNotice) -> RelaySymbol {
        switch notice {
        case .purchased, .restored: return .positive
        case .pending: return .info
        case .cancelled, .nothingToRestore: return .info
        case .productUnavailable, .verificationFailed, .storeUnavailable, .setupPending, .accountMismatch: return .caution
        }
    }
}

/// Relay Pro's ground. It belongs to the presented surface, not to the inner
/// scroll view or its geometry proxy: those can lag one layout pass behind the
/// size the sheet really occupies (iPad landscape after a keyboard, B2-IPAD-001),
/// which left the warm canvas ending mid-screen while the feature copy carried on
/// over the system background.
private struct RelayProGround: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        // The container background is what actually covers a presented page: the
        // inner scroll view's own frame can stay one pass behind the sheet.
        content
            .containerBackground(RelayColor.canvas, for: .navigation)
            .background(RelayColor.canvas)
        #else
        content.background(RelayColor.canvas)
        #endif
    }
}

private extension Text {
    /// tvOS draws links as focusable buttons, which need no underline.
    func relayLegalLinkUnderline() -> Text {
        #if os(tvOS)
        self
        #else
        underline()
        #endif
    }
}
