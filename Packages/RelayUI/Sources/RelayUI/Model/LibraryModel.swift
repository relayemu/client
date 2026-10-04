// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryModel.swift
//  RelayUI
//
//  The observable state behind every screen: games, metadata, play history,
//  continuity projection (Continue across devices, cloud-only content,
//  Two versions). All database, hashing and image work happens in the library
//  layer off the main actor; this class only awaits results and publishes
//  value snapshots, so SwiftUI bodies never touch the store.

import Foundation
import Observation
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayDesignSystem
import RelaySync
import RelayEntitlements

@MainActor
@Observable
public final class LibraryModel {
    // MARK: Snapshot state

    public private(set) var games: [Game] = []
    public private(set) var metadata: [GameID: GameMetadata] = [:]
    /// The player's own covers present on this device (they win over any other artwork).
    public private(set) var customCoverLocations: [GameID: ContentLocation] = [:]
    public private(set) var history: [GameID: PlayHistoryEntry] = [:]
    public private(set) var systemCounts: [SystemID: Int] = [:]
    /// Whether the game's content is on this device (false: in iCloud or on another device).
    public private(set) var contentPresence: [GameID: Bool] = [:]
    public private(set) var isReady = false
    public private(set) var loadError: ProductMessage?
    /// The underlying failure behind `loadError`, kept for Diagnostics and device
    /// logs. The player sees `loadError`; this is the technical detail the spec
    /// asks to keep separately (§37, §38) and never appears in the ordinary UX.
    public private(set) var loadErrorDetail: String?

    // MARK: Import state

    public enum ImportProgress: Equatable, Sendable {
        case running(done: Int, total: Int)
        case summary(added: Int, duplicates: Int, problems: Int)
    }

    public private(set) var importProgress: ImportProgress?
    public private(set) var problems: [ProductMessage] = []
    /// Game that receives the one-time "Open it. Relay saves as you go." hint (UX §4.3).
    public private(set) var firstImportHintGameID: GameID?

    // MARK: Play state

    public private(set) var playingGame: Game?
    public private(set) var playMessage: ProductMessage?
    private var currentSession: PlaySession?
    public let play: PlayModel

    public let environment: LibraryEnvironment
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults
    private var summaryTask: Task<Void, Never>?

    // MARK: Cover state

    /// Settings ▸ Library ▸ Download Covers (on by default, per device).
    public internal(set) var downloadCovers: Bool
    let coverSetting: CoverDownloadSetting
    var coverQueue: CoverQueue?

    public init(environment: LibraryEnvironment, now: @escaping @Sendable () -> Date = { Date() }, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.now = now
        self.defaults = defaults
        coverSetting = CoverDownloadSetting(defaults: defaults)
        downloadCovers = coverSetting.isOn
        let play = PlayModel(environment: environment, preferences: PlayPreferences(defaults: defaults), now: now)
        self.play = play
        environment.relayPro.entitlementDidChange = { [weak play] state in
            play?.entitlementDidChange(state)
        }
    }

    public var session: EmulationSession { environment.session }
    public var deviceKind: DeviceKind { environment.deviceKind }
    public var sync: SyncModel { environment.sync }
    private var store: (any LibraryStore)? { environment.store }

    // MARK: Loading

    public func load() async {
        do {
            try await environment.open()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
            return
        }
        await refresh()
        isReady = true
        startMetadataBackfill()
        startCoverDownloads()
    }

    /// Matches the existing library once per metadata-provider revision, in the
    /// background and held during gameplay; titles refresh when anything matched.
    private func startMetadataBackfill() {
        let provider = environment.metadataProvider
        guard metadataBackfill == nil, let store, let revision = provider.revision else { return }
        let applier = MetadataApplier(store: store, location: environment.location, provider: provider,
                                      artworkStore: environment.artworkStore)
        let backfill = TitleBackfill(applier: applier, store: store, gate: environment.backgroundActivity)
        let marker = environment.location.metadataBackfillMarkerURL
        metadataBackfill = Task(priority: .background) { [weak self] in
            guard let report = await backfill.runOnce(revision: "\(provider.id)@\(revision)", marker: marker),
                  report.matched > 0 else { return }
            await self?.refresh()
        }
    }

    /// The running (or finished) backfill; one per model, so a repeated `load()` never starts a second pass.
    private var metadataBackfill: Task<Void, Never>?

