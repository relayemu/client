// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDomain
import RelayDesignSystem
import RelayEmulation
import RelayEntitlements
import RelayInput
import RelayVideo

extension RelayProFeature {
    var productTitle: String {
        switch self {
        case .transfer: return L("From a computer")
        case .macGameplay: return L("Play on Mac")
        case .extendedRewind: return L("Extended Rewind")
        case .advancedSpeeds: return L("Advanced Speeds")
        case .touchLayoutEditing: return L("Touch Layout Editor")
        case .advancedControllerMapping: return L("Controller Mapping")
        case .cheats: return L("Cheats")
        case .advancedDisplay: return L("Advanced Display")
        case .extendedRecording: return L("Long Recordings")
        }
    }

    var productDescription: String {
        switch self {
        case .transfer: return L("Send games from your computer straight to Relay. Your files aren't stored online.")
        case .macGameplay: return L("Start and continue your games in the native Relay app for Mac.")
        case .extendedRewind: return L("Keep up to 60 seconds of recent play ready to rewind.")
        case .advancedSpeeds: return L("Add slow motion, 3×, 4× and Max when the active core supports them.")
        case .touchLayoutEditing: return L("Move, resize and fade controls on iPhone and iPad, for each system and orientation.")
        case .advancedControllerMapping: return L("Map game buttons and Relay actions, with a safe default always available.")
        case .cheats: return L("Use validated manual cheat codes on iPhone, iPad and Mac, with a safety save made first.")
        case .advancedDisplay: return L("Choose curated scaling, filters and per-game screen layouts.")
        case .extendedRecording: return L("Record gameplay without a plan-imposed time limit. Storage and device safety limits still apply.")
        }
    }

    var symbol: RelaySymbol {
        switch self {
        case .transfer: return .importFiles
        case .macGameplay: return .deviceMac
        case .extendedRewind: return .rewind
        case .advancedSpeeds: return .speed
        case .touchLayoutEditing: return .touch
        case .advancedControllerMapping: return .controller
        case .cheats: return .cheats
        case .advancedDisplay: return .display
        case .extendedRecording: return .recording
        }
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.relayBadge)
            .foregroundStyle(RelayColor.textSecondary)
            .padding(.horizontal, RelaySpacing.xs)
            .padding(.vertical, 3)
            .background(RelayColor.surfaceElevated, in: Capsule())
            .accessibilityLabel(Text("Relay Pro", bundle: .module))
    }
}

struct ProFeatureRow: View {
    let feature: RelayProFeature
    let unlocked: Bool
    private let activation: Activation

    private enum Activation {
        case action(() -> Void)
        case destination(Route)
    }

    init(feature: RelayProFeature, unlocked: Bool, action: @escaping () -> Void) {
        self.feature = feature
        self.unlocked = unlocked
        activation = .action(action)
    }

    init(feature: RelayProFeature, unlocked: Bool, destination: Route) {
        self.feature = feature
        self.unlocked = unlocked
        activation = .destination(destination)
    }

