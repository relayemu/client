// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Portable, CloudKit-free records keyed by content fingerprints and entity
// UUIDs; the coordinator that turns journal intents into outbound changes,
// validates and applies inbound changes transactionally, resolves conflicts
// by record semantics and reconciles the battery revision graph; the
// transport boundary the CloudKit adapter (Packages/RelayCloudKit) implements;
// an in-memory cloud for deterministic multi-device tests and a file-backed
// transport for two-process walks without credentials.
//
// Depends on RelayDomain and RelayLibrary only. RelayPersistence is a test
// dependency so the harness runs against the real SQLite store.
import PackageDescription

let package = Package(
    name: "RelaySync",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelaySync", targets: ["RelaySync"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../RelayLibrary"),
        .package(path: "../RelayPersistence"),
    ],
    targets: [
        .target(
            name: "RelaySync",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayLibrary", package: "RelayLibrary"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelaySyncTests",
            dependencies: [
                "RelaySync",
                .product(name: "RelayPersistence", package: "RelayPersistence"),
            ]
        ),
    ]
)
