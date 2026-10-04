// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CloudKitDiagnostics.swift
//  RelayCloudKit
//
//  Read-only evidence about what actually exists in the user's private
//  database: which zones Relay created and how many records of each type are
//  in them. Used by Settings ▸ Advanced ▸ Diagnostics and by the real-CloudKit
//  verification script. Metadata only: `desiredKeys: []` never downloads an
//  asset, so probing costs nothing in bytes.

import CloudKit
import Foundation
import RelaySync

public enum CloudKitDiagnostics {
    public struct ZoneReport: Sendable, Equatable {
        public let zoneName: String
        /// Record counts per record type, in the order of `SyncRecordType.allCases`.
        public let countsByType: [String: Int]

        public var total: Int { countsByType.values.reduce(0, +) }

        public var summary: String {
            let types = countsByType.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(zoneName)[\(types.isEmpty ? "empty" : types)]"
        }
    }

    /// Names of every record zone in the private database.
    public static func zoneNames(containerIdentifier: String) async throws -> [String] {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zones = try await database.allRecordZones()
        return zones.map(\.zoneID.zoneName).sorted()
    }

    /// Counts the records of a zone by type, without downloading any asset.
    public static func report(containerIdentifier: String, zoneName: String) async throws -> ZoneReport {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var counts: [String: Int] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: [], resultsLimit: nil)
            for (_, modification) in result.modificationResultsByID {
                if case .success(let value) = modification {
                    counts[value.record.recordType, default: 0] += 1
                }
            }
            token = result.changeToken
            more = result.moreComing
        }
        return ZoneReport(zoneName: zoneName, countsByType: counts)
    }

    /// Deletes Relay's own zones from the private database. Used only by the
    /// development verification script to start from a known server state; it
    /// touches no other zone and is never reachable from the product UI.
    public static func deleteRelayZones(containerIdentifier: String) async throws -> [String] {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let existing = try await database.allRecordZones()
        let mine = existing.map(\.zoneID).filter { $0.zoneName == CloudKitSyncTransport.syncZoneName || $0.zoneName == CloudKitSyncTransport.contentZoneName }
        guard !mine.isEmpty else { return [] }
        _ = try await database.modifyRecordZones(saving: [], deleting: mine)
        return mine.map(\.zoneName).sorted()
    }

    /// One line of evidence for a verification log: container, zones and per-type counts.
    public static func probe(containerIdentifier: String) async -> String {
        do {
            let zones = try await zoneNames(containerIdentifier: containerIdentifier)
            var parts: [String] = []
            for zone in zones where zone == CloudKitSyncTransport.syncZoneName || zone == CloudKitSyncTransport.contentZoneName {
                parts.append((try await report(containerIdentifier: containerIdentifier, zoneName: zone)).summary)
            }
            return "container=\(containerIdentifier) zones=[\(zones.joined(separator: ","))] \(parts.joined(separator: " "))"
        } catch {
            return "container=\(containerIdentifier) probe failed: \(CloudKitErrorClassifier.classify(error))"
        }
    }
}
