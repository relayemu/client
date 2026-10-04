// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDesignSystem

extension View {
    /// Keep television headings outside the list's focus-driven scrolling and fade.
    @ViewBuilder
    func relaySettingsPage(_ title: String) -> some View {
        #if os(tvOS)
        TVSettingsPage(title: title) { self }
        #else
        self.navigationTitle(Text(verbatim: title))
        #endif
    }

    /// tvOS's inline picker can omit its label. Keep the label and choices together.
    @ViewBuilder
    func relayTVSettingsControl(_ title: String) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Text(title)
                .font(.relayMeta)
                .foregroundStyle(RelayColor.textSecondary)
            self.labelsHidden()
        }
        .padding(.vertical, RelaySpacing.xs)
        #else
        self
        #endif
    }

    /// An information page has no controls of its own. On a television an
    /// unfocusable page hands focus to the tab bar, which leaves the text
    /// unscrollable and sends Menu out of the app instead of returning to the
    /// parent. The reading surface itself owns focus instead (B2-TV-002).
    @ViewBuilder
    func relayInfoSettingsPage(_ title: String) -> some View {
        #if os(tvOS)
        TVInfoPage(title: title) { self }
        #else
        self.navigationTitle(Text(verbatim: title))
        #endif
    }
}

#if os(tvOS)
/// Title column plus one focusable reading column. Used by the pages that only
/// show information: the remote scrolls the surface and Menu pops the stack.
struct TVInfoPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    /// The information page is the only reading target on screen, so it takes
    /// focus as soon as it appears. Without an owned focus target the pushed page
    /// leaves focus empty, the remote cannot scroll and Menu leaves the app
    /// (B2-TV-002).
    @FocusState private var reading: Bool

    var body: some View {
        TVSettingsPage(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, RelaySpacing.xl)
            }
            .focusSection()
            .defaultFocus($reading, true)
            .accessibilityIdentifier("settings.infoPage")
        }
    }
}

/// A group of lines on an information page, with the same dash that introduces
/// every other Relay group.
struct TVInfoSection<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: Content
    @FocusState private var focused: Bool

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if let header {
                HStack(alignment: .top, spacing: RelaySpacing.xs) {
                    RelayDash(RelayColor.textTertiary, height: 3).padding(.top, 7)
                    Text(header)
                        .font(.relayShelfTitle)
                        .foregroundStyle(RelayColor.textPrimary)
                }
            }
            VStack(alignment: .leading, spacing: RelaySpacing.m) { content }
            if let footer {
                Text(footer)
                    .font(.relayMeta)
                    .foregroundStyle(RelayColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Each block of information is a focus target of its own: the remote
        // walks the page and the scroll view follows it.
        .focusable()
        .focused($focused)
    }
}

