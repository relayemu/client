// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AuthenticationServices
import RelaySync
import RelayDesignSystem

struct SyncSettingsSections: View {
    @Environment(LibraryModel.self) private var model
    private var sync: SyncModel { model.sync }

    var body: some View {
        Section {
            Picker(selection: Binding(get: { sync.selectedProvider }, set: { choice in
                Task { await sync.selectProvider(choice) }
            })) {
                ForEach(sync.availableProviders, id: \.self) { provider in
                    Text(providerName(provider)).tag(provider)
                }
            } label: { Text("Sync provider", bundle: .module) }
            .relayTVSettingsControl(L("Sync provider"))
            .disabled(sync.isSwitchingProvider)
            .accessibilityIdentifier("settings.syncProvider")
            if sync.isSwitchingProvider { Text("Connecting…", bundle: .module) }
            if sync.selectedProvider == .off {
                Text("Sync is off. Your games and saves stay on this device.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            #if !os(tvOS)
            SettingsHeader(L("Sync"))
            #endif
        } footer: {
            Text("Choose one service for automatic sync. Switching keeps your local library and the previous service's data. Different save versions stay available for you to choose.", bundle: .module)
                .foregroundStyle(RelayColor.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }

        if sync.selectedProvider == .iCloud { CloudSettingsSection() }
        if model.environment.relayAccount != nil {
            Section {
                NavigationLink(value: Route.relayAccount) {
                    Label { Text("Relay account", bundle: .module) } icon: { RelaySymbol.settings.image }
                }
                .accessibilityIdentifier("settings.relayAccount.open")
            }
        }
    }

    private func providerName(_ provider: SyncProviderSelection) -> String {
        switch provider {
        case .off: L("Off")
        case .iCloud: L("iCloud")
        case .relaySync: L("Relay Sync")
        }
    }
}

/// Live adapter: only this layer can call account or synchronization operations.
struct RelayAccountSettingsSection: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openURL) private var openURL
    let account: RelayAccountModel

    var body: some View {
        let sync = model.sync
        RelayAccountPresentationSection(presentation: .init(account: account, sync: sync), actions: .init(
            signIn: { account.signIn(anchor: $0) },
            refresh: { Task { await account.refresh() } },
            signOut: { Task { await account.signOut() } },
            openPortal: { openURL(account.environment.portalOrigin) },
            setGameFilesEnabled: { value in Task { await sync.setGameFilesEnabled(value) } },
            retrySync: { Task { await account.refresh(); await sync.requestSync() } },
            acceptAccountChange: { Task { await sync.acceptAccountChange() } },
            keepSyncOff: { Task { await sync.selectProvider(.off) } }
        ))
        Section {
            NavigationLink(value: Route.relayMembership) {
                Text("Explore Sync memberships", bundle: .module)
            }
            .accessibilityIdentifier("settings.relayAccount.membership")
        }
    }
}

/// Value-only input shared by product rows and clearly marked Debug snapshots.
/// It cannot provide credentials, change entitlements, or attach a transport.
struct RelayAccountPresentation {
    let isConnected: Bool
    let isBusy: Bool
    let canSignIn: Bool
    let hasLoadedAccount: Bool
    let planName: String?
    let vaultStatus: String
    let usedBytes: Int64
    let quotaBytes: Int64
    let canUpload: Bool
    let recoveryMessage: String?
    let purgeAt: Date?
    let lastSyncAt: Date?
    let errorMessage: String?
    let portalOrigin: URL
    let isRelaySelected: Bool
    let isSwitchingProvider: Bool
    let syncStatus: SyncStatus
}

extension RelayAccountPresentation {
    @MainActor init(account: RelayAccountModel, sync: SyncModel) {
        self.init(isConnected: account.isConnected, isBusy: account.isBusy,
                  canSignIn: account.session != nil, hasLoadedAccount: account.hasLoadedAccount,
                  planName: account.planName, vaultStatus: account.vaultStatus,
                  usedBytes: account.usedBytes, quotaBytes: account.quotaBytes,
                  canUpload: account.canUpload, recoveryMessage: account.recoveryMessage,
                  purgeAt: account.purgeAt, lastSyncAt: account.lastSyncAt,
                  errorMessage: account.errorMessage, portalOrigin: account.environment.portalOrigin,
                  isRelaySelected: sync.selectedProvider == .relaySync,
                  isSwitchingProvider: sync.isSwitchingProvider, syncStatus: sync.status)
    }
}

struct RelayAccountPresentationActions {
    let signIn: @MainActor (ASPresentationAnchor) -> Void
    let refresh: () -> Void
    let signOut: () -> Void
    let openPortal: () -> Void
    let setGameFilesEnabled: (Bool) -> Void
    let retrySync: () -> Void
    let acceptAccountChange: () -> Void
    let keepSyncOff: () -> Void
}

/// The same native rows render live observations and immutable UI fixtures.
struct RelayAccountPresentationSection: View {
    let presentation: RelayAccountPresentation
    let actions: RelayAccountPresentationActions
    @State private var confirmingSignOut = false

