// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PauseOverlay.swift
//  three quick actions (only when the running core supports them), then
//  collapsed preferences. On a short landscape iPhone the header stays pinned
//  when it fits; at accessibility sizes the whole card can scroll.
//  tvOS: Resume is default-focused; Menu resumes.

import SwiftUI
import RelayDomain
import RelayDesignSystem
import RelayEmulation
import RelayInput
import RelayVideo
import RelayEntitlements

struct PauseOverlay: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var confirmExit = false
    @State private var rewindHeld = false
    @State private var activeTool: PlayTool?
    @State private var shareFile: GameplayShareFile?
    // Shared by every ViewThatFits candidate so opening a group cannot reset it
    // when the card switches from fitting content to its scrolling layout.
    @State private var speedExpanded = false
    @State private var rewindExpanded = false
    @State private var displayExpanded = false
    @State private var controllerExpanded = false
    @State private var discExpanded = false
    #if os(tvOS)
    @FocusState private var resumeFocused: Bool
    #endif

    private var play: PlayModel { model.play }
    private var showsTool: Bool {
        activeTool != nil || shareFile != nil || actions.playSavesPresented
            || actions.activePresentation == .playTool || actions.activePresentation == .playSaves
    }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// iPhone portrait: a bottom sheet; everywhere else a centred card (IPHONE_UX §5.3, IPAD_UX §8).
    private var cardAlignment: Alignment {
        #if os(iOS)
        return sizeClass == .compact && verticalSizeClass == .regular ? .bottom : .center
        #else
        return .center
        #endif
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
                .onTapGesture { if actions.canPresentRelaySurface { play.resume() } }
                .accessibilityHidden(true)
            OverlayCard {
                #if os(tvOS)
                // Expanding a preference must not replace the focused remote
                // button by switching ViewThatFits candidates.
                scrollingPreferences
                #else
                // Hug the content when it fits; otherwise pin the header and scroll the list (IPHONE_UX §5.3).
                ViewThatFits(in: .vertical) {
                    VStack(spacing: RelaySpacing.m) {
                        header
                        list
                    }
                    .padding(RelaySpacing.l)
                    scrollingPreferences
                    ScrollView {
                        VStack(spacing: RelaySpacing.m) {
                            header
                            list
                        }
                        .padding(RelaySpacing.l)
                    }
                }
                #endif
            }
            .frame(maxHeight: .infinity, alignment: cardAlignment)
            .padding(RelaySpacing.layout.screenMargin)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Paused", bundle: .module))
            .opacity(showsTool ? 0 : 1)
        }
        // Hide Pause controls while a tool owns presentation, retaining the
        // backdrop that keeps gameplay from competing with the active tool.
        .opacity(rewindHeld ? 0 : 1)
        .allowsHitTesting(!showsTool)
        .accessibilityHidden(showsTool)
        .confirmationDialog(Text("Exit without saving?", bundle: .module), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await model.stop() } } label: { Text("Exit Game", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Your last save didn't go through. Relay will try once more on exit.", bundle: .module)
        }
        #if os(tvOS)
        // Explicit full-screen presentation also preserves the native tvOS
        // behavior on 26.0, whose sheet presentation was corrected in 26.1.
        .fullScreenCover(item: $activeTool, onDismiss: { actions.presentationDidDismiss(.playTool) }) { tool in
            toolDestination(tool)
        }
        #else
        .sheet(item: $activeTool, onDismiss: { actions.presentationDidDismiss(.playTool) }) { tool in
            toolDestination(tool)
        }
        #endif
        #if os(iOS) || os(macOS)
        .sheet(item: $shareFile, onDismiss: { actions.presentationDidDismiss(.playTool) }) { file in
            GameplayShareSheet(file: file)
        }
        #endif
        #if os(tvOS)
        .onAppear { resumeFocused = true }
        #endif
    }

    private var scrollingPreferences: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], RelaySpacing.l)
            ScrollView {
                list.padding(RelaySpacing.l)
            }
            .mask(scrollFade)
        }
    }

    private func toolDestination(_ tool: PlayTool) -> some View {
        NavigationStack {
            switch tool {
            case .pro(let feature): RelayProView(feature: feature, isPresentedModally: true, dismissPresentation: { activeTool = nil }).relayRoutes()
            case .controller: ControllerMappingEditor()
            case .cheats: CheatsEditor()
            case .display: AdvancedDisplayEditor()
            case .achievements:
                if let game = play.game { GameAchievementsView(gameID: game.id, isPresentedModally: true).relayRoutes() }
            #if os(iOS)
            case .touch: TouchLayoutEditor()
            case .skin: SkinEditor()
            #endif
            }
        }
        #if os(tvOS)
        .relayCanvas(grouped: true)
        #endif
    }

    // MARK: Pinned header: notice, Resume, quick actions

    private var header: some View {
        VStack(spacing: RelaySpacing.s) {
            if play.notice == .controllerDisconnected {
                NoticeBar(headline: L("Your controller disconnected."),
                          message: play.requiresController ? L("Reconnect a controller to continue.") : L("Reconnect it, or use touch controls."),
                          symbol: .controllerDisconnected)
            }
            Button { play.resume() } label: {
                Label { Text("Resume", bundle: .module) } icon: { RelaySymbol.play.image }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ember)
            .disabled(!actions.canPresentRelaySurface || (play.notice == .controllerDisconnected && play.requiresController))
            .relayKeyboardShortcut(.escape, modifiers: [])
            #if os(tvOS)
            .focused($resumeFocused)
            #endif
            if play.canSaveStates || play.canRewind {
                if dynamicType > .xLarge {
                    VStack(spacing: RelaySpacing.s) { quickActions }
                } else {
                    HStack(spacing: RelaySpacing.s) { quickActions }
                }
            }
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        if play.canSaveStates {
            quickAction(L("Quick Save"), symbol: .quickSave) { Task { await play.quickSave() } }
                .accessibilityLabel(Text("Quick Save", bundle: .module))
            quickAction(L("Saves"), symbol: .loadState) { actions.openPlaySaves() }
        }
        if play.canRewind {
            RewindButton(held: $rewindHeld, enabled: play.hasRewindHistory,
                         begin: { play.beginRewind() }, end: { play.endRewind() })
        }
    }

    private func quickAction(_ title: String, symbol: RelaySymbol, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            QuickActionLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.quiet)
        .frame(maxWidth: .infinity)
    }

    // MARK: Preferences stay one disclosure away from the common actions

    private var list: some View {
        VStack(spacing: RelaySpacing.m) {
            if let disc = play.session.discStatus, disc.count > 1 {
                PauseDisclosure(id: "disc", title: L("Disc"), value: L("Disc \(disc.selectedIndex + 1) of \(disc.count)"),
                                symbol: .systems, isExpanded: $discExpanded) {
                    Picker(L("Disc"), selection: Binding(get: { play.session.discStatus?.selectedIndex ?? 0 }, set: { play.selectDisc(at: $0) })) {
                        ForEach(0..<disc.count, id: \.self) { index in Text("Disc \(index + 1)", bundle: .module).tag(index) }
                    }
                    .modifier(PausePickerStyle())
                    .accessibilityIdentifier("relay.pause.discPicker")
                    Text("Change discs when the game asks. Then resume play.", bundle: .module)
                        .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                }
            }
            if let game = play.game, AchievementSystem.isEligible(game.systemID) {
                Button { presentTool(.achievements) } label: {
                    Label { Text("Achievements", bundle: .module) } icon: { RelaySymbol.achievements.image }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("relay.pause.achievements")
            }
            if play.canFastForward {
                PauseDisclosure(id: "speed", title: L("Speed"), value: Formatting.speedLabel(play.speed),
                                symbol: .speed, isExpanded: $speedExpanded) {
                    Picker(L("Speed"), selection: Binding(get: { play.speed }, set: { play.setSpeed($0) })) {
                        ForEach(play.availableSpeeds, id: \.self) { Text(Formatting.speedLabel($0)).tag($0) }
                    }
                    .modifier(PausePickerStyle())
                    .accessibilityIdentifier("relay.pause.speedPicker")
                    if !play.allows(.advancedSpeeds), play.session.supportedSpeeds.contains(where: { ![.normal, .double].contains($0) }) {
                        ProFeatureRow(feature: .advancedSpeeds, unlocked: false) { presentTool(.pro(.advancedSpeeds)) }
                    }
                }
            }
            if play.canRewind {
                PauseDisclosure(id: "rewind", title: L("Rewind"), value: rewindDescription,
                                symbol: .rewind, isExpanded: $rewindExpanded) {
                    Picker(L("Rewind"), selection: Binding(get: { play.effectiveRewindDuration }, set: { play.setRewindDuration($0) })) {
                        Text("Off", bundle: .module).tag(0.0)
#if os(tvOS)
                        Text(verbatim: "10 s").tag(10.0)
                            .accessibilityLabel(Text("10 seconds", bundle: .module))
                        if play.allows(.extendedRewind) {
                            Text(verbatim: "30 s").tag(30.0)
                                .accessibilityLabel(Text("30 seconds", bundle: .module))
                            Text(verbatim: "60 s").tag(60.0)
                                .accessibilityLabel(Text("1 minute", bundle: .module))
                        }
#else
                        Text("10 seconds", bundle: .module).tag(10.0)
                        if play.allows(.extendedRewind) {
                            Text("30 seconds", bundle: .module).tag(30.0)
                            Text("1 minute", bundle: .module).tag(60.0)
                        }
#endif
                    }
                    .modifier(PausePickerStyle())
                    .accessibilityIdentifier("relay.pause.rewindPicker")
                    if !play.allows(.extendedRewind) {
                        ProFeatureRow(feature: .extendedRewind, unlocked: false) { presentTool(.pro(.extendedRewind)) }
                    }
                }
            }
            PauseDisclosure(id: "display", title: L("Display"), value: displayDescription,
                            symbol: .display, isExpanded: $displayExpanded) {
                Picker(L("Scaling"), selection: Binding(get: { play.display.scaling }, set: { play.display.scaling = $0 })) {
                    Text("Pixel-perfect", bundle: .module).tag(DisplayScaling.integer)
                    Text("Fit", bundle: .module).tag(DisplayScaling.fit)
                }
                .modifier(PausePickerStyle())
                .accessibilityIdentifier("relay.pause.scalingPicker")
                Picker(L("Filter"), selection: Binding(get: { play.display.filter }, set: { play.display.filter = $0 })) {
                    Text("Original", bundle: .module).tag(DisplayFilter.original)
                    Text("Sharp", bundle: .module).tag(DisplayFilter.sharp)
                }
                .modifier(PausePickerStyle())
                .accessibilityIdentifier("relay.pause.filterPicker")
                if play.hasMultipleScreens {
                    Picker(L("Screens"), selection: Binding(get: { play.screenArrangement ?? .stacked },
                                                            set: { play.screenArrangement = $0 })) {
                        Text("Stacked", bundle: .module).tag(ScreenArrangement.stacked)
                        Text("Side by side", bundle: .module).tag(ScreenArrangement.sideBySide)
                        Text("Large and small", bundle: .module).tag(ScreenArrangement.primarySecondary)
                    }
                    .modifier(PausePickerStyle())
                }
                ProFeatureRow(feature: .advancedDisplay, unlocked: play.allows(.advancedDisplay)) {
                    presentTool(play.allows(.advancedDisplay) ? .display : .pro(.advancedDisplay))
                }
            }
            PauseDisclosure(id: "controller", title: L("Controls"), value: controllerDescription,
                            symbol: play.controllerName == nil ? .controllerDisconnected : .controller,
                            isExpanded: $controllerExpanded) {
                if play.session.supportedControllers.count > 1 {
                    Picker(L("Controller type"), selection: Binding(get: { play.session.controllerKind }, set: { play.setControllerKind($0) })) {
                        Text("Digital", bundle: .module).tag(EmulationControllerKind.digital)
                        Text("DualShock", bundle: .module).tag(EmulationControllerKind.dualShock)
                    }
                    .modifier(PausePickerStyle())
                    .accessibilityIdentifier("relay.pause.controllerKind")
                    #if os(tvOS)
                    if let game = play.game, let system = SystemCatalog.descriptor(for: game.systemID),
                       SystemGamepadMapping(system: system, appleTV: true, profile: play.controllerMapping()).simultaneousStickClickInput != nil {
                        Text("Press both sticks together for Select.", bundle: .module)
                            .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                    }
                    #endif
                    if play.session.controllerKind == .dualShock {
                        Toggle(isOn: Binding(get: { play.session.analogModeEnabled }, set: { play.setAnalogModeEnabled($0) })) {
                            Text("Analog mode", bundle: .module)
                        }
                        .accessibilityIdentifier("relay.pause.analogMode")
                    }
                }
                if play.session.usesEmulatedFirmware {
                    Text("Using emulated system software. Add PlayStation firmware in Settings for better compatibility.", bundle: .module)
                        .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                }
                ProFeatureRow(feature: .advancedControllerMapping, unlocked: play.allows(.advancedControllerMapping)) {
                    presentTool(play.allows(.advancedControllerMapping) ? .controller : .pro(.advancedControllerMapping))
                }
                #if os(iOS)
                Button { presentTool(.skin) } label: {
                    HStack {
                        Label { Text("Skin", bundle: .module) } icon: { Image(systemName: "circle.lefthalf.filled") }
                            .font(.relayCardTitle)
                        Spacer(minLength: RelaySpacing.s)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(RelayColor.textTertiary).accessibilityHidden(true)
                    }
                    .frame(minHeight: EmberButtonStyle.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("relay.skin.open")
                ProFeatureRow(feature: .touchLayoutEditing, unlocked: play.allows(.touchLayoutEditing)) {
                    presentTool(play.allows(.touchLayoutEditing) ? .touch : .pro(.touchLayoutEditing))
                }
                #endif
            }
            #if os(iOS) || os(macOS)
            GameplayShareMenu(play: play) { file in
                shareFile = file
            }
            #endif
            #if !os(tvOS)
            if play.canUseCheats {
                ProFeatureRow(feature: .cheats, unlocked: play.allows(.cheats)) {
                    presentTool(play.allows(.cheats) ? .cheats : .pro(.cheats))
                }
            }
            #endif
            Button(role: .destructive) {
                if play.lastAutoSaveFailed { confirmExit = true } else { Task { await model.stop() } }
            } label: {
                Label { Text("Exit Game", bundle: .module) } icon: { RelaySymbol.exitGame.image }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(RelayColor.critical)
            }
            .buttonStyle(.quiet)
            .disabled(!actions.canPresentRelaySurface)
            .relayKeyboardShortcut("w", modifiers: [.command, .shift])
        }
    }

    private func presentTool(_ tool: PlayTool) {
        guard actions.beginPresentation(.playTool) else { return }
        activeTool = tool
    }

    private var controllerDescription: String {
        if let name = play.controllerName { return name }
        #if os(iOS)
        return L("Touch controls")
        #elseif os(macOS)
        return L("Keyboard")
        #else
        return L("None")
        #endif
    }

    private var rewindDescription: String {
        switch play.effectiveRewindDuration {
        case 0: return L("Off")
        case 10: return L("10 seconds")
        case 30: return L("30 seconds")
        default: return L("1 minute")
        }
    }

    private var displayDescription: String {
        switch play.display.filter {
        case .original: return L("Original")
        case .sharp: return L("Sharp")
        case .smooth: return L("Smooth")
        case .crtSoft: return L("Soft CRT")
        }
    }

    private var scrollFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }
    }
}

