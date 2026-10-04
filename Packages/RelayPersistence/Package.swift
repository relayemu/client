// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Implements the RelayLibrary repository protocols. Explicit schema and
// migrations, transactional writes, foreign keys. No UI, no CloudKit, no
import PackageDescription

let package = Package(
    name: "RelayPersistence",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayPersistence", targets: ["RelayPersistence"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../RelayLibrary"),
        // Pinned exactly; bump deliberately (ADR 0002).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "RelayPersistence",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayLibrary", package: "RelayLibrary"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayPersistenceTests",
            dependencies: ["RelayPersistence"]
        ),
    ]
)