    /// Gameplay pauses background library work and tells sync which game is running.
    private func setGameplay(active id: GameID?) async {
        await environment.backgroundActivity.setPaused(id != nil)
        await sync.gameplay(active: id)
    }

    public func refresh() async {
        guard let store else { return }
        do {
            async let games = store.games.allGames()
            async let history = store.playHistory.recentlyPlayed(limit: 200)
            async let counts = store.games.gameCountsBySystem()
            let (loadedGames, loadedHistory, loadedCounts) = try await (games, history, counts)
            let loadedCustomCovers = try await loadCustomCoverLocations(from: store)
            var loadedMetadata: [GameID: GameMetadata] = [:]
            var presence: [GameID: Bool] = [:]
            for game in loadedGames {
                if let m = try await store.games.metadata(for: game.id) { loadedMetadata[game.id] = m }
                presence[game.id] = try await store.games.files(for: game.id).contains { $0.role == .primary }
            }
            self.games = loadedGames
            self.history = Dictionary(uniqueKeysWithValues: loadedHistory.map { ($0.gameID, $0) })
            self.systemCounts = loadedCounts
            self.metadata = loadedMetadata
            self.customCoverLocations = loadedCustomCovers
            self.contentPresence = presence
            loadError = nil
            loadErrorDetail = nil
            await sync.updateLibrary(games: loadedGames, contentPresence: presence)
            scheduleCoverDownloads()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
        }
    }

    // MARK: Derived shelves (Home order is fixed: UX §4.1)

    public var isEmpty: Bool { games.isEmpty }

    public func game(_ id: GameID) -> Game? { games.first { $0.id == id } }

    public func hasContent(_ id: GameID) -> Bool { contentPresence[id] ?? false }

    /// Games with progress on any device, latest session first (max 12).
    public var continuePlaying: [Game] {
        Array(games.filter { history[$0.id] != nil }
            .sorted { history[$0.id]!.lastPlayedAt > history[$1.id]!.lastPlayedAt }
            .prefix(12))
    }

    /// Recently played excluding the first three Continue items (max 20).
    public var recentlyPlayed: [Game] {
        let excluded = Set(continuePlaying.prefix(3).map(\.id))
        return Array(games.filter { history[$0.id] != nil && !excluded.contains($0.id) }
            .sorted { history[$0.id]!.lastPlayedAt > history[$1.id]!.lastPlayedAt }
            .prefix(20))
    }

    /// Last 20 imports by library creation time (never file-system dates).
    public var recentlyAdded: [Game] {
        Array(games.sorted { ($0.addedAt, $1.id.description) > ($1.addedAt, $0.id.description) }.prefix(20))
    }

    public var favorites: [Game] { games.filter(\.isFavorite).sorted(by: Self.byTitle) }

    public struct SystemSummary: Identifiable, Sendable {
        public let id: SystemID
        public let name: String
        public let count: Int
        public let recent: [Game]
    }

