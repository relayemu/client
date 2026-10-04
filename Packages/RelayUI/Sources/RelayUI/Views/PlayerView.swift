// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlayerView.swift
//  TVOS_UX §11, MACOS_UX §6). Nothing but the game on black; touch controls on
//  iPhone/iPad; a fading pause button; toasts and the mode pill; the pause
//  overlay; lifecycle handling (background → pause + autosave).

import SwiftUI
import RelayDomain
import RelayDesignSystem
import RelayEmulation
import RelayVideo
import RelayInput

public struct PlayerView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var pauseButtonVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// The play surface must hold keyboard focus. Without it the library's sidebar
    /// list stays the window's first responder and eats the arrow keys the player
    /// is pressing to move in the game.
    @FocusState private var focused: Bool

    public init() {}

    private var play: PlayModel { model.play }

    public var body: some View {
        @Bindable var actions = actions
        GeometryReader { proxy in
            #if os(iOS)
            // This reader receives SwiftUI's safe content bounds. Only the black
            // background bleeds under system regions; subtracting the reported
            // insets here would reserve those edges a second time.
            let system = play.game.flatMap { SystemCatalog.descriptor(for: $0.systemID) }
            let custom = system.flatMap {
                play.preferences.effectiveCustomTouchLayout(for: $0.id, portrait: proxy.size.width <= proxy.size.height,
                                                           policy: play.accessPolicy)
            }
            let layout = RelayPlaySurfaceLayout(size: proxy.size, showsTouchControls: showsTouchControls,
                                               controls: system?.inputLayout, screens: play.screens,
                                               preferredArrangement: play.screenArrangement, scaling: play.display.scaling,
                                               displayScale: displayScale, customTouchLayout: custom)
            #else
            let layout = RelayPlaySurfaceLayout(size: proxy.size, showsTouchControls: false)
            #endif
            // Hit testing, bottom to top: the reveal surface takes only what nothing
            // else wanted; the picture carries the touch screens of two-screen
            // systems; the touch controls take their own controls and let every
            // other touch fall through; the HUD takes nothing; the pause button is
            ZStack {
                Color.black.ignoresSafeArea()
                #if !os(tvOS)
                revealSurface
                #endif
                #if os(iOS)
                if showsTouchControls {
                    RelaySkinDeck(configuration: play.skin, system: play.game?.systemID ?? .gameBoyAdvance,
                                  excluding: layout.gameFrame)
                }
                #endif
                gameArea(in: layout)
                    #if os(tvOS)
                    // Gameplay owns Menu without wrapping Pause's controls in
                    // a custom focusable container.
                    .focusable(!play.isPaused)
                    .focused($focused)
                    .focusEffectDisabled()
                    #endif
                #if os(iOS)
                touchControls(in: layout)
                #endif
                hud
                #if os(iOS) || os(macOS)
                if play.sharing.state == .recording, !play.isPaused {
                    VStack {
                        HStack {
                            Button { play.sharing.stopClip() } label: {
                                Label {
                                    Text("Stop · \(play.sharing.elapsedTime)", bundle: .module)
                                        .monospacedDigit()
                                } icon: { Image(systemName: "stop.circle.fill") }
                                .padding(RelaySpacing.s)
                                .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("relay.share.stop")
                            .accessibilityLabel(Text("Stop recording", bundle: .module))
                            Spacer()
                        }
                        Spacer()
                    }.padding(RelaySpacing.m)
                }
                #endif
                #if !os(tvOS)
                pauseButton(in: layout)
                #endif
                if play.isPaused {
                    PauseOverlay()
                        .transition(.opacity)
                }
            }
            .environment(\.relayPlaySurfaceSize, proxy.size)
            #if os(iOS)
            // A stable immersive presentation avoids a size/bar-visibility
            // feedback loop when a resizable window crosses a square aspect.
            .statusBarHidden(true)
            #endif
        }
        .tint(RelayColor.ember)
        // Stable hook for the UI tests that check what is on screen during play.
        .accessibilityIdentifier("relay.player")
        #if DEBUG && os(iOS)
        // Test-only: which touch controls a finger is holding, and the last one
        // pressed (kept after release so a tap that has ended is still visible).
        // This is how a UI test proves a real touch reached the control layer
        .accessibilityValue(touchStateValue)
        #endif
        #if os(iOS) || os(macOS)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: play.isPaused) { _, paused in focused = !paused && actions.canPresentRelaySurface }
        .onChange(of: actions.canPresentRelaySurface) { _, available in focused = available && !play.isPaused }
        #endif
        #if os(macOS)
        // The game already receives keys through GameController's keyboard profile,
        // which reads the hardware directly and does not go through the responder
        // chain. AppKit therefore sees the same key press as unhandled and beeps at
        // every one of them, so the play surface consumes them here. Command
        // shortcuts are left alone: those belong to the menu bar.
        .onKeyPress(phases: [.down, .repeat, .up]) { press in
            guard !play.isPaused, actions.canPresentRelaySurface else { return .ignored }
            return press.modifiers.contains(.command) ? .ignored : .handled
        }
        #endif
        .persistentSystemOverlays(.hidden)
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: play.isPaused)
        .onAppear { scheduleHide(); focused = true }
        #if os(tvOS)
        .onExitCommand { if actions.canPresentRelaySurface { play.togglePause() } }
        .onPlayPauseCommand { if actions.canPresentRelaySurface { play.togglePause() } }
        .onChange(of: play.isPaused) { _, paused in focused = !paused }
        #endif
        #if os(macOS)
        .onExitCommand { if actions.canPresentRelaySurface { play.togglePause() } }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive: play.sceneDidBecomeInactive()
            case .background: Task { await play.sceneDidEnterBackground() }
            case .active: play.sceneDidBecomeActive()
            @unknown default: break
            }
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $actions.playSavesPresented, onDismiss: { actions.presentationDidDismiss(.playSaves) }) {
            SavesView(context: .inGame)
        }
        #else
        .sheet(isPresented: $actions.playSavesPresented, onDismiss: { actions.presentationDidDismiss(.playSaves) }) {
            SavesView(context: .inGame)
        }
        #endif
        .alert(item: problemBinding) { message in
            Alert(title: Text(message.headline), message: Text(message.message),
                  dismissButton: .default(Text("Close", bundle: .module)) { actions.acknowledgePlayError(message.id) })
        }
        .accessibilityElement(children: .contain)
        #if os(iOS)
        // The retained native tab/sidebar shell is behind this play surface.
        // VoiceOver must stay in the active game/Pause subtree, not that shell.
        .accessibilityAddTraits(.isModal)
        #endif
    }

    private var problemBinding: Binding<ProductMessage?> {
        let presented = RelayPlayerAlert.pending(problem: play.problem,
                                                 acknowledgedID: actions.acknowledgedPlayErrorID,
                                                 presentationOccupied: !actions.canPresentRelaySurface)
        return Binding(get: { presented }, set: { value in
            guard actions.canPresentRelaySurface, value == nil, let presented else { return }
            actions.acknowledgePlayError(presented.id)
        })
    }

    // MARK: Game

    /// Allocate the picture without replacing its view on a size transition.
    private func gameArea(in layout: RelayPlaySurfaceLayout) -> some View {
        screensView(in: layout.gameFrame.size)
            .accessibilityLabel(Text(model.playingGame?.title ?? ""))
            .accessibilityHint(Text(play.isPaused ? "Paused" : "Game running", bundle: .module))
            .frame(width: layout.gameFrame.width, height: layout.gameFrame.height)
            .position(x: layout.gameFrame.midX, y: layout.gameFrame.midY)
    }

    // MARK: Screens

    /// Stable screen identities preserve the Metal surfaces through arrangements.
    /// The native pixel mapping remains owned by the existing video presenter.
    @ViewBuilder
    private func screensView(in size: CGSize) -> some View {
        let sources = play.session.screenFrameSources
        let screens = play.screens
        if sources.count > 1, screens.count == sources.count {
            let layout = RelayLogicalScreenLayout(size: size, screens: screens,
                                                   preferred: play.screenArrangement, gap: RelaySpacing.xs)
            ZStack {
                ForEach(sources.indices, id: \.self) { index in
                    let frame = layout.frames[index]
                    screenView(index, sources: sources, screens: screens)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .zIndex(layout.arrangement == .secondaryPrimary ? Double(1 - index) : Double(index))
                }
            }
        } else {
            EmulationVideoView(source: play.session.frameSource, counter: play.session.presentationCounter, options: play.display)
        }
    }

    @ViewBuilder
    private func screenView(_ index: Int, sources: [VideoFrameSource], screens: [LogicalScreen]) -> some View {
        let source = sources[index]
        let video = EmulationVideoView(source: source, counter: index == 0 ? play.session.presentationCounter : nil, options: play.display)
        if screens[index].acceptsTouch {
            #if os(tvOS)
            video
            #elseif os(iOS)
            // A stylus press must reach the emulator at touch-down. A SwiftUI
            // drag can defer a stationary tap until its release, leaving no
            // emulated frame with a pressed touch screen.
            ZStack {
                video
                ScreenTouchSurface(source: source, options: play.display, displayScale: displayScale,
                                   isEnabled: !play.isPaused && !play.isRewinding,
                                   onTouch: { x, y in play.touchScreen(index: index, x: x, y: y) },
                                   onRelease: { play.releaseTouchScreen() })
            }
            #else
            // The drag lives on a transparent shape above the picture rather than
            // on the video itself: the video is a non-interactive display surface,
            GeometryReader { screenProxy in
                video.overlay(
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    if let point = MetalFrameView.nativePoint(for: value.location, frame: source.frameDescriptor,
                                                                              in: screenProxy.size, options: play.display,
                                                                              displayScale: displayScale) {
                                        play.touchScreen(index: index, x: point.x, y: point.y)
                                    } else {
                                        play.releaseTouchScreen()
                                    }
                                }
                                .onEnded { _ in play.releaseTouchScreen() }))
            }
            #endif
        } else {
            video
        }
    }

    #if os(iOS)
    private var showsTouchControls: Bool { !play.touchControlsHidden && !play.isRewinding }

    @ViewBuilder
    private func touchControls(in surface: RelayPlaySurfaceLayout) -> some View {
        // Keep the existing two-finger recognizer available when the buttons are
        // hidden. An empty layout has no game-button hit areas and lets ordinary
        // screen touches pass through, while rebuilding releases held buttons.
        let layout = surface.touchLayout
        TouchControls(layout: layout, haptics: play.preferences.touchHaptics, opacity: play.effectiveTouchOpacity,
                      // Both the portrait deck and landscape grips are now
                      // outside the pictures; keep their outlines readable.
                      hasDedicatedBackground: true,
                      isEnabled: !play.isPaused && !play.isRewinding,
                      skin: play.skin, skinSystem: play.game?.systemID ?? .gameBoyAdvance,
                      onChange: { control, pressed in play.touch(control, pressed: pressed) },
                      onStick: { control, position in play.touchStick(control, position: position) },
                      onTwoFingerTap: { play.toggleTouchControls() })
            .frame(width: surface.controlFrame.width, height: surface.controlFrame.height)
            .position(x: surface.controlFrame.midX, y: surface.controlFrame.midY)
            .opacity(play.isPaused || play.isRewinding ? 0 : 1)
            .allowsHitTesting(!play.isPaused && !play.isRewinding)
            .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: play.touchControlsHidden)
    }
    #endif

    // MARK: HUD (§17.3)

    private var hud: some View {
        VStack {
            HStack {
                if play.isRewinding {
                    ModePill(L("Rewinding"), symbol: .rewind)
                } else if play.speed != .normal {
                    ModePill(Formatting.speedLabel(play.speed), symbol: .speed)
                }
                Spacer()
            }
            .padding(RelaySpacing.m)
            Spacer()
        }
        .overlay(alignment: hudToastAlignment) {
            VStack(spacing: RelaySpacing.s) {
                if let toast = play.toast {
                    StatusToast(toast.text, symbol: toast.symbol, thumbnail: toast.thumbnail)
                        .transition(.opacity)
                }
                if let achievement = model.environment.achievements.notification {
                    AchievementUnlockToast(achievement: achievement)
                        .id(achievement.id)
                        .transition(.opacity)
                } else if model.environment.achievements.activationNotice {
                    StatusToast(model.environment.achievements.activeMode == .hardcore ? L("RetroAchievements ready · Hardcore") : L("RetroAchievements ready · Casual"), symbol: .achievements)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(4))
                            model.environment.achievements.dismissActivationNotice()
                        }
                }
                let achievements = model.environment.achievements
                if achievements.activeMode == .hardcore || !achievements.challenges.isEmpty || achievements.measuredProgress != nil || achievements.resetRequired {
                    AchievementActivityHUD(model: achievements)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, RelaySpacing.m)
        }
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: play.toast)
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: model.environment.achievements.notification)
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: play.isRewinding)
        .allowsHitTesting(false)
    }

    private var hudToastAlignment: Alignment {
        #if os(tvOS)
        return .topLeading
        #else
        return .top
        #endif
    }

    // MARK: Pause button (iPhone/iPad/macOS)

    #if !os(tvOS)
    private var pauseControl: some View {
        Button { play.pause() } label: {
            RelaySymbol.pause.image
                .font(.relayCardTitle)
                .foregroundStyle(RelayColor.offWhite)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .relayKeyboardShortcut("p", modifiers: .command)
        .disabled(!actions.canPresentRelaySurface)
        .accessibilityLabel(Text("Pause", bundle: .module))
        .opacity(pauseButtonVisible && !play.isPaused && !play.isRewinding ? 1 : 0)
        // Hidden Pause must not steal game touches. Its reveal location is
        // separately kept clear of controller hit areas by the layout.
        .allowsHitTesting(pauseButtonVisible && !play.isPaused && !play.isRewinding)
        .animation(RelayMotion.standard(reduceMotion: reduceMotion), value: pauseButtonVisible)
    }

    @ViewBuilder
    private func pauseButton(in surface: RelayPlaySurfaceLayout) -> some View {
        #if os(iOS)
        let frame = surface.pauseButtonFrame
        pauseControl
            .position(x: frame.midX, y: frame.midY)
            .background(keyboardCommands)
        #else
        VStack {
            HStack {
                pauseControl
                Spacer()
            }
            Spacer()
        }
        .padding(RelaySpacing.m)
        .background(keyboardCommands)
        #endif
    }

    #if DEBUG && os(iOS)
    /// Which touch controls a finger is holding, and the last one pressed (kept
    /// after release so a tap that has ended is still observable). Carried as the
    /// player's accessibility value so a UI test can prove a real touch reached
    private var touchStateValue: String {
        let held = play.touchedControls.map(\.rawValue).sorted().joined(separator: "+")
        let last = play.lastTouchedControl?.rawValue ?? "-"
        return "held:\(held) last:\(last)"
    }
    #endif

    /// Brings the pause button back after a tap that no interactive layer wanted.
    ///
    /// This used to be a full-screen `contentShape` + `onTapGesture` wrapped around
    /// the pause button, sitting ABOVE the touch controls, so it captured every
    /// finger on the player and the touch controls never saw a touch at all
    /// only ever receives what nothing above it claimed.
    private var revealSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { pauseButtonVisible = true; scheduleHide() }
            #if os(macOS)
            .onContinuousHover { phase in
                if case .active = phase { pauseButtonVisible = true; scheduleHide() }
            }
            #endif
    }

    /// Menu-bar / keyboard commands that must never double as game buttons:
    /// hidden buttons carrying the shortcuts (MACOS_UX §4–5, IPAD_UX §6).
    private var keyboardCommands: some View {
        Group {
            Button("") { Task { await play.quickSave() } }.relayKeyboardShortcut("s", modifiers: .command)
            Button("") { Task { await play.quickLoad() } }.relayKeyboardShortcut("l", modifiers: .command)
            Button("") { Task { await play.saveNow() } }.relayKeyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { actions.openPlaySaves() }.relayKeyboardShortcut("l", modifiers: [.command, .shift])
            Button("") { play.setSpeed(play.speed == .normal ? play.preferences.fastForwardSpeed : .normal) }.relayKeyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { play.pause() }.relayKeyboardShortcut(.escape, modifiers: [])
        }
        .disabled(!actions.canPresentRelaySurface)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
    #endif

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pauseButtonVisible = false
        }
    }
}

enum RelayPlayerAlert {
    static func pending(problem: ProductMessage?, acknowledgedID: UUID?, presentationOccupied: Bool) -> ProductMessage? {
        guard !presentationOccupied, let problem, problem.id != acknowledgedID else { return nil }
        return problem
    }
}
