// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// The upstream C sources are unmodified. Only cartridge hashing is needed for
// Relay's eligible V1 systems; no disc, encrypted media or ZIP reader is linked.
let package = Package(
    name: "rcheevos",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "CRetroAchievements", targets: ["CRetroAchievements"])],
    targets: [.target(
        name: "CRetroAchievements", path: ".",
        exclude: ["src/rcheevos/rc_runtime_types.natvis"],
        sources: ["src/rc_client.c", "src/rc_compat.c", "src/rc_util.c", "src/rc_version.c",
                  "src/rapi", "src/rcheevos", "src/rhash/hash.c", "src/rhash/hash_rom.c", "src/rhash/md5.c"],
        publicHeadersPath: "include",
        cSettings: [.define("RC_CLIENT_SUPPORTS_HASH"), .define("RC_HASH_NO_DISC"),
                    .define("RC_HASH_NO_ZIP"), .define("RC_HASH_NO_ENCRYPTED"),
                    // Upstream includes this header inside a clock function.
                    // Preinclude it at file scope for Apple's modular SDKs.
                    .unsafeFlags(["-include", "AvailabilityMacros.h", "-Wno-modules-import-nested-redundant"])],
        linkerSettings: [.linkedLibrary("m")]
    )]
)