    /// Systems with at least one game, ordered by count then name.
    public var systems: [SystemSummary] {
        systemCounts.map { id, count in
            let recent = Array(games.filter { $0.systemID == id }
                .sorted { ($0.addedAt, $1.id.description) > ($1.addedAt, $0.id.description) }.prefix(3))
            return SystemSummary(id: id, name: Formatting.systemName(id), count: count, recent: recent)
        }
        .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    public func games(in system: SystemID) -> [Game] { games.filter { $0.systemID == system }.sorted(by: Self.byTitle) }

    static func byTitle(_ a: Game, _ b: Game) -> Bool {
        let c = a.title.localizedCaseInsensitiveCompare(b.title)
        return c == .orderedSame ? a.id.description < b.id.description : c == .orderedAscending
    }

    public func isNew(_ game: Game) -> Bool { now().timeIntervalSince(game.addedAt) < 48 * 3600 }

    // MARK: Continuity projection (CONTINUITY_UX §4–§6)

    /// Status line under a Continue card or in Game Detail: "Played on iPad · 2 h ago", with a
    /// cloud suffix only when something is worth saying (Up to date is silence).
    public func statusLine(for game: Game) -> String {
        var parts: [String] = []
        if let entry = history[game.id] {
            parts.append(Formatting.playedStatus(session: entry.latestSession, localInstallation: environment.identity?.installationID,
                                                 thisDevice: deviceKind, now: now()))
        }
        switch sync.gameStatus(game.id) {
        case .localOnly: if sync.isAvailable, sync.status.isEnabled == false { parts.append(Formatting.localOnly(deviceKind)) }
        case .upToDate: break
        case .pending: parts.append(L("Not synced yet"))
        case .cloudOnly(let size): parts.append(sync.selectedProvider == .relaySync ? L("In Relay Sync") : L("In iCloud")); parts.append(Formatting.bytes(size))
        case .downloading(let p): parts.append(L("Downloading · \(Int(p * 100)) %"))
        case .onAnotherDevice: parts.append(history[game.id] == nil ? L("On another device") : Formatting.notOnThisDevice(deviceKind))
        case .conflict: parts.append(L("Two versions"))
        case .failed: parts.append(L("Not synced yet"))
        }
        return parts.joined(separator: " · ")
    }

    /// Symbol for the status line (never colour alone).
    public func statusSymbol(for game: Game) -> RelaySymbol {
        switch sync.gameStatus(game.id) {
        case .localOnly: return Formatting.deviceSymbol(deviceKind)
        case .upToDate: return history[game.id].map { Self.originSymbol($0.latestSession, local: environment.identity?.installationID, thisDevice: deviceKind) } ?? Formatting.deviceSymbol(deviceKind)
        case .pending, .failed: return .notSynced
        case .cloudOnly: return .inCloud
        case .downloading: return .download
        case .onAnotherDevice: return history[game.id].map { Self.originSymbol($0.latestSession, local: environment.identity?.installationID, thisDevice: deviceKind) } ?? .deviceUnknown
        case .conflict: return .conflict
        }
    }

    private static func originSymbol(_ session: PlaySession, local: InstallationID?, thisDevice: DeviceKind) -> RelaySymbol {
        let isLocal = session.origin == .local || (local != nil && session.installationID == local)
        return Formatting.deviceSymbol(isLocal ? thisDevice : session.deviceKind)
    }

    /// The primary action a game offers right now.
    public enum PrimaryAction: Equatable, Sendable {
        case play, `continue`, download(size: Int64), review, howToAdd, downloading(Double)
    }

    public func primaryAction(for game: Game) -> PrimaryAction {
        if sync.isInConflict(game.id) { return .review }
        switch sync.gameStatus(game.id) {
        case .downloading(let p): return .downloading(p)
        case .cloudOnly(let size): return .download(size: size)
        case .onAnotherDevice: return .howToAdd
        default: break
        }
        if !hasContent(game.id) { return .howToAdd }
        return history[game.id] == nil ? .play : .continue
    }

    // MARK: Card models

    public func cardModel(for game: Game, meta: Bool = false) -> GameCardModel {
        let badge: GameCardModel.Badge?
        switch sync.gameStatus(game.id) {
        case .cloudOnly: badge = .inCloud
        case .downloading(let p): badge = .downloading(p)
        default: badge = isNew(game) ? .new : nil
        }
        return GameCardModel(id: game.id, title: game.title, system: game.systemID,
                             systemName: Formatting.systemName(game.systemID),
                             hue: SystemAccent.hue(for: game.systemID),
                             meta: meta ? history[game.id].map { Formatting.relative(Formatting.lastPlayedDate(session: $0.latestSession), now: now()) } : nil,
                             badge: badge,
                             artworkLoader: artworkLoader(for: game), artworkRevision: artworkRevision(for: game))
    }

    public func continueModel(for game: Game) -> ContinueCardModel {
        let capsule: ContinueCardModel.Capsule
        switch primaryAction(for: game) {
        case .play, .continue: capsule = .continue
        case .download: capsule = .download
        case .review: capsule = .review
        case .howToAdd: capsule = .howToAdd
        case .downloading(let p): capsule = .downloading(p)
        }
        let session = history[game.id]?.latestSession
        let isRemote = session.map { !($0.origin == .local || (environment.identity != nil && $0.installationID == environment.identity?.installationID)) } ?? false
        return ContinueCardModel(id: game.id, title: game.title,
                                 statusLine: statusLine(for: game),
                                 hue: SystemAccent.hue(for: game.systemID), system: game.systemID,
                                 systemName: Formatting.systemName(game.systemID),
                                 screenshotLoader: screenshotLoader(for: game), artworkLoader: artworkLoader(for: game),
                                 capsule: capsule, deviceSymbol: isRemote ? Formatting.deviceSymbol(session!.deviceKind) : nil,
                                 // Progress that reached this device from another one is the
                                 // product's whole point: the card says so once, then stops.
                                 arrived: isRemote, artworkRevision: continueArtworkRevision(for: game))
    }

    public func tileModel(for summary: SystemSummary) -> SystemTileModel {
        SystemTileModel(id: summary.id, name: summary.name, gameCount: summary.count, hue: SystemAccent.hue(for: summary.id),
                        recentArtwork: summary.recent.map { cardModel(for: $0).artwork })
    }

    /// The player's cover, else the downloaded or provider cover, else none (placeholder).
    public func artworkLoader(for game: Game) -> ArtworkLoader? {
        guard let location = customCoverLocations[game.id] ?? metadata[game.id]?.artworkLocation else { return nil }
        let store = environment.artworkStore
        return { size in await store.image(at: location, maxPixelSize: size) }
    }

    public func screenshotLoader(for game: Game) -> ArtworkLoader? {
        guard let location = history[game.id]?.latestSession.screenshotLocation else { return nil }
        let store = environment.artworkStore
        return { size in await store.image(at: location, maxPixelSize: size) }
    }

    private func continueArtworkRevision(for game: Game) -> String? {
        if let session = history[game.id]?.latestSession, let location = session.screenshotLocation {
            // last.png is overwritten at exit. Session start / lastPlayedAt can
            // reach Home before that write; the recorded end follows persistence.
            let ended = session.endedAt.map { String($0.timeIntervalSince1970) } ?? "running"
            return "screenshot:\(session.id):\(ended):\(location)"
        }
        return artworkRevision(for: game)
    }

    /// Identity of the cover a card shows; it changes whenever those bytes do
    /// (a cover downloaded, replaced or removed), so a visible card reloads.
    func artworkRevision(for game: Game) -> String? {
        // A custom cover's file is named by its fingerprint: the location is its identity.
        if let custom = customCoverLocations[game.id] { return "custom:\(custom)" }
        guard let metadata = metadata[game.id], let location = metadata.artworkLocation else { return nil }
        return "artwork:\(metadata.matchedAt.timeIntervalSince1970):\(location)"
    }

    // MARK: Search

    public func search(_ text: String) async -> [Game] {
        guard let store, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? await store.games.games(matching: GameQuery(text: text, sort: .title, limit: 200))) ?? []
    }