    var body: some View {
        Group {
            switch activation {
            case .action(let action):
                // A plain button carries no platform disclosure of its own, so the
                // label keeps the chevron for those rows only.
                Button(action: action) { ProFeatureLabel(feature: feature, unlocked: unlocked, showsDisclosure: true) }
            case .destination(let destination):
                // A NavigationLink inside a List already draws the platform
                // disclosure indicator; a second chevron reads as two links
                // (B2-IPH-002).
                NavigationLink(value: destination) { ProFeatureLabel(feature: feature, unlocked: unlocked, showsDisclosure: false) }
            }
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityIdentifier("relay.proFeature.\(feature.rawValue)")
        .accessibilityHint(unlocked ? Text("Opens settings", bundle: .module) : Text("Shows Relay Pro options", bundle: .module))
    }
}

private struct ProFeatureLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let feature: RelayProFeature
    let unlocked: Bool
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: RelaySpacing.s) {
            if !dynamicType.isAccessibilitySize {
                feature.symbol.image
                    .frame(width: 24)
                    .foregroundStyle(RelayColor.textSecondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                Text(feature.productTitle)
                    .font(.relayCardTitle)
                    .foregroundStyle(RelayColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if dynamicType.isAccessibilitySize && !unlocked { ProBadge() }
            }
            Spacer(minLength: RelaySpacing.s)
            if !dynamicType.isAccessibilitySize && !unlocked { ProBadge() }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RelayColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        // Keep the native button or link's full hit region inside its label.
        .frame(minHeight: EmberButtonStyle.height)
        .contentShape(Rectangle())
    }
}

struct ControllerMappingEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ControllerMappingProfile()
    @State private var perGame = false

    private var play: PlayModel { library.play }
    private var system: SystemDescriptor? {
        play.game.flatMap { SystemCatalog.descriptor(for: $0.systemID) }
    }

    var body: some View {
        Form {
            Section {
                Text("Choose what each physical button does. Menu and Home always keep Relay navigation safe.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
            }
            if let system {
                Section {
                    ForEach(ControllerMappingProfile.editableElements, id: \.self) { element in
                        Picker(gamepadLabel(element), selection: binding(for: element)) {
                            Text("Relay Default", bundle: .module).tag(InputBinding?.none)
                            ForEach(bindingChoices(for: system), id: \.self) { choice in
                                Text(bindingLabel(choice)).tag(Optional(choice))
                            }
                        }
                    }
                } header: {
                    Text(Formatting.systemName(system.id))
                }
                Section {
                    Toggle(isOn: $perGame) { Text("Only for this game", bundle: .module) }
                        .onChange(of: perGame) { _, newValue in profile = play.controllerMapping(perGame: newValue) }
                    Button {
                        play.resetControllerMapping(perGame: perGame)
                        profile = play.controllerMapping(perGame: perGame)
                    } label: { Text("Reset to Relay Default", bundle: .module) }
                    Button {
                        play.saveControllerMapping(profile, perGame: perGame)
                        dismiss()
                    } label: { Text("Save Mapping", bundle: .module) }
                        .buttonStyle(.ember)
                }
            }
        }
#if os(tvOS)
        .navigationTitle(Text("Controller", bundle: .module))
#else
        .navigationTitle(Text("Controller Mapping", bundle: .module))
#endif
        .accessibilityIdentifier("relay.controllerMappingEditor")
#if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
        }
#endif
        .onAppear {
            perGame = play.hasPerGameControllerMapping
            profile = play.controllerMapping(perGame: perGame)
        }
    }

    private func binding(for element: GamepadElement) -> Binding<InputBinding?> {
        Binding {
            profile.bindings[element]
        } set: { newValue in
            if let newValue { profile.bindings[element] = newValue }
            else { profile.bindings.removeValue(forKey: element) }
        }
    }

    private func bindingChoices(for system: SystemDescriptor) -> [InputBinding] {
        let inputs = EmulationInput.allCases
            .filter { ControllerMappingProfile.supports($0, in: system.inputLayout) }
            .map(InputBinding.input)
        return inputs + InputCommand.allCases.map(InputBinding.command)
    }

    private func gamepadLabel(_ element: GamepadElement) -> String {
        switch element {
        case .buttonA: return L("South button")
        case .buttonB: return L("East button")
        case .buttonX: return L("West button")
        case .buttonY: return L("North button")
        case .leftShoulder: return L("Left shoulder")
        case .rightShoulder: return L("Right shoulder")
        case .leftTrigger: return L("Left trigger")
        case .rightTrigger: return L("Right trigger")
        case .leftThumbstickButton: return L("Left stick click")
        case .rightThumbstickButton: return L("Right stick click")
        case .options: return L("Options button")
        case .dpadUp: return L("Up")
        case .dpadDown: return L("Down")
        case .dpadLeft: return L("Left")
        case .dpadRight: return L("Right")
        case .menu: return L("Menu")
        case .home: return L("Home")
        }
    }

    private func bindingLabel(_ binding: InputBinding) -> String {
        switch binding {
        case .input(let input): return L("Game · \(Formatting.inputName(input, system: play.game?.systemID))")
        case .command(let command):
            switch command {
            case .pause: return L("Relay · Pause")
            case .quickSave: return L("Relay · Quick Save")
            case .quickLoad: return L("Relay · Quick Load")
            case .rewind: return L("Relay · Rewind")
            case .fastForward: return L("Relay · Fast Forward")
            case .screenshot: return L("Relay · Screenshot")
            }
        }
    }
}

