// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) || os(macOS)
import SwiftUI
import RelayDesignSystem

@MainActor @Observable
final class GameplayCardDraft {
    static let captionLimit = 280
    let snapshot: GameplayShareSnapshot?
    private var captionValue: String
    var caption: String {
        get { captionValue }
        set { captionValue = String(newValue.prefix(Self.captionLimit)) }
    }
    private(set) var file: GameplayShareFile
    private var preparedCaption: String
    private(set) var failed = false
    var canExport: Bool { snapshot == nil || (preparedCaption == caption && !failed) }

    init(file: GameplayShareFile) {
        self.file = file
        snapshot = file.cardSnapshot
        let initialCaption = ""
        captionValue = initialCaption
        preparedCaption = initialCaption
    }

    func prepare() async {
        guard let snapshot, !canExport else { return }
        let requested = caption
        failed = false
        guard let image = RelayShareCard.image(snapshot, caption: requested) else { failed = true; return }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GameplayShareFile.png(image, kind: .card)
            }.value
            guard !Task.isCancelled, caption == requested else { return }
            file = result
            preparedCaption = requested
        } catch { if !Task.isCancelled { failed = true } }
    }
}

struct GameplayCardEditor: View {
    @Bindable var draft: GameplayCardDraft
    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.s) {
            if let snapshot = draft.snapshot {
                GeometryReader { geometry in
                    RelayShareCard(snapshot: snapshot, caption: draft.caption)
                        .scaleEffect(min(geometry.size.width / 1200, geometry.size.height / 1320))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(minHeight: 180, idealHeight: 320, maxHeight: 380)
                .allowsHitTesting(false)
                .accessibilityLabel(Text("Relay Card preview", bundle: .module))
            }
            HStack {
                Text("Caption", bundle: .module).font(.relayCardTitle)
                Spacer()
                Text(verbatim: "\(draft.caption.count)/\(GameplayCardDraft.captionLimit)")
                    .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.caption)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityIdentifier("relay.share.caption")
                    .accessibilityLabel(Text("Caption", bundle: .module))
                    .focused($captionFocused)
                if draft.caption.isEmpty {
                    Text("Write your own caption", bundle: .module)
                        .foregroundStyle(RelayColor.textSecondary)
                        .padding(9)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(.background, in: RoundedRectangle(cornerRadius: RelayRadius.s))
            .overlay(RoundedRectangle(cornerRadius: RelayRadius.s).strokeBorder(RelayColor.textSecondary.opacity(0.3)))
            if draft.failed {
                Text("Relay couldn't prepare this card. Try again.", bundle: .module).font(.relayMeta)
                Button { Task { await draft.prepare() } } label: { Text("Try Again", bundle: .module) }
            }
        }
        #if os(macOS)
        .onAppear { captionFocused = true }
        #endif
        .task(id: draft.caption) {
            guard !draft.canExport else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await draft.prepare()
        }
    }
}
#endif
