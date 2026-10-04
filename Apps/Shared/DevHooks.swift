// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
import RelayLibrary
import RelayTitleCatalog
import RelayEmulation
import RelayVideo
import RelayUI
import RelayEntitlements
import RelayCloudKit
import RelayHostedSync
#if os(iOS)
import AVFAudio
#endif
#if os(macOS)
import AppKit
#endif

extension DevHooks.ScriptStep {
    var isKeepRemote: Bool { if case .keepRemote = self { return true } else { return false } }
}

#if DEBUG
private final class TransferPreviewSessionStore: HostedSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HostedSessionCredential?
    init(_ credential: HostedSessionCredential) { self.credential = credential }
    func load() throws -> HostedSessionCredential? { lock.withLock { credential } }
    func save(_ credential: HostedSessionCredential) throws { lock.withLock { self.credential = credential } }
    func remove() throws { lock.withLock { credential = nil } }
}

struct DebugTransferPreview: Decodable {
    let origin: URL
    let accountID: UUID
    let installationID: UUID
    let nativeToken: String
    let expiresAt: Date

    static func load() -> Self? {
        guard let path = DevHooks.value(after: "--relay-transfer-preview") else { return nil }
        guard DevHooks.value(after: "--relay-isolated-qualification").flatMap(UUID.init(uuidString:)) != nil,
              let root = DevHooks.libraryRoot,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            preconditionFailure("Transfer preview requires its own isolated configuration")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 8192 else { throw HostedAuthError.invalidResponse }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let result = try decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            _ = try RelayHostedEnvironment.transferTestEnvironment(origin: result.origin)
            guard result.expiresAt > Date(), result.expiresAt.timeIntervalSinceNow <= 7200,
                  result.nativeToken.utf8.count == 43 else { throw HostedAuthError.invalidResponse }
            return result
        } catch { preconditionFailure("Transfer preview configuration is unavailable or invalid") }
    }

    @MainActor
    func makeAccount(entitlements: CombinedRelayEntitlementProvider) -> RelayAccountModel {
        let environment = try! RelayHostedEnvironment.transferTestEnvironment(origin: origin,
            showPublicPortal: DevHooks.arguments.contains("--relay-transfer-public-address"))
        let store = TransferPreviewSessionStore(.init(accessToken: nativeToken, expiresAt: expiresAt, relayAccountID: accountID))
        let expected = installationID
        return RelayAccountModel(environment: environment, entitlements: entitlements, sessionStoreFactory: { actual in
            precondition(actual == expected, "Transfer preview installation does not match its isolated library")
            return store
        })
    }
}
#endif

