// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CloudKitEntitlements.swift
//  RelayCloudKit
//
//  `CKContainer(identifier:)` traps when the running code has no iCloud
//  container entitlement, so the app asks first. On macOS the entitlement is
//  read from the process's own code signature; iOS and tvOS have no public
//  API for that, so the app decides with the `RELAY_CLOUDKIT` compilation
//  condition that only signed CloudKit builds set (Apps/project.yml,
//  Scripts/relay-verify-cloud.sh). Nothing is inferred from Info.plist.

import Foundation
#if os(macOS)
import Security
#endif

public enum CloudKitEntitlements {
    public static let expectedContainer = "iCloud.app.relayemu.relay"

    /// The first iCloud container identifier in this process's entitlements (macOS only; nil elsewhere).
    public static var containerIdentifier: String? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        if let identifiers = value as? [String], let first = identifiers.first { return first }
        if let identifier = value as? String { return identifier }
        return nil
        #else
        return nil
        #endif
    }

    /// Whether the CloudKit service entitlement is present (macOS only; false elsewhere).
    public static var hasCloudKitService: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        if let services = value as? [String] { return services.contains("CloudKit") }
        if let service = value as? String { return service == "CloudKit" }
        return false
        #else
        return false
        #endif
    }
}
