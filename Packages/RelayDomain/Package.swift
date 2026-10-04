// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   - Foundation only. No SwiftUI/UIKit/AppKit, no CloudKit/StoreKit/GameController,
//     no Realm/GRDB, no Provenance modules.
//   - Value types, Sendable and Codable, so the same model can later serve
//     Android and Relay Sync without translation.
import PackageDescription

let package = Package(
    name: "RelayDomain",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayDomain", targets: ["RelayDomain"]),
    ],
    targets: [
        .target(
            name: "RelayDomain",
            dependencies: [],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayDomainTests",
            dependencies: ["RelayDomain"]
        ),
    ]
)
