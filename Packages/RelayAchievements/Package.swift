// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "RelayAchievements",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RelayAchievementInterfaces", targets: ["RelayAchievementInterfaces"]),
        .library(name: "RelayAchievements", targets: ["RelayAchievements"])
    ],
    dependencies: [.package(path: "../RelayDomain"), .package(path: "../../Vendor/rcheevos")],
    targets: [
        .target(name: "RelayAchievementInterfaces"),
        .target(name: "RelayAchievements", dependencies: [
            "RelayAchievementInterfaces", .product(name: "RelayDomain", package: "RelayDomain"),
            .product(name: "CRetroAchievements", package: "rcheevos")
        ], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "RelayAchievementsTests", dependencies: ["RelayAchievements",
            .product(name: "CRetroAchievements", package: "rcheevos")])
    ]
)
