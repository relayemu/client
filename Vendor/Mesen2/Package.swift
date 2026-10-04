// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Relay-added SwiftPM manifest for the vendored Mesen 2 tree (upstream builds
// with MSBuild/make and has no package manifest). Only the emulator itself is
// compiled: Core/, Utilities/, Lua/, SevenZip/ — exactly the source selection of
// upstream's makefile for libMesenCore. UI/, InteropDLL/, Sdl/, Linux/, MacOS/
// and Windows/ are frontends and are not built. RelayBridge/ is Relay's own C
// API over the C++ Emulator (GPL-3.0-or-later, see RelayBridge/README.md).
import PackageDescription

let package = Package(
    name: "Mesen2",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MesenRelay", targets: ["MesenRelay"]),
    ],
    targets: [
        .target(
            name: "MesenRelay",
            path: ".",
            exclude: [
                "Core/Core.vcxproj",
                "Core/Core.vcxproj.filters",
                "Core/Core.ruleset",
                "Utilities/Utilities.vcxproj",
                "Utilities/Utilities.vcxproj.filters",
                "Utilities/Audio/ymfm/ymfm_fm.ipp",
                "SevenZip/SevenZip.vcxproj",
                "SevenZip/SevenZip.vcxproj.filters",
                "Lua/Lua.vcxproj",
                "Lua/Lua.vcxproj.filters",
            ],
            sources: [
                "Core",
                "Utilities",
                "SevenZip",
                "Lua",
                "RelayBridge/src",
            ],
            publicHeadersPath: "RelayBridge/include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("Core"),
                .headerSearchPath("Utilities"),
                // Lua's os.execute calls system(), which iOS and tvOS do not have;
                // the prefix header routes it to a bridge stub that always fails.
                .headerSearchPath("RelayBridge/shim"),
                .unsafeFlags(["-include", "mesen_relay_lua_system.h"]),
                // Mesen bundles blip_buf (LGPL-2.1+), and so does the vendored mGBA;
                // both export C symbols, so Mesen's copy is renamed at compile
                // time. Same list under cxxSettings for the C++ callers.
                .define("blip_new", to: "mesen_blip_new"),
                .define("blip_delete", to: "mesen_blip_delete"),
                .define("blip_set_rates", to: "mesen_blip_set_rates"),
                .define("blip_clear", to: "mesen_blip_clear"),
                .define("blip_add_delta", to: "mesen_blip_add_delta"),
                .define("blip_add_delta_fast", to: "mesen_blip_add_delta_fast"),
                .define("blip_clocks_needed", to: "mesen_blip_clocks_needed"),
                .define("blip_end_frame", to: "mesen_blip_end_frame"),
                .define("blip_samples_avail", to: "mesen_blip_samples_avail"),
                .define("blip_read_samples", to: "mesen_blip_read_samples"),
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("Core"),
                .headerSearchPath("Utilities"),
                .define("blip_new", to: "mesen_blip_new"),
                .define("blip_delete", to: "mesen_blip_delete"),
                .define("blip_set_rates", to: "mesen_blip_set_rates"),
                .define("blip_clear", to: "mesen_blip_clear"),
                .define("blip_add_delta", to: "mesen_blip_add_delta"),
                .define("blip_add_delta_fast", to: "mesen_blip_add_delta_fast"),
                .define("blip_clocks_needed", to: "mesen_blip_clocks_needed"),
                .define("blip_end_frame", to: "mesen_blip_end_frame"),
                .define("blip_samples_avail", to: "mesen_blip_samples_avail"),
                .define("blip_read_samples", to: "mesen_blip_read_samples"),
                // Upstream compiles with -O3; an unoptimised emulator is not playable.
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx17
)
