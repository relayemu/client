// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  OnboardingView.swift
//
//  Three steps, each one idea, each a screen the player can act on:
//
//    1. what Relay is — the promise, in the website's words;
//    2. how games get in on THIS platform, with the real import action;
//    3. what makes Relay Relay — progress that follows you (or, on Apple TV,
//       the controller the couch needs, then how a library arrives there).
//
//  No account, no permissions, no tour of features. Every claim below is true
//  today: game-file iCloud sync is Free but remains an explicit opt-in.
//  The drawings are Relay's own pen (BRAND_IDENTITY §6, onboarding added in

import SwiftUI
import RelayDomain
import RelayDesignSystem
#if canImport(GameController)
import GameController
#endif

/// The steps, in the order this platform shows them.
enum OnboardingStep: Hashable, CaseIterable {
    case welcome
    case bringGames
    case continuity
    case controller
    case libraryArrives

    static var flow: [OnboardingStep] {
        #if os(tvOS)
        return [.welcome, .controller, .libraryArrives]
        #else
        return [.welcome, .bringGames, .continuity]
        #endif
    }
}

public struct OnboardingView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    private let steps = OnboardingStep.flow

    public init() {}

    private var step: OnboardingStep { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    public var body: some View {
        OnboardingFrame {
            ZStack {
                page(for: step)
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: index)
        } footer: {
            footer
        }
        .relayCanvas()
        .accessibilityAction(.escape) { finish() }
        #if os(tvOS)
        .onExitCommand { finish() }
        #endif
    }

    // MARK: Pages

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomePage()
        case .bringGames: BringGamesPage()
        case .continuity: ContinuityPage()
        case .controller: ControllerPage()
        case .libraryArrives: LibraryArrivesPage()
        }
    }

    // MARK: Footer: progress, the one action, and the way out

    private var footer: some View {
        VStack(spacing: RelaySpacing.m) {
            StepDashes(count: steps.count, current: index)
            HStack(spacing: RelaySpacing.s) {
                if step == .bringGames {
                    Button { chooseGames() } label: { Text(bringGamesActionTitle, bundle: .module) }
                        .buttonStyle(.ember)
                        .accessibilityIdentifier("onboarding.chooseGames")
                    Button { advance() } label: { Text("Not Now", bundle: .module) }
                        .buttonStyle(.quiet)
                } else {
                    Button { advance() } label: { Text(primaryTitle, bundle: .module) }
                        .buttonStyle(.ember)
                        .accessibilityIdentifier("onboarding.primary")
                    if !isLast {
                        Button { finish() } label: { Text("Skip", bundle: .module) }
                            .buttonStyle(.quiet)
                            .accessibilityIdentifier("onboarding.skip")
                    }
                }
            }
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: return "Get Started"
        default: return isLast ? "Done" : "Continue"
        }
    }

    private var bringGamesActionTitle: LocalizedStringKey {
        #if os(macOS)
        return "Import Games…"
        #else
        return "Choose Games"
        #endif
    }

    private func advance() {
        if isLast { finish() } else { index += 1 }
    }

    /// Done or skipped: either way the player has met Relay and knows Settings
    /// keeps Getting Started, so the record is written and the cover goes away.
    private func finish() {
        actions.completeOnboarding()
    }

    /// The real import, not a picture of it: the cover closes and the platform's
    /// file picker opens over Home, so the first game lands before the tour ends.
    private func chooseGames() {
        actions.completeOnboarding(thenImport: true)
    }
}

// MARK: - Frame