struct CheatsEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var code = ""
    @State private var format: CheatFormat = .gameShark
    @State private var validationMessage: String?

    private var play: PlayModel { library.play }
    private var formats: [CheatFormat] { CheatFormat.allCases.filter(play.supportedCheatFormats.contains) }

    var body: some View {
        ScrollViewReader { proxy in
            PlayToolsPage {
                #if !os(tvOS)
                if play.problem != nil {
                    RelayInlineOperationProblem(source: .play)
                        .id(RelayInlineOperationProblem.scrollID)
                }
                PlayToolsSection {
                    HStack(alignment: .top, spacing: RelaySpacing.m) {
                        PlayToolsIcon(systemName: "shield.lefthalf.filled")
                        Text("Relay creates a manual safety save before the first cheat is enabled in each play session.", bundle: .module)
                            .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                PlayToolsSection(title: L("Saved Cheats")) {
                    if play.cheats.isEmpty {
                        Text("No cheats for this game.", bundle: .module)
                            .foregroundStyle(RelayColor.textSecondary)
                    }
                    ForEach(play.cheats) { cheat in
                        HStack {
                            Button {
                                Task { await play.setCheatEnabled(cheat.id, enabled: !cheat.isEnabled) }
                            } label: {
                                Image(systemName: cheat.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(cheat.isEnabled ? RelayColor.ember : RelayColor.textSecondary)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.quietGlyph)
                            .accessibilityLabel(Text(cheat.label))
                            .accessibilityValue(cheat.isEnabled ? Text("Enabled", bundle: .module) : Text("Disabled", bundle: .module))
                            VStack(alignment: .leading) {
                                Text(cheat.label).font(.relayCardTitle)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(formatLabel(cheat.format)).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                            }
                            Spacer()
                            Button(role: .destructive) { play.removeCheat(cheat.id) } label: {
                                RelaySymbol.delete.image
                            }
                            .buttonStyle(.quietGlyph)
                            .accessibilityLabel(Text("Delete cheat", bundle: .module))
                            .accessibilityValue(Text(cheat.label))
                        }
                        if cheat.id != play.cheats.last?.id { Divider() }
                    }
                }
                PlayToolsSection(title: L("Manual Cheat"), footer: L("Use a code made for this exact game and region. Relay does not download cheat databases.")) {
                    TextField(String(localized: "Cheat name", bundle: .module), text: $label)
                        .textFieldStyle(.roundedBorder)
                    Picker(String(localized: "Format", bundle: .module), selection: $format) {
                        ForEach(formats, id: \.self) { Text(formatLabel($0)).tag($0) }
                    }
                    Divider()
                    TextField(String(localized: "Code", bundle: .module), text: $code, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...5)
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(RelayColor.critical)
                    }
                    Button(action: addCheat) { Text("Add Cheat", bundle: .module) }
                        .buttonStyle(.ember)
                        .disabled(formats.isEmpty)
                }
                #endif
            }
            .navigationTitle(Text("Cheats", bundle: .module))
            .accessibilityIdentifier("relay.cheatsEditor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
            .onAppear { if let first = formats.first { format = first } }
            .onChange(of: play.problem?.id) { _, id in
                guard id != nil else { return }
                proxy.scrollTo(RelayInlineOperationProblem.scrollID, anchor: .top)
            }
        }
    }

    private func addCheat() {
        let cheat = CheatDefinition(label: label, code: code, format: format)
        if let error = play.addCheat(cheat) {
            validationMessage = validationText(error)
        } else {
            label = ""
            code = ""
            validationMessage = nil
        }
    }

    private func validationText(_ error: CheatValidationError) -> String {
        switch error {
        case .emptyLabel: return L("Give this cheat a name.")
        case .emptyCode: return L("Enter a cheat code.")
        case .unsupportedFormat: return L("This cheat format is not supported here.")
        case .malformedCode: return L("This code does not match the selected format.")
        }
    }

    private func formatLabel(_ format: CheatFormat) -> String {
        switch format {
        case .gameShark: return "GameShark"
        case .codeBreaker: return "CodeBreaker"
        case .proActionReplay: return "Pro Action Replay"
        }
    }
}

struct AdvancedDisplayEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var options = DisplayOptions.standard
    @State private var arrangement: ScreenArrangement?
    @State private var perGame = true

    private var play: PlayModel { library.play }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Scaling", bundle: .module), selection: $options.scaling) {
                    Text("Pixel-perfect", bundle: .module).tag(DisplayScaling.integer)
                    Text("Fit", bundle: .module).tag(DisplayScaling.fit)
                    Text("Fill screen", bundle: .module).tag(DisplayScaling.fill)
                }
                Picker(String(localized: "Filter", bundle: .module), selection: $options.filter) {
                    Text("Original", bundle: .module).tag(DisplayFilter.original)
                    Text("Sharp", bundle: .module).tag(DisplayFilter.sharp)
                    Text("Smooth", bundle: .module).tag(DisplayFilter.smooth)
                    Text("Soft CRT", bundle: .module).tag(DisplayFilter.crtSoft)
                }
                if play.hasMultipleScreens {
                    Picker(String(localized: "Screens", bundle: .module), selection: screenBinding) {
                        Text("Stacked", bundle: .module).tag(Optional(ScreenArrangement.stacked))
                        Text("Side by side", bundle: .module).tag(Optional(ScreenArrangement.sideBySide))
                        Text("Top screen large", bundle: .module).tag(Optional(ScreenArrangement.primarySecondary))
                        Text("Bottom screen large", bundle: .module).tag(Optional(ScreenArrangement.secondaryPrimary))
                    }
                }
            } header: {
                Text("Picture", bundle: .module)
            }
            Section {
                Toggle(isOn: $perGame) { Text("Only for this game", bundle: .module) }
                Button {
                    play.saveAdvancedDisplay(options, arrangement: arrangement, perGame: perGame)
                    dismiss()
                } label: { Text("Save Display", bundle: .module) }
                    .buttonStyle(.ember)
            }
        }