/// Menu pickers retain complete French labels and large text without fitting
/// every choice into the card's width. tvOS keeps its remote-friendly segments.
private struct PausePickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var accessibleMinimumHeight: CGFloat = 44

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.pickerStyle(.segmented).labelsHidden()
        #else
        content
            .pickerStyle(.menu)
            // A menu Picker otherwise keeps a compact control height even when
            // its selected value grows to several accessibility-sized lines.
            // Scale the hit region with the body font so the label stays inside
            // the control instead of overlapping the adjacent picker.
            .frame(maxWidth: .infinity,
                   minHeight: dynamicType.isAccessibilitySize ? accessibleMinimumHeight : nil,
                   alignment: .leading)
        #endif
    }
}

/// Native disclosure on handhelds and Mac; tvOS uses a native focusable button
/// because DisclosureGroup is unavailable there. The value remains readable
/// without opening the group, and only the selected preferences take space.
private struct PauseDisclosure<Content: View>: View {
    let id: String
    let title: String
    let value: String
    let symbol: RelaySymbol
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Button {
                withAnimation(RelayMotion.standard(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: RelaySpacing.s) {
                    rowLabel
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("relay.pause.\(id)")
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed", bundle: .module))
            if isExpanded { preferences }
        }
        #else
        DisclosureGroup(isExpanded: $isExpanded) {
            preferences.padding(.top, RelaySpacing.xs)
        } label: {
            // Keep the disclosure identifier on its label. Applying it to the
            // group also overwrites the identifiers of its revealed controls.
            rowLabel.accessibilityIdentifier("relay.pause.\(id)")
        }
        .tint(RelayColor.textSecondary)
        #endif
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowLabel: some View {
        HStack(spacing: RelaySpacing.s) {
            symbol.image.foregroundStyle(RelayColor.textSecondary).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RelaySpacing.s) {
                    Text(title).font(.relayCardTitle).fixedSize()
                    Spacer(minLength: RelaySpacing.s)
                    Text(value).font(.relayMeta).foregroundStyle(RelayColor.textSecondary).fixedSize()
                }
                VStack(alignment: .leading, spacing: RelaySpacing.xxs) {
                    Text(title).font(.relayCardTitle)
                    Text(value).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(RelayColor.textPrimary)
        .frame(minHeight: EmberButtonStyle.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        #if os(macOS)
        .help(value)
        #endif
    }
}

private enum PlayTool: Identifiable {
    case pro(RelayProFeature)
    case controller
    case cheats
    case display
    case achievements
    #if os(iOS)
    case touch
    case skin
    #endif

    var id: String {
        switch self {
        case .pro(let feature): return "pro.\(feature.rawValue)"
        case .controller: return "controller"
        case .cheats: return "cheats"
        case .display: return "display"
        case .achievements: return "achievements"
        #if os(iOS)
        case .touch: return "touch"
        case .skin: return "skin"
        #endif
        }
    }
}

/// Press-and-hold Rewind (§17.2 / §17.3): the overlay hides, the picture runs
/// backwards while held, release resumes play. Also a plain button on tvOS
/// (hold on the Siri Remote / controller button).
struct RewindButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Binding var held: Bool
    let enabled: Bool
    let begin: () -> Void
    let end: () -> Void

    var body: some View {
        QuickActionLabel(title: L("Rewind"), symbol: .rewind)
        .padding(.horizontal, RelaySpacing.l)
        .padding(.vertical, RelaySpacing.xs)
        .frame(minHeight: EmberButtonStyle.height)
        .foregroundStyle(enabled ? RelayColor.textPrimary : RelayColor.textTertiary)
        .background {
            if dynamicType.isAccessibilitySize {
                RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                    .fill(RelayColor.surfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                        .strokeBorder(RelayColor.separator))
            } else {
                Capsule().fill(RelayColor.surfaceElevated)
                    .overlay(Capsule().strokeBorder(RelayColor.separator))
            }
        }
        .contentShape(Capsule())
        #if os(tvOS)
        .focusable(enabled)
        #endif
        .modifier(HoldModifier { pressing in
            guard enabled else { return }
            if pressing, !held { held = true; begin() }
            if !pressing, held { held = false; end() }
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Rewind", bundle: .module))
        .accessibilityHint(Text("Hold to rewind", bundle: .module))
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity)
    }
}

/// Press-and-hold detection with the platform's available long-press API.
private struct HoldModifier: ViewModifier {
    let onPressingChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: onPressingChanged)
        #else
        content.onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}, onPressingChanged: onPressingChanged)
        #endif
    }
}

/// Every primary action reserves the same icon and two-line label footprint.
/// Longer text sizes stack the group before words become squeezed in the row.
private struct QuickActionLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    #if os(tvOS)
    private let iconSlotHeight: CGFloat = 44
    private let labelSlotHeight: CGFloat = 56
    #else
    @ScaledMetric(relativeTo: .title3) private var iconSlotHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .caption) private var labelSlotHeight: CGFloat = 32
    #endif
    let title: String
    let symbol: RelaySymbol

    var body: some View {
        VStack(spacing: RelaySpacing.xxs) {
            symbol.image.font(.relaySubheader)
                .frame(height: iconSlotHeight)
            Group {
                if dynamicType > .xLarge {
                    Text(title)
                } else {
                    Text(title).lineLimit(2)
                }
            }
            .font(.relayBadge)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Reserve the common footprint around the whole visible group. A
        // reserved invisible second text line shifts one-line labels upwards.
        .frame(maxWidth: .infinity, minHeight: iconSlotHeight + RelaySpacing.xxs + labelSlotHeight, alignment: .center)
        .padding(.vertical, RelaySpacing.xxs)
        .padding(.horizontal, -RelaySpacing.s)
    }
}
