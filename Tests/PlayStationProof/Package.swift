// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription
let package = Package(name: "PlayStationProof", platforms: [.macOS(.v14)], dependencies: [
    .package(path: "../../Packages/RelayEmulation"),
    .package(path: "../../Packages/RelayDomain"),
    .package(path: "../../Packages/RelayLibrary"),
    .package(path: "../../Packages/RelayPersistence"),
    .package(path: "../../Packages/RelaySync"),
], targets: [
    .testTarget(name: "PlayStationProofTests", dependencies: [
        .product(name: "RelayPCSXAdapter", package: "RelayEmulation"),
        .product(name: "RelayEmulation", package: "RelayEmulation"),
        .product(name: "RelayVideo", package: "RelayEmulation"),
        .product(name: "RelayDomain", package: "RelayDomain"),
        .product(name: "RelayLibrary", package: "RelayLibrary"),
        .product(name: "RelayPersistence", package: "RelayPersistence"),
        .product(name: "RelaySync", package: "RelaySync"),
    ]),
])
