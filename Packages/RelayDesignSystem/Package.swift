// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tokens (colour, System Spectrum, typography roles, spacing, radii, motion,
// symbols) and reusable product components. Depends on RelayDomain for
// SystemID only; never on library, persistence, emulation or sync layers.
// Components receive plain view models.
import PackageDescription

let package = Package(
    name: "RelayDesignSystem",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RelayDesignSystem", targets: ["RelayDesignSystem"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
    ],
    targets: [
        .target(
            name: "RelayDesignSystem",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
            ],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayDesignSystemTests",
            dependencies: ["RelayDesignSystem"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
