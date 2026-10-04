// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The only Relay module that imports CloudKit. Implements RelaySync's
// SyncTransport with CKSyncEngine on the user's private database (zone
// RelaySync), direct on-demand operations on the heavy content zone
// (RelayContent), account monitoring, error classification and the
// persisted engine state. CKRecord, CKAsset, CKRecord.ID, CKRecordZone.ID and
// CKSyncEngine never leave this package.
import PackageDescription

let package = Package(
    name: "RelayCloudKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayCloudKit", targets: ["RelayCloudKit"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../RelayLibrary"),
        .package(path: "../RelaySync"),
    ],
    targets: [
        .target(
            name: "RelayCloudKit",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayLibrary", package: "RelayLibrary"),
                .product(name: "RelaySync", package: "RelaySync"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayCloudKitTests",
            dependencies: ["RelayCloudKit"]
        ),
    ]
)
