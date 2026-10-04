// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
import UniformTypeIdentifiers
import RelayDesignSystem
import RelayDomain

#if os(iOS) || os(macOS)
/// One native menu in Pause; preparing an export leads directly to the system
/// share sheet. Recording has its own deliberate action and a visible stop.
struct GameplayShareMenu: View {
    @Environment(RelayActions.self) private var actions
    let play: PlayModel
    let present: (GameplayShareFile) -> Void
    @State private var preparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            Menu {
                Button { export(card: false) } label: {
                    Label { Text("Screenshot", bundle: .module) } icon: { Image(systemName: "camera") }
                }
                .accessibilityIdentifier("relay.share.screenshot")
                Button { export(card: true) } label: {
                    Label { Text("Relay Card", bundle: .module) } icon: { Image(systemName: "rectangle.portrait") }
                }
                .accessibilityIdentifier("relay.share.card")
                Divider()
                if let clip = play.sharing.clip {
                    Button {
                        guard actions.beginPresentation(.playTool) else { return }
                        present(clip)
                    } label: {
                        Label { Text("Share Clip", bundle: .module) } icon: { Image(systemName: "film") }
                    }
                    .accessibilityIdentifier("relay.share.clip")
                }
                Button {
                    guard actions.beginPresentation(.playTool) else { return }
                    Task {
                        await play.startSharingClip()
                        actions.presentationDidDismiss(.playTool)
                    }
                } label: {
                    Label {
                        Text(play.allows(.extendedRecording) ? "Record Gameplay" : "Record 15-Second Clip", bundle: .module)
                    } icon: { Image(systemName: "record.circle") }
                }
                .accessibilityIdentifier("relay.share.record")
                .disabled(!play.sharing.canRecord || play.speed != .normal)
            } label: {
                Label {
                    Text(play.sharing.clip == nil ? "Share" : "Share · Clip Ready", bundle: .module)
                } icon: { Image(systemName: "square.and.arrow.up") }
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            // Keep native Menu measurement: the custom quiet label stalls
            // iOS 27 while the adaptive Pause card measures its candidates.
            .font(.relayCardTitle)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(RelayColor.textPrimary)
            #else
            .buttonStyle(.quiet)
            .help(Text("Gameplay Clips include game audio at normal speed. Microphone audio is never included.", bundle: .module))
            #endif
            .accessibilityIdentifier("relay.share.menu")
            .disabled(preparing || play.sharing.busy)
            if preparing || play.sharing.state == .starting || play.sharing.state == .finishing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(play.sharing.state == .starting ? "Starting recording…" : "Preparing to share…", bundle: .module)
                }.font(.relayMeta)
            }
            if let error = play.sharing.error {
                Text(message(error)).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                    .accessibilityIdentifier("relay.share.error")
            }
            #if os(iOS)
            Text("Gameplay Clips include game audio at normal speed. Microphone audio is never included.", bundle: .module)
                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private func export(card: Bool) {
        guard !preparing, actions.beginPresentation(.playTool) else { return }
        play.sharing.dismissError()
        guard let game = play.game,
              let system = SystemCatalog.descriptor(for: game.systemID),
              let image = GameplayShareComposition(screens: play.screens, arrangement: play.screenArrangement)
                .image(from: play.session.screenFrameSources) else {
            play.sharing.report(GameplayShareError.frameUnavailable)
            actions.presentationDidDismiss(.playTool)
            return
        }
        let snapshot = GameplayShareSnapshot(image: image, title: game.title,
                                            systemName: system.name, systemID: game.systemID)
        guard let output = card ? RelayShareCard.image(snapshot) : image else {
            play.sharing.report(GameplayShareError.encoding)
            actions.presentationDidDismiss(.playTool)
            return
        }
        preparing = true
        Task {
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try GameplayShareFile.png(output, kind: card ? .card : .screenshot)
                }.value
                preparing = false
                present(GameplayShareFile(url: file.url, kind: file.kind, cardSnapshot: card ? snapshot : nil))
            } catch {
                preparing = false
                play.sharing.report(error)
                actions.presentationDidDismiss(.playTool)
            }
        }
    }

    private func message(_ error: GameplayShareError) -> String {
        switch error {
        case .unavailable: return L("Recording is unavailable right now. You can still share an image.")
        case .noAudio: return L("No game audio was captured. Try recording another Gameplay Clip.")
        case .tooShort: return L("That clip was too short. Record a little more gameplay.")
        case .storageLow: return L("Recording stopped because storage is low. Share any ready recording before starting another.")
        case .storageUnavailable: return L("Relay couldn't check the available storage. Recording has stopped.")
        case .frameUnavailable: return L("The game image isn't ready yet. Resume and try again.")
        case .encoding, .capture: return L("Relay couldn't prepare this share. Try again.")
        }
    }
}

