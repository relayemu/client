// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RelayHostedSync",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [.library(name: "RelayHostedSync", targets: ["RelayHostedSync"])],
    dependencies: [
        .package(path: "../RelayDomain"), .package(path: "../RelayLibrary"),
        .package(path: "../RelaySync"), .package(path: "../RelayCommerce"),
        .package(path: "../RelayPersistence"),
    ],
    targets: [
        .target(name: "RelayHostedSync", dependencies: [
            .product(name: "RelayDomain", package: "RelayDomain"),
            .product(name: "RelayLibrary", package: "RelayLibrary"),
            .product(name: "RelaySync", package: "RelaySync"),
            .product(name: "RelayEntitlements", package: "RelayCommerce"),
        ], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "RelayHostedSyncTests", dependencies: ["RelayHostedSync",
            .product(name: "RelayPersistence", package: "RelayPersistence")]),
    ]
)
