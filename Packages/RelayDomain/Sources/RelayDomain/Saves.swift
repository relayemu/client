// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Saves.swift
//  RelayDomain
//
//  Two distinct concepts that must never be confused:
//
//  * `Save` — the game's own persistent memory (battery/SRAM/flash/memory
//    card). Written by the game through the core in the game's native format;
//    generally portable across core versions and platforms. This is the
//    preferred continuity mechanism.
//
//  * `SaveState` — a snapshot of the emulator's full machine state. Tied to a
//    core implementation, its state-compatibility version and a state format;
//    may be unloadable by another version. Carries enough metadata to refuse
//    an unsafe restore.
//
//  the battery save that forms a version graph across devices
//  "current bytes" row; revisions are the durable, synchronizable history.

import Foundation

public struct Save: Hashable, Codable, Sendable, Identifiable {
    public let id: SaveID
    public let gameID: GameID
    /// Where the save file lives in Relay-managed storage.
    public var location: ContentLocation
    public var sizeInBytes: Int64
    /// SHA-256 of the save file, when known (lets future sync compare content cheaply).
    public var fingerprint: ContentFingerprint?
    public var updatedAt: Date

    public init(id: SaveID = SaveID(), gameID: GameID, location: ContentLocation, sizeInBytes: Int64,
                fingerprint: ContentFingerprint? = nil, updatedAt: Date) {
        self.id = id
        self.gameID = gameID
        self.location = location
        self.sizeInBytes = sizeInBytes
        self.fingerprint = fingerprint
        self.updatedAt = updatedAt
    }
}

/// One immutable version of a game's battery save. `parentIDs` link revisions
/// into a graph: a root has none, a normal successor has one, a merge created
/// by conflict resolution has several. Bytes never change under an id.
public struct BatteryRevision: Hashable, Codable, Sendable, Identifiable {
    public let id: BatteryRevisionID
    public let gameID: GameID
    public let generation: Int64
    public let parentIDs: [BatteryRevisionID]
    public let createdAt: Date
    /// SHA-256 of the save bytes.
    public let dataFingerprint: ContentFingerprint
    public let sizeInBytes: Int64
    public let installationID: InstallationID
    public let deviceKind: DeviceKind
    /// `Saves/<GameID>/battery/revisions/<id>.sav` — immutable once written.
    public let location: ContentLocation
    public var screenshotLocation: ContentLocation?
    public let origin: SyncOrigin

    public init(id: BatteryRevisionID = BatteryRevisionID(), gameID: GameID, parentIDs: [BatteryRevisionID], createdAt: Date,
                dataFingerprint: ContentFingerprint, sizeInBytes: Int64, installationID: InstallationID, deviceKind: DeviceKind,
                location: ContentLocation, screenshotLocation: ContentLocation? = nil, origin: SyncOrigin, generation: Int64 = 0) {
        self.id = id
        self.gameID = gameID
        self.generation = generation
        self.parentIDs = parentIDs
        self.createdAt = createdAt
        self.dataFingerprint = dataFingerprint
        self.sizeInBytes = sizeInBytes
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.location = location
        self.screenshotLocation = screenshotLocation
        self.origin = origin
    }
}

public struct SaveState: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Created automatically on safe lifecycle transitions; replaced over time.
        case auto
        /// Created by the quick-save action; replaced by the next quick save.
        case quick
        /// Created deliberately by the user; immutable until deleted.
        case manual
    }

    public let id: SaveStateID
    public let gameID: GameID
    public let generation: Int64
    public let coreID: CoreID
    /// Version of the core that produced the state (`EmulatorCoreDescriptor.version`).
    public let coreVersion: String
    /// The core's declared state-compatibility identifier at capture time
    /// (`EmulatorCoreDescriptor.stateCompatibilityVersion`). Defaults to the
    /// core version: every core version is its own compatibility class until
    /// a core explicitly declares otherwise.
    public let stateCompatibilityVersion: String
    /// Relay's version of the state container/metadata format.
    public let formatVersion: Int
    public let kind: Kind
    public let createdAt: Date
    public var location: ContentLocation
    public var screenshotLocation: ContentLocation?
    public var label: String?
    /// The battery revision that was the active head when the state was
    /// captured; Continue only restores an Auto Resume whose revision is the
    /// current head (RELAY_SYNC_CONFLICTS.md §2.1).
    public var batteryRevisionID: BatteryRevisionID?
    public var installationID: InstallationID?
    public var deviceKind: DeviceKind
    public var origin: SyncOrigin

    /// The current Relay save-state format version written by this build.
    /// Version 2 adds the game content fingerprint and the state
    /// compatibility version to the container header; version 1 files remain readable.
    public static let currentFormatVersion = 2

    public init(id: SaveStateID = SaveStateID(), gameID: GameID, coreID: CoreID, coreVersion: String,
                stateCompatibilityVersion: String? = nil,
                formatVersion: Int = SaveState.currentFormatVersion, kind: Kind, createdAt: Date,
                location: ContentLocation, screenshotLocation: ContentLocation? = nil, label: String? = nil,
                batteryRevisionID: BatteryRevisionID? = nil, installationID: InstallationID? = nil,
                deviceKind: DeviceKind = .unknown, origin: SyncOrigin = .local, generation: Int64 = 0) {
        self.id = id
        self.gameID = gameID
        self.generation = generation
        self.coreID = coreID
        self.coreVersion = coreVersion
        self.stateCompatibilityVersion = stateCompatibilityVersion ?? coreVersion
        self.formatVersion = formatVersion
        self.kind = kind
        self.createdAt = createdAt
        self.location = location
        self.screenshotLocation = screenshotLocation
        self.label = label
        self.batteryRevisionID = batteryRevisionID
        self.installationID = installationID
        self.deviceKind = deviceKind
        self.origin = origin
    }

    /// Whether `core` can be expected to restore this state safely. Conservative:
    /// same core, same state-compatibility version, known format version. A core
    /// update that keeps its state format may declare the same compatibility
    /// version; nothing is ever assumed compatible.
    public func isRestorable(by core: EmulatorCoreDescriptor) -> Bool {
        core.id == coreID
            && core.stateCompatibilityVersion == stateCompatibilityVersion
            && formatVersion <= SaveState.currentFormatVersion
    }
}

