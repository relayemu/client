// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RelayEntitlements is portable product policy. RelayStoreKit is the only
// target that imports StoreKit and translates verified App Store transactions
// into that policy. Neither target owns UI or gameplay.
import PackageDescription

let package = Package(
    name: "RelayCommerce",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RelayEntitlements", targets: ["RelayEntitlements"]),
        .library(name: "RelayStoreKit", targets: ["RelayStoreKit"]),
    ],
    targets: [
        .target(
            name: "RelayEntitlements",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "RelayStoreKit",
            dependencies: ["RelayEntitlements"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayEntitlementsTests",
            dependencies: ["RelayEntitlements"]
        ),
        .testTarget(
            name: "RelayStoreKitTests",
            dependencies: ["RelayEntitlements", "RelayStoreKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
