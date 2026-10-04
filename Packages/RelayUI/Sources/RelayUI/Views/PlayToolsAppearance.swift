// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelayDesignSystem

/// A reading surface for optional play tools, with the same cards as Game Detail.
struct PlayToolsPage<Content: View>: View {
    @ViewBuilder let content: Content

    private var pageMargin: CGFloat {
        #if os(tvOS)
        RelaySpacing.xl
        #else
        RelaySpacing.layout.screenMargin
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RelaySpacing.xl) { content }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(pageMargin)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .relayKeyboardScrollContainer()
        .relayCanvas(grouped: true)
        .tint(RelayColor.ember)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

struct PlayToolsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if let title { SettingsHeader(title).font(.relaySubheader) }
            VStack(alignment: .leading, spacing: RelaySpacing.m) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .playToolsSurface()
            if let footer {
                Text(footer)
                    .font(.relayMeta)
                    .foregroundStyle(RelayColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PlayToolsIcon: View {
    var systemName: String = "trophy.fill"
    var highlighted = true

    var body: some View {
        Image(systemName: systemName)
            .font(.relaySubheader)
            .foregroundStyle(highlighted ? RelayColor.ember : RelayColor.textSecondary)
            .frame(width: RelaySpacing.huge, height: RelaySpacing.huge)
            .background(highlighted ? RelayColor.emberTint : RelayColor.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: RelayRadius.m, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func playToolsTextField() -> some View {
        #if os(tvOS)
        self
        #else
        self.textFieldStyle(.roundedBorder)
        #endif
    }

    func playToolsSurface() -> some View {
        padding(RelaySpacing.l)
            .background(RelayColor.surface, in: RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous).strokeBorder(RelayColor.separator))
    }
}