/// A synchronized deletion. Keyed by the logical, cross-device identity of
/// what was deleted so a stale device cannot resurrect it.
public struct DeletionTombstone: Hashable, Codable, Sendable {
    public enum Target: Hashable, Codable, Sendable {
        /// A game removed from the library everywhere (key: content fingerprint).
        case game(ContentFingerprint)
        /// Any deleted state, including automatic and quick-save retention.
        case saveState(SaveStateID)

        public var kindName: String {
            switch self {
            case .game: return "game"
            case .saveState: return "state"
            }
        }

        public var keyString: String {
            switch self {
            case .game(let fp): return fp.canonicalString
            case .saveState(let id): return id.description
            }
        }
    }

    public let target: Target
    public let generation: Int64
    /// Optional for legacy UUID tombstones whose game row no longer exists.
    public let gameFingerprint: ContentFingerprint?
    public let deletedAt: Date
    public let installationID: InstallationID

    public init(target: Target, deletedAt: Date, installationID: InstallationID, generation: Int64 = 0,
                gameFingerprint: ContentFingerprint? = nil) {
        self.target = target
        self.generation = generation
        if case .game(let fingerprint) = target { self.gameFingerprint = fingerprint }
        else { self.gameFingerprint = gameFingerprint }
        self.deletedAt = deletedAt
        self.installationID = installationID
    }
}

// Legacy records always identify initial generation.
extension BatteryRevision {
    private enum CodingKeys: String, CodingKey {
        case id, gameID, parentIDs, createdAt, dataFingerprint, sizeInBytes, installationID, deviceKind, location, screenshotLocation, origin, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(BatteryRevisionID.self, forKey: .id),
            gameID: try values.decode(GameID.self, forKey: .gameID),
            parentIDs: try values.decode([BatteryRevisionID].self, forKey: .parentIDs),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            dataFingerprint: try values.decode(ContentFingerprint.self, forKey: .dataFingerprint),
            sizeInBytes: try values.decode(Int64.self, forKey: .sizeInBytes),
            installationID: try values.decode(InstallationID.self, forKey: .installationID),
            deviceKind: try values.decode(DeviceKind.self, forKey: .deviceKind),
            location: try values.decode(ContentLocation.self, forKey: .location),
            screenshotLocation: try values.decodeIfPresent(ContentLocation.self, forKey: .screenshotLocation),
            origin: try values.decode(SyncOrigin.self, forKey: .origin),
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }
}


// Legacy records always identify initial generation.
extension SaveState {
    private enum CodingKeys: String, CodingKey {
        case id, gameID, coreID, coreVersion, stateCompatibilityVersion, formatVersion, kind, createdAt, location, screenshotLocation, label, batteryRevisionID, installationID, deviceKind, origin, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(SaveStateID.self, forKey: .id),
            gameID: try values.decode(GameID.self, forKey: .gameID),
            coreID: try values.decode(CoreID.self, forKey: .coreID),
            coreVersion: try values.decode(String.self, forKey: .coreVersion),
            stateCompatibilityVersion: try values.decodeIfPresent(String.self, forKey: .stateCompatibilityVersion),
            formatVersion: try values.decode(Int.self, forKey: .formatVersion),
            kind: try values.decode(Kind.self, forKey: .kind),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            location: try values.decode(ContentLocation.self, forKey: .location),
            screenshotLocation: try values.decodeIfPresent(ContentLocation.self, forKey: .screenshotLocation),
            label: try values.decodeIfPresent(String.self, forKey: .label),
            batteryRevisionID: try values.decodeIfPresent(BatteryRevisionID.self, forKey: .batteryRevisionID),
            installationID: try values.decodeIfPresent(InstallationID.self, forKey: .installationID),
            deviceKind: try values.decodeIfPresent(DeviceKind.self, forKey: .deviceKind) ?? .unknown,
            origin: try values.decodeIfPresent(SyncOrigin.self, forKey: .origin) ?? .local,
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0
        )
    }
}


// Legacy records always identify initial generation.
extension DeletionTombstone {
    private enum CodingKeys: String, CodingKey {
        case target, deletedAt, installationID, generation, gameFingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            target: try values.decode(Target.self, forKey: .target),
            deletedAt: try values.decode(Date.self, forKey: .deletedAt),
            installationID: try values.decode(InstallationID.self, forKey: .installationID),
            generation: try values.decodeIfPresent(Int64.self, forKey: .generation) ?? 0,
            gameFingerprint: try values.decodeIfPresent(ContentFingerprint.self, forKey: .gameFingerprint)
        )
    }
}
