// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SimulatedDevice.swift — one Relay installation for the deterministic
//  multi-device harness: its own library directory and SQLite store, managers,
//  coordinator and a transport into a shared InMemoryCloud. Nothing moves
//  between devices until a test pumps a transport.

import Foundation
import XCTest
import RelayDomain
import RelayLibrary
import RelayPersistence
@testable import RelaySync

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

let fakeCore = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "1", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])
let otherCore = EmulatorCoreDescriptor(id: "fake", name: "Fake", version: "2", license: "MIT", supportedSystems: [.gameBoyAdvance], capabilities: [.saveStates])

/// Synthetic GBA content that passes ingestion (extension-based system identification).
func gbaBytes(seed: UInt8, size: Int = 4096) -> Data {
    var bytes = [UInt8](repeating: seed, count: size)
    bytes[0] = 0x2E; bytes[1] = 0x00; bytes[2] = 0x00; bytes[3] = 0xEA
    return Data(bytes)
}

final class SimulatedDevice: @unchecked Sendable {
    let name: String
    let kind: DeviceKind
    let root: URL
    let location: LibraryLocation
    let store: SQLiteLibraryStore
    let identity: SyncIdentity
    let batterySaves: BatterySaveManager
    let saveStates: SaveStateManager
    let ingestion: GameIngestion
    let coordinator: SyncCoordinator
    let transport: InMemoryCloudTransport
    let clock: TestClock
    let cloud: InMemoryCloud

    init(name: String, kind: DeviceKind, cloud: InMemoryCloud, clock: TestClock, root: URL? = nil,
         transport: InMemoryCloudTransport? = nil, capabilities: SyncCapabilities = .internalTesting) async throws {
        self.name = name
        self.kind = kind
        self.cloud = cloud
        self.clock = clock
        self.root = root ?? FileManager.default.temporaryDirectory.appending(path: "RelaySync-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: self.root)
        try location.createDirectories()
        store = try SQLiteLibraryStore.open(at: location.databaseURL, deviceKind: kind, clock: { clock.now })
        identity = try await store.syncStore.identity()
        batterySaves = BatterySaveManager(store: store, location: location, identity: identity)
        saveStates = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location), identity: identity)
        ingestion = GameIngestion(store: store, location: location, clock: { clock.now })
        self.transport = transport ?? cloud.connect(device: name)
        coordinator = SyncCoordinator(store: store, syncStore: store.syncStore, location: location, batterySaves: batterySaves,
                                      saveStates: saveStates, identity: identity, configuration: .init(capabilities: capabilities), clock: { clock.now })
    }

    func start() async { await coordinator.start(transport: transport) }

    /// Simulates a process restart: same library on disk, fresh store and coordinator, same transport state (cursor).
    func restart() async throws -> SimulatedDevice {
        await coordinator.stop()
        try store.close()
        let device = try await SimulatedDevice(name: name, kind: kind, cloud: cloud, clock: clock, root: root, transport: transport)
        await device.start()
        return device
    }

    func destroy() { try? store.close(); try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func sync() async throws -> Int { try await transport.pump() }

    // MARK: Library helpers

    @discardableResult
    func importGame(_ bytes: Data, title: String = "Game") async throws -> Game {
        let file = root.appending(path: "\(title.replacingOccurrences(of: " ", with: "_"))-\(UUID().uuidString.prefix(6)).gba")
        try bytes.write(to: file)
        let outcome = try await ingestion.ingestLocalFile(at: file, title: title)
        try? FileManager.default.removeItem(at: file)
        await coordinator.flushSoon()
        return outcome.game
    }

    func game(_ fingerprint: ContentFingerprint) async throws -> Game? { try await store.games.game(fingerprint: fingerprint) }

    func hasContent(_ game: Game) async throws -> Bool { !(try await store.games.files(for: game.id)).isEmpty }

    /// One play session: records the session, writes a battery snapshot (new revision when the bytes changed),
    /// an Auto Resume state paired with the head, and ends the session.
    @discardableResult
    func play(_ game: Game, battery: Data, seconds: TimeInterval = 60, autoState: Bool = true, core: EmulatorCoreDescriptor = fakeCore) async throws -> PlaySession {
        await coordinator.setGameplayActive(game.id)
        var session = PlaySession(gameID: game.id, coreID: core.id, startedAt: clock.now, installationID: identity.installationID, deviceKind: kind, generation: game.generation)
        try await store.playHistory.record(session)
        clock.advance(seconds)
        _ = try await batterySaves.snapshot(gameID: game.id, data: battery, now: clock.now)
        if autoState {
            let head = try await store.saves.activeBatteryRevisionID(for: game.id)
            _ = try await saveStates.create(kind: .auto, game: game, core: core, payload: Data("auto-\(battery.map { String($0) }.joined(separator: "."))".utf8),
                                            batteryRevisionID: head, now: clock.now)
        }
        session = session.ended(at: clock.now)
        try await store.playHistory.record(session)
        await coordinator.setGameplayActive(nil)
        await coordinator.flushSoon()
        return session
    }

    func currentBattery(_ game: Game) throws -> Data? {
        let url = location.url(for: try LibraryLocation.batterySaveLocation(gameID: game.id))
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    func heads(_ game: Game) async throws -> [BatteryRevision] { try await batterySaves.heads(for: game.id) }

    func history(_ game: Game) async throws -> PlayHistoryEntry? {
        try await store.playHistory.recentlyPlayed(limit: 50).first { $0.gameID == game.id }
    }

    func pendingCount() async throws -> Int { try await store.syncStore.journal.pendingCount() }

    var status: SyncStatus { get async { await coordinator.status } }
}