enum DevHooks {
    #if DEBUG
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var autoplayFixture: Bool { arguments.contains("--relay-autoplay-fixture") }
    static var diagnosticsLog: Bool { arguments.contains("--relay-diag-log") }
    static var resetLibrary: Bool { arguments.contains("--relay-reset-library") }
    static var screen: String? { value(after: "--relay-screen") }
    static var diagnosticsFile: URL? {
        if let path = value(after: "--relay-diag-file") { return URL(fileURLWithPath: path) }
        if arguments.contains("--relay-skins-share-qualification"), value(after: "--relay-isolated-qualification") != nil {
            return libraryRoot?.appendingPathComponent("skins-share-diagnostics.log")
        }
        return nil
    }
    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    static var exitAfter: TimeInterval? { value(after: "--relay-exit-after").flatMap(TimeInterval.init) }
    static var screenshotDirectory: URL? { value(after: "--relay-screenshot-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var libraryRoot: URL? {
        if let raw = value(after: "--relay-isolated-qualification") {
            // Invalid isolation must never silently fall back to the owner's library.
            guard let id = UUID(uuidString: raw) else { preconditionFailure("Invalid qualification isolation identifier") }
            #if os(tvOS)
            let directory = FileManager.SearchPathDirectory.cachesDirectory
            #else
            let directory = FileManager.SearchPathDirectory.applicationSupportDirectory
            #endif
            guard let container = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
                preconditionFailure("Qualification container unavailable")
            }
            return container.appendingPathComponent("HostedQualification", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        }
        return value(after: "--relay-library-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var fileCloudDirectory: URL? { value(after: "--relay-file-cloud").map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var syncOff: Bool { arguments.contains("--relay-sync-off") }
    static var gameFileSync: Bool { arguments.contains("--relay-game-file-sync") || UserDefaults.standard.bool(forKey: "relay.dev.gameFileSync") }
    static var proTestScenario: DebugEntitlementProvider.Scenario? {
        value(after: "--relay-pro-test").flatMap(DebugEntitlementProvider.Scenario.init(rawValue:))
    }
    static var proFeature: RelayProFeature? {
        value(after: "--relay-pro-feature").flatMap(RelayProFeature.init(rawValue:))
    }
    static var deviceKindOverride: DeviceKind? { value(after: "--relay-device-kind").map { DeviceKind(lenient: $0) } }
    static var cloudProbe: Bool { arguments.contains("--relay-cloud-probe") }
    /// Play a game already in the library, matched by a case-insensitive title substring.
    /// Reproduces a launch the way the product does it, with the refusal message logged.
    static var playTitle: String? { value(after: "--relay-play-title") }
    /// Import the bundled fixture and stop there, leaving the product UI on Home
    /// with one game. Used by the UI tests, which drive real taps from that state.
    static var importFixture: Bool { arguments.contains("--relay-import-fixture") }
    static var cloudReset: Bool { arguments.contains("--relay-cloud-reset") }
    /// Seed a library across several systems so the design of Home, the Library and
    /// the System Spectrum can be reviewed on a real build. Verification only: the
    /// rows go in through the ordinary repository, carry no content, and never ship.
    static var demoLibrary: Bool { arguments.contains("--relay-demo-library") }
    /// Which Debug fixture `--relay-autoplay-fixture` uses: `240p` (default, no SRAM) or `counter` (writes SRAM at boot and on A).
    static var fixtureName: String { value(after: "--relay-fixture") ?? "240p" }
    enum ScriptStep { case press(EmulationInput), speed(EmulationSpeed), pause, resume, quickSave, quickLoad, saveNow, rewind, fastForward, menu, saves, display, background, touch, sync, download, keepRemote, keepLocal, deleteEverywhere, removeDownload, toggleSync }
    static var rewindSeconds: TimeInterval? { value(after: "--relay-rewind-seconds").flatMap(TimeInterval.init) }
    static var inputScript: [(TimeInterval, ScriptStep)] {
        guard let script = value(after: "--relay-input-script") else { return [] }
        return script.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let t = TimeInterval(parts[0]) else { return nil }
            switch String(parts[1]) {
            case "pause": return (t, .pause)
            case "resume": return (t, .resume)
            case "quicksave": return (t, .quickSave)
            case "quickload": return (t, .quickLoad)
            case "savenow": return (t, .saveNow)
            case "rewind": return (t, .rewind)
            case "ff": return (t, .fastForward)
            case "menu": return (t, .menu)
            case "saves": return (t, .saves)
            case "display": return (t, .display)
            case "background": return (t, .background)
            case "touch": return (t, .touch)
            case "speed025": return (t, .speed(.quarter))
            case "speed05": return (t, .speed(.half))
            case "speed1": return (t, .speed(.normal))
            case "speed2": return (t, .speed(.double))
            case "speed3": return (t, .speed(.triple))
            case "speed4": return (t, .speed(.quadruple))
            case "speedmax": return (t, .speed(.maximum))
            case "sync": return (t, .sync)
            case "download": return (t, .download)
            case "keepremote": return (t, .keepRemote)
            case "keeplocal": return (t, .keepLocal)
            case "deleteeverywhere": return (t, .deleteEverywhere)
            case "removedownload": return (t, .removeDownload)
            case "toggle-sync": return (t, .toggleSync)
            case let name: return inputByName[name].map { (t, .press($0)) }
            }
        }
    }
    private static let inputByName: [String: EmulationInput] = [
        "up": .up, "down": .down, "left": .left, "right": .right, "a": .a, "b": .b,
        "l": .l, "r": .r, "start": .start, "select": .select,
    ]

    /// Debug builds describe the bundled fixture through the metadata boundary, so the
    /// library shows the game's real name, then fall back to the offline title catalog
    /// like Release.
    static var metadataProvider: any MetadataProvider {
        let fixture = try! ContentFingerprint(parsing: "sha256:47844f7140738a06f8f3bc09780da3ab095539a250b870f614feed561d9d6f34")
        var providers: [any MetadataProvider] = [StaticMetadataProvider(id: "relay-dev-fixtures", entries: [
            fixture: MetadataCandidate(title: "240p Test Suite", developer: "Artemio Urbina, Damian Yerrick",
                                       releaseYear: 2021, genre: "Test suite", region: "World",
                                       summary: "Homebrew video test patterns for the Game Boy Advance (GPL-2.0). Bundled in development builds only."),
        ])]
        if let catalog = TitleCatalogProvider.bundled() { providers.append(catalog) }
        return ChainedMetadataProvider(providers)
    }
    #else
    static var autoplayFixture: Bool { false }
    static var playTitle: String? { nil }
    static var importFixture: Bool { false }
    static var diagnosticsLog: Bool { false }
    static var resetLibrary: Bool { false }
    static var screen: String? { nil }
    static var diagnosticsFile: URL? { nil }
    static var exitAfter: TimeInterval? { nil }
    static var screenshotDirectory: URL? { nil }
    static var libraryRoot: URL? { nil }
    static var fileCloudDirectory: URL? { nil }
    static var syncOff: Bool { false }
    static var gameFileSync: Bool { false }
    static var deviceKindOverride: DeviceKind? { nil }
    static var cloudProbe: Bool { false }
    static var cloudReset: Bool { false }
    static var fixtureName: String { "240p" }
    enum ScriptStep { case press(EmulationInput), speed(EmulationSpeed), pause, resume, quickSave, quickLoad, saveNow, rewind, fastForward, menu, saves, display, background, touch, sync, download, keepRemote, keepLocal, deleteEverywhere, removeDownload, toggleSync }
    static var rewindSeconds: TimeInterval? { nil }
    static var inputScript: [(TimeInterval, ScriptStep)] { [] }
    /// The offline title catalog; without it (resource unreadable) games keep their file names.
    static var metadataProvider: any MetadataProvider { TitleCatalogProvider.bundled() ?? NoMetadataProvider() }
    #endif

    static func log(_ message: String) {
        guard diagnosticsLog else { return }
        print("RELAY-DIAG \(message)")
        fflush(stdout)
        appendToDiagnosticsFile("RELAY-DIAG \(message)")
    }

    static func appendToDiagnosticsFile(_ line: String) {
        guard let url = diagnosticsFile, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    @MainActor
    static func apply(model: LibraryModel, actions: RelayActions) {
        #if DEBUG
        if cloudReset {
            Task { @MainActor in
                let container = CloudKitEntitlements.containerIdentifier ?? cloudContainerFallback
                if let container {
                    let deleted = (try? await CloudKitDiagnostics.deleteRelayZones(containerIdentifier: container)) ?? []
                    log("cloud reset container=\(container) deleted=[\(deleted.joined(separator: ","))]")
                } else {
                    log("cloud reset skipped: no container entitlement")
                }
                exit(0)
            }
            return
        }
        // First run: an automated launch goes straight to its screen; a screenshot
        // of the first launch asks for the tour whatever this simulator remembers.
        let automated = autoplayFixture || importFixture || diagnosticsLog || exitAfter != nil || screen != nil || playTitle != nil || demoLibrary || resetLibrary
        if arguments.contains("--relay-onboarding") {
            actions.onboardingForced = true
        } else if automated {
            actions.onboardingSuppressed = true
        }
        guard automated else { return }
        switch screen {
        case "library", "transfer": actions.debugInitialDestination = .allGames
        case "search": actions.debugInitialDestination = .search
        case "settings": actions.debugInitialDestination = .settings
        case "achievements": actions.debugInitialDestination = .settings; actions.debugInitialRoute = .retroAchievements
        case "pro": actions.openRelayPro(feature: proFeature)
        default: break
        }
        Task { @MainActor in
            while !model.isReady && model.loadError == nil { try? await Task.sleep(for: .milliseconds(50)) }
            log("library ready games=\(model.games.count) schema=\(model.environment.appliedMigrations().joined(separator: ","))" + " root=\(model.environment.location.rootURL.path)" + (model.loadError.map { " loadError=\($0.headline) detail=\(model.loadErrorDetail ?? "-")" } ?? ""))
            if screen == "detail", let first = model.games.first {
                actions.debugInitialRoute = .game(first.id)
                log("screen detail game=\(first.id)")
            }
            if screen == "transfer" { actions.fromComputer() }
            if gameFileSync, model.sync.isAvailable, !model.sync.status.gameFilesEnabled {
                await model.sync.setGameFilesEnabled(true)   // explicit Debug opt-in for continuity walks
            }
            logSync(model, "ready")
            if demoLibrary { await seedDemoLibrary(model) }
            if importFixture {
                let fixtures = fixtureName == "all" ? RelayStorage.devFixtureURLs
                                                    : RelayStorage.selectedDevFixtureURLs
                await model.importFiles(fixtures)
                log("library import-only games=\(model.games.count)")
            }
            if autoplayFixture, let fixture = RelayStorage.devFixtureURL {
                log("library import starting fixture=\(fixture.lastPathComponent)")
                await model.importFiles(RelayStorage.selectedDevFixtureURLs)
                // Pick exactly the fixture that was requested (--relay-fixture), by content identity.
                let fingerprint = try? await RelayStorage.devFixtureFingerprint(fixture)
                let game = model.games.first { $0.contentFingerprint == fingerprint }

                log("library import games=\(model.games.count) problems=\(model.problems.count) fixture=\(game?.id.description ?? "missing") title=\(game?.title ?? "-") progress=\(String(describing: model.importProgress))")
                if let game {
                    await model.play(game.id)
                    log("library play game=\(game.id) state=\(model.session.state) message=\(model.playMessage?.headline ?? "none")")
                    if let rewindSeconds {
                        model.play.setRewindDuration(rewindSeconds)
                        log("play rewind configured requested=\(rewindSeconds)s effective=\(model.play.effectiveRewindDuration)s")
                    }
                }
            }
            if let needle = playTitle {
                let match = model.games.first { $0.title.range(of: needle, options: .caseInsensitive) != nil }
                if let game = match {
                    log("library candidate game=\(game.id) title=\(game.title) system=\(game.systemID) content=\(model.hasContent(game.id)) status=\(model.sync.gameStatus(game.id)) conflict=\(model.sync.isInConflict(game.id))")
                    await model.play(game.id)
                    log("library play game=\(game.id) state=\(model.session.state) message=\(model.playMessage?.headline ?? "none")")
                } else {
                    log("library candidate none matching '\(needle)' in \(model.games.map(\.title))")
                }
            }
            scheduleInputScript(model, actions)
            if diagnosticsLog {
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    Task { @MainActor in logDiagnostics(model.session, play: model.play) }
                }
            }
            if let dir = screenshotDirectory {
                let at = max((exitAfter ?? 10) - 2, 3)
                Timer.scheduledTimer(withTimeInterval: at, repeats: false) { _ in
                    Task { @MainActor in captureScreenshots(model.session, into: dir) }
                }
            }
            if let seconds = exitAfter {
                Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                    Task { @MainActor in
                        if model.isPlaying { await model.stop() }
                        try? await Task.sleep(for: .milliseconds(600))
                        logWindowChrome("after stop")
                        if let entry = model.history.values.max(by: { $0.lastPlayedAt < $1.lastPlayedAt }) {
                            log("library playhistory game=\(entry.gameID) sessions=\(entry.sessionCount) total=\(String(format: "%.1f", entry.totalPlayDuration))s paused=\(String(format: "%.1f", entry.latestSession.pausedDuration))s screenshot=\(entry.latestSession.screenshotLocation?.description ?? "none")")
                            let states = await model.browserStates(for: entry.gameID)
                            let battery = await model.batterySave(for: entry.gameID)
                            let all = (try? await model.environment.saveStates?.states(for: entry.gameID)) ?? []
                            log("library saves game=\(entry.gameID) auto=\(all.filter { $0.kind == .auto }.count) quick=\(states.quick.count) manual=\(states.manual.count) battery=\(battery.map { "\($0.sizeInBytes)B" } ?? "none")")
                        }
                        logSync(model, "exit")
                        await probeCloudIfRequested()
                        if let first = model.continuePlaying.first {
                            log("library continue game=\(first.id) status=\(model.statusLine(for: first)) action=\(model.primaryAction(for: first)) content=\(model.hasContent(first.id))")
                        }
                        log("exiting after \(seconds)s, final state=\(model.session.state) continue=\(model.continuePlaying.count) recentlyAdded=\(model.recentlyAdded.count)")
                        exit(0)
                    }
                }
            }
        }
        #endif
    }

    /// One title for every V1-playable system, plus two extra GBA titles so the
    /// artwork fan is reviewed at full depth. Deferred systems stay out of this
    /// fixture: the System grid must represent the exact twelve-system V1 set.
    @MainActor
    static func seedDemoLibrary(_ model: LibraryModel) async {
        guard let store = model.environment.store else { return }
        let entries: [(SystemID, String)] = [
            (.gameBoy, "Tiny Tower Quest"), (.gameBoyColor, "Harbour Lights"),
            (.gameBoyAdvance, "Windmill Coast"), (.nes, "Cavern of Bells"),
            (.snes, "Nine Rivers"), (.nintendoDS, "Two Screens Diner"),
            (.masterSystem, "Blue Sector"), (.gameGear, "Pocket Grand Prix"),
            (.pcEngine, "Paper Kite"), (.wonderSwan, "Slow Train"),
            (.wonderSwanColor, "Late Bloom"), (.playStation, "Night Ferry"),
            // Three of one system, so the artwork fan is reviewed at full depth with
            // every card sharing a hue — the case that used to read as one shape.
            (.gameBoyAdvance, "Copper Lantern"), (.gameBoyAdvance, "Salt Flats"),
        ]
        let now = Date()
        for (index, entry) in entries.enumerated() {
            let digest = String(repeating: String(format: "%02x", index + 17), count: 32)
            guard let fingerprint = try? ContentFingerprint(parsing: "sha256:" + digest) else { continue }
            let game = Game(systemID: entry.0, title: entry.1, contentFingerprint: fingerprint,
                            addedAt: now.addingTimeInterval(-Double(index) * 3_600),
                            isFavorite: index % 5 == 0)
            try? await store.games.insert(game, files: [])
        }
        await model.refresh()
        log("library demo games=\(model.games.count)")
    }

    @MainActor
    static func scheduleInputScript(_ model: LibraryModel, _ actions: RelayActions) {
        let session = model.session
        let play = model.play
        for (time, step) in inputScript {
            Timer.scheduledTimer(withTimeInterval: time, repeats: false) { _ in
                Task { @MainActor in
                    // Scripted input is never a Hardcore interaction, including
                    // a restart scheduled after this debug script was installed.
                    if play.hardcoreEnabled { play.continueInCasual() }
                    let checksum = String(session.diagnostics.frameChecksum, radix: 16)
                    switch step {
                    case .press(let input):
                        session.press(input)
                        log("input press \(input) checksumBefore=0x\(checksum)")
                        try? await Task.sleep(for: .milliseconds(100))
                        session.release(input)
                    case .speed(let requested):
                        play.setSpeed(requested)
                        try? await Task.sleep(for: .milliseconds(1100))
                        log("play speed requested=\(requested.rawValue) actual=\(session.speed.rawValue) emuFPS=\(String(format: "%.1f", session.diagnostics.emulationFramesPerSecond)) audio=\(session.diagnostics.audioRunning) buffered=\(session.diagnostics.audioBufferedBytes)")
                    case .pause:
                        play.pause(); log("lifecycle pause state=\(session.state) checksum=0x\(checksum)")
                    case .resume:
                        play.resume(); log("lifecycle resume state=\(session.state) checksum=0x\(checksum)")
                    case .quickSave:
                        await play.quickSave()
                        log("play quicksave quick=\(play.quickStates.count) captureMs=\(String(format: "%.2f", session.diagnostics.lastStateCaptureMillis)) problem=\(play.problem?.headline ?? "none") checksum=0x\(checksum)")
                    case .quickLoad:
                        await play.quickLoad()
                        log("play quickload restoreMs=\(String(format: "%.2f", session.diagnostics.lastStateRestoreMillis)) problem=\(play.problem?.headline ?? "none") checksumBefore=0x\(checksum) checksumAfter=0x\(String(session.frameSource?.sampledChecksum() ?? 0, radix: 16))")
                    case .saveNow:
                        await play.saveNow()
                        log("play savenow manual=\(play.manualStates.count) problem=\(play.problem?.headline ?? "none")")
                    case .rewind:
                        let stats = session.rewindStatistics
                        play.beginRewind()
                        log("play rewind begin rewinding=\(play.isRewinding) entries=\(stats?.entries ?? 0) bytes=\(stats?.bytes ?? 0) checksumBefore=0x\(checksum)")
                        try? await Task.sleep(for: .milliseconds(1500))
                        let during = String(session.frameSource?.sampledChecksum() ?? 0, radix: 16)
                        play.endRewind()
                        log("play rewind end state=\(session.state) checksumDuring=0x\(during)")
                    case .fastForward:
                        play.setFastForwardHeld(true)
                        try? await Task.sleep(for: .milliseconds(1500))
                        log("play fastforward speed=\(session.speed) emuFPS=\(String(format: "%.1f", session.diagnostics.emulationFramesPerSecond)) audio=\(session.diagnostics.audioRunning)")
                        play.setFastForwardHeld(false)
                    case .menu:
                        play.pause(); log("play menu paused=\(play.isPaused) state=\(session.state)")
                    case .saves:
                        play.pause(); actions.openPlaySaves(); log("play saves presented=\(actions.playSavesPresented)")
                    case .display:
                        play.display = DisplayOptions(scaling: .fit, filter: .sharp); log("play display \(play.display)")
                    case .touch:
                        #if os(iOS)
                        play.toggleTouchControls(); log("play touch hidden=\(play.touchControlsHidden)")
                        #endif
                    case .sync:
                        await model.sync.requestSync()
                        try? await Task.sleep(for: .milliseconds(1500))
                        await model.refresh()
                        logSync(model, "sync")
                    case .download:
                        if let game = model.games.first(where: { !model.hasContent($0.id) }) {
                            await model.downloadAndPlay(game.id)
                            log("play download game=\(game.id) content=\(model.hasContent(game.id)) state=\(session.state) message=\(model.playMessage?.headline ?? "none")")
                        } else { log("play download none") }
                    case .keepRemote, .keepLocal:
                        if let id = model.sync.status.conflictGameIDs.first, let conflict = await model.conflict(for: id) {
                            let mine = model.environment.identity?.installationID
                            let head = conflict.heads.first { (step.isKeepRemote ? $0.installationID != mine : $0.installationID == mine) } ?? conflict.heads[0]
                            let ok = await model.resolveConflict(gameID: id, keeping: head.id)
                            log("sync resolve game=\(id) keep=\(head.deviceKind.rawValue) ok=\(ok) conflicts=\(model.sync.status.conflictGameIDs.count)")
                        } else { log("sync resolve none") }
                    case .deleteEverywhere:
                        if let game = model.games.first { await model.delete(game.id); log("library deleteEverywhere game=\(game.id) games=\(model.games.count)") }
                    case .removeDownload:
                        if let game = model.games.first(where: { model.hasContent($0.id) }) { await model.removeDownload(game.id); log("library removeDownload game=\(game.id) content=\(model.hasContent(game.id))") }
                    case .toggleSync:
                        await model.sync.setEnabled(!model.sync.status.isEnabled)
                        logSync(model, "toggle")
                    case .background:
                        await play.sceneDidEnterBackground()
                        log("lifecycle background paused=\(play.isPaused) state=\(session.state) autosaveFailed=\(play.lastAutoSaveFailed)")
                        try? await Task.sleep(for: .milliseconds(1000))
                        play.sceneDidBecomeActive()
                        log("lifecycle active backgroundDuration=\(String(format: "%.1f", play.backgroundDuration))")
                    }
                }
            }
        }
    }

    /// Real-CloudKit evidence: what the server actually holds (metadata only).
    @MainActor
    static func probeCloudIfRequested() async {
        #if DEBUG
        guard cloudProbe, let container = CloudKitEntitlements.containerIdentifier ?? cloudContainerFallback else { return }
        log("cloud probe \(await CloudKitDiagnostics.probe(containerIdentifier: container))")
        #endif
    }

    #if DEBUG
    private static var cloudContainerFallback: String? {
        #if RELAY_CLOUDKIT
        return CloudKitEntitlements.expectedContainer
        #else
        return nil
        #endif
    }
    #endif

    @MainActor
    static func logSync(_ model: LibraryModel, _ tag: String) {
        let s = model.sync.status
        log("sync \(tag) available=\(model.sync.isAvailable) enabled=\(s.isEnabled) account=\(s.account.rawValue) active=\(s.isActive) pending=\(s.pendingCount) lastPush=\(s.lastPushAt.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "-") lastPull=\(s.lastPullAt.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "-") conflicts=\(s.conflictGameIDs.count) cloudOnly=\(s.cloudOnlyCount) problem=\(s.problem.map { "\($0)" } ?? "none") gameFiles=\(s.gameFilesEnabled) recent=[\(s.recentProblems.joined(separator: " "))] detail=\(s.transportDetail)")
    }

    @MainActor
    static func captureScreenshots(_ session: EmulationSession, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let source = session.frameSource {
            let ok = writeFramePNG(source, to: dir.appendingPathComponent("frame.png"))
            log("screenshot frame.png written=\(ok)")
        }
        #if os(macOS)
        logWindowChrome("playing")
        // Render the window's view hierarchy (AppKit-backed SwiftUI); the Metal layer is
        // covered separately by frame.png.
        // SwiftUI sheets are separate NSWindows. Picking the first visible window can
        // select a 33-point menu-bar helper instead of the actual product surface.
        let windows = visibleWindows.sorted {
            $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
        }
        for (index, window) in windows.enumerated() {
            let name = index == 0 ? "window.png" : "window-\(index + 1).png"
            let url = dir.appendingPathComponent(name)
            if let size = writeWindowPNG(window, to: url) {
                log("screenshot \(name) written=true size=\(size.width)x\(size.height)")
            }
        }
        #endif
    }

    /// What AppKit itself is showing around the SwiftUI content. The toolbar is
    /// window chrome, so it survives an opacity change and has to be checked
    /// directly; the first responder says who would receive a key press.
    @MainActor
    static func logWindowChrome(_ moment: String) {
        #if os(macOS)
        guard let window = largestVisibleWindow else { return }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        log("window chrome \(moment) toolbar=\(window.toolbar?.isVisible == true ? "visible" : "hidden") titlebarHeight=\(Int(window.frame.height - window.contentLayoutRect.height)) firstResponder=\(responder)")
        #endif
    }

    #if os(macOS)
    @MainActor
    private static var visibleWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
    }

