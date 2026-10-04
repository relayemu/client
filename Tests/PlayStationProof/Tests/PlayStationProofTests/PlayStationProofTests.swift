// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelayVideo
import RelayPCSXAdapter
import RelaySync

final class PlayStationProofTests: XCTestCase {
    static var fixtures: URL {
        if let fixture = Bundle(for: Self.self).url(forResource: "relay-ps1-counter", withExtension: "cue") { return fixture.deletingLastPathComponent() }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("Tests/Fixtures/ROMs/relay-ps1-counter")
    }
    @MainActor
    final class Device {
        let root: URL, location: LibraryLocation, store: SQLiteLibraryStore
        let identity: SyncIdentity, battery: BatterySaveManager, states: SaveStateManager
        let transport: InMemoryCloudTransport, coordinator: SyncCoordinator
        let factory = PCSXDriverFactory()
        init(_ name: String, _ cloud: InMemoryCloud, installationID: UUID? = nil, startInMemory: Bool = true) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPS1-" + UUID().uuidString)
            location = LibraryLocation(rootURL: root); try location.createDirectories()
            store = try SQLiteLibraryStore.open(at: location.databaseURL, deviceKind: name == "a" ? .mac : .iPhone)
            if let installationID { try await store.syncStore.setMetaValue(installationID.uuidString.lowercased(), forKey: "installation_id") }
            identity = try await store.syncStore.identity()
            battery = BatterySaveManager(store: store, location: location, identity: identity)
            states = SaveStateManager(store: store, location: location, artworkStore: ArtworkStore(location: location), identity: identity)
            transport = cloud.connect(device: name)
            coordinator = SyncCoordinator(store: store, syncStore: store.syncStore, location: location,
                batterySaves: battery, saveStates: states, identity: identity, configuration: .init(capabilities: .internalTesting))
            if startInMemory { await coordinator.start(transport: transport) }
        }
        func close() { try? store.close(); try? FileManager.default.removeItem(at: root) }
        func importDisc() async throws -> Game {
            let report = await GameImporter(store: store, location: location).importFiles([
                PlayStationProofTests.fixtures.appendingPathComponent("relay-ps1-counter.cue"), PlayStationProofTests.fixtures.appendingPathComponent("relay-ps1-counter.bin")])
            return try XCTUnwrap(report.addedGames.first, "\(report)")
        }
        func launch(_ game: Game, audio: Bool = false) async throws -> EmulationSession {
            let launch = try await GameLaunchResolver(store: store, location: location, availableCores: factory.availableCores).resolve(gameID: game.id)
            try await battery.prepareForLaunch(gameID: game.id, romBaseName: launch.contentURL.deletingPathExtension().lastPathComponent)
            let session = EmulationSession(factory: factory, storage: EmulationStorage(
                batterySavesDirectory: battery.workingDirectory(for: game.id), saveStatesDirectory: location.saveStatesDirectory(forGame: game.id), firmwareDirectory: root.appendingPathComponent("Firmware")), rewindConfiguration: .disabled)
            try session.play(romURL: launch.contentURL, coreID: PCSXDriverFactory.coreID, systemID: .playStation, audio: audio)
            session.pause(); await coordinator.setGameplayActive(game.id)
            return session
        }
        func save(_ run: EmulationSession, game: Game) async throws {
            let shot = try XCTUnwrap(run.frameSource.flatMap(FrameCapture.image(from:)))
            _ = try ArtworkStore(location: location).storeScreenshot(shot, for: game.id)
            _ = try await battery.snapshot(gameID: game.id, data: run.batterySaveBytes())
            let head = try await store.saves.activeBatteryRevisionID(for: game.id)
            _ = try await states.create(kind: .auto, game: game, core: PCSXDriverFactory.descriptor,
                                       payload: run.captureState(), screenshot: shot, batteryRevisionID: head)
            let session = PlaySession(gameID: game.id, coreID: PCSXDriverFactory.coreID, startedAt: Date().addingTimeInterval(-30), installationID: identity.installationID, deviceKind: identity.deviceKind)
            try await store.playHistory.record(session.ended(at: Date()))
            run.stop(); await coordinator.setGameplayActive(nil); await coordinator.flushSoon()
        }
    }
    @MainActor
    func frames(_ run: EmulationSession, _ count: Int) {
        XCTAssertEqual(run.state, .paused)
        for _ in 0..<count { run.stateSerializer?.runSingleFrame() }
    }
    @MainActor
    func counter(_ run: EmulationSession) throws -> UInt8 {
        let bytes = try XCTUnwrap(run.batterySaveBytes())
        XCTAssertEqual(bytes.count, 262144)
        XCTAssertEqual(bytes[8320..<8324], Data("RELY".utf8))
        XCTAssertEqual(bytes[0..<2], Data("MC".utf8)); XCTAssertEqual(bytes[131072..<131074], Data("MC".utf8))
        return bytes[8324]
    }
    @MainActor
    func cross(_ run: EmulationSession) {
        run.press(.b); frames(run, 20); run.release(.b); frames(run, 20)
    }
    @MainActor
    func testManagedDiscLoadsFromLongAppleContainerPath() async throws {
        let device = try await Device("a", InMemoryCloud()); defer { device.close() }
        let game = try await device.importDisc()
        let resolved = try await GameLaunchResolver(store: device.store, location: device.location,
            availableCores: device.factory.availableCores).resolve(gameID: game.id)
        let parent = device.root.appendingPathComponent(String(repeating: "a", count: 100))
            .appendingPathComponent(String(repeating: "b", count: 100))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let copied = parent.appendingPathComponent("Playable")
        try FileManager.default.copyItem(at: resolved.contentURL.deletingLastPathComponent(), to: copied)
        let url = copied.appendingPathComponent("game.m3u")
        XCTAssertGreaterThan(url.path.utf8.count, 256)
        let run = EmulationSession(factory: device.factory, storage: EmulationStorage(
            batterySavesDirectory: device.root.appendingPathComponent("Cards"),
            saveStatesDirectory: device.root.appendingPathComponent("States"),
            firmwareDirectory: device.root.appendingPathComponent("Firmware")), rewindConfiguration: .disabled)
        defer { run.stop() }
        try run.play(romURL: url, coreID: PCSXDriverFactory.coreID, systemID: .playStation, audio: false)
        run.pause(); frames(run, 180); XCTAssertEqual(try counter(run), 1)
    }
    @MainActor
    func testRealCoreCardsManualStateInputAnalogAndFreshLaunch() async throws {
        let device = try await Device("a", InMemoryCloud()); defer { device.close() }
        let game = try await device.importDisc()
        let run = try await device.launch(game); defer { run.stop() }
        frames(run, 180); XCTAssertEqual(try counter(run), 1)
        cross(run); XCTAssertEqual(try counter(run), 2)
        let source = try XCTUnwrap(run.frameSource)
        XCTAssertEqual(source.frameDescriptor.aspectRatio, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertNotEqual(source.sampledChecksum(), 0)
        try run.setControllerKind(.dualShock); try run.setAnalogModeEnabled(true)
        run.move(.leftStickX, to: 0.5); frames(run, 120)
        var blue: UInt8 = 0
        source.withCurrentFrame { pixels, _ in blue = pixels.assumingMemoryBound(to: UInt8.self)[2] }
        XCTAssertEqual(Double(blue), 191, accuracy: 12)
        let state = try run.captureState()
        cross(run); XCTAssertEqual(try counter(run), 3)
        try run.setControllerKind(.digital); try run.restoreState(state)
        XCTAssertEqual(try counter(run), 2); XCTAssertEqual(run.controllerKind, .dualShock); XCTAssertTrue(run.analogModeEnabled)
        var broken = state; broken[100] ^= 1
        XCTAssertThrowsError(try run.restoreState(broken)); XCTAssertEqual(try counter(run), 2)
        try await device.save(run, game: game)
        let fresh = try await device.launch(game); defer { fresh.stop() }
        frames(fresh, 180); XCTAssertEqual(try counter(fresh), 3, "boots from native card progress")
        try fresh.restoreState(state); XCTAssertEqual(try counter(fresh), 2, "same compatibility class restores across instances")
    }
    @MainActor
    func testImmediateAutoResumeAcceptsInputWithoutBootingFirst() async throws {
        let device = try await Device("a", InMemoryCloud()); defer { device.close() }
        let game = try await device.importDisc()
        let first = try await device.launch(game)
        frames(first, 180); cross(first); let state = try first.captureState(); first.stop()
        let fresh = try await device.launch(game); defer { fresh.stop() }
        try fresh.restoreState(state); XCTAssertEqual(try counter(fresh), 2)
        cross(fresh); XCTAssertEqual(try counter(fresh), 3)
    }

    @MainActor
    func testDiscSwitchAndStateRestoreKeepBothCardsAndSelectedDisc() async throws {
        let device = try await Device("a", InMemoryCloud()); defer { device.close() }
        let source = device.root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: Self.fixtures.appendingPathComponent("relay-ps1-counter.bin"))
        var files: [URL] = []
        for name in ["A", "B"] {
            let bin = source.appendingPathComponent(name + ".bin"), cue = source.appendingPathComponent(name + ".cue")
            try bytes.write(to: bin); try Data("FILE \"\(name).bin\" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\n".utf8).write(to: cue)
            files += [cue, bin]
        }
        let playlist = source.appendingPathComponent("Game.m3u"); try Data("A.cue\nB.cue\n".utf8).write(to: playlist)
        let report = await GameImporter(store: device.store, location: device.location).importFiles([playlist] + files)
        let game = try XCTUnwrap(report.addedGames.first)
        let run = try await device.launch(game); defer { run.stop() }
        frames(run, 180); cross(run)
        XCTAssertEqual(run.discStatus?.count, 2)
        let cards = run.batterySaveBytes()
        try run.selectDisc(at: 1); XCTAssertEqual(run.discStatus?.selectedIndex, 1)
        XCTAssertEqual(run.batterySaveBytes(), cards)
        let state = try run.captureState()
        try run.selectDisc(at: 0); try run.restoreState(state)
        XCTAssertEqual(run.discStatus?.selectedIndex, 1); XCTAssertEqual(run.batterySaveBytes(), cards)
        XCTAssertThrowsError(try run.selectDisc(at: 2)); XCTAssertEqual(run.discStatus?.selectedIndex, 1)
    }
    /// Opt-in private material, never a resource of this test bundle/export.
    @MainActor
    func testPrivateDiscWithVerifiedBIOS() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RELAY_PS1_PRIVATE_CUE"], let biosPath = env["RELAY_PS1_PRIVATE_BIOS"] else {
            throw XCTSkip("Set RELAY_PS1_PRIVATE_CUE and RELAY_PS1_PRIVATE_BIOS for the owner's private compatibility run")
        }
        let d = try await Device("a", InMemoryCloud()); defer { d.close() }
        let source = URL(fileURLWithPath: path)
        let references = try CueSheetParser.parse(Data(contentsOf: source)).referencedNames
        let report = await GameImporter(store: d.store, location: d.location).importFiles([source] + references.map { source.deletingLastPathComponent().appendingPathComponent($0) })
        let game = try XCTUnwrap(report.addedGames.first, "Private disc import failed: \(report)")
        let biosData = try Data(contentsOf: URL(fileURLWithPath: biosPath))
        try PlayStationFirmwareStore(firmwareDirectory: d.root.appendingPathComponent("Firmware")).importData(biosData)
        let duration = Double(env["RELAY_PS1_AUDIO_SECONDS"] ?? "0") ?? 0
        let run = try await d.launch(game, audio: duration > 0); defer { run.stop() }
        XCTAssertFalse(run.usesEmulatedFirmware)
        var checksums = Set<UInt32>()
        for block in 0..<40 {
            if block % 4 == 2 { run.press(.start); run.press(.b) }
            frames(run, 150); run.release(.start); run.release(.b)
            checksums.insert(try XCTUnwrap(run.frameSource).sampledChecksum())
            if let output = env["RELAY_PS1_PRIVATE_OUTPUT"], block % 5 == 4 {
                let url = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let shot = try XCTUnwrap(run.frameSource.flatMap(FrameCapture.image(from:)))
                let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url.appendingPathComponent("frame-\(block).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(target, shot, nil); XCTAssertTrue(CGImageDestinationFinalize(target))
            }
        }
        XCTAssertGreaterThan(checksums.count, 3, "The private title must produce changing frames")
        let state = try run.captureState()
        XCTAssertNil(state.range(of: biosData.prefix(1024)), "Portable states must omit the proprietary BIOS")
        frames(run, 60); try run.restoreState(state); frames(run, 120)
        XCTAssertNotEqual(try XCTUnwrap(run.frameSource).sampledChecksum(), 0)
        if duration > 0 {
            run.resume()
            try await Task.sleep(for: .seconds(3))
            let before = run.diagnostics
            let measuredAt = Date()
            var minimumFPS = Double.greatestFiniteMagnitude, maximumFPS = 0.0
            for _ in 0..<Int(duration) {
                try await Task.sleep(for: .seconds(1))
                minimumFPS = min(minimumFPS, run.diagnostics.emulationFramesPerSecond)
                maximumFPS = max(maximumFPS, run.diagnostics.emulationFramesPerSecond)
            }
            let after = run.diagnostics
            run.pause()
            let requested = after.audioFramesRequested - before.audioFramesRequested
            let missing = after.audioFramesMissing - before.audioFramesMissing
            let discarded = after.audioFramesDiscarded - before.audioFramesDiscarded
            print("PS1_PACED seconds=\(Date().timeIntervalSince(measuredAt)) produced=\(after.audioFramesProduced - before.audioFramesProduced) initialQueue=\(before.audioBufferedBytes) target=\(after.targetFramesPerSecond) fpsMin=\(minimumFPS) fpsMax=\(maximumFPS) requested=\(requested) missing=\(missing) discarded=\(discarded) queueBytes=\(after.audioBufferedBytes) longestFrameMs=\(after.longestFrameMilliseconds)")
            XCTAssertTrue(after.audioRunning)
            XCTAssertGreaterThan(requested, UInt64(duration * 40_000))
            XCTAssertLessThan(Double(missing) / Double(max(requested, 1)), 0.001)
            XCTAssertEqual(discarded, 0)
            XCTAssertGreaterThan(minimumFPS, after.targetFramesPerSecond * 0.95)
        }
        if let output = env["RELAY_PS1_PRIVATE_OUTPUT"] {
            let url = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let shot = try XCTUnwrap(run.frameSource.flatMap(FrameCapture.image(from:)))
            let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url.appendingPathComponent("frame.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(target, shot, nil); XCTAssertTrue(CGImageDestinationFinalize(target))
            try state.write(to: url.appendingPathComponent("private.state"), options: .atomic)
        }
        run.stop()
        // A receiver without the matching firmware must report the BIOS
        // contract explicitly, before attempting to deserialize the state.
        try FileManager.default.removeItem(at: PlayStationFirmwareStore(firmwareDirectory: d.root.appendingPathComponent("Firmware")).directory)
        let hle = try await d.launch(game); defer { hle.stop() }
        XCTAssertTrue(hle.usesEmulatedFirmware)
        XCTAssertThrowsError(try hle.restoreState(state)) { error in
            XCTAssertEqual(error as? EmulationError, .stateFirmwareMismatch)
        }
        print("PRIVATE PS1 proof: content=\(game.contentFingerprint.hexDigest), distinctFrames=\(checksums.count), stateBytes=\(state.count), BIOS omitted, mismatched firmware rejected")
    }

    @MainActor
    func testAToRemoteFreshBContinueBToRemoteAUsesExistingSemantics() async throws {
        let cloud = InMemoryCloud()
        let a = try await Device("a", cloud); defer { a.close() }
        let gameA = try await a.importDisc()
        let runA = try await a.launch(gameA); defer { runA.stop() }
        frames(runA, 180); cross(runA); XCTAssertEqual(try counter(runA), 2)
        try await a.save(runA, game: gameA); try await a.transport.pump()
        // B is created only after A's upload. It has no inherited database or cache.
        let b = try await Device("b", cloud); defer { b.close() }
        try await b.transport.pump()
        let received = try await b.store.games.game(fingerprint: gameA.contentFingerprint)
        let gameB = try XCTUnwrap(received)
        let beforeFiles = try await b.store.games.files(for: gameB.id); XCTAssertTrue(beforeFiles.isEmpty)
        let head = try await b.store.saves.activeBatteryRevisionID(for: gameB.id)
        let auto = try await b.states.latestAutoResume(for: gameB.id, activeRevision: head)
        let continueState = try XCTUnwrap(auto)
        _ = try await b.importDisc()
        let runB = try await b.launch(gameB); defer { runB.stop() }
        frames(runB, 180); XCTAssertEqual(try counter(runB), 3)
        try runB.restoreState(b.states.load(continueState, game: gameB, for: PCSXDriverFactory.descriptor))
        XCTAssertEqual(try counter(runB), 2)
        cross(runB); XCTAssertEqual(try counter(runB), 3)
        try await b.save(runB, game: gameB); try await b.transport.pump(); try await a.transport.pump()
        let returned = try Data(contentsOf: a.location.url(for: LibraryLocation.batterySaveLocation(gameID: gameA.id)))
        XCTAssertEqual(returned[8324], 3)
        let heads = try await a.battery.heads(for: gameA.id); XCTAssertEqual(heads.count, 1)
        let history = try await a.store.playHistory.recentlyPlayed(limit: 1)
        XCTAssertEqual(history.first?.sessionCount, 2)
        let final = try await a.launch(gameA); defer { final.stop() }
        frames(final, 180); XCTAssertEqual(try counter(final), 4)
        let finalHead = try await a.store.saves.activeBatteryRevisionID(for: gameA.id)
        let finalAuto = try await a.states.latestAutoResume(for: gameA.id, activeRevision: finalHead)
        try final.restoreState(a.states.load(XCTUnwrap(finalAuto), game: gameA, for: PCSXDriverFactory.descriptor))
        XCTAssertEqual(try counter(final), 3)
    }
}

// Capture actual core pixels without linking the complete UI and unrelated cores.
private enum FrameCapture {
    static func image(from source: VideoFrameSource) -> CGImage? {
        var image: CGImage?
        source.withCurrentFrame { pointer, d in
            guard d.width > 0, d.height > 0, d.pixelFormat == .rgbx8 else { return }
            let data = Data(bytes: pointer, count: d.bytesPerRow * d.height)
            guard let provider = CGDataProvider(data: data as CFData) else { return }
            image = CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: d.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return image
    }
}