#if os(tvOS)
        .navigationTitle(Text("Display", bundle: .module))
#else
        .navigationTitle(Text("Advanced Display", bundle: .module))
#endif
        .accessibilityIdentifier("relay.advancedDisplayEditor")
#if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
        }
#endif
        .onAppear {
            options = play.display
            arrangement = play.screenArrangement
        }
    }

    private var screenBinding: Binding<ScreenArrangement?> {
        Binding(get: { arrangement ?? .stacked }, set: { arrangement = $0 })
    }
}

#if os(iOS)
struct TouchLayoutEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.relayPlaySurfaceSize) private var playSurfaceSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var portrait = true
    @State private var draft = RelayTouchLayoutDraft()
    @State private var dragControl: TouchControl?
    @State private var dragOrigin = CGPoint.zero
    @State private var dragCanvas = CGSize.zero

    private var play: PlayModel { library.play }
    private var system: SystemDescriptor {
        play.game.flatMap { SystemCatalog.descriptor(for: $0.systemID) } ?? SystemCatalog.gameBoyAdvance
    }
    private func resolve(_ custom: TouchLayout?) -> RelayPlaySurfaceLayout {
        let size = CGSize(width: portrait ? min(playSurfaceSize.width, playSurfaceSize.height) : max(playSurfaceSize.width, playSurfaceSize.height),
                          height: portrait ? max(playSurfaceSize.width, playSurfaceSize.height) : min(playSurfaceSize.width, playSurfaceSize.height))
        return RelayPlaySurfaceLayout(size: size, showsTouchControls: true, controls: system.inputLayout,
                                      screens: system.screens, preferredArrangement: play.screenArrangement,
                                      scaling: play.display.scaling, displayScale: displayScale, customTouchLayout: custom)
    }
    private var surface: RelayPlaySurfaceLayout { resolve(draft.layout) }
    private var deviceScale: CGFloat { surface.controlScale }
    private var fallback: TouchLayout { resolve(nil).touchLayout }

    /// Show the paused pictures wherever they intersect the editor's canonical
    /// control canvas. The excluded space is visible rather than an unexplained
    /// empty region where a drag silently stops. This preview receives no input.
    private func picturePreview(in canvas: CGSize) -> some View {
        let geometry = surface
        let sources = play.session.screenFrameSources
        let pictures = RelayLogicalScreenLayout(size: geometry.gameFrame.size, screens: play.screens,
                                                preferred: play.screenArrangement, gap: RelaySpacing.xs)
        let xScale = canvas.width / max(1, geometry.controlFrame.width)
        let yScale = canvas.height / max(1, geometry.controlFrame.height)
        return ZStack {
            ForEach(sources.indices, id: \.self) { index in
                if index < pictures.frames.count {
                    let frame = pictures.frames[index]
                    EmulationVideoView(source: sources[index], options: play.display)
                        .frame(width: frame.width * xScale, height: frame.height * yScale)
                        .position(x: (geometry.gameFrame.minX - geometry.controlFrame.minX + frame.midX) * xScale,
                                  y: (geometry.gameFrame.minY - geometry.controlFrame.minY + frame.midY) * yScale)
                        .zIndex(pictures.arrangement == .secondaryPrimary ? Double(1 - index) : Double(index))
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: RelaySpacing.m) {
            Picker(String(localized: "Orientation", bundle: .module), selection: $portrait) {
                Text("Portrait", bundle: .module).tag(true)
                Text("Landscape", bundle: .module).tag(false)
            }
            .pickerStyle(.segmented)

            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                        .fill(play.skin.enabled ? play.skin.background : RelayColor.ink)
                    RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                        .strokeBorder(RelayColor.separator)
                    picturePreview(in: proxy.size)
                    ForEach(surface.touchLayout.elements, id: \.control) { element in
                        let previewSize = surface.previewSize(for: element, in: proxy.size)
                        let factor = previewSize.width / element.shape.size.width
                        touchElement(element)
                            .frame(width: element.shape.size.width, height: element.shape.size.height)
                            .scaleEffect(factor)
                            .frame(width: previewSize.width, height: previewSize.height)
                            // Selection targets are transparent and independent
                            // of the accurately scaled visible control shape.
                            .frame(width: max(44, previewSize.width), height: max(44, previewSize.height))
                            .contentShape(Rectangle())
                            .position(previewCenter(of: element, in: proxy.size))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("relay.touch.editor")).onChanged { value in
                                if dragControl != element.control {
                                    draft.selected = element.control
                                    dragControl = element.control
                                    dragOrigin = element.fittedCenter(in: surface.controlFrame.size)
                                    dragCanvas = proxy.size
                                }
                                guard proxy.size == dragCanvas,
                                      abs(value.translation.width) + abs(value.translation.height) > 0.5 else { return }
                                let center = CGPoint(x: dragOrigin.x + value.translation.width / max(1, proxy.size.width),
                                                     y: dragOrigin.y + value.translation.height / max(1, proxy.size.height))
                                move(element.control, to: center)
                            }.onEnded { _ in dragControl = nil })
                            .accessibilityLabel(Text(element.label.isEmpty ? L("Directional pad") : element.label))
                            .accessibilityHint(Text("Choose this control, then move or resize it.", bundle: .module))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                draft.selected = element.control
                            }
                            .accessibilityAction(named: Text("Move left", bundle: .module)) {
                                nudge(element, x: -0.03, y: 0)
                            }
                            .accessibilityAction(named: Text("Move right", bundle: .module)) {
                                nudge(element, x: 0.03, y: 0)
                            }
                            .accessibilityAction(named: Text("Move up", bundle: .module)) {
                                nudge(element, x: 0, y: -0.03)
                            }
                            .accessibilityAction(named: Text("Move down", bundle: .module)) {
                                nudge(element, x: 0, y: 0.03)
                            }
                    }
                }
                .coordinateSpace(name: "relay.touch.editor")
            }
            .aspectRatio(max(1, surface.controlFrame.width) / max(1, surface.controlFrame.height), contentMode: .fit)
            .frame(maxHeight: 480)

            // Keep the row's space while nothing is selected so choosing a
            // control does not move the canvas beneath the first drag.
            HStack {
                Text("Size", bundle: .module)
                Slider(value: draft.selected.map { sizeBinding(for: $0) } ?? .constant(1), in: 0.6...1.6, step: 0.05)
                    .accessibilityLabel(Text("Control size", bundle: .module))
            }
            .opacity(draft.selected == nil ? 0 : 1)
            .allowsHitTesting(draft.selected != nil)
            .accessibilityHidden(draft.selected == nil)
            HStack {
                Text("Opacity", bundle: .module)
                Slider(value: $draft.opacity, in: 0.2...1, step: 0.05)
                    .accessibilityLabel(Text("Control opacity", bundle: .module))
            }
            HStack {
                Button {
                    play.resetTouchLayout(portrait: portrait)
                    draft = RelayTouchLayoutDraft(layout: resolve(nil).touchLayout, opacity: draft.opacity)
                    dragControl = nil
                } label: { Text("Reset", bundle: .module) }
                    .buttonStyle(.quiet)
                Button {
                    play.saveTouchLayout(draft.layout,
                                         portrait: portrait, scale: deviceScale, opacity: draft.opacity)
                    dismiss()
                } label: { Text("Save Layout", bundle: .module) }
                    .buttonStyle(.ember)
            }
        }
        .padding(RelaySpacing.layout.screenMargin)
        .background(RelayColor.canvas)
        .navigationTitle(Text("Touch Layout Editor", bundle: .module))
        .accessibilityIdentifier("relay.touchLayoutEditor")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
        }
        .onAppear { loadLayout() }
        .onChange(of: portrait) { _, _ in loadLayout() }
        .onChange(of: playSurfaceSize) { _, _ in
            // Invalidate a gesture's projection without treating its next
            // accumulated translation as the start of a new drag.
            if dragControl != nil { dragCanvas = .zero }
        }
    }

    private func loadLayout() {
        let custom = play.preferences.effectiveCustomTouchLayout(for: system.id, portrait: portrait, policy: play.accessPolicy)
        draft = RelayTouchLayoutDraft(layout: custom ?? resolve(nil).touchLayout, opacity: play.effectiveTouchOpacity)
        dragControl = nil
    }

    private func nudge(_ element: TouchLayoutElement, x: CGFloat, y: CGFloat) {
        draft.selected = element.control
        let center = element.fittedCenter(in: surface.controlFrame.size)
        move(element.control, to: CGPoint(x: center.x + x, y: center.y + y))
    }

    private func move(_ control: TouchControl, to center: CGPoint) {
        let current = surface
        draft.edit(control, on: current) { element in
            let moved = element.moved(to: center)
            return moved.moved(to: moved.fittedCenter(in: current.controlFrame.size))
        }
    }

    private func sizeBinding(for control: TouchControl) -> Binding<Double> {
        Binding(get: {
            guard let element = surface.touchLayout.elements.first(where: { $0.control == control }) else { return 1 }
            return scale(of: element, relativeTo: fallback)
        }, set: { newValue in
            guard let base = fallback.elements.first(where: { $0.control == control }) else { return }
            let current = surface
            draft.edit(control, on: current) { element in
                let resized = TouchLayoutElement(control, base.shape.scaled(by: newValue), at: element.center, label: element.label)
                return resized.moved(to: resized.fittedCenter(in: current.controlFrame.size))
            }
        })
    }

    private func touchElement(_ element: TouchLayoutElement) -> some View {
        ZStack {
            TouchLayoutPreviewShape(shape: element.shape)
                .fill((play.skin.enabled ? play.skin.background : RelayColor.surfaceElevated).opacity(draft.opacity))
                .overlay(TouchLayoutPreviewShape(shape: element.shape)
                    .stroke(draft.selected == element.control ? RelayColor.ember : (play.skin.enabled ? play.skin.accentColor(for: system.id) : RelayColor.offWhite.opacity(0.45)),
                            lineWidth: draft.selected == element.control ? 3 : 1))
            Text(element.shape.isDPad ? "+" : element.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(play.skin.enabled ? play.skin.foreground : RelayColor.offWhite)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 4)
        }
    }

    private func scale(of element: TouchLayoutElement, relativeTo fallback: TouchLayout) -> Double {
        guard let base = fallback.elements.first(where: { $0.control == element.control }),
              base.shape.size.width > 0 else { return 1 }
        return Double(min(1.6, max(0.6, element.shape.size.width / base.shape.size.width)))
    }

    /// Both centers and visible sizes project the player geometry. Selection
    /// target expansion never changes either the picture or the raw draft.
    private func previewCenter(of element: TouchLayoutElement, in canvas: CGSize) -> CGPoint {
        surface.previewCenter(for: element, in: canvas)
    }
}

private struct TouchLayoutPreviewShape: Shape {
    let shape: TouchLayoutElement.Shape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .round, .stick: return Path(ellipseIn: rect)
        case .capsule: return RoundedRectangle(cornerRadius: rect.height / 2).path(in: rect)
        case .dpad:
            let arm = rect.width * 0.34
            let vertical = CGRect(x: rect.midX - arm / 2, y: rect.minY, width: arm, height: rect.height)
            let horizontal = CGRect(x: rect.minX, y: rect.midY - arm / 2, width: rect.width, height: arm)
            var path = RoundedRectangle(cornerRadius: arm * 0.3).path(in: vertical)
            path.addPath(RoundedRectangle(cornerRadius: arm * 0.3).path(in: horizontal))
            return path
        }
    }
}

private extension TouchLayoutElement.Shape {
    var isDPad: Bool {
        if case .dpad = self { return true }
        return false
    }
}
#endif