/// One labelled line of an information page.
struct TVInfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
            Text(label).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .relayBody)
                .foregroundStyle(RelayColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A stable title column and a native, independently scrolling settings list.
/// Native rows retain the system's directional focus and Menu navigation.
private struct TVSettingsPage<Content: View>: View {
    let title: String
    var preview: TVSettingsCategory? = nil
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: RelaySpacing.giant) {
                VStack(alignment: .leading, spacing: RelaySpacing.xl) {
                    if let preview {
                        preview.symbol.image
                            .font(.relayScreenTitle)
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        Text(title)
                            .font(.relayScreenTitle)
                            .fixedSize()
                        Text(title)
                            .font(.relayShelfTitle)
                            .fixedSize()
                        Text(title)
                            .font(.relayShelfTitle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview {
                        Text(preview.explanation)
                            .font(.relayBody)
                            .foregroundStyle(RelayColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .foregroundStyle(RelayColor.textPrimary)
                    .frame(width: geometry.size.width / 3, alignment: .leading)
                    .padding(.top, RelaySpacing.xxl)

                content
                    .listStyle(.plain)
                    .labelStyle(TVSettingsLabelStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tint(RelayColor.textPrimary)
            }
            .padding(.horizontal, RelaySpacing.layout.screenMargin)
            .padding(.top, RelaySpacing.xl)
            .padding(.bottom, RelaySpacing.layout.screenMargin)
        }
        .relayCanvas()
        .navigationTitle(Text(verbatim: ""))
    }
}

/// Keep category and nested app routes on the same value-based navigation path.
/// A view-based category would remain above a subsequently pushed Route value.
private enum TVSettingsSectionRoute: Hashable {
    case play, sync, firmware, library, help, advanced
}

private enum TVSettingsCategory: Hashable {
    case pro, play, sync, achievements, firmware, library, help, advanced, about

    var title: String {
        switch self {
        case .pro: L("Relay Pro")
        case .play: L("Play")
        case .sync: L("Sync")
        case .achievements: L("RetroAchievements")
        case .firmware: L("PlayStation Firmware")
        case .library: L("Library")
        case .help: L("Help")
        case .advanced: L("Advanced")
        case .about: L("About Relay")
        }
    }

    var symbol: RelaySymbol {
        switch self {
        case .pro: .pro
        case .play: .play
        case .sync: .syncing
        case .achievements: .achievements
        case .firmware: .firmware
        case .library: .library
        case .help, .about: .info
        case .advanced: .gameSettings
        }
    }

    var explanation: String {
        switch self {
        case .pro: L("Play tools and purchase options.")
        case .play: L("Resume, rewind, and game speed.")
        case .sync: L("Choose how your progress and games sync.")
        case .achievements: L("Free, optional achievements for supported games.")
        case .firmware: L("Check or add PlayStation system files.")
        case .library: L("Game count and local storage.")
        case .help: L("Getting started and supported formats.")
        case .advanced: L("Diagnostic information for troubleshooting.")
        case .about: L("App version, credits, and licenses.")
        }
    }
}

private struct TVSettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVSettingsLabel(configuration: configuration)
    }
}

private struct TVSettingsLabel: View {
    @Environment(\.isFocused) private var isFocused
    let configuration: LabelStyleConfiguration

    var body: some View {
        HStack(spacing: RelaySpacing.xl) {
            configuration.icon
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isFocused ? RelayColor.ink : RelayColor.textPrimary)
                .frame(width: RelaySpacing.huge)
            configuration.title
        }
    }
}

/// A short category list mirrors the system Settings hierarchy instead of putting
/// every preference, explanation and upgrade action into one long television list.
struct TVSettingsRootView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @FocusState private var focusedCategory: TVSettingsCategory?
    @State private var previewCategory: TVSettingsCategory = .pro

    var body: some View {
        TVSettingsPage(title: previewCategory.title, preview: previewCategory) {
            categories
        }
        .navigationDestination(for: TVSettingsSectionRoute.self) { section in
            sectionPage(section)
        }
        .onChange(of: focusedCategory) { _, category in
            // Preserve context when focus moves to the tab bar or a destination.
            if let category { previewCategory = category }
        }
    }

    private var categories: some View {
        List {
            NavigationLink(value: Route.relayPro(nil)) {
                HStack {
                    Label { Text("Relay Pro", bundle: .module) } icon: { RelaySymbol.pro.image }
                    Spacer()
                    if model.play.allows(.macGameplay) {
                        Text("Active", bundle: .module)
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                }
            }
            .focused($focusedCategory, equals: .pro)
            .accessibilityIdentifier("settings.relayPro")

            NavigationLink(value: TVSettingsSectionRoute.play) {
                Label { Text("Play", bundle: .module) } icon: { RelaySymbol.play.image }
            }
            .focused($focusedCategory, equals: .play)
            .accessibilityIdentifier("settings.play")

            NavigationLink(value: TVSettingsSectionRoute.sync) {
                Label { Text("Sync", bundle: .module) } icon: { RelaySymbol.syncing.image }
            }
            .focused($focusedCategory, equals: .sync)
            .accessibilityIdentifier("settings.sync")

            NavigationLink(value: Route.retroAchievements) {
                Label { Text("RetroAchievements", bundle: .module) } icon: { RelaySymbol.achievements.image }
            }
            .focused($focusedCategory, equals: .achievements)
            .accessibilityIdentifier("settings.retroAchievements")

            NavigationLink(value: TVSettingsSectionRoute.firmware) {
                Label { Text("PlayStation Firmware", bundle: .module) } icon: { RelaySymbol.firmware.image }
            }
            .focused($focusedCategory, equals: .firmware)

            NavigationLink(value: TVSettingsSectionRoute.library) {
                Label { Text("Library", bundle: .module) } icon: { RelaySymbol.library.image }
            }
            .focused($focusedCategory, equals: .library)

            NavigationLink(value: TVSettingsSectionRoute.help) {
                Label { Text("Help", bundle: .module) } icon: { RelaySymbol.info.image }
            }
            .focused($focusedCategory, equals: .help)

            NavigationLink(value: TVSettingsSectionRoute.advanced) {
                Label { Text("Advanced", bundle: .module) } icon: { RelaySymbol.gameSettings.image }
            }
            .focused($focusedCategory, equals: .advanced)

            NavigationLink(value: Route.about) {
                Label { Text("About Relay", bundle: .module) } icon: { RelaySymbol.info.image }
            }
            .focused($focusedCategory, equals: .about)
        }
        .accessibilityIdentifier("settings.screen")
    }

    @ViewBuilder
    private func sectionPage(_ section: TVSettingsSectionRoute) -> some View {
        switch section {
        case .play:
            List { PlaySettingsSection() }
                .relaySettingsPage(L("Play"))
        case .sync:
            List { SyncSettingsSections() }
                .relaySettingsPage(L("Sync"))
        case .firmware: PlayStationFirmwareView()
        case .library: librarySettings
        case .help: helpSettings
        case .advanced: advancedSettings
        }
    }

    private var librarySettings: some View {
        List {
            Section {
                DetailRow(label: L("Games"), value: model.games.count.formatted())
                DetailRow(label: L("Library location"), value: String(localized: "On \(Formatting.thisDevice(model.deviceKind))", bundle: .module))
                if !model.problems.isEmpty {
                    Button { model.dismissAllProblems() } label: { Text("Clear import issues", bundle: .module) }
                }
            } footer: {
                Text("Games are copied into Relay's own storage on \(Formatting.thisDevice(model.deviceKind)).", bundle: .module)
            }
            CoverSettingsSection()
        }
        .relaySettingsPage(L("Library"))
    }

    private var helpSettings: some View {
        List {
            Button { actions.replayOnboarding() } label: { Text("Getting Started", bundle: .module) }
                .accessibilityIdentifier("settings.gettingStarted")
            NavigationLink(value: Route.formats) { Text("Which formats work?", bundle: .module) }
        }
        .relaySettingsPage(L("Help"))
    }

    private var advancedSettings: some View {
        List {
            NavigationLink(value: Route.diagnostics) { Text("Diagnostics", bundle: .module) }
        }
        .relaySettingsPage(L("Advanced"))
    }
}
#endif