    var body: some View {
        Section {
            StatusLine(presentation.isConnected ? L("Connected") : L("Not connected"),
                       tone: presentation.isConnected ? .neutral : .caution,
                       symbol: presentation.isConnected ? .upToDate : .cloudOff)
                .accessibilityLabel(Text("Relay account", bundle: .module))
                .accessibilityValue(Text(presentation.isConnected ? L("Connected") : L("Not connected")))
                .accessibilityIdentifier("settings.relayAccount.connection")
                .fixedSize(horizontal: false, vertical: true)
            if presentation.isBusy { Text("Connecting…", bundle: .module).foregroundStyle(RelayColor.textSecondary) }
            if presentation.isConnected {
                if let plan = presentation.planName {
                    RelayAccountDetailRow(label: L("Plan"), value: plan)
                        .accessibilityIdentifier("settings.relayAccount.plan")
                }
                if !presentation.canUpload {
                    RelayAccountDetailRow(label: L("Online storage"), value: presentation.vaultStatus)
                        .accessibilityIdentifier("settings.relayAccount.vault")
                }
                if presentation.hasLoadedAccount {
                    RelayAccountDetailRow(label: L("Used"), value: Formatting.bytes(presentation.usedBytes))
                        .accessibilityIdentifier("settings.relayAccount.usage")
                    RelayAccountDetailRow(label: L("Storage limit"), value: Formatting.bytes(presentation.quotaBytes))
                        .accessibilityIdentifier("settings.relayAccount.quota")
                    if presentation.quotaBytes > 0 {
                        ProgressView(value: Double(min(presentation.usedBytes, presentation.quotaBytes)), total: Double(presentation.quotaBytes))
                            .accessibilityIdentifier("settings.relayAccount.storageProgress")
                            .accessibilityLabel(Text("Storage usage", bundle: .module))
                            .accessibilityValue(Text("\(Formatting.bytes(presentation.usedBytes)) of \(Formatting.bytes(presentation.quotaBytes))", bundle: .module))
                    }
                }
                if let message = presentation.recoveryMessage {
                    Text(message).foregroundStyle(RelayColor.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.relayAccount.recovery")
                }
                if let date = presentation.purgeAt {
                    LabeledContent { Text(date, style: .date) } label: { Text("Recovery ends", bundle: .module) }
                        .accessibilityIdentifier("settings.relayAccount.recoveryEnds")
                }
                if presentation.isRelaySelected {
                    hostedSyncRows
                }
                Button(action: actions.refresh) { Text("Refresh account status", bundle: .module) }
                    .accessibilityIdentifier("settings.relayAccount.refresh")
                    .disabled(presentation.isBusy)
                Button { confirmingSignOut = true } label: { Text("Sign out", bundle: .module) }
                    .disabled(presentation.isBusy)
                    .accessibilityIdentifier("settings.relayAccount.signOut")
            } else {
                NativeAppleSignInButton(isEnabled: !presentation.isBusy && presentation.canSignIn, action: actions.signIn)
            }
            if let error = presentation.errorMessage {
                StatusLine(error, tone: .caution, symbol: .notSynced)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.relayAccount.error")
            }
            #if os(tvOS)
            // tvOS has no general-purpose web browser. Show the canonical portal
            // for use on a phone/computer instead of presenting an inert link.
            Text("Open your account portal on your iPhone or computer:", bundle: .module)
            Text(presentation.portalOrigin.absoluteString)
                .font(.relayMeta)
                .accessibilityLabel(Text("Account portal", bundle: .module))
                .accessibilityValue(presentation.portalOrigin.absoluteString)
            #else
            Button(action: actions.openPortal) { Text("Open account portal", bundle: .module) }
                .accessibilityIdentifier("settings.relayAccount.portal")
            #endif
        } header: {
            SettingsHeader(L("Relay Sync · Preproduction"))
        } footer: {
            Text("A preproduction service for your Relay account. Membership options come from the App Store. Game-file uploads need a separate opt-in for this service. Relay Sync does not provide end-to-end encryption.", bundle: .module)
                .foregroundStyle(RelayColor.textSecondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(Text("Sign out of Relay Sync?", bundle: .module), isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button(action: actions.signOut) { Text("Sign out", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("This stops Relay Sync on this device. Your local games and saves and your online library are kept.", bundle: .module)
        }
    }

    @ViewBuilder private var hostedSyncRows: some View {
        StatusLine(syncStatusText, tone: presentation.syncStatus.problem == nil ? .neutral : .caution,
                   symbol: presentation.syncStatus.problem == nil ? .upToDate : .notSynced)
            .accessibilityLabel(Text("Relay Sync status", bundle: .module))
            .accessibilityValue(Text(syncStatusText))
            .accessibilityIdentifier("settings.relayAccount.syncStatus")
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        let last = [presentation.syncStatus.lastPullAt, presentation.syncStatus.lastPushAt, presentation.lastSyncAt].compactMap { $0 }.max()
        if let last {
            LabeledContent { Text(last, style: .relative) } label: { Text("Last successful sync", bundle: .module) }
                .accessibilityIdentifier("settings.relayAccount.lastSync")
        } else {
            RelayAccountDetailRow(label: L("Last successful sync"), value: L("Not yet"))
                .accessibilityIdentifier("settings.relayAccount.lastSync")
        }
        Toggle(isOn: Binding(get: { presentation.syncStatus.gameFilesEnabled }, set: { value in
            actions.setGameFilesEnabled(value)
        })) { Text("Upload game files to Relay Sync", bundle: .module) }
            .disabled(!presentation.canUpload || presentation.isSwitchingProvider)
            .accessibilityIdentifier("settings.relayGameFileSync")
        if presentation.syncStatus.problem != nil {
            Button(action: actions.retrySync) { Text("Retry sync", bundle: .module) }
                .disabled(presentation.isBusy || presentation.syncStatus.isSyncing || presentation.isSwitchingProvider || presentation.syncStatus.accountChangePending)
                .accessibilityIdentifier("settings.relayAccount.retrySync")
        }
        if presentation.syncStatus.pendingCount > 0 {
            RelayAccountDetailRow(label: L("Waiting to sync"), value: String(localized: "\(presentation.syncStatus.pendingCount) items", bundle: .module))
        }
        if !presentation.syncStatus.conflictGameIDs.isEmpty {
            RelayAccountDetailRow(label: L("Two versions"), value: String(localized: "\(presentation.syncStatus.conflictGameIDs.count) games", bundle: .module))
        }
        if presentation.syncStatus.accountChangePending {
            Text("A different Relay account is connected. Choose whether to sync this library with it.", bundle: .module)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: actions.acceptAccountChange) { Text("Sync with this account", bundle: .module) }
            Button(action: actions.keepSyncOff) { Text("Keep sync off", bundle: .module) }
        }
    }

    private var syncStatusText: String {
        if !presentation.syncStatus.conflictGameIDs.isEmpty { return L("Two versions") }
        if presentation.syncStatus.accountChangePending { return L("Account confirmation needed") }
        if presentation.syncStatus.problem == .quotaFull { return L("Your Relay Sync storage is full. Download or manage your files in the account portal.") }
        if let problem = presentation.syncStatus.problem, let message = RelayHostedSyncProblemCopy.message(for: problem) { return message }
        if presentation.syncStatus.problem != nil { return L("Sync is paused. Your local progress is safe. Check your account status and connection.") }
        if !presentation.syncStatus.isActive || presentation.syncStatus.account != .available { return L("Sync is paused. Your local progress is safe. Check your account status and connection.") }
        if presentation.syncStatus.isSyncing { return L("Syncing…") }
        if presentation.syncStatus.pendingCount > 0 { return L("Not synced yet") }
        if !presentation.canUpload { return L("Uploads paused") }
        return L("Up to date")
    }
}

/// Only recognized transport reasons become product copy. Unknown details never
/// reach the screen; the surrounding status view supplies a generic safe error.
enum RelayHostedSyncProblemCopy {
    static func message(for problem: SyncProblem) -> String? {
        switch problem {
        case .failed("hosted history requires original installation"):
            return L("Some older progress belongs to another device and stays local here. Open Relay on the original device to sync it.")
        case .failed("hosted state retention deletion unsupported"):
            return L("Relay Sync cannot automatically remove older save history yet. Your local saves are safe. You can keep playing while this sync action is paused.")
        default:
            return nil
        }
    }
}

/// Account metadata gives each value the available width at accessibility sizes.
/// A side-by-side pair otherwise splits long lifecycle labels into narrow columns.
private struct RelayAccountDetailRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        let layout = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: RelaySpacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: RelaySpacing.s))
        layout {
            Text(label).foregroundStyle(RelayColor.textSecondary)
            if !dynamicType.isAccessibilitySize { Spacer(minLength: RelaySpacing.s) }
            Text(value)
                .foregroundStyle(RelayColor.textPrimary)
                .monospacedDigit()
                .multilineTextAlignment(dynamicType.isAccessibilitySize ? .leading : .trailing)
        }
        .font(.relayMeta)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
