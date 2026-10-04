// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS)
import SwiftUI
import RelayDomain
import RelayDesignSystem

struct SkinEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    private var play: PlayModel { library.play }
    private var system: SystemDescriptor {
        play.game.flatMap { SystemCatalog.descriptor(for: $0.systemID) } ?? SystemCatalog.gameBoyAdvance
    }

    var body: some View {
        Form {
            Section {
                SkinPreview(configuration: play.skin, system: system)
                    .frame(height: 230)
                    .accessibilityHidden(true)
                    .listRowInsets(EdgeInsets())
                Toggle(isOn: Binding(get: { play.skin.enabled }, set: { play.setSkinEnabled($0) })) {
                    Text("Use Skin", bundle: .module)
                }
                .accessibilityIdentifier("relay.skin.enabled")
            } footer: {
                Text("Your control positions stay the same.", bundle: .module)
            }
            Section {
                Picker(selection: Binding(get: { play.skin.finish }, set: {
                    var skin = play.skin; skin.finish = $0; play.setSkin(skin)
                })) {
                    Text("Graphite", bundle: .module).tag(RelaySkinConfiguration.Finish.graphite)
                    Text("Mist", bundle: .module).tag(RelaySkinConfiguration.Finish.mist)
                } label: { Text("Finish", bundle: .module) }
                .accessibilityIdentifier("relay.skin.finish")
                .disabled(!play.allows(.touchLayoutEditing) || !play.skin.enabled)

                Picker(selection: Binding(get: { play.skin.accent }, set: {
                    var skin = play.skin; skin.accent = $0; play.setSkin(skin)
                })) {
                    Text("System Accent", bundle: .module).tag(RelaySkinConfiguration.Accent.system)
                    Text("Neutral", bundle: .module).tag(RelaySkinConfiguration.Accent.neutral)
                    Text("Teal", bundle: .module).tag(RelaySkinConfiguration.Accent.teal)
                    Text("Violet", bundle: .module).tag(RelaySkinConfiguration.Accent.violet)
                } label: { Text("Accent", bundle: .module) }
                .accessibilityIdentifier("relay.skin.accent")
                .disabled(!play.allows(.touchLayoutEditing) || !play.skin.enabled)
                if !play.allows(.touchLayoutEditing) {
                    NavigationLink {
                        RelayProView(feature: .touchLayoutEditing)
                    } label: {
                        Label { Text("Customize with Relay Pro", bundle: .module) } icon: { Image(systemName: "slider.horizontal.3") }
                    }
                }
            } header: {
                Text(system.name)
            } footer: {
                Text("Saved for this system in both orientations.", bundle: .module)
            }
        }
        .navigationTitle(Text("Skin", bundle: .module))
        .accessibilityIdentifier("relay.skin.editor")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        }
    }
}

/// Uses the shipping UIKit controls, at their actual proportions, in a compact
/// non-interactive landscape preview. The editor beside it owns touch geometry.
private struct SkinPreview: View {
    let configuration: RelaySkinConfiguration
    let system: SystemDescriptor
    var body: some View {
        GeometryReader { proxy in
            let surface = RelayPlaySurfaceLayout(size: CGSize(width: 740, height: 360), showsTouchControls: true,
                                                 controls: system.inputLayout, screens: system.screens)
            ZStack {
                configuration.enabled ? configuration.background : .black
                RelayMark(mono: configuration.enabled ? configuration.foreground.opacity(0.25) : RelayColor.offWhite.opacity(0.25))
                    .frame(width: 120, height: 120)
                TouchControls(layout: surface.touchLayout, haptics: false, opacity: 1,
                              hasDedicatedBackground: true, isEnabled: false,
                              skin: configuration, skinSystem: system.id,
                              onChange: { _, _ in }, onTwoFingerTap: {})
                    .frame(width: surface.controlFrame.width, height: surface.controlFrame.height)
                    .position(x: surface.controlFrame.midX, y: surface.controlFrame.midY)
            }
            .frame(width: 740, height: 360)
            .scaleEffect(min(proxy.size.width / 740, proxy.size.height / 360))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
        .background(configuration.enabled ? configuration.background : .black)
    }
}
#endif