/// The page's shape per platform: a phone stacks illustration over text with the
/// actions at the thumb; a wide canvas (iPad, Mac, Apple TV) sets the illustration
/// beside the text so nothing is a stretched phone.
private struct OnboardingFrame<Content: View, Footer: View>: View {
    private let content: Content
    private let footer: Footer
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        #if os(tvOS)
        VStack(spacing: RelaySpacing.giant) {
            content
            footer
        }
        .padding(.horizontal, 120)
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #elseif os(macOS)
        VStack(spacing: RelaySpacing.xxl) {
            content
            footer
        }
        .padding(RelaySpacing.xxxl)
        .frame(width: 760, height: 560)
        #else
        if sizeClass == .regular {
            // iPad: one composed group in the middle of the canvas, the way the
            // Mac sheet sits, so a tablet is not a phone with a taller gap.
            VStack(spacing: RelaySpacing.xxl) {
                content
                footer
            }
            .padding(RelaySpacing.xxxl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // iPhone: the page sits a little above the middle, the actions at the
            // thumb; the empty space goes below the text, not above the drawing.
            VStack(spacing: RelaySpacing.xl) {
                Spacer(minLength: 0).frame(maxHeight: 96)
                content
                Spacer(minLength: RelaySpacing.l)
                footer
            }
            .padding(.horizontal, RelaySpacing.xl)
            .padding(.top, RelaySpacing.m)
            .padding(.bottom, RelaySpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}

/// One page: a drawing, a title, a body, an optional live line. The layout is
/// vertical on iPhone and side by side where there is room.
private struct OnboardingPage<Extra: View>: View {
    let scene: PenScene?
    let symbol: RelaySymbol?
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let extra: Extra
    #if os(tvOS)
    private let sceneWidth: CGFloat = 520
    #else
    @ScaledMetric(relativeTo: .body) private var sceneWidth: CGFloat = 220
    #endif

    init(scene: PenScene? = nil, symbol: RelaySymbol? = nil, title: LocalizedStringKey, message: LocalizedStringKey,
         @ViewBuilder extra: () -> Extra) {
        self.scene = scene
        self.symbol = symbol
        self.title = title
        self.message = message
        self.extra = extra()
    }

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: RelaySpacing.giant) {
            illustration
            text
                .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        VStack(spacing: RelaySpacing.l) {
            illustration
            text
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder
    private var illustration: some View {
        if let scene {
            PenSceneView(scene, width: sceneWidth)
        } else if let symbol {
            symbol.image
                .font(.system(size: sceneWidth * 0.22, weight: .regular))
                .foregroundStyle(RelayColor.ember)
                .frame(width: sceneWidth * 0.5, height: sceneWidth * 0.5)
                .background(RelayColor.emberTint, in: Circle())
                .overlay(Circle().strokeBorder(RelayColor.ember.opacity(0.22)))
                .accessibilityHidden(true)
        }
    }

    private var text: some View {
        VStack(alignment: textAlignment, spacing: RelaySpacing.s) {
            Text(title, bundle: .module)
                .font(titleFont)
                .foregroundStyle(RelayColor.textPrimary)
                .multilineTextAlignment(multilineAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message, bundle: .module)
                .font(.relayBody)
                .foregroundStyle(RelayColor.textSecondary)
                .multilineTextAlignment(multilineAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: textAlignment == .leading ? .leading : .center)
            extra
                .padding(.top, RelaySpacing.xs)
        }
    }

    private var titleFont: Font {
        #if os(tvOS)
        return .relayScreenTitle
        #else
        return .relayDetailTitle
        #endif
    }

    private var textAlignment: HorizontalAlignment {
        #if os(tvOS)
        return .leading
        #else
        return .center
        #endif
    }

    private var multilineAlignment: TextAlignment {
        #if os(tvOS)
        return .leading
        #else
        return .center
        #endif
    }
}

extension OnboardingPage where Extra == EmptyView {
    init(scene: PenScene? = nil, symbol: RelaySymbol? = nil, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(scene: scene, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - The pages

/// Step 1: what Relay is, in the words the website uses.
private struct WelcomePage: View {
    #if os(tvOS)
    private let sceneWidth: CGFloat = 520
    #else
    @ScaledMetric(relativeTo: .body) private var sceneWidth: CGFloat = 220
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: RelaySpacing.giant) {
            PenSceneView(.welcome, width: sceneWidth)
            promise(alignment: .leading)
                .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        VStack(spacing: RelaySpacing.l) {
            PenSceneView(.welcome, width: sceneWidth)
            promise(alignment: .center)
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    private func promise(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: RelaySpacing.m) {
            RelayLockup(.hero)
            VStack(alignment: alignment, spacing: 0) {
                Text("Your games.", bundle: .module)
                Text("Every Apple screen.", bundle: .module)
            }
            .font(.relayDetailTitle)
            .foregroundStyle(RelayColor.textPrimary)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Relay plays the game files you own on iPhone, iPad, Apple TV and Mac, and keeps your progress with you.", bundle: .module)
                .font(.relayBody)
                .foregroundStyle(RelayColor.textSecondary)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: alignment == .leading ? .leading : .center)
        }
    }
}

/// Step 2 (iPhone, iPad, Mac): the ways games actually get in on this platform.
private struct BringGamesPage: View {
    var body: some View {
        #if os(macOS)
        OnboardingPage(scene: .dropIn, title: "Bring your games.",
                       message: "Drag the game files you own into this window, or choose File ▸ Import. Relay recognises each one and finds the cover.")
        #else
        OnboardingPage(scene: .dropIn, title: "Bring your games.",
                       message: "Add the game files you own from the Files app, by AirDrop, or straight from another app. Relay recognises each one and finds the cover.")
        #endif
    }
}

/// Step 3 (iPhone, iPad, Mac): progress that follows you, and what iCloud is
/// doing on this device right now.
private struct ContinuityPage: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        OnboardingPage(scene: .handoff, title: "Play here. Continue there.",
                       message: "Relay saves as you go. With iCloud on, your saves and your library follow you to every Relay. Without iCloud, everything still works right here.") {
            cloudLine
        }
    }

    @ViewBuilder
    private var cloudLine: some View {
        if model.sync.isAvailable, !isCloudOff {
            StatusLine(L("iCloud ready"), tone: .positive, symbol: .positive)
        } else {
            StatusLine(L("iCloud is off"), symbol: .info)
        }
    }

    private var isCloudOff: Bool {
        if case .cloudOff = model.sync.problem { return true }
        return false
    }
}

/// Step 2 (Apple TV): the couch needs a controller, and this screen knows
/// whether one is already there.
private struct ControllerPage: View {
    @State private var controllerName: String? = ControllerPage.firstControllerName

    var body: some View {
        OnboardingPage(symbol: .controller, title: "Grab a controller.",
                       message: "The Siri Remote gets you around. Games want a controller: pair one in Settings ▸ Remotes and Devices, then press any button.") {
            if let controllerName {
                StatusLine(String(localized: "Controller connected: \(controllerName)", bundle: .module), tone: .positive, symbol: .positive)
            } else {
                StatusLine(L("No controller yet"), symbol: .controllerDisconnected)
            }
        }
        #if canImport(GameController)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllerName = Self.firstControllerName }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in controllerName = Self.firstControllerName }
        #endif
    }

    private static var firstControllerName: String? {
        #if canImport(GameController)
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) else { return nil }
        return controller.vendorName ?? L("Controller")
        #else
        return nil
        #endif
    }
}

/// Step 3 (Apple TV): how a library reaches a television that has no file
/// picker, stated exactly as far as Relay goes today.
private struct LibraryArrivesPage: View {
    var body: some View {
        OnboardingPage(scene: .handoff, title: "Your library follows you.",
                       message: "With Relay Pro, choose Add games → From a computer to send games to this Apple TV. You can also sync your library from your iPhone, iPad or Mac.")
    }
}

// MARK: - Progress

/// Relay's own page indicator: the dash, one per step, Ember for the current one.
private struct StepDashes: View {
    let count: Int
    let current: Int
    #if os(tvOS)
    private let height: CGFloat = 8
    #else
    private let height: CGFloat = 4
    #endif

    var body: some View {
        HStack(spacing: RelaySpacing.xs) {
            ForEach(0..<count, id: \.self) { step in
                RelayDash(step == current ? RelayColor.ember : RelayColor.textTertiary.opacity(0.5), height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current + 1) of \(count)", bundle: .module))
    }
}
