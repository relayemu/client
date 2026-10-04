// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
// and macOS shells. Consumes RelayDomain/RelayLibrary/RelayPersistence through
// the library model and RelayEmulation through EmulationSession; never Realm,
// PVGame, RomDatabase or the Provenance adapter (the app injects the driver factory).
import PackageDescription

let package = Package(
    name: "RelayUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RelayUI", targets: ["RelayUI"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../RelayLibrary"),
        .package(path: "../RelayPersistence"),
        .package(path: "../RelayDesignSystem"),
        .package(path: "../RelayEmulation"),
        .package(path: "../RelaySync"),
        .package(path: "../RelayHostedSync"),
        .package(path: "../RelayCommerce"),
        .package(path: "../RelayAchievements"),
        .package(path: "../RelayTransfer"),
    ],
    targets: [
        .target(
            name: "RelayUI",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayLibrary", package: "RelayLibrary"),
                .product(name: "RelayPersistence", package: "RelayPersistence"),
                .product(name: "RelayDesignSystem", package: "RelayDesignSystem"),
                .product(name: "RelayEmulation", package: "RelayEmulation"),
                .product(name: "RelayVideo", package: "RelayEmulation"),
                .product(name: "RelayInput", package: "RelayEmulation"),
                .product(name: "RelaySync", package: "RelaySync"),
                .product(name: "RelayHostedSync", package: "RelayHostedSync"),
                .product(name: "RelayEntitlements", package: "RelayCommerce"),
                .product(name: "RelayAchievements", package: "RelayAchievements"),
                .product(name: "RelayTransfer", package: "RelayTransfer"),
            ],
            resources: [.process("Localizable.xcstrings"), .copy("licenses.json"), .copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayUITests",
            dependencies: [
                "RelayUI",
                .product(name: "RelaySync", package: "RelaySync"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
