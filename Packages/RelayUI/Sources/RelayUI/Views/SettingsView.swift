// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SettingsView.swift
//  Advanced ▸ Diagnostics, About ▸ Acknowledgements. Nothing that Relay cannot do yet is shown.

import SwiftUI
import RelayDomain
import RelayLibrary
import RelayDesignSystem
import RelayEmulation
import RelaySync
import RelayEntitlements

public struct SettingsView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions

    public init() {}

    public var body: some View {
        #if os(tvOS)
        TVSettingsRootView()
        #else
        List {
            // Settings is a native form and stays one: the brand appears once, at the
            // top, so the screen belongs to Relay without any control pretending to.
            Section {
                SettingsLockup(version: Self.versionString)
            }
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif

            Section {
                NavigationLink(value: Route.relayPro(nil)) {
                    HStack {
                        Label {
                            Text("Relay Pro", bundle: .module)
                        } icon: {
                            RelaySymbol.pro.image
                        }
                        Spacer()
                        if model.play.allows(.macGameplay) {
                            Text("Active", bundle: .module)
                                .foregroundStyle(RelayColor.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("settings.relayPro")
            } footer: {
                Text("Mac gameplay and advanced play tools, with Once or Monthly.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                    #if os(macOS)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }

            Section {
                DetailRow(label: L("Games"), value: model.games.count.formatted())
                DetailRow(label: L("Library location"), value: locationDescription)
                if !model.problems.isEmpty {
                    Button { model.dismissAllProblems() } label: { Text("Clear import issues", bundle: .module) }
                }
            } header: {
                SettingsHeader(L("Library"))
            } footer: {
                Text("Games are copied into Relay's own storage on \(Formatting.thisDevice(model.deviceKind)).", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                    #if os(macOS)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }

            CoverSettingsSection()

            Section {
                NavigationLink { PlayStationFirmwareView() } label: { Text("PlayStation Firmware", bundle: .module) }
            }

            PlaySettingsSection()

            SyncSettingsSections()

            Section {
                NavigationLink(value: Route.retroAchievements) {
                    Label { Text("RetroAchievements", bundle: .module) } icon: { RelaySymbol.achievements.image }
                }
                .accessibilityIdentifier("settings.retroAchievements")
            } footer: {
                Text("Free, optional achievements for supported games.", bundle: .module)
            }

            Section {
                Button { actions.replayOnboarding() } label: { Text("Getting Started", bundle: .module) }
                    .accessibilityIdentifier("settings.gettingStarted")
                NavigationLink(value: Route.formats) {
                    Text("Which formats work?", bundle: .module)
                }
            } header: {
                SettingsHeader(L("Help"))
            }

            Section {
                NavigationLink(value: Route.diagnostics) { Text("Diagnostics", bundle: .module) }
            } header: {
                SettingsHeader(L("Advanced"))
            }

            Section {
                NavigationLink(value: Route.about) { Text("About Relay", bundle: .module) }
            } header: {
                SettingsHeader(L("About"))
            } footer: {
                Text("Relay includes no games. Bring the files you own.", bundle: .module)
                    .foregroundStyle(RelayColor.textSecondary)
                    #if os(macOS)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }
        }
        .accessibilityIdentifier("settings.screen")
        .navigationTitle(Text("Settings", bundle: .module))
        #endif
    }

    private var locationDescription: String {
        return String(localized: "On \(Formatting.thisDevice(model.deviceKind))", bundle: .module)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

/// Settings ▸ iCloud (UX §14, CONTINUITY_UX §7): status, Sync saves, opt-in game files,
/// approximate Relay usage, waiting items, account decision. No "Sync now".
struct CloudSettingsSection: View {
    @Environment(LibraryModel.self) private var model
    @Environment(RelayActions.self) private var actions

    private var sync: SyncModel { model.sync }

    var body: some View {
        Section {
            StatusLine(statusText, tone: statusTone, symbol: statusSymbol)
            if sync.isAvailable {
                if sync.status.gameFilesAllowed {
                    Toggle(isOn: Binding(get: { sync.status.gameFilesEnabled }, set: { on in
                        Task { await sync.setGameFilesEnabled(on) }
                    })) { Text("Sync game files", bundle: .module) }
                        .disabled(!sync.status.isEnabled)
                        .accessibilityIdentifier("settings.gameFileSync")
                }
                if sync.status.approximateCloudBytes > 0 {
                    DetailRow(label: L("Relay in iCloud"), value: L("about \(Formatting.bytes(sync.status.approximateCloudBytes))"))
                }
                if sync.status.pendingCount > 0 {
                    DetailRow(label: L("Waiting to sync"), value: String(localized: "\(sync.status.pendingCount) items", bundle: .module))
                }
                if !sync.status.conflictGameIDs.isEmpty {
                    DetailRow(label: L("Two versions"), value: String(localized: "\(sync.status.conflictGameIDs.count) games", bundle: .module))
                }
                if sync.status.accountChangePending {
                    Button { Task { await sync.acceptAccountChange() } } label: { Text("Sync with this account", bundle: .module) }
                    Button(role: .destructive) { Task { await sync.declineAccountChange() } } label: { Text("Keep iCloud off", bundle: .module) }
                }
                if sync.status.problem == .quotaFull {
                    Button { actions.manageStorage() } label: { Text("Manage iCloud Storage", bundle: .module) }
                }
            } else if sync.status.account == .noAccount || sync.status.account == .restricted {
                Button { actions.openSystemSettings() } label: { Text("Open Settings", bundle: .module) }
            }
        } header: {
            SettingsHeader(L("iCloud"))
        } footer: {
            Text(footer)
                .foregroundStyle(RelayColor.textSecondary)
                #if os(macOS)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                #endif
        }
    }

    private var statusText: String {
        guard sync.isAvailable else { return L("iCloud is off") }
        let status = sync.status
        if status.accountChangePending { return L("A different iCloud account is signed in") }
        if !status.isEnabled { return Formatting.localOnly(model.deviceKind) }
        switch status.account {
        case .noAccount, .restricted: return L("iCloud is off")
        case .temporarilyUnavailable, .unknown: return L("iCloud is unavailable right now")
        case .available: break
        }
        if !status.conflictGameIDs.isEmpty { return L("Two versions") }
        if status.problem == .quotaFull { return L("iCloud storage is full") }
        if status.isSyncing { return L("Syncing…") }
        if status.pendingCount > 0 { return L("Not synced yet") }
        return L("Up to date")
    }

    private var statusTone: StatusTone {
        guard sync.isAvailable else { return .caution }
        let status = sync.status
        if !status.conflictGameIDs.isEmpty || status.problem == .quotaFull || status.accountChangePending { return .critical }
        if status.account != .available && status.isEnabled { return .caution }
        return .neutral
    }

    private var statusSymbol: RelaySymbol {
        guard sync.isAvailable else { return .cloudOff }
        let status = sync.status
        if !status.conflictGameIDs.isEmpty { return .conflict }
        if status.problem == .quotaFull { return .storageFull }
        if status.accountChangePending { return .conflict }
        if !status.isEnabled { return Formatting.deviceSymbol(model.deviceKind) }
        if status.account != .available { return .cloudOff }
        if status.isSyncing { return .syncing }
        if status.pendingCount > 0 { return .notSynced }
        return .upToDate
    }

    private var footer: String {
        guard sync.isAvailable else { return L("This build can't reach iCloud. Your games and saves stay on \(Formatting.thisDevice(model.deviceKind)).") }
        if sync.status.gameFilesAllowed {
            return L("Saves and progress follow you across your devices. Game files in iCloud count against your storage; downloads happen only when you play.")
        }
        return L("Saves and progress follow you across your devices. Game files stay where you added them.")
    }
}

struct PlaySettingsSection: View {
    @Environment(LibraryModel.self) private var model
    @State private var continueFromLatest = true
    @State private var rewindDuration: Double = 10
    @State private var fastForward: EmulationSpeed = .double
    @State private var haptics = true
    @State private var opacity = 0.55
    @State private var showWithController = false
    @State private var twoFingerToggle = true

    private var preferences: PlayPreferences { model.play.preferences }
    private var policy: RelayAccessPolicy { model.play.accessPolicy }

    var body: some View {
        Section {
            Toggle(isOn: $continueFromLatest) { Text("Continue from latest save", bundle: .module) }
                .onChange(of: continueFromLatest) { _, v in preferences.continueFromLatestSave = v }
            Picker(selection: $rewindDuration) {
                Text("Off", bundle: .module).tag(0.0)
                Text("10 seconds", bundle: .module).tag(10.0)
                if policy.allows(.extendedRewind) {
                    Text("30 seconds", bundle: .module).tag(30.0)
                    Text("1 minute", bundle: .module).tag(60.0)
                }
            } label: { Text("Rewind", bundle: .module) }
                .onChange(of: rewindDuration) { _, v in model.play.setRewindDuration(v) }
                .relayTVSettingsControl(L("Rewind"))
            if !policy.allows(.extendedRewind) {
                ProFeatureRow(feature: .extendedRewind, unlocked: false, destination: .relayPro(.extendedRewind))
            }
            Picker(selection: $fastForward) {
                Text("2×").tag(EmulationSpeed.double)
                if policy.allows(.advancedSpeeds) {
                    Text("Max", bundle: .module).tag(EmulationSpeed.maximum)
                }
            } label: { Text("Fast Forward", bundle: .module) }
                .onChange(of: fastForward) { _, v in preferences.fastForwardSpeed = v }
                .relayTVSettingsControl(L("Fast Forward"))
            if !policy.allows(.advancedSpeeds) {
                ProFeatureRow(feature: .advancedSpeeds, unlocked: false, destination: .relayPro(.advancedSpeeds))
            }
        } header: {
            #if !os(tvOS)
            SettingsHeader(L("Play"))
            #endif
        } footer: {
            Text("Relay saves as you go. Rewind keeps the last moments in memory only.", bundle: .module)
                .foregroundStyle(RelayColor.textSecondary)
                #if os(macOS)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                #endif
                .accessibilityIdentifier("settings.playDescription")
        }
        .onAppear {
            continueFromLatest = preferences.continueFromLatestSave
            rewindDuration = min(preferences.rewindDuration, policy.allows(.extendedRewind) ? 60 : 10)
            fastForward = policy.allows(.advancedSpeeds) ? preferences.fastForwardSpeed : .double
        }
        .onChange(of: model.environment.relayPro.entitlement) { _, _ in
            rewindDuration = min(preferences.rewindDuration, policy.allows(.extendedRewind) ? 60 : 10)
            fastForward = policy.allows(.advancedSpeeds) ? preferences.fastForwardSpeed : .double
        }

        #if os(iOS)
        Section {
            Toggle(isOn: $haptics) { Text("Haptics", bundle: .module) }
                .onChange(of: haptics) { _, v in preferences.touchHaptics = v }
            if policy.allows(.touchLayoutEditing) {
                HStack {
                    Text("Opacity", bundle: .module)
                    Slider(value: $opacity, in: 0.2...1, step: 0.05)
                        .onChange(of: opacity) { _, v in preferences.touchOpacity = v }
                        .accessibilityLabel(Text("Opacity", bundle: .module))
                }
            } else {
                ProFeatureRow(feature: .touchLayoutEditing, unlocked: false, destination: .relayPro(.touchLayoutEditing))
            }
            Toggle(isOn: $showWithController) { Text("Show when a controller is connected", bundle: .module) }
                .onChange(of: showWithController) { _, v in preferences.showTouchControlsWithController = v }
            Toggle(isOn: $twoFingerToggle) { Text("Two-finger tap shows or hides them", bundle: .module) }
                .onChange(of: twoFingerToggle) { _, v in preferences.twoFingerTapTogglesControls = v }
        } header: {
            SettingsHeader(L("Touch Controls"))
        }
        .onAppear {
            haptics = preferences.touchHaptics
            opacity = preferences.touchOpacity
            showWithController = preferences.showTouchControlsWithController
            twoFingerToggle = preferences.twoFingerTapTogglesControls
        }
        #endif
    }
}

/// Settings ▸ Advanced ▸ Diagnostics (§16): the only place with technical vocabulary. English only.
public struct DiagnosticsView: View {
    @Environment(LibraryModel.self) private var model
    @State private var pending: [SyncJournalEntry] = []
    @State private var deferred = 0
    @State private var installation = "-"

    public init() {}

    public var body: some View {
        List {
            Section("Relay") {
                DetailRow(label: "Version", value: SettingsView.versionString)
                DetailRow(label: "Platform", value: platform)
            }
            Section("Emulation") {
                ForEach(model.environment.cores) { core in
                    DetailRow(label: core.supportedSystems.map(Formatting.systemName).joined(separator: ", "),
                              value: "\(core.name) \(core.version) (\(core.license)); state compatibility \(core.stateCompatibilityVersion)")
                    Text(core.capabilities.names.joined(separator: ", "))
                        .font(.relayStatus).foregroundStyle(RelayColor.textTertiary)
                }
            }
            Section("Sync") {
                let s = model.sync.status
                DetailRow(label: "Available in this build", value: model.sync.isAvailable ? "yes" : "no")
                DetailRow(label: "Account", value: s.account.rawValue + (s.accountChangePending ? " (changed, decision pending)" : ""))
                DetailRow(label: "Sync saves", value: s.isEnabled ? "on" : "off")
                DetailRow(label: "Game files", value: s.gameFilesAllowed ? (s.gameFilesEnabled ? "on (opted in)" : "off (not opted in)") : "not supported by this transport")
                DetailRow(label: "Engine", value: s.transportDetail.isEmpty ? (s.isActive ? "running" : "stopped") : s.transportDetail)
                DetailRow(label: "Pending journal", value: "\(s.pendingCount) (\(deferred) deferred)")
                DetailRow(label: "Last push / pull", value: "\(s.lastPushAt.map { Formatting.relative($0) } ?? "never") / \(s.lastPullAt.map { Formatting.relative($0) } ?? "never")")
                DetailRow(label: "Unresolved conflicts", value: "\(s.conflictGameIDs.count)")
                DetailRow(label: "Cloud-only games", value: "\(s.cloudOnlyCount)")
                DetailRow(label: "Last problem", value: s.problem.map { "\($0)" } ?? "none")
                DetailRow(label: "Last error category", value: s.lastErrorCategory ?? "none")
                if !s.recentProblems.isEmpty {
                    DetailRow(label: "Recent record problems", value: s.recentProblems.joined(separator: ", "))
                }
                DetailRow(label: "Record schema", value: "v\(SyncSchema.version)")
                DetailRow(label: "Installation", value: installation)
                if model.sync.isAvailable {
                    Button("Request Sync") { Task { await model.sync.requestSync() } }
                }
                ForEach(pending.prefix(20)) { entry in
                    Text("#\(entry.id) \(entry.intent.kind.rawValue) \(entry.intent.operation.rawValue) \(entry.intent.key.prefix(24))… attempts \(entry.attempts)\(entry.lastError.map { " · \($0)" } ?? "")")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(RelayColor.textTertiary)
                }
            }
            Section("Play session") {
                let d = model.play.session.diagnostics
                DetailRow(label: "State", value: "\(model.play.session.state)")
                DetailRow(label: "Emulation / presented fps", value: String(format: "%.1f / %.0f", d.emulationFramesPerSecond, d.presentedFramesPerSecond))
                DetailRow(label: "Audio", value: d.audioRunning ? String(format: "on, %.0f Hz, %d B queued", d.audioSampleRate, d.audioBufferedBytes) : "off")
                DetailRow(label: "Speed", value: d.speed.rawValue)
                DetailRow(label: "Rewind buffer", value: "\(d.rewindEntries) entries, \(ByteCountFormatter.string(fromByteCount: Int64(d.rewindBytes), countStyle: .memory)), \(String(format: "%.1f s", d.rewindRetainedSeconds))")
                DetailRow(label: "State capture / restore", value: String(format: "%.2f ms / %.2f ms", d.lastStateCaptureMillis, d.lastStateRestoreMillis))
                DetailRow(label: "Controller", value: d.controllerName ?? "none")
            }
            Section("Library") {
                DetailRow(label: "Database schema", value: model.environment.appliedMigrations().joined(separator: ", "))
                DetailRow(label: L("Games"), value: model.games.count.formatted())
                DetailRow(label: "Path", value: model.environment.location.rootURL.path(percentEncoded: false))
            }
            Section("Imported games (SHA-256)") {
                ForEach(model.games) { game in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title).font(.relayMeta).foregroundStyle(RelayColor.textPrimary)
                        Text(game.contentFingerprint.hexDigest).font(.system(.caption2, design: .monospaced)).foregroundStyle(RelayColor.textTertiary)
                    }
                }
            }
        }
        .relaySettingsPage("Diagnostics")
        .task {
            pending = await model.sync.pendingEntries()
            deferred = await model.sync.deferredCount()
            if let id = await model.sync.installationIdentifier { installation = String(id.prefix(8)) + "…" }
        }
    }

    private var platform: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let name = "tvOS"
        #elseif os(macOS)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        return "\(name) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

// Licences and attribution live in AboutRelayView / OpenSourceView, fed by the
// generated dataset (Scripts/relay-licenses.py); nothing is typed by hand here.

public struct FormatsView: View {
    @Environment(\.dismiss) private var dismiss
    private let isPresentedModally: Bool
    public init(isPresentedModally: Bool = true) { self.isPresentedModally = isPresentedModally }

    @ViewBuilder public var body: some View {
        if isPresentedModally {
            NavigationStack { content }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            #if os(tvOS)
            // No controls here: the reading surface owns focus so the remote can
            // scroll the whole list and Menu returns to Help (B2-TV-002).
            TVInfoPage(title: L("Which formats work?")) {
                TVInfoSection {
                    Text("Relay includes no games. Bring the files you own.", bundle: .module)
                        .font(.relayBody).foregroundStyle(RelayColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TVInfoSection(header: L("Systems"),
                              footer: L("ZIP archives with game files inside work too. A game whose progress arrived from another device becomes playable as soon as you add its file here. More systems arrive in later versions.")) {
                    ForEach(SystemCatalog.all.filter(\.isPlayable)) { system in
                        TVInfoRow(label: system.name,
                                  value: system.fileExtensions.map { ".\($0)" }.joined(separator: ", ") + ", .zip")
                    }
                }
                TVInfoSection {
                    Text("For PlayStation, select the CUE file and all BIN tracks together, or import a CHD disc. To keep several discs in one game, select an M3U playlist and all the discs it lists. Large ZIP files should be unzipped before import.", bundle: .module)
                        .font(.relayBody).foregroundStyle(RelayColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #else
            List {
                Section {
                    Text("Relay includes no games. Bring the files you own.", bundle: .module)
                        .font(.relayBody).foregroundStyle(RelayColor.textSecondary)
                }
                Section {
                    ForEach(SystemCatalog.all.filter(\.isPlayable)) { system in
                        HStack {
                            Rectangle().fill(SystemAccent.hue(for: system.id).accent).frame(width: 2, height: 28)
                            Text(system.name).font(.relayCardTitle).foregroundStyle(RelayColor.textPrimary)
                            Spacer()
                            Text(system.fileExtensions.map { ".\($0)" }.joined(separator: ", ") + ", .zip")
                                .font(.relayMeta).foregroundStyle(RelayColor.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Systems", bundle: .module)
                } footer: {
                    Text("ZIP archives with game files inside work too. A game whose progress arrived from another device becomes playable as soon as you add its file here. More systems arrive in later versions.", bundle: .module)
                        .foregroundStyle(RelayColor.textSecondary)
                }
                Section {
                    Text("For PlayStation, select the CUE file and all BIN tracks together, or import a CHD disc. To keep several discs in one game, select an M3U playlist and all the discs it lists. Large ZIP files should be unzipped before import.", bundle: .module)
                }
            }
            .relaySettingsPage(L("Which formats work?"))
            #endif
        }
            .toolbar {
                if isPresentedModally {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Text("Done", bundle: .module) }
                    }
                }
            }
    }
}


/// The Relay lockup at the top of Settings: the mark, the name, the version.
/// Nothing here is a control, and nothing below it is branded.
struct SettingsLockup: View {
    let version: String
    @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 30

    var body: some View {
        HStack(spacing: RelaySpacing.s) {
            RelayMark()
                .frame(width: markSize, height: markSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Relay")
                    .font(.relayShelfTitle)
                    .foregroundStyle(RelayColor.textPrimary)
                Text(version)
                    .font(.relayStatus)
                    .foregroundStyle(RelayColor.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, RelaySpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// A Settings group heading, with the same dash that introduces every other group
/// in Relay. Diagnostics deliberately does not use it: it is meant to be boring.
struct SettingsHeader: View {
    private let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(alignment: .top, spacing: RelaySpacing.xs) {
            RelayDash(RelayColor.textTertiary, height: 3)
                .padding(.top, 7)
            Text(title)
                .foregroundStyle(RelayColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
