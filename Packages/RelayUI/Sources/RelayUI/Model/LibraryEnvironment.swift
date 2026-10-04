// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LibraryEnvironment.swift
//  RelayUI
//
//  Everything the screens need, built once by the app: the managed library
//  location, the SQLite store, the importer, artwork/screenshot storage, the
//  emulation session, the cores the app registered, the cover mirror of the
//  build (if any) and — when the app provides a transport — the sync
//  coordinator behind `SyncModel`.

import Foundation
import Observation
import RelayDomain
import RelayLibrary
import RelayPersistence
import RelayEmulation
import RelaySync
import RelayEntitlements
@_exported import RelayAchievements

/// The kind of device Relay runs on; drives "this iPhone" / "cet iPad" copy and sync provenance.
public typealias DeviceKind = RelayDomain.DeviceKind

public extension DeviceKind {
    @MainActor
    static var current: DeviceKind {
        #if os(tvOS)
        return .appleTV
        #elseif os(macOS)
        return .mac
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac ? .mac : (UIDeviceIdiom.isPad ? .iPad : .iPhone)
        #endif
    }
}

#if os(iOS)
import UIKit
enum UIDeviceIdiom {
    @MainActor static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}
#endif

/// Builds the transport for a library once its location is known (the app decides: CloudKit, file, none).
public typealias SyncTransportFactory = @MainActor (LibraryLocation) -> any SyncTransport

@MainActor
public final class LibraryEnvironment {
    public let location: LibraryLocation
    public let session: EmulationSession
    public let cores: [EmulatorCoreDescriptor]
    public let deviceKind: DeviceKind
    public let metadataProvider: any MetadataProvider
    public let artworkStore: ArtworkStore
    /// Relay's cover mirror for this build; nil when the build has no cover origin (no request is ever made).
    public let coverSource: (any CoverArtSource)?
    /// Holds background library work (the metadata backfill) while a game is playing.
    public let backgroundActivity = ActivityGate()
    public let firmwareDirectory: URL
    public let sync: SyncModel
    public let relayPro: RelayProModel
    public let achievements: AchievementsModel
    public let syncCapabilities: SyncCapabilities
    public let gameplayRequiresPro: Bool
    private let transportFactory: SyncTransportFactory?
    public let relayAccount: RelayAccountModel?
    private let hostedTransportFactory: (@MainActor (LibraryLocation, SyncIdentity, RelayAccountModel) -> (any SyncTransport)?)?
    public private(set) var store: SQLiteLibraryStore?
    public private(set) var importer: GameImporter?
    public private(set) var ingestion: GameIngestion?
    public private(set) var batterySaves: BatterySaveManager?
    public private(set) var saveStates: SaveStateManager?
    public private(set) var identity: SyncIdentity?
    public private(set) var coordinator: SyncCoordinator?

    public init(location: LibraryLocation, session: EmulationSession, cores: [EmulatorCoreDescriptor],
                deviceKind: DeviceKind = .current, metadataProvider: any MetadataProvider = NoMetadataProvider(),
                firmwareDirectory: URL? = nil, syncCapabilities: SyncCapabilities = .gameFilesSupported,
                gameplayRequiresPro: Bool = false,
                entitlementProvider: (any RelayEntitlementProviding)? = nil,
                transportFactory: SyncTransportFactory? = nil, sync: SyncModel? = nil,
                relayAccount: RelayAccountModel? = nil,
                achievements: AchievementsModel? = nil,
                hostedTransportFactory: (@MainActor (LibraryLocation, SyncIdentity, RelayAccountModel) -> (any SyncTransport)?)? = nil,
                coverSource: (any CoverArtSource)? = nil) {
        self.location = location
        self.session = session
        self.cores = cores
        self.deviceKind = deviceKind
        self.metadataProvider = metadataProvider
        self.artworkStore = ArtworkStore(location: location)
        self.coverSource = coverSource
        self.firmwareDirectory = firmwareDirectory ?? location.rootURL.deletingLastPathComponent().appending(path: "Firmware", directoryHint: .isDirectory)
        self.syncCapabilities = syncCapabilities
        self.gameplayRequiresPro = gameplayRequiresPro
        relayPro = RelayProModel(provider: entitlementProvider ?? UnavailableEntitlementProvider())
        self.transportFactory = transportFactory
        self.relayAccount = relayAccount
        self.achievements = achievements ?? AchievementsModel()
        self.hostedTransportFactory = hostedTransportFactory
        self.sync = sync ?? SyncModel()
    }

    /// Opens the store (creating and migrating the database), sweeps interrupted
    /// imports and inbound staging, builds the managers with this installation's
    /// identity, and — when a transport factory exists — starts synchronization.
    public func open() async throws {
        guard store == nil else { return }
        try location.createDirectories()
        location.sweepStaging()
        let opened = try SQLiteLibraryStore.open(at: location.databaseURL, deviceKind: deviceKind)
        store = opened
        let identity = try await opened.syncStore.identity()
        self.identity = identity
        importer = GameImporter(store: opened, location: location, metadataProvider: metadataProvider, artworkStore: artworkStore)
        ingestion = GameIngestion(store: opened, location: location)
        let battery = BatterySaveManager(store: opened, location: location, identity: identity)
        let states = SaveStateManager(store: opened, location: location, artworkStore: artworkStore, identity: identity)
        batterySaves = battery
        saveStates = states
        if transportFactory != nil || relayAccount != nil {
            let coordinator = SyncCoordinator(store: opened, syncStore: opened.syncStore, location: location, batterySaves: battery,
                                              saveStates: states, identity: identity, configuration: .init(capabilities: syncCapabilities))
            self.coordinator = coordinator
            var providers: [SyncProviderSelection] = [.off]
            if transportFactory != nil { providers.append(.iCloud) }
            if relayAccount != nil { providers.append(.relaySync) }
            await sync.attach(coordinator, availableProviders: providers, cloudCapabilities: syncCapabilities) { [weak self] selection in
                guard let self else { return nil }
                switch selection {
                case .off: return nil
                case .iCloud: return self.transportFactory?(self.location)
                case .relaySync:
                    guard let account = self.relayAccount else { return nil }
                    return self.hostedTransportFactory?(self.location, identity, account)
                }
            }
            relayAccount?.start(identity: identity, sync: sync)

        }
        // Entitlements are observed independently of iCloud. Commerce must not
        // alter saves, library sync, Continue or the user's game-file opt-in.
        relayPro.start()
        achievements.start()
    }

    public var isOpen: Bool { store != nil }

    /// Diagnostics: applied schema migrations.
    public func appliedMigrations() -> [String] {
        (try? store?.appliedMigrations()) ?? []
    }
}