    // MARK: Import

    public func importFiles(_ urls: [URL]) async {
        _ = await importFilesReporting(urls)
    }

    /// Transfer shares every normal import side effect and receives its report.
    func importFilesReporting(_ urls: [URL]) async -> ImportReport {
        guard let importer = environment.importer, !urls.isEmpty else { return ImportReport() }
        summaryTask?.cancel()
        importProgress = .running(done: 0, total: urls.count)
        let deviceKind = deviceKind
        let report = await importer.importFiles(urls) { done, total, _ in
            Task { @MainActor [weak self] in self?.importProgress = .running(done: done, total: total) }
        }
        let wasEmpty = games.isEmpty
        await refresh()
        let newProblems = report.outcomes.compactMap { ProductMessage.forImport($0, deviceKind: deviceKind) }
        problems.append(contentsOf: newProblems)
        if wasEmpty, let first = report.addedGames.first, !defaults.bool(forKey: Self.hintShownKey) {
            firstImportHintGameID = first.id
        }
        importProgress = .summary(added: report.addedGames.count, duplicates: report.duplicateCount, problems: newProblems.count)
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.importProgress = nil
        }
        await sync.flushSoon()
        // Game-file sync (Free, opt-in): offer the new content to iCloud in
        // the background. Importing never waits for an upload, exactly as launching never
        // waits for a fetch (owner policy, 2026-09-03).
        if sync.status.gameFilesEnabled {
            let ids = report.addedGames.map(\.id)
            let sync = self.sync
            Task { for id in ids { await sync.upload(gameID: id) } }
        }
        return report
    }

    private static let hintShownKey = "relay.firstImportHintShown"

    public func dismissProblem(_ message: ProductMessage) {
        problems.removeAll { $0 == message }
    }

    public func dismissAllProblems() { problems.removeAll() }

    // MARK: Editing

    public func toggleFavorite(_ id: GameID) async {
        guard let store, var game = game(id) else { return }
        game.isFavorite.toggle()
        game.updatedAt = now()
        do {
            try await store.games.update(game)
            if let index = games.firstIndex(where: { $0.id == id }) { games[index] = game }
            await sync.flushSoon()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
        }
    }

    /// Delete from Library (everywhere): the game, its progress, and — through the
    /// tombstone — its presence on every device and in iCloud.
    public func delete(_ id: GameID) async {
        guard let importer = environment.importer else { return }
        do {
            try await importer.removeGame(id: id)
            await sync.refreshConflicts()
            await refresh()
            await sync.flushSoon()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
        }
    }

    /// Remove Download: the file leaves this device; the game, its saves and iCloud stay.
    public func removeDownload(_ id: GameID) async {
        guard let ingestion = environment.ingestion else { return }
        do {
            try await ingestion.removeLocalContent(gameID: id)
            await refresh()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
        }
    }

    /// Whether a game is synced (so deletion offers "Delete from this iPhone" vs "Delete Everywhere").
    public func isSynced(_ id: GameID) -> Bool {
        guard sync.isAvailable, sync.status.isEnabled else { return false }
        switch sync.gameStatus(id) {
        case .localOnly: return false
        default: return true
        }
    }

    /// Whether the game's content exists in iCloud (Remove Download keeps it available).
    public func hasCloudContent(_ id: GameID) -> Bool {
        guard let game = game(id) else { return false }
        return sync.cloudContent.contains(game.contentFingerprint)
    }

    public func files(for id: GameID) async -> [GameFile] {
        (try? await store?.games.files(for: id)) ?? []
    }

    // MARK: Two versions

    public func conflict(for id: GameID) async -> BatteryConflict? {
        await sync.conflict(for: id)
    }

    /// Keep one version; the other stays in Previous versions.
    public func resolveConflict(gameID: GameID, keeping revisionID: BatteryRevisionID) async -> Bool {
        do {
            try await sync.resolve(gameID: gameID, keeping: revisionID)
            await refresh()
            return true
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
            return false
        }
    }

    /// Revisions that are not the current progress (Previous versions in Saves).
    public func previousVersions(for id: GameID) async -> [BatteryRevision] {
        guard let battery = environment.batterySaves, let store else { return [] }
        let active = try? await store.saves.activeBatteryRevisionID(for: id)
        let all = (try? await battery.revisions(for: id)) ?? []
        return all.filter { $0.id != active }
    }

    public func restore(_ revision: BatteryRevision) async {
        guard let battery = environment.batterySaves, playingGame?.id != revision.gameID else { return }
        do {
            _ = try await battery.restore(revision, now: now())
            await sync.flushSoon()
            await refresh()
        } catch {
            loadError = .forStorage(error)
            loadErrorDetail = String(describing: error)
        }
    }

    public func revisionScreenshotLoader(for revision: BatteryRevision) -> ArtworkLoader? {
        guard let location = revision.screenshotLocation else { return nil }
        let store = environment.artworkStore
        return { size in await store.image(at: location, maxPixelSize: size) }
    }

    // MARK: Play

    public var isPlaying: Bool { playingGame != nil }
    public var canStartGameplay: Bool {
        !environment.gameplayRequiresPro
            || RelayAccessPolicy(entitlement: environment.relayPro.entitlement).allows(.macGameplay)
    }

    public func play(_ id: GameID) async {
        guard let store, let game = game(id), playingGame == nil else { return }
        playMessage = nil
        if sync.isInConflict(id) {
            // Two versions: never continue silently from one of them (CONTINUITY_UX §8).
            playMessage = await twoVersionsMessage(for: game)
            return
        }
        // Content elsewhere: offer the download or explain.
        if !hasContent(id) {
            switch sync.gameStatus(id) {
            case .cloudOnly(let size):
                playMessage = .cloudOnly(gameID: id, title: game.title, size: size, deviceKind: deviceKind)
            default:
                playMessage = .onAnotherDevice(title: game.title, deviceKind: deviceKind)
            }
            return
        }
        guard canStartGameplay else {
            playMessage = .relayProRequiredOnMac(title: game.title)
            return
        }
        // Local-first (owner policy, 2026-09-03): a game that is playable here starts
        // now. Relay never begins a fetch to launch a game and never waits for one;
        // it synchronizes on foreground and idle instead. When a fetch happens to be
        // in flight already, Continue pauses for an imperceptible grace so a result
        // that is milliseconds away is used, then re-checks the known conflict state.
        // A divergent revision that lands after launch is preserved by the revision
        // graph and surfaces as Two versions at the next safe point, never as a loss.
        if history[id] != nil, sync.status.isFetching {
            await sync.graceForInFlightFetch()
            if sync.isInConflict(id) { playMessage = await twoVersionsMessage(for: game); return }
        }
        do {
            let resolver = GameLaunchResolver(store: store, location: environment.location, availableCores: environment.cores)
            let launch = try await resolver.resolve(gameID: id)
            var playSession = PlaySession(gameID: id, coreID: launch.core.id, startedAt: now(),
                                          installationID: environment.identity?.installationID, deviceKind: deviceKind,
                                          generation: launch.game.generation)
            try await store.playHistory.record(playSession)
            await setGameplay(active: id)
            do {
                try await play.start(launch: launch)
            } catch {
                playSession = playSession.ended(at: now())
                try? await store.playHistory.record(playSession)
                await setGameplay(active: nil)
                throw error
            }
            currentSession = playSession
            playingGame = game
            if firstImportHintGameID == id {
                firstImportHintGameID = nil
                defaults.set(true, forKey: Self.hintShownKey)
            }
        } catch {
            playMessage = .forLaunch(error, title: game.title)
        }
    }

    func twoVersionsMessage(for game: Game) async -> ProductMessage {
        let conflict = await sync.conflict(for: game.id)
        let kinds = conflict?.heads.map(\.deviceKind) ?? []
        return .twoVersions(gameID: game.id, title: game.title, deviceA: kinds.first ?? deviceKind, deviceB: kinds.dropFirst().first ?? .unknown)
    }

    /// Download & Play: fetch, verify, install, then launch.
    public func downloadAndPlay(_ id: GameID) async {
        await download(id, playAfterDownload: true)
    }

    /// Content recovery is Free, including on Mac. The caller chooses whether
    /// a successful download continues into the separately gated play boundary.
    public func download(_ id: GameID) async {
        await download(id, playAfterDownload: false)
    }

    private func download(_ id: GameID, playAfterDownload: Bool) async {
        guard let game = game(id), let ingestion = environment.ingestion, playingGame == nil else { return }
        playMessage = nil
        do {
            _ = try await sync.download(gameID: id, ingestion: ingestion)
            await refresh()
            if playAfterDownload { await play(id) }
        } catch {
            playMessage = .downloadFailed(error, title: game.title, deviceKind: deviceKind)
            await refresh()
        }
    }

    public func pause() { play.pause() }
    public func resume() { play.resume() }

    /// Exits the game: progress is written first (battery save, Auto Resume,
    /// Continue screenshot), then the session record — with background time
    /// excluded — so Home is already updated when it reappears (§9.2, §17.2);
    /// then the sync layer is nudged so the session reaches other devices.
    public func stop() async {
        let screenshot = await play.finish()
        if let store, var ended = currentSession {
            ended = ended.ended(at: now())
            ended.pausedDuration = play.backgroundDuration
            ended.screenshotLocation = screenshot ?? ended.screenshotLocation
            do { try await store.playHistory.record(ended) } catch { loadError = .forStorage(error); loadErrorDetail = String(describing: error) }
        }
        currentSession = nil
        await setGameplay(active: nil)
        await sync.flushSoon()
        await refresh()
        playingGame = nil
    }

    /// Launches a game and restores a specific state (Saves browser in Game Detail).
    public func play(_ id: GameID, restoring state: SaveState) async {
        await play(id)
        guard isPlaying else { return }
        // An explicit state resume is Casual, just like Auto Resume.
        if play.hardcoreEnabled { play.continueInCasual() }
        await play.load(state)
    }

    /// Save states of a game for the library-side Saves browser (never Auto Resume).
    public func browserStates(for id: GameID) async -> (quick: [SaveState], manual: [SaveState]) {
        (try? await environment.saveStates?.browserStates(for: id, now: now())) ?? ([], [])
    }

    public func deleteState(_ state: SaveState) async {
        do {
            try await environment.saveStates?.delete(state)
            await sync.flushSoon()
        } catch { loadError = .forStorage(error); loadErrorDetail = String(describing: error) }
    }

    /// Battery save summary for Game Detail ("In-game save · 2 h ago").
    public func batterySave(for id: GameID) async -> Save? {
        try? await environment.batterySaves?.currentSave(for: id)
    }

    public func stateThumbnailLoader(for state: SaveState) -> ArtworkLoader? {
        guard let location = state.screenshotLocation else { return nil }
        let store = environment.artworkStore
        return { size in await store.image(at: location, maxPixelSize: size) }
    }

    public func clearPlayMessage() { playMessage = nil }
}