    @MainActor
    private static var largestVisibleWindow: NSWindow? {
        visibleWindows
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    @MainActor
    private static func writeWindowPNG(_ window: NSWindow, to url: URL) -> (width: Int, height: Int)? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage, writePNG(image, to: url) else { return nil }
        return (image.width, image.height)
    }
    #endif

    static func writeFramePNG(_ source: VideoFrameSource, to url: URL) -> Bool {
        var image: CGImage?
        source.withCurrentFrame { pointer, d in
            let data = Data(bytes: pointer, count: d.bytesPerRow * d.height)
            guard let provider = CGDataProvider(data: data as CFData) else { return }
            image = CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: d.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image else { return false }
        return writePNG(image, to: url)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Resident memory of this process, in MB (mach task info; 0 when unavailable).
    static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    @MainActor
    static func logDiagnostics(_ session: EmulationSession, play: PlayModel? = nil) {
        guard diagnosticsLog else { return }
        let d = session.diagnostics
        var line = String(format: "RELAY-DIAG state=%@ core=%@ emuFPS=%.1f presentedFPS=%.0f audio=%@ rate=%.0f audioBuffered=%d frameChecksum=0x%08x controller=%@ speed=%@ rewind=%d/%dB stateMs=%.2f/%.2f residentMB=%.0f rewindSeconds=%.1f",
                          "\(session.state)", session.core?.id.rawValue ?? "-", d.emulationFramesPerSecond, d.presentedFramesPerSecond,
                          d.audioRunning ? "on" : "off", d.audioSampleRate, d.audioBufferedBytes, d.frameChecksum, d.controllerName ?? "none",
                          d.speed.rawValue, d.rewindEntries, d.rewindBytes, d.lastStateCaptureMillis, d.lastStateRestoreMillis,
                          residentMegabytes(), d.rewindRetainedSeconds)
        #if DEBUG
        if arguments.contains("--relay-skins-share-qualification") {
            line += String(format: " qualTime=%.3f sharing=%@", Date().timeIntervalSince1970,
                           play?.sharingDiagnosticState ?? "unknown")
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            line += " audioCategory=\(audioSession.category.rawValue) audioOptions=\(audioSession.categoryOptions.rawValue) outputVolume=\(audioSession.outputVolume) outputPorts=\(audioSession.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))"
            #endif
        }
        #endif
        print(line)
        fflush(stdout)
        appendToDiagnosticsFile(line)
    }
}
