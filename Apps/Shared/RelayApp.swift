// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RelayApp.swift
//  Relay — one SwiftUI entry point shared by the iOS/iPadOS, tvOS and native
//  macOS targets. The product UI lives in Packages/RelayUI; this file wires the
//  concrete emulation driver factory, the managed library location and the
//  platform scenes (menus and Settings window on macOS).

import SwiftUI
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayCores
#if DEBUG
@_spi(AccessibilityQualification) import RelayUI
#else
import RelayUI
#endif
import RelayDesignSystem
import RelaySync
import RelayCloudKit
import RelayHostedSync
import CryptoKit
import RelayEntitlements
import RelayStoreKit
#if RELAY_HOSTED_PRODUCTION && RELAY_HOSTED_PREPRODUCTION
#error("Production and preproduction hosted environments are mutually exclusive")
#endif
#if RELAY_HOSTED_PRODUCTION && (DEBUG || RELAY_DEV_FIXTURES)
#error("Public production must not compile Debug or development fixtures")
#endif
#if RELAY_TESTFLIGHT_PREPRODUCTION
#if DEBUG || RELAY_DEV_FIXTURES
#error("TestFlight preproduction must not compile Debug or development fixtures")
#endif
#if !RELAY_HOSTED_PREPRODUCTION || !RELAY_CLOUDKIT
#error("TestFlight preproduction requires the real hosted account and CloudKit")
#endif
#endif
#if os(macOS)
import AppKit
#endif

@main
struct RelayApp: App {
    @State private var model: LibraryModel
    @State private var actions = RelayActions()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(RelayMacDelegate.self) private var delegate
    #endif

