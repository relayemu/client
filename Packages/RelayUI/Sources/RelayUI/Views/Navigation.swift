// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Navigation.swift
//  RelayUI — routes shared by every shell.

import SwiftUI
import RelayDomain
import RelayEntitlements

public enum Route: Hashable {
    case game(GameID)
    case system(SystemID)
    case library(LibraryFilter)
    case settings
    case relayPro(RelayProFeature?)
    case relayAccount
    case relayMembership
    case retroAchievements
    case achievements(GameID)
    case formats
    case diagnostics
    case about
    case openSource
    case licenseComponent(String)
}

public enum LibraryFilter: Hashable, Sendable {
    case all
    case favorites
    case system(SystemID)
    case recentlyPlayed
    case recentlyAdded
}

/// Sidebar sections (iPad, macOS) and tabs (iPhone, tvOS).
public enum Destination: Hashable, Sendable {
    case home
    case allGames
    case favorites
    case system(SystemID)
    case search
    case settings
}

/// Applies the app's navigation destinations to a stack.
struct RouteDestinations: ViewModifier {
    @Environment(LibraryModel.self) private var model

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            // A pushed browsing destination owns its bar preferences; hiding
            // only the tab's root does not hide this screen's native chrome.
            // Keep this scoped to game-launch routes, not Pro/Account sheets.
            case .game(let id):
                GameDetailView(gameID: id)
                    #if os(iOS)
                    .relayChromeHidden(model.isPlaying)
                    #endif
            case .system(let id):
                SystemPageView(systemID: id)
                    #if os(iOS)
                    .relayChromeHidden(model.isPlaying)
                    #endif
            case .library(let filter):
                LibraryView(initialFilter: filter)
                    #if os(iOS)
                    .relayChromeHidden(model.isPlaying)
                    #endif
            case .settings: SettingsView()
            case .relayPro(let feature): RelayProView(feature: feature)
            case .retroAchievements: RetroAchievementsSettingsView()
            case .achievements(let id): GameAchievementsView(gameID: id)
            case .relayAccount:
                if let account = model.environment.relayAccount {
                    List { RelayAccountSettingsSection(account: account) }
                        .relaySettingsPage(L("Relay account"))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            case .relayMembership:
                if let account = model.environment.relayAccount {
                    RelaySyncMembershipView(account: account)
                }
            case .formats: FormatsView(isPresentedModally: false)
            case .diagnostics: DiagnosticsView()
            case .about: AboutRelayView()
            case .openSource: OpenSourceView()
            case .licenseComponent(let id):
                if let component = LicensesDataset.bundled()?.shippedComponents.first(where: { $0.id == id }) {
                    ComponentDetailView(component: component)
                } else {
                    OpenSourceView()
                }
            }
        }
    }
}

public extension View {
    func relayRoutes() -> some View { modifier(RouteDestinations()) }
}

private struct RelayBrowsingStateKey: EnvironmentKey {
    static let defaultValue: Binding<RelayBrowsingState>? = nil
}

extension EnvironmentValues {
    /// Adaptive iOS shells supply durable state; standalone Mac/TV views keep
    /// their own local state without sharing it with another window or tab.
    var relayBrowsingState: Binding<RelayBrowsingState>? {
        get { self[RelayBrowsingStateKey.self] }
        set { self[RelayBrowsingStateKey.self] = newValue }
    }
}

extension View {
    /// Keyboard shortcuts exist on iOS/iPadOS/macOS only; tvOS has no keyboard.
    @ViewBuilder
    func relayKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers) -> some View {
        #if os(tvOS)
        self
        #else
        keyboardShortcut(key, modifiers: modifiers)
        #endif
    }
}

extension View {
    /// Hides the platform's own window chrome while a game is playing. AppKit's
    /// window toolbar and UIKit's navigation and tab bars are not part of the
    /// SwiftUI content, so they survive `opacity(0)` and would sit on top of the
    /// picture.
    @ViewBuilder
    func relayChromeHidden(_ hidden: Bool) -> some View {
        #if os(macOS)
        // SwiftUI's `.toolbar(_:for: .windowToolbar)` does not win against the
        // split view that declares the toolbar, so the window is told directly.
        background(WindowChrome(toolbarHidden: hidden))
        #elseif os(iOS)
        toolbar(hidden ? .hidden : .visible, for: .navigationBar, .tabBar)
        #else
        self
        #endif
    }
}


#if os(macOS)
import AppKit

/// Hides the window's toolbar while a game is playing and restores it afterwards.
/// The toolbar belongs to the NSWindow, not to the SwiftUI content, so neither
/// `opacity` nor a toolbar visibility on an ancestor of the split view removes it,
/// and it would otherwise sit above the picture.
private struct WindowChrome: NSViewRepresentable {
    let toolbarHidden: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let hidden = toolbarHidden
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.toolbar?.isVisible = !hidden
            window.titlebarAppearsTransparent = hidden
            window.titleVisibility = hidden ? .hidden : .visible
        }
    }
}
#endif
