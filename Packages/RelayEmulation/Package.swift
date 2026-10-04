// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Layering (top → bottom):
//   Relay SwiftUI shells (Apps/*)
//     → RelayEmulation        Foundation-only public API (EmulationSession, EmulationDriver, …)
//     → RelayProvenanceAdapter Provenance-backed EmulationDriver for the mGBA core
//     → Vendor/Provenance      PVEmulatorCore / PVCoreBridge / PVCoreObjCBridge / PVCoreAudio / Cores/mGBA
//     → RelayCores            every shipped adapter behind one CompositeDriverFactory
//   RelayVideo (Metal presenter), RelayInput (GameController/keyboard) and RelayAudioOutput only talk to RelayEmulation types.
//   the RelayLibraryProofTests target proves library → launch through the real mGBA path.
import PackageDescription

let vendor = "../../Vendor/Provenance"

let package = Package(
    name: "RelayEmulation",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RelayEmulation", targets: ["RelayEmulation"]),
        .library(name: "RelayProvenanceAdapter", targets: ["RelayProvenanceAdapter"]),
        .library(name: "RelayVideo", targets: ["RelayVideo"]),
        .library(name: "RelayInput", targets: ["RelayInput"]),
        .library(name: "RelayAudioOutput", targets: ["RelayAudioOutput"]),
        .library(name: "RelayMesenAdapter", targets: ["RelayMesenAdapter"]),
        .library(name: "RelayMelonAdapter", targets: ["RelayMelonAdapter"]),
        .library(name: "RelayPCSXAdapter", targets: ["RelayPCSXAdapter"]),
        .library(name: "RelayCores", targets: ["RelayCores"]),
    ],
    dependencies: [
        .package(path: "../RelayDomain"),
        .package(path: "../RelayAchievements"),
        .package(path: "../RelayLibrary"),
        .package(path: "../RelayPersistence"),
        .package(path: "../RelaySync"),
        .package(path: "\(vendor)/PVEmulatorCore"),
        .package(path: "\(vendor)/PVCoreBridge"),
        .package(path: "\(vendor)/PVCoreAudio"),
        .package(path: "\(vendor)/PVAudio"),
        .package(path: "\(vendor)/PVLogging"),
        .package(path: "\(vendor)/Cores/mGBA"),
        .package(path: "../../Vendor/Mesen2"),
        .package(path: "../../Vendor/melonDS"),
        .package(path: "../../Vendor/PCSXReARMed"),
    ],
    targets: [
        .target(
            name: "RelayEmulation",
            dependencies: [
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayAchievementInterfaces", package: "RelayAchievements"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "RelayProvenanceAdapter",
            dependencies: [
                "RelayEmulation",
                .product(name: "PVEmulatorCore", package: "PVEmulatorCore"),
                .product(name: "PVCoreBridge", package: "PVCoreBridge"),
                .product(name: "PVCoreAudio", package: "PVCoreAudio"),
                .product(name: "PVAudio", package: "PVAudio"),
                .product(name: "PVLogging", package: "PVLogging"),
                .product(name: "PVCoremGBA", package: "mGBA"),
                .product(name: "PVmGBABridge", package: "mGBA"),
            ]
        ),
        // Relay's own audio output, for cores that hand Relay their samples.
        .target(
            name: "RelayAudioOutput",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // Mesen 2 (NES, SNES) through the C bridge in Vendor/Mesen2/RelayBridge.
        .target(
            name: "RelayMesenAdapter",
            dependencies: [
                "RelayEmulation",
                "RelayAudioOutput",
                .product(name: "MesenRelay", package: "Mesen2"),
            ]
        ),
        // melonDS (Nintendo DS) through the C bridge in Vendor/melonDS/RelayBridge.
        .target(
            name: "RelayMelonAdapter",
            dependencies: [
                "RelayEmulation",
                "RelayAudioOutput",
                .product(name: "MelonRelay", package: "melonDS"),
            ]
        ),
        .target(name: "RelayPCSXAdapter", dependencies: [
            "RelayEmulation", "RelayAudioOutput",
            .product(name: "RelayLibrary", package: "RelayLibrary"),
            .product(name: "PCSXRelay", package: "PCSXReARMed"),
        ]),
        // Every shipped core behind one factory.
        .target(
            name: "RelayCores",
            dependencies: ["RelayEmulation", "RelayProvenanceAdapter", "RelayMesenAdapter", "RelayMelonAdapter", "RelayPCSXAdapter"]
        ),
        .target(
            name: "RelayVideo",
            dependencies: ["RelayEmulation"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "RelayInput",
            dependencies: ["RelayEmulation"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RelayEmulationTests",
            dependencies: ["RelayEmulation", "RelayInput"]
        ),
        .testTarget(
            name: "RelayLibraryProofTests",
            dependencies: [
                "RelayEmulation",
                "RelayProvenanceAdapter",
                "RelayMesenAdapter",
                "RelayMelonAdapter",
                "RelayCores",
                "RelayPCSXAdapter",
                .product(name: "RelayDomain", package: "RelayDomain"),
                .product(name: "RelayLibrary", package: "RelayLibrary"),
                .product(name: "RelayPersistence", package: "RelayPersistence"),
                .product(name: "RelaySync", package: "RelaySync"),
                .product(name: "PVCoremGBA", package: "mGBA"),
                .product(name: "PVmGBABridge", package: "mGBA"),
            ]
        ),
    ]
)
