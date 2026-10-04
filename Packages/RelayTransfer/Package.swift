// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RelayTransfer",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [.library(name: "RelayTransfer", targets: ["RelayTransfer"])],
    dependencies: [.package(path: "../RelayLibrary"), .package(path: "../RelayHostedSync"), .package(path: "../RelayPersistence")],
    targets: [
        .binaryTarget(name: "RelayDataChannel", path: "Artifacts/RelayDataChannel.xcframework"),
        .target(name: "RelayTransfer", dependencies: ["RelayDataChannel",
            .product(name: "RelayLibrary", package: "RelayLibrary"),
            .product(name: "RelayHostedSync", package: "RelayHostedSync")],
            resources: [.copy("Resources/TransportProvenance.json")],
            linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "RelayTransferTests", dependencies: ["RelayTransfer", .product(name: "RelayPersistence", package: "RelayPersistence")]),
    ],
    swiftLanguageModes: [.v5]
)
