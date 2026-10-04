// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Repository/service protocols over RelayDomain, content hashing, the local
// content-location model and the minimal deterministic ingestion + launch
import PackageDescription

let package = Package(
    name: "RelayLibrary",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayLibrary", targets: ["RelayLibrary"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../../Vendor/PCSXReARMed"),
    ],
    targets: [
        .target(
            name: "RelayLibrary",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayDiscCodec", package: "PCSXReARMed"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayLibraryTests",
            dependencies: ["RelayLibrary"]
        ),
    ]
)