    init() {
        #if DEBUG
        if DevHooks.arguments.contains("--relay-layout-fixture") ||
            DevHooks.arguments.contains("--relay-accessibility-evidence") {
            precondition(DevHooks.value(after: "--relay-isolated-qualification").flatMap(UUID.init(uuidString:)) != nil,
                         "Layout qualification requires an isolated library identifier")
        }
        #endif
        #if DEBUG && RELAY_HOSTED_PREPRODUCTION
        if DevHooks.arguments.contains("--relay-accessibility-fixture") ||
            DevHooks.arguments.contains("--relay-accessibility-evidence") {
            precondition(DevHooks.value(after: "--relay-isolated-qualification").flatMap(UUID.init(uuidString:)) != nil,
                         "Accessibility qualification requires an isolated library identifier")
        }
        #endif
        #if DEBUG
        // Reset before any view can start LibraryEnvironment.open(). isReady
        // stays false during opening and cannot protect a live SQLite store.
        if DevHooks.resetLibrary {
            let libraryRoot = RelayStorage.libraryRootURL()
            if FileManager.default.fileExists(atPath: libraryRoot.path) {
                do {
                    try FileManager.default.removeItem(at: libraryRoot)
                } catch {
                    preconditionFailure("Could not reset the Debug library: \(error)")
                }
            }
            DevHooks.log("library reset")
        }
        #endif
        let factory = RelayCores.standardFactory()
        let session = EmulationSession(factory: factory, storage: RelayStorage.emulationStorage())
        let entitlementProvider: (any RelayEntitlementProviding)?
        #if DEBUG
        if let scenario = DevHooks.proTestScenario {
            entitlementProvider = DebugEntitlementProvider(scenario: scenario)
        } else {
            entitlementProvider = StoreKitEntitlementProvider()
        }
        #else
        entitlementProvider = StoreKitEntitlementProvider()
        #endif
        let combined = CombinedRelayEntitlementProvider(store: entitlementProvider ?? UnavailableEntitlementProvider())
        let account: RelayAccountModel?
        let hostedEnvironment: RelayHostedEnvironment?
        #if RELAY_HOSTED_PRODUCTION
        hostedEnvironment = .production
        #elseif RELAY_HOSTED_PREPRODUCTION
        hostedEnvironment = .preproduction
        #else
        hostedEnvironment = nil
        #endif
        let hostedAccount: RelayAccountModel?
        if let hostedEnvironment {
            hostedAccount = RelayAccountModel(environment: hostedEnvironment, entitlements: combined,
                                    configureBilling: { session in
                                        (entitlementProvider as? StoreKitEntitlementProvider)?.setBillingBridge(session)
                                    },
                                    billingAccountChanged: { accountID in
                                        (entitlementProvider as? StoreKitEntitlementProvider)?.setBillingAccountID(accountID)
                                    })
        } else {
            hostedAccount = nil
        }
        #if DEBUG
        account = DebugTransferPreview.load()?.makeAccount(entitlements: combined) ?? hostedAccount
        #else
        account = hostedAccount
        #endif
        let achievements: AchievementsModel?
        #if DEBUG
        achievements = DebugAchievements.make()
        #else
        achievements = nil
        #endif
        // Account, Transfer signaling and public covers share the selected origin.
        let coverSource: (any CoverArtSource)? = hostedEnvironment.flatMap {
            HostedCoverArtSource(origin: $0.apiOrigin)
        }
        let environment = LibraryEnvironment(location: LibraryLocation(rootURL: RelayStorage.libraryRootURL()),
                                             session: session,
                                             cores: factory.availableCores,
                                             deviceKind: DevHooks.deviceKindOverride ?? .current,
                                             metadataProvider: DevHooks.metadataProvider,
                                             firmwareDirectory: RelayStorage.emulationStorage().firmwareDirectory,
                                             syncCapabilities: RelaySyncSetup.capabilities,
                                             gameplayRequiresPro: Self.gameplayRequiresPro,
                                             entitlementProvider: combined,
                                             transportFactory: RelaySyncSetup.makeTransportFactory(),
                                             relayAccount: account,
                                             achievements: achievements,
                                             hostedTransportFactory: { location, identity, account in
                                                 guard let session = account.session, let accountID = account.accountID else { return nil }
                                                 let http = session.makeHTTPClient(expectedAccountID: accountID)
                                                 let content = HostedContentClient(http: http,
                                                     stagingDirectory: location.syncDirectory.appending(path: "HostedContent", directoryHint: .isDirectory))
                                                 guard let transport = try? RelayHostedSyncTransport(http: http, content: content,
                                                     accountIdentity: SHA256.hash(data: Data((account.environment.keychainService + ":" + accountID.uuidString.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined(),
                                                     installationID: identity.installationID,
                                                     stateDirectory: location.syncDirectory,
                                                     environmentID: account.environment.keychainService,
                                                     vaultWritable: account.canUpload) else { return nil }
                                                 account.trackTransport(transport)
                                                 return transport
                                             },
                                             coverSource: coverSource)
        let playDefaults: UserDefaults
        #if DEBUG
        if DevHooks.arguments.contains("--relay-skins-share-qualification") {
            guard let raw = DevHooks.value(after: "--relay-isolated-qualification"),
                  let id = UUID(uuidString: raw),
                  let suite = UserDefaults(suiteName: "app.relayemu.skins-share.\(id.uuidString)") else {
                preconditionFailure("Skin qualification requires isolated preferences and library")
            }
            // A simulator may inherit a connected host gamepad. This slice
            // deliberately exercises the real touch controls as well.
            suite.set(true, forKey: "relay.touch.showWithController")
            playDefaults = suite
        } else { playDefaults = .standard }
        #else
        playDefaults = .standard
        #endif
        let model = LibraryModel(environment: environment, defaults: playDefaults)
        _model = State(initialValue: model)
        #if os(macOS)
        RelayMacDelegate.model = model
        #endif
    }

    private static var gameplayRequiresPro: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            qualificationRoot
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(RelayMenuCopy.importGames) { actions.importFiles() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(!actions.canPresentRelaySurface)
            }
            CommandMenu(RelayMenuCopy.game) {
                Button(model.play.isPaused ? RelayMenuCopy.resume : RelayMenuCopy.pause) { model.play.togglePause() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!model.isPlaying || !actions.canPresentRelaySurface)
                Divider()
                Button(RelayMenuCopy.quickSave) { Task { await model.play.quickSave() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isPlaying || !model.play.canSaveStates || !actions.canPresentRelaySurface)
                Button(RelayMenuCopy.quickLoad) { Task { await model.play.quickLoad() } }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!model.isPlaying || !model.play.canSaveStates || !actions.canPresentRelaySurface)
                Button(RelayMenuCopy.saveNow) { Task { await model.play.saveNow() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isPlaying || !model.play.canSaveStates || !actions.canPresentRelaySurface)
                Button(RelayMenuCopy.loadSave) { actions.openPlaySaves() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.isPlaying || !model.play.canSaveStates || !actions.canPresentRelaySurface)
                Divider()
                Button(model.play.speed == .normal ? RelayMenuCopy.fastForward : RelayMenuCopy.normalSpeed) {
                    model.play.setSpeed(model.play.speed == .normal ? model.play.preferences.fastForwardSpeed : .normal)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!model.isPlaying || !model.play.canFastForward || !actions.canPresentRelaySurface)
                Divider()
                Button(RelayMenuCopy.exitGame) { Task { await model.stop() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.isPlaying || !actions.canPresentRelaySurface)
            }
            CommandGroup(replacing: .help) {
                Button(RelayMenuCopy.supportedFormats) { actions.whichFormats() }
                    .disabled(!actions.canPresentRelaySurface)
                Button(RelayMenuCopy.diagnostics) { actions.openDiagnostics() }
                    .disabled(!actions.canPresentRelaySurface)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            NavigationStack { SettingsView().relayRoutes() }
                // A window minimum belongs to this standalone scene. Applying it
                // to SettingsView also overflows narrower split-view detail panes.
                .frame(minWidth: 480, minHeight: 420)
                .environment(model)
                .environment(actions)
        }
        #endif
    }

    @ViewBuilder
    private var qualificationRoot: some View {
        #if DEBUG
        if DevHooks.arguments.contains("--relay-layout-fixture") {
            RelayLayoutStressFixtureView()
        } else if DevHooks.arguments.contains("--relay-accessibility-evidence"),
                  DevHooks.value(after: "--relay-accessibility-fixture") == nil {
            // Read actual UI traits without enabling the hosted account fixture.
            VStack(spacing: 0) {
                productRoot
                RelayAccessibilityEnvironmentProbe()
            }
        } else {
            hostedQualificationRoot
        }
        #else
        productRoot
        #endif
    }

    @ViewBuilder
    private var hostedQualificationRoot: some View {
        #if DEBUG && RELAY_HOSTED_PREPRODUCTION
        if let scenario = DevHooks.value(after: "--relay-accessibility-fixture") {
            VStack(spacing: 0) {
                RelaySyncAccessibilityFixtureView(scenario: scenario)
                RelayAccessibilityEnvironmentProbe()
            }
        } else {
            productRoot
        }
        #else
        productRoot
        #endif
    }

    private var productRoot: some View {
        RelayRootView()
            .environment(model)
            .environment(actions)
            .onAppear {
                model.play.allowsGameplayCommands = { actions.canPresentRelaySurface }
                DevHooks.apply(model: model, actions: actions)
            }
    }
}

#if os(macOS)
/// Quit writes the saves and the session record first (MACOS_UX §13.9); closing the
/// window while playing exits the game the same way (§6).
final class RelayMacDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: LibraryModel?
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CKSyncEngine needs the app registered for remote notifications to be told
        // about changes from other devices without polling. Silent pushes need no
        // user permission; registration is skipped when CloudKit is not in use.
        if MainActor.assumeIsolated({ RelaySyncSetup.usesCloudKit }) {
            NSApplication.shared.registerForRemoteNotifications()
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.isMainWindow || window.isKeyWindow,
                      let model = RelayMacDelegate.model, model.isPlaying else { return }
                Task { await model.stop() }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isPlaying else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DevHooks.log("push registered token=\(deviceToken.count)B")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DevHooks.log("push registration failed: \(error.localizedDescription)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        DevHooks.log("push received keys=\(userInfo.keys.sorted().joined(separator: ","))")
    }
}
#endif

/// How this build reaches iCloud (RELAY_SYNC_ARCHITECTURE.md §7, §12):
///   - CloudKit through CKSyncEngine when the process carries the iCloud container
///     entitlement (signed builds); the container comes from the entitlement, never
///     from a hard-coded string, so an unentitled build never traps in CKContainer;
///   - the Debug file transport (`--relay-file-cloud <dir>`) for two-process walks;
///   - nothing otherwise: Relay stays fully local and Settings says so.
/// Game-file iCloud sync is Free and opt-in in every normal build. The Debug
/// flag only asks verification hooks to turn that preference on automatically.
enum RelaySyncSetup {
    static var capabilities: SyncCapabilities {
        .gameFilesSupported
    }

    /// Whether this build talks to CloudKit (as opposed to the Debug file transport or nothing).
    @MainActor
    static var usesCloudKit: Bool {
        #if DEBUG
        if DevHooks.syncOff || DevHooks.fileCloudDirectory != nil { return false }
        #endif
        if CloudKitEntitlements.containerIdentifier != nil, CloudKitEntitlements.hasCloudKitService { return true }
        #if RELAY_CLOUDKIT
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static func makeTransportFactory() -> SyncTransportFactory? {
        #if DEBUG
        if DevHooks.syncOff || DevHooks.cloudReset { return nil }
        if let directory = DevHooks.fileCloudDirectory {
            return { location in FileCloudTransport(root: directory, stateDirectory: location.syncDirectory) }
        }
        #endif
        // macOS: the code signature is the truth. iOS/tvOS: only builds compiled with
        // RELAY_CLOUDKIT (signed with the iCloud capability) may touch CKContainer.
        var container: String?
        if let probed = CloudKitEntitlements.containerIdentifier, CloudKitEntitlements.hasCloudKitService { container = probed }
        #if RELAY_CLOUDKIT
        container = container ?? CloudKitEntitlements.expectedContainer
        #endif
        guard let container else { return nil }
        return { location in
            CloudKitSyncTransport(configuration: .init(containerIdentifier: container,
                                                        stateFileURL: location.syncDirectory.appending(path: "cksyncengine-state.json"),
                                                        scratchDirectory: location.syncDirectory.appending(path: "Scratch", directoryHint: .isDirectory)))
        }
    }
}

/// Where Relay keeps its data: Application Support/Relay/… on iOS, iPadOS and
/// macOS; Caches/Relay/… on tvOS, which refuses every other location.
enum RelayStorage {
    static func baseDirectory() -> URL {
        #if DEBUG
        if let override = DevHooks.libraryRoot { return override }
        #endif
        // tvOS refuses to create anything under Application Support (and has no
        // Documents directory): the device returns NSCocoaErrorDomain 513 with
        // POSIX EPERM, which the tvOS *simulator* does not, so this only appears
        // on real hardware. Caches is the writable location there. It is
        // purgeable when the system needs space, which is the platform's own
        // model: on Apple TV the local library is a replica and iCloud carries
        #if os(tvOS)
        let container = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let container = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        let base = container.appendingPathComponent("Relay", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Managed library root (games, artwork, screenshots, database) — `ContentLocation.Root.managedLibrary`.
    static func libraryRootURL() -> URL {
        baseDirectory().appendingPathComponent("Library", isDirectory: true)
    }

    /// Session defaults; per-game directories under Library/Saves/<GameID>/ override
    /// directories are no longer written.
    static func emulationStorage() -> EmulationStorage {
        let base = baseDirectory()
        return EmulationStorage(batterySavesDirectory: base.appendingPathComponent("Battery Saves", isDirectory: true),
                                saveStatesDirectory: base.appendingPathComponent("Save States", isDirectory: true),
                                firmwareDirectory: base.appendingPathComponent("Firmware", isDirectory: true))
    }

    /// Development fixtures bundled only in Debug builds (see Apps/project.yml):
    /// the 240p Test Suite (GPL-2.0, no SRAM) and the Relay SRAM counter (CC0, writes SRAM).
    /// The bundled Debug fixtures, one per playable system plus the 240p suite.
    static let devFixtures: [(name: String, ext: String)] = [
        ("240pee_mb", "gba"), ("relay-sram-counter", "gba"), ("relay-sram-tone", "gba"),
        ("relay-gb-counter", "gb"), ("relay-gbc-counter", "gbc"),
        ("relay-nes-counter", "nes"), ("relay-snes-counter", "sfc"), ("relay-ds-counter", "nds"),
        ("relay-sms-counter", "sms"), ("relay-gg-counter", "gg"), ("relay-pce-counter", "pce"),
        ("relay-ws-counter", "ws"), ("relay-wsc-counter", "wsc"), ("relay-ps1-counter", "cue"),
    ]

    /// `--relay-fixture <name>`: `240p` (default), `counter` (the GBA SRAM counter)
    /// or any bundled fixture's base name (`relay-nes-counter`, …).
    static var devFixtureURL: URL? {
        #if RELAY_DEV_FIXTURES
        let requested = DevHooks.fixtureName
        if requested == "relay-ps1-multidisc" { return multiDiscQualificationFixture }
        let name = requested == "counter" ? "relay-sram-counter" : requested == "240p" ? "240pee_mb" : requested
        guard let fixture = devFixtures.first(where: { $0.name == name }) else { return nil }
        return Bundle.main.url(forResource: fixture.name, withExtension: fixture.ext)
        #else
        return nil
        #endif
    }

    /// Every bundled Debug fixture (`--relay-fixture all`).
    static var devFixtureURLs: [URL] {
        #if RELAY_DEV_FIXTURES
        return devFixtures.compactMap { Bundle.main.url(forResource: $0.name, withExtension: $0.ext) }.flatMap(devFixtureMembers)
        #else
        return []
        #endif
    }
    static var selectedDevFixtureURLs: [URL] { devFixtureURL.map(devFixtureMembers) ?? [] }
    private static func devFixtureMembers(_ url: URL) -> [URL] {
        #if RELAY_DEV_FIXTURES
        if url.pathExtension == "m3u", url == multiDiscQualificationFixture {
            return [url] + ["relay-ps1-counter.cue", "relay-ps1-second.cue", "relay-ps1-counter.bin"]
                .map { url.deletingLastPathComponent().appendingPathComponent($0) }
        }
        #endif
        guard url.pathExtension == "cue", let bin = Bundle.main.url(forResource: "relay-ps1-counter", withExtension: "bin") else { return [url] }
        return [url, bin]
    }

    #if RELAY_DEV_FIXTURES
    private static let multiDiscQualificationFixture: URL? = {
        guard DevHooks.fixtureName == "relay-ps1-multidisc" else { return nil }
        guard let isolation = DevHooks.value(after: "--relay-isolated-qualification"),
              UUID(uuidString: isolation) != nil else {
            preconditionFailure("Multi-disc qualification requires an isolated library")
        }
        guard let cue = Bundle.main.url(forResource: "relay-ps1-counter", withExtension: "cue"),
              let bin = Bundle.main.url(forResource: "relay-ps1-counter", withExtension: "bin") else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayMultiDisc-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for member in [cue, bin] {
                try FileManager.default.copyItem(at: member, to: directory.appendingPathComponent(member.lastPathComponent))
            }
            try FileManager.default.copyItem(at: cue, to: directory.appendingPathComponent("relay-ps1-second.cue"))
            let playlist = directory.appendingPathComponent("relay-ps1-multidisc.m3u")
            try Data("relay-ps1-counter.cue\nrelay-ps1-second.cue\n".utf8).write(to: playlist)
            return playlist
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }()
    #endif

    static func devFixtureFingerprint(_ url: URL) async throws -> ContentFingerprint {
        if !["cue", "m3u"].contains(url.pathExtension) { return try await SHA256ContentHasher().hash(fileAt: url).fingerprint }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("RelayFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for member in devFixtureMembers(url) { try FileManager.default.copyItem(at: member, to: staging.appendingPathComponent(member.lastPathComponent)) }
        let package = try await PlayStationDiscPackage.build(from: staging.appendingPathComponent(url.lastPathComponent), in: staging)
        return try await SHA256ContentHasher().hash(fileAt: package).fingerprint
    }

}