#if os(iOS)
import UIKit
struct GameplayShareSheet: View {
    let file: GameplayShareFile
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var destination: Destination?
    @State private var saved = false
    @State private var draft: GameplayCardDraft

    init(file: GameplayShareFile) {
        self.file = file
        _draft = State(initialValue: GameplayCardDraft(file: file))
    }

    private enum Destination: String, Identifiable {
        case save, share
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: RelaySpacing.l) {
            if draft.snapshot != nil {
                ScrollView { GameplayCardEditor(draft: draft) }
                    .scrollDismissesKeyboard(.interactively)
            } else if file.kind == .clip {
                GameplayClipPreview(player: player).frame(maxHeight: 380)
            } else if let image = UIImage(contentsOfFile: file.url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 380)
            }
            HStack(spacing: RelaySpacing.m) {
                Button { player?.pause(); dismissKeyboard(); destination = .save } label: {
                    Label { Text("Save", bundle: .module) } icon: { Image(systemName: "square.and.arrow.down") }
                }
                .accessibilityIdentifier("relay.share.save")
                Button { player?.pause(); dismissKeyboard(); destination = .share } label: {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                }
                .accessibilityIdentifier("relay.share.native")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!draft.canExport)
            if saved { Text("Saved", bundle: .module).font(.relayMeta) }
            Button { dismiss() } label: { Text("Done", bundle: .module) }
        }
        .padding(RelaySpacing.l)
        .onAppear { if file.kind == .clip { player = AVPlayer(url: file.url) } }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: draft.caption) { saved = false }
        .sheet(item: $destination) { action in
            switch action {
            case .save: GameplaySavePicker(file: draft.file) { saved = true }
            case .share: GameplayNativeSharePicker(file: draft.file)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

private struct GameplayNativeSharePicker: UIViewControllerRepresentable {
    let file: GameplayShareFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct GameplaySavePicker: UIViewControllerRepresentable {
    let file: GameplayShareFile
    let didSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(didSave: didSave) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let didSave: () -> Void
        init(didSave: @escaping () -> Void) { self.didSave = didSave }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { didSave() }
        }
    }
}

private struct GameplayClipPreview: UIViewControllerRepresentable {
    let player: AVPlayer?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
#elseif os(macOS)
struct GameplayShareSheet: View {
    let file: GameplayShareFile
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var saveFailed = false
    @State private var saved = false
    @State private var draft: GameplayCardDraft

    init(file: GameplayShareFile) {
        self.file = file
        _draft = State(initialValue: GameplayCardDraft(file: file))
    }

    var body: some View {
        VStack(spacing: RelaySpacing.l) {
            if draft.snapshot != nil {
                GameplayCardEditor(draft: draft)
            } else if file.kind == .clip {
                GameplayClipPreview(player: player).frame(height: 300)
            } else if let image = NSImage(contentsOf: file.url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 380)
            }
            HStack(spacing: RelaySpacing.m) {
                Button(action: save) {
                    Label { Text("Save As…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.down") }
                }
                .accessibilityIdentifier("relay.share.save")
                ShareLink(item: draft.file.url) {
                    Label { Text("Share", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
                }
                .accessibilityIdentifier("relay.share.native")
            }
            .disabled(saving || !draft.canExport)
            if saving { ProgressView().controlSize(.small) }
            if saved { Text("Saved", bundle: .module).font(.relayMeta) }
            Button { dismiss() } label: { Text("Done", bundle: .module) }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
        }
        .padding(RelaySpacing.l)
        .frame(minWidth: 440, maxWidth: 640)
        .onAppear { if file.kind == .clip { player = AVPlayer(url: file.url) } }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: draft.caption) { saved = false }
        .interactiveDismissDisabled(saving)
        .alert(Text("Couldn't save the file", bundle: .module), isPresented: $saveFailed) {
            Button { } label: { Text("OK", bundle: .module) }
        } message: {
            Text("Your export is still available. Try saving it in another location.", bundle: .module)
        }
    }

    private func save() {
        guard !saving, draft.canExport else { return }
        saved = false
        saving = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [file.kind == .clip ? .mpeg4Movie : .png]
        panel.nameFieldStringValue = file.url.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let source = draft.file.url
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { saving = false; return }
            Task {
                // The system save panel grants access to this selected URL.
                defer { destination.stopAccessingSecurityScopedResource(); saving = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try GameplayShareExport.copy(from: source, to: destination)
                    }.value
                    saved = true
                } catch { saveFailed = true }
            }
        }
    }
}

/// Use AppKit's player directly. The SwiftUI VideoPlayer adapter aborts while
/// initializing its generic view metadata on the qualified macOS 26.6.2 host.
private struct GameplayClipPreview: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
#endif
#endif
