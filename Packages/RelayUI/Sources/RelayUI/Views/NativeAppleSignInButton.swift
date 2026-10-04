// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AuthenticationServices

/// Apple's own control and authorization sheet, including the native tvOS
/// nearby-device flow. The originating window supplies the presentation anchor.
struct NativeAppleSignInButton: View {
    let isEnabled: Bool
    let action: @MainActor (ASPresentationAnchor) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AppleAuthorizationControl(isEnabled: isEnabled,
                                  style: colorScheme == .dark ? .white : .black, action: action)
            .id(colorScheme)
            .frame(minHeight: minimumHeight)
            .accessibilityIdentifier("settings.relayAccount.signIn")
    }

    private var minimumHeight: CGFloat {
        #if os(tvOS)
        66
        #else
        44
        #endif
    }
}

#if os(macOS)
private struct AppleAuthorizationControl: NSViewRepresentable {
    let isEnabled: Bool
    let style: ASAuthorizationAppleIDButton.Style
    let action: @MainActor (ASPresentationAnchor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: style)
        button.target = context.coordinator
        button.action = #selector(Coordinator.pressed(_:))
        return button
    }
    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) { button.isEnabled = isEnabled }

    @MainActor final class Coordinator: NSObject {
        let action: @MainActor (ASPresentationAnchor) -> Void
        init(action: @escaping @MainActor (ASPresentationAnchor) -> Void) { self.action = action }
        @objc func pressed(_ button: ASAuthorizationAppleIDButton) {
            guard let window = button.window else { return }
            action(window)
        }
    }
}
#else
private struct AppleAuthorizationControl: UIViewRepresentable {
    let isEnabled: Bool
    let style: ASAuthorizationAppleIDButton.Style
    let action: @MainActor (ASPresentationAnchor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: style)
        // ASAuthorizationAppleIDButton is a UIControl, not a UIButton: on iOS a tap sends
        // touchUpInside only; the tvOS remote's select sends primaryActionTriggered.
        #if os(tvOS)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .primaryActionTriggered)
        #else
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .touchUpInside)
        #endif
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) { button.isEnabled = isEnabled }

    @MainActor final class Coordinator: NSObject {
        let action: @MainActor (ASPresentationAnchor) -> Void
        init(action: @escaping @MainActor (ASPresentationAnchor) -> Void) { self.action = action }
        @objc func pressed(_ button: ASAuthorizationAppleIDButton) {
            guard let window = button.window else { return }
            action(window)
        }
    }
}
#endif
