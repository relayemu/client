// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelayDomain
import RelayDesignSystem
import RelayAchievements

struct RetroAchievementsSettingsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var username = ""
    @State private var password = ""
    @State private var submitting = false
    @State private var confirmDisconnect = false
    private var model: AchievementsModel { library.environment.achievements }

    var body: some View {
        PlayToolsPage {
            PlayToolsSection(footer: L("Optional. RetroAchievements does not affect gameplay, Relay Account or sync.")) {
                HStack(alignment: .top, spacing: RelaySpacing.m) {
                    PlayToolsIcon()
                    VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                        Text("Achievements for supported games", bundle: .module).font(.relaySubheader)
                        Text("Sign in with a free RetroAchievements account.", bundle: .module)
                            .font(.relayBody).foregroundStyle(RelayColor.textSecondary)
                    }
                }
            }

            PlayToolsSection(title: wrappableRetroAchievements(in: L("RetroAchievements account"))) {
                if model.isDisconnecting {
                    ProgressView().accessibilityLabel(Text("Disconnecting…", bundle: .module))
                } else if model.hasAccount {
                    accountStatus
                    if model.lastError == .invalidCredentials {
                        SecureField(L("Password"), text: $password)
                            .playToolsTextField()
                            .accessibilityIdentifier("ra.password")
                        Button { connect() } label: { Text("Sign in again", bundle: .module) }
                            .buttonStyle(.ember)
                            .disabled(submitting || password.isEmpty)
                            .accessibilityIdentifier("ra.renewSession")
                    } else if !model.isConnected {
                        Button { Task { await model.retry() } } label: { Text("Reconnect", bundle: .module) }
                            .buttonStyle(.quiet)
                            .accessibilityIdentifier("ra.reconnect")
                    }
                    Button(role: .destructive) {
                        if model.pendingUnlockCount > 0 || model.activeGameID != nil { confirmDisconnect = true }
                        else { Task { await model.disconnect() } }
                    } label: { Text("Disconnect", bundle: .module) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(RelayColor.critical)
                    .accessibilityIdentifier("ra.disconnect")
                } else if model.account == .credentialRemovalFailed {
                    Text("Relay couldn't remove the RetroAchievements sign-in from this device. Unlock it and finish disconnecting.", bundle: .module)
                    Button { Task { await model.disconnect() } } label: { Text("Finish disconnecting", bundle: .module) }
                        .accessibilityIdentifier("ra.finishDisconnect")
                } else {
                    VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                        Text("RetroAchievements username", bundle: .module)
                            .font(.relayMeta)
                            // Keep the protected service name readable without
                            // discretionary hyphenation at the largest sizes.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        TextField("", text: $username)
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .accessibilityLabel(Text("RetroAchievements username", bundle: .module))
                            .playToolsTextField()
                            .accessibilityIdentifier("ra.username")
                    }
                    SecureField(L("Password"), text: $password)
                        .playToolsTextField()
                        .accessibilityIdentifier("ra.password")
                        .onSubmit { connect() }
                    Button { connect() } label: {
                        Text(submitting ? L("Connecting…") : L("Sign In"))
                    }
                    .buttonStyle(.ember)
                    .disabled(submitting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("ra.connect")
                }
                if let error = model.lastError {
                    let errorText = achievementErrorText(error)
                    Text(wrappableRetroAchievements(in: errorText))
                        .foregroundStyle(RelayColor.textSecondary)
                        // This copy contains the long protected service name.
                        // Cap only this paragraph and offer one controlled
                        // break at the CamelCase boundary; this avoids adding
                        // a hyphen inside the protected product name. The
                        // surrounding screen and its actions still reach AX5.
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .accessibilityLabel(Text(verbatim: errorText))
                        .accessibilityIdentifier("ra.error")
                }
            }

            if model.pendingUnlockCount > 0 {
                PlayToolsSection {
                    Text("\(model.pendingUnlockCount) achievements waiting to send", bundle: .module)
                        .accessibilityIdentifier("ra.pending")
                    Text("Keep this account connected. Relay retries when RetroAchievements is available.", bundle: .module)
                }
            }

            if model.hardcoreAvailable {
                PlayToolsSection(title: L("How it works")) {
                    Toggle(isOn: Binding(get: { model.preferredMode == .hardcore }, set: { model.setPreferredMode($0 ? .hardcore : .casual) })) {
                        Text("Hardcore for new games", bundle: .module)
                    }
                    .accessibilityIdentifier("ra.hardcore")
                    Text("Hardcore restarts the game without loading Auto Resume. Loading Saves, Rewind, cheats and slow motion are unavailable. You can still create Saves and use Fast Forward.", bundle: .module)
                }
            }

            PlayToolsSection(title: L("Privacy")) {
                Text("When connected, Relay sends game identification, play activity and achievements to RetroAchievements. Your password is never saved. Your sign-in and achievements waiting to send stay on this device.", bundle: .module)
                Text("If a connected game loses service access, Relay keeps newly earned achievements on this device and retries. Starting a game offline does not enable achievements until it reconnects.", bundle: .module)
                Link(destination: URL(string: "https://retroachievements.org")!) {
                    Text("Visit RetroAchievements", bundle: .module)
                }
                Link(destination: URL(string: "https://retroachievements.org/terms")!) {
                    Text("RetroAchievements privacy and terms", bundle: .module)
                }
            }
            .font(.relayMeta)
            .foregroundStyle(RelayColor.textSecondary)
            #if os(tvOS)
            .focusable()
            #endif
        }
        .relaySettingsPage(L("RetroAchievements"))
        .accessibilityIdentifier("ra.settings")
        .onDisappear { password = "" }
        .confirmationDialog(Text("Disconnect RetroAchievements?", bundle: .module), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await model.disconnect() } } label: { Text("Disconnect", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text(disconnectMessage)
        }
    }

    @ViewBuilder private var accountStatus: some View {
        switch model.account {
        case .connected(let name):
            Label { Text("Connected as \(name)", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                .accessibilityIdentifier("ra.connected")
        case .reconnecting:
            HStack { ProgressView(); Text("Reconnecting…", bundle: .module) }
        default:
            Text("RetroAchievements is unavailable. You can keep playing.", bundle: .module)
        }
    }

    private func connect() {
        guard !submitting, !password.isEmpty else { return }
        let secret = password
        password = ""
        submitting = true
        Task {
            await model.connect(username: model.username ?? username, password: secret)
            submitting = false
        }
    }

    private var disconnectMessage: String {
        if model.activeGameID != nil, model.pendingUnlockCount > 0 {
            return L("Relay will stop checking achievements for the current game. Achievements waiting to send will be removed from this device. Achievements already on your RetroAchievements account stay there.")
        }
        if model.pendingUnlockCount > 0 {
            return L("Achievements waiting to send will be removed from this device. Achievements already on your RetroAchievements account stay there.")
        }
        return L("Relay will stop checking achievements for the current game. Gameplay continues.")
    }
}

struct GameAchievementsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let gameID: GameID
    var isPresentedModally = false
    @State private var onlyLocked = false
    @State private var confirmHardcoreRestart = false
    private var model: AchievementsModel { library.environment.achievements }

    var body: some View {
        PlayToolsPage {
            if model.activeGameID == gameID && model.hasAccount {
                PlayToolsSection {
                    DetailRow(label: L("Mode"), value: model.activeMode == .hardcore ? L("Hardcore") : L("Casual"))
                    if model.activeMode == .hardcore {
                        Button { library.play.continueInCasual() } label: { Text("Continue in Casual", bundle: .module) }
                            .accessibilityIdentifier("ra.continueCasual")
                    } else if model.hardcoreAvailable {
                        Button { confirmHardcoreRestart = true } label: { Text("Restart in Hardcore", bundle: .module) }
                            .accessibilityIdentifier("ra.restartHardcore")
                    }
                }
            }
            if let game = model.games[gameID], !game.achievements.isEmpty || !game.leaderboards.isEmpty {
                let visibleAchievements = game.achievements.filter { !onlyLocked || !$0.isUnlocked }.sorted { $0.id < $1.id }
                PlayToolsSection {
                    HStack(alignment: .top, spacing: RelaySpacing.m) {
                        PlayToolsIcon()
                        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                            Text(game.title).font(.relaySubheader)
                            Text("\(game.earnedPoints) of \(game.totalPoints) points", bundle: .module)
                                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary).monospacedDigit()
                        }
                    }
                    VStack(alignment: .leading, spacing: RelaySpacing.s) {
                        Text("\(game.unlockedCount) of \(game.achievements.count) unlocked", bundle: .module)
                            .accessibilityIdentifier("ra.summary")
                        ProgressView(value: Double(game.unlockedCount), total: Double(max(1, game.achievements.count)))
                            .tint(RelayColor.ember)
                            .accessibilityLabel(Text("Achievement progress", bundle: .module))

                    }
                    .padding(.vertical, RelaySpacing.s)
                }
                if model.gameStates[gameID] != .active || !model.isConnected {
                    PlayToolsSection { Text("Saved progress from \(game.updatedAt.formatted(date: .abbreviated, time: .shortened))", bundle: .module) }
                }
                playStatus
                PlayToolsSection {
                    Toggle(isOn: $onlyLocked) { Text("Show remaining achievements", bundle: .module) }
                        .accessibilityIdentifier("ra.remaining")
                }
                if !visibleAchievements.isEmpty {
                    PlayToolsSection(title: L("Achievements")) {
                        ForEach(visibleAchievements) { achievement in
                            AchievementRow(achievement: achievement)
                            if achievement.id != visibleAchievements.last?.id { Divider() }
                        }
                    }
                }
                if !game.leaderboards.isEmpty {
                    PlayToolsSection(title: L("Leaderboards")) {
                        if model.hardcoreAvailable && game.mode != .hardcore {
                            Text("Leaderboards are active in Hardcore mode.", bundle: .module)
                        }
                        ForEach(game.leaderboards) { board in
                            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                                Text(board.title).font(.relayCardTitle)
                                Text(board.description).foregroundStyle(RelayColor.textSecondary)
                                if board.isTracking { Text(board.value).monospacedDigit() }
                                if !board.isSupported { Text("Unavailable in this game session", bundle: .module) }
                            }
                            .accessibilityElement(children: .combine)
                            #if os(tvOS)
                            .focusable()
                            #endif
                        }
                    }
                }
                if let result = model.leaderboardResult, model.activeGameID == gameID {
                    PlayToolsSection(title: L("Latest leaderboard result")) {
                        Text("Score: \(result.score)", bundle: .module)
                        Text("Rank \(result.rank) of \(result.entries)", bundle: .module)
                    }
                }
                if !game.richPresence.isEmpty {
                    PlayToolsSection(title: L("RetroAchievements activity")) { Text(game.richPresence) }
                }
            } else if !model.hasAccount {
                PlayToolsSection {
                    PlayToolsIcon()
                    Text("Sign in with a free RetroAchievements account to earn achievements in this game.", bundle: .module)
                        .font(.relaySubheader)
                    NavigationLink(value: Route.retroAchievements) { Text("Sign In to RetroAchievements", bundle: .module) }
                        .buttonStyle(.ember)
                        .accessibilityIdentifier("ra.openConnect")
                }
            } else {
                PlayToolsSection {
                    PlayToolsIcon(highlighted: false)
                    emptyState
                }
                #if os(tvOS)
                .focusable()
                #endif
            }
        }
        .relaySettingsPage(L("Achievements"))
        .accessibilityIdentifier("ra.dashboard")
        .confirmationDialog(Text("Restart in Hardcore?", bundle: .module), isPresented: $confirmHardcoreRestart, titleVisibility: .visible) {
            Button { Task { dismiss(); await library.play.restartInHardcore() } } label: { Text("Restart in Hardcore", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Your in-game save is kept. The game restarts without loading Auto Resume or a Save. Cheats and Rewind are unavailable in Hardcore.", bundle: .module)
        }
        .toolbar {
            if isPresentedModally {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
        }
    }

    @ViewBuilder private var playStatus: some View {
        if model.pendingUnlockCount > 0 {
            PlayToolsSection { Text("Achievements are waiting to send. Keep playing; Relay will retry.", bundle: .module) }
        } else if model.deliveryUnavailable {
            PlayToolsSection { Text("RetroAchievements is unavailable. You can keep playing.", bundle: .module) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.gameStates[gameID] ?? .inactive {
        case .loading:
            HStack { ProgressView(); Text("Finding achievements…", bundle: .module) }
            Text("If the game is paused, resume it to finish loading achievements.", bundle: .module)
        case .unidentified:
            Text("No achievements found for this version of the game.", bundle: .module)
        case .unsupported:
            Text("Achievements are not available for this system.", bundle: .module)
        case .unavailable:
            Text("RetroAchievements is unavailable. You can keep playing.", bundle: .module)
            Button { Task { await model.retry() } } label: { Text("Try again", bundle: .module) }
        default:
            Text("Play this game to discover its achievements.", bundle: .module)
        }
    }
}

private struct AchievementRow: View {
    let achievement: Achievement
    var body: some View {
        HStack(alignment: .top, spacing: RelaySpacing.m) {
            PlayToolsIcon(systemName: achievement.isUnlocked ? "trophy.fill" : "lock", highlighted: achievement.isUnlocked)
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                Text(achievement.title).font(.relayCardTitle)
                Text(achievement.description).font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if achievement.isUnlocked {
                    Label { Text("Unlocked", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                        .font(.relayStatus).foregroundStyle(RelayColor.positive)
                }
                else if !achievement.isSupported { Text("Unavailable in this game session", bundle: .module) }
                else if achievement.isChallengeActive { Text("Challenge active", bundle: .module).foregroundStyle(RelayColor.ember) }
                if !achievement.isUnlocked && !achievement.progress.isEmpty {
                    ProgressView(value: achievement.percent, total: 100)
                        .tint(RelayColor.ember)
                        .accessibilityLabel(Text("Achievement progress", bundle: .module))
                        .accessibilityValue(achievement.progress)
                    Text(achievement.progress).font(.relayMeta)
                }
                Text("\(achievement.points) points", bundle: .module).font(.relayMeta).monospacedDigit()
                    .foregroundStyle(RelayColor.textSecondary)
            }
        }
        .padding(.vertical, RelaySpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ra.achievement.\(achievement.id)")
        #if os(tvOS)
        .focusable()
        #endif
    }
}

struct AchievementUnlockToast: View {
    let achievement: Achievement
    var body: some View {
        HStack(spacing: RelaySpacing.m) {
            RelaySymbol.achievements.image.font(.relayCardTitle).foregroundStyle(RelayColor.ember)
            VStack(alignment: .leading, spacing: RelaySpacing.xs) {
                Text("Achievement unlocked", bundle: .module).font(.relayMeta)
                Text(achievement.title).font(.relayCardTitle)
                HStack {
                    Text("\(achievement.points) points", bundle: .module)
                    Text(achievement.isHardcore ? L("Hardcore") : L("Casual"))
                }.font(.relayMeta)
            }
        }
        .padding(RelaySpacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RelayRadius.l))
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ra.unlockNotification")
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "Achievement unlocked: \(achievement.title)", bundle: .module)).post()
        }
    }
}

private func achievementErrorText(_ error: AchievementServiceError) -> String {
    switch error {
    case .invalidCredentials: return L("RetroAchievements didn't accept your sign-in. Check your details and try again.")
    case .storage: return L("Relay couldn't save your RetroAchievements sign-in or achievements waiting to send. Unlock this device and try again.")
    default: return L("RetroAchievements is unavailable. You can keep playing.")
    }
}

private func wrappableRetroAchievements(in text: String) -> String {
    text.replacingOccurrences(of: "RetroAchievements", with: "Retro\u{200B}Achievements")
}

/// Official runtime indicators, separate from user input and pause controls.
struct AchievementActivityHUD: View {
    let model: AchievementsModel
    var body: some View {
        VStack(alignment: .leading, spacing: RelaySpacing.xs) {
            if model.activeMode == .hardcore && model.activeGameID != nil {
                Label(L("Hardcore"), systemImage: "shield.checkered")
                    .accessibilityIdentifier("ra.hardcoreActive")
            }
            ForEach(model.challenges) { achievement in
                Label(achievement.title, systemImage: "scope")
            }
            if let progress = model.measuredProgress {
                Text("\(progress.title) · \(progress.progress)", bundle: .module)
                    .accessibilityIdentifier("ra.measuredProgress")
            }
            if let id = model.activeGameID, let game = model.games[id] {
                ForEach(game.leaderboards.filter(\.isTracking)) { board in
                    Text("\(board.title) · \(board.value)", bundle: .module).monospacedDigit()
                }
            }
            if model.resetRequired {
                Text("Restart the game to use achievements safely.", bundle: .module)
            }
        }
        .font(.relayMeta)
        .padding(RelaySpacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RelayRadius.s))
        .fixedSize(horizontal: false, vertical: true)
    }
}
