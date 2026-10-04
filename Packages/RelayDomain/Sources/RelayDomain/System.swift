// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  System.swift
//  RelayDomain
//
//  Emulated systems are static reference data shipped with Relay, not user
//  data: games store a `SystemID`, and the catalog describes what it means.
//
//  description of a system: what its content looks like, which core Relay
//  prefers for it, what controls it has, how many screens it draws, what
//  firmware it needs, and whether Relay may currently play it. The product
//  understands Systems; only the adapter understands cores.

import Foundation

// MARK: - How a system's content is packaged

/// How one game of this system arrives and is stored.
public enum ContentPackaging: String, Hashable, Codable, Sendable {
    /// One ROM file is the whole game.
    case singleFile
    /// A disc image: an ordered set of member files described by a manifest
    /// (a `.cue` sheet and its tracks). Identity is the package, never one file.
    case discPackage
}

// MARK: - Screens

/// One logical picture a system draws. Systems with a single screen have one;
/// the Nintendo DS has two, and only one of them accepts touch.
public struct LogicalScreen: Hashable, Codable, Sendable, Identifiable {
    /// Stable identifier inside the system (`main`, `top`, `bottom`).
    public let id: String
    /// Native pixel size of this screen.
    public let width: Int
    public let height: Int
    /// Display aspect ratio (width / height) the presenter must honour, which
    /// is not always `width / height`: several systems used non-square pixels.
    public let aspectRatio: Double
    /// Whether the emulated hardware reads touches on this screen.
    public let acceptsTouch: Bool

    public init(id: String, width: Int, height: Int, aspectRatio: Double? = nil, acceptsTouch: Bool = false) {
        self.id = id
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio ?? (Double(width) / Double(height))
        self.acceptsTouch = acceptsTouch
    }
}

// MARK: - Firmware

/// A firmware/BIOS file a system needs before Relay can start a game.
/// Relay never bundles proprietary firmware; the player supplies it.
public struct FirmwareRequirement: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    /// What to call it to the player, e.g. "PlayStation system software".
    public let displayName: String
    /// File names the ecosystem uses, shown as a hint. Never a storage path.
    public let expectedFileNames: [String]
    /// Exact size in bytes when the ecosystem publishes an authoritative one.
    public let sizeInBytes: Int?
    /// Lowercase hex SHA-256 of the authoritative file when one is published.
    public let sha256: String?
    /// False when the core runs without it (a high-level emulation fallback exists).
    public let isRequired: Bool

    public init(id: String, displayName: String, expectedFileNames: [String],
                sizeInBytes: Int? = nil, sha256: String? = nil, isRequired: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.expectedFileNames = expectedFileNames
        self.sizeInBytes = sizeInBytes
        self.sha256 = sha256
        self.isRequired = isRequired
    }
}

// MARK: - Controls

/// A control the emulated hardware physically has. Relay's own vocabulary:
/// never an emulator button code, never a manufacturer's glyph.
public enum SystemControl: String, Hashable, Codable, Sendable, CaseIterable {
    /// Eight-way digital pad.
    case dPad
    /// Continuous stick. `analog` systems keep the real value; they never
    /// quantise it into pad presses.
    case leftStick
    case rightStick
    case leftStickClick
    case rightStickClick
    /// The two primary face buttons every target system has.
    case faceA
    case faceB
    /// The second pair, on systems that have four face buttons.
    case faceX
    case faceY
    /// The Nintendo 64's yellow C directions, which behave as four buttons.
    case cPad
    case shoulderL
    case shoulderR
    case triggerL
    case triggerR
    /// The Nintendo 64's Z trigger.
    case triggerZ
    case start
    case select
    /// Mega Drive's third face button row / Mode.
    case mode
    /// A screen the hardware itself reads touches from.
    case touchScreen
    case microphone

    /// Whether this control carries a continuous value rather than a press.
    public var isAnalog: Bool {
        switch self {
        case .leftStick, .rightStick, .triggerL, .triggerR: return true
        default: return false
        }
    }
}

/// The complete set of controls a system offers, in Relay's vocabulary.
/// Touch layouts, controller mappings and keyboard mappings are all derived
/// from this; none of them may hardcode a particular system's shape.
public struct SystemInputLayout: Hashable, Codable, Sendable {
    public let controls: [SystemControl]
    /// What the hardware prints on a control when it is not the usual letter:
    /// the Master System's "1"/"2", the PC Engine's "I"/"II" and "RUN". Touch
    /// layouts show these; controllers and keyboards never need them.
    public let labels: [SystemControl: String]

    public init(_ controls: [SystemControl], labels: [SystemControl: String] = [:]) {
        self.controls = controls
        self.labels = labels
    }

    /// The label a touch button shows for `control`, or nil for the default.
    public func label(for control: SystemControl) -> String? { labels[control] }

    public func has(_ control: SystemControl) -> Bool { controls.contains(control) }
    /// True when any control of this system carries a continuous value.
    public var hasAnalog: Bool { controls.contains(where: \.isAnalog) }
    public var faceButtonCount: Int {
        [SystemControl.faceA, .faceB, .faceX, .faceY].filter(controls.contains).count
    }
}

// MARK: - Availability

/// Whether Relay may currently play a system, and why not when it may not.
/// A system Relay cannot play may still be recognised on import so the player
/// gets a true answer instead of "unsupported file".
public enum SystemAvailability: Hashable, Codable, Sendable {
    case playable
    /// Relay recognises the content but ships no core for it. The reason is a
    case deferred(reason: DeferralReason)

    public enum DeferralReason: String, Hashable, Codable, Sendable {
        /// Every known core forbids commercial use.
        case licenceProhibitsCommercialUse
        /// A commercially usable core exists but its copyleft obligations
        /// against App Store distribution are unresolved (owner/legal decision).
        case copyleftReviewRequired
        /// Acceptable speed needs a JIT Relay cannot ship through the App Store.
        case requiresJIT
        /// No core reaches Relay's quality or stability bar.
        case quality
    }

    public var isPlayable: Bool { if case .playable = self { return true }; return false }
}

// MARK: - The descriptor

public struct SystemDescriptor: Hashable, Codable, Sendable, Identifiable {
    public let id: SystemID
    /// User-facing name, e.g. "Game Boy Advance".
    public let name: String
    /// Short user-facing name, e.g. "GBA".
    public let shortName: String
    /// Manufacturer, e.g. "Nintendo".
    public let manufacturer: String
    /// Lowercase file extensions (without dot) that identify content for this
    /// system. For `discPackage` systems these are the manifest's extensions.
    public let fileExtensions: [String]
    /// How a game of this system is packaged and stored.
    public let packaging: ContentPackaging
    /// The one core Relay uses for this system. Nil while the system is deferred:
    /// the player is never asked to choose, so a system without a choice has none.
    public let preferredCoreID: CoreID?
    /// The controls the hardware has.
    public let inputLayout: SystemInputLayout
    /// The pictures the hardware draws, in presentation order.
    public let screens: [LogicalScreen]
    /// Firmware the player must supply before a game can start.
    public let firmware: [FirmwareRequirement]
    /// Whether cartridges of this system carry their own persistent memory.
    /// A system without it (PC Engine HuCards) has no battery save to snapshot;
    /// its progress is carried by save states only.
    public let saveMemory: SaveMemory
    /// Whether Relay can currently play this system.
    public let availability: SystemAvailability

    public enum SaveMemory: String, Hashable, Codable, Sendable {
        /// Battery-backed RAM, flash or EEPROM on the cartridge.
        case cartridge
        /// Nothing persistent on the cartridge.
        case none
    }

    public init(id: SystemID, name: String, shortName: String, manufacturer: String,
                fileExtensions: [String], packaging: ContentPackaging = .singleFile,
                preferredCoreID: CoreID? = nil, inputLayout: SystemInputLayout,
                screens: [LogicalScreen], firmware: [FirmwareRequirement] = [],
                saveMemory: SaveMemory = .cartridge,
                availability: SystemAvailability) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.manufacturer = manufacturer
        self.fileExtensions = fileExtensions.map { $0.lowercased() }
        self.packaging = packaging
        self.preferredCoreID = preferredCoreID
        self.inputLayout = inputLayout
        self.screens = screens
        self.firmware = firmware
        self.saveMemory = saveMemory
        self.availability = availability
    }

    /// Whether Relay can currently play this system.
    public var isPlayable: Bool { availability.isPlayable }
    /// The screen the player touches, when the hardware has one.
    public var touchScreen: LogicalScreen? { screens.first(where: \.acceptsTouch) }
}

// MARK: - The catalog

public extension SystemID {
    static let gameBoy: SystemID = "gb"
    static let gameBoyColor: SystemID = "gbc"
    static let gameBoyAdvance: SystemID = "gba"
    static let nes: SystemID = "nes"
    static let snes: SystemID = "snes"
    static let nintendo64: SystemID = "n64"
    static let nintendoDS: SystemID = "nds"
    static let masterSystem: SystemID = "sms"
    static let gameGear: SystemID = "gg"
    static let megaDrive: SystemID = "md"
    static let playStation: SystemID = "ps1"
    static let playStationPortable: SystemID = "psp"
    static let pcEngine: SystemID = "pce"
    static let pcEngineCD: SystemID = "pcecd"
    static let wonderSwan: SystemID = "ws"
    static let wonderSwanColor: SystemID = "wsc"
    static let neoGeoPocket: SystemID = "ngp"
    static let neoGeoPocketColor: SystemID = "ngpc"
}

/// The systems Relay knows about. Extend here (and only here) when a system is
/// approved. `availability` is the gate: a deferred system is recognised on
/// import and shown honestly, but never launched.
public enum SystemCatalog {
    // Shorthands for the layouts the target matrix uses.
    private static let padTwoButtons = SystemInputLayout([.dPad, .faceA, .faceB, .start, .select])
    private static let padTwoButtonsStartOnly = SystemInputLayout([.dPad, .faceA, .faceB, .start])
    private static let padShoulders = SystemInputLayout([.dPad, .faceA, .faceB, .shoulderL, .shoulderR, .start, .select])
    private static let padFourShoulders = SystemInputLayout([.dPad, .faceA, .faceB, .faceX, .faceY,
                                                             .shoulderL, .shoulderR, .start, .select])

    // MARK: Nintendo

    public static let gameBoy = SystemDescriptor(
        id: .gameBoy, name: "Game Boy", shortName: "GB", manufacturer: "Nintendo",
        fileExtensions: ["gb"], preferredCoreID: "mgba",
        inputLayout: padTwoButtons,
        screens: [LogicalScreen(id: "main", width: 160, height: 144)],
        availability: .playable)

    public static let gameBoyColor = SystemDescriptor(
        id: .gameBoyColor, name: "Game Boy Color", shortName: "GBC", manufacturer: "Nintendo",
        fileExtensions: ["gbc"], preferredCoreID: "mgba",
        inputLayout: padTwoButtons,
        screens: [LogicalScreen(id: "main", width: 160, height: 144)],
        availability: .playable)

    public static let gameBoyAdvance = SystemDescriptor(
        id: .gameBoyAdvance, name: "Game Boy Advance", shortName: "GBA", manufacturer: "Nintendo",
        fileExtensions: ["gba"], preferredCoreID: "mgba",
        inputLayout: padShoulders,
        screens: [LogicalScreen(id: "main", width: 240, height: 160)],
        availability: .playable)

    public static let nes = SystemDescriptor(
        id: .nes, name: "Nintendo Entertainment System", shortName: "NES", manufacturer: "Nintendo",
        fileExtensions: ["nes"], preferredCoreID: "mesen2",
        inputLayout: padTwoButtons,
        screens: [LogicalScreen(id: "main", width: 256, height: 240, aspectRatio: 4.0 / 3.0)],
        availability: .playable)

    public static let snes = SystemDescriptor(
        id: .snes, name: "Super Nintendo Entertainment System", shortName: "SNES", manufacturer: "Nintendo",
        fileExtensions: ["sfc", "smc"], preferredCoreID: "mesen2",
        inputLayout: padFourShoulders,
        screens: [LogicalScreen(id: "main", width: 256, height: 224, aspectRatio: 4.0 / 3.0)],
        availability: .playable)

    public static let nintendo64 = SystemDescriptor(
        id: .nintendo64, name: "Nintendo 64", shortName: "N64", manufacturer: "Nintendo",
        fileExtensions: ["z64", "n64", "v64"],
        inputLayout: SystemInputLayout([.dPad, .leftStick, .faceA, .faceB, .cPad,
                                        .shoulderL, .shoulderR, .triggerZ, .start]),
        screens: [LogicalScreen(id: "main", width: 320, height: 240, aspectRatio: 4.0 / 3.0)],
        availability: .deferred(reason: .requiresJIT))

    public static let nintendoDS = SystemDescriptor(
        id: .nintendoDS, name: "Nintendo DS", shortName: "DS", manufacturer: "Nintendo",
        fileExtensions: ["nds"], preferredCoreID: "melonds",
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .faceX, .faceY,
                                        .shoulderL, .shoulderR, .start, .select,
                                        .touchScreen, .microphone]),
        screens: [LogicalScreen(id: "top", width: 256, height: 192),
                  LogicalScreen(id: "bottom", width: 256, height: 192, acceptsTouch: true)],
        // No firmware: melonDS boots games directly with its own free BIOS and a
        // generated firmware image, so nothing of Nintendo's is needed or read.
        availability: .playable)

    // MARK: Sega

    /// Buttons "1" and "2"; "2" is the right-hand one, so it takes the A role.
    /// The console's Pause is on the console itself and behaves like Start.
    public static let masterSystem = SystemDescriptor(
        id: .masterSystem, name: "Master System", shortName: "SMS", manufacturer: "Sega",
        fileExtensions: ["sms"], preferredCoreID: "mesen2",
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .start],
                                       labels: [.faceA: "2", .faceB: "1", .start: "PAUSE"]),
        screens: [LogicalScreen(id: "main", width: 256, height: 192, aspectRatio: 4.0 / 3.0)],
        availability: .playable)

    public static let gameGear = SystemDescriptor(
        id: .gameGear, name: "Game Gear", shortName: "GG", manufacturer: "Sega",
        fileExtensions: ["gg"], preferredCoreID: "mesen2",
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .start],
                                       labels: [.faceA: "2", .faceB: "1"]),
        screens: [LogicalScreen(id: "main", width: 160, height: 144)],
        availability: .playable)

    public static let megaDrive = SystemDescriptor(
        id: .megaDrive, name: "Mega Drive", shortName: "MD", manufacturer: "Sega",
        fileExtensions: ["md", "gen", "bin"],
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .faceX, .faceY,
                                        .shoulderL, .shoulderR, .start, .mode]),
        screens: [LogicalScreen(id: "main", width: 320, height: 224, aspectRatio: 4.0 / 3.0)],
        availability: .deferred(reason: .licenceProhibitsCommercialUse))

    // MARK: Sony

    public static let playStation = SystemDescriptor(
        id: .playStation, name: "PlayStation", shortName: "PS", manufacturer: "Sony",
        fileExtensions: ["cue", "chd", "m3u"], packaging: .discPackage, preferredCoreID: "pcsx-rearmed",
        inputLayout: SystemInputLayout([.dPad, .leftStick, .rightStick, .leftStickClick, .rightStickClick,
                                        .faceA, .faceB, .faceX, .faceY,
                                        .shoulderL, .shoulderR, .triggerL, .triggerR,
                                        .start, .select],
                                       labels: [.faceA: "○", .faceB: "×", .faceX: "△", .faceY: "□", .shoulderL: "L1", .shoulderR: "R1"]),
        screens: [LogicalScreen(id: "main", width: 320, height: 240, aspectRatio: 4.0 / 3.0)],
        firmware: [FirmwareRequirement(id: "ps1-bios", displayName: "PlayStation system software",
                                       expectedFileNames: ["scph5500.bin", "scph5501.bin", "scph5502.bin"],
                                       sizeInBytes: 524_288, isRequired: false)],
        availability: .playable)

    public static let playStationPortable = SystemDescriptor(
        id: .playStationPortable, name: "PlayStation Portable", shortName: "PSP", manufacturer: "Sony",
        fileExtensions: ["iso", "cso"],
        inputLayout: SystemInputLayout([.dPad, .leftStick, .faceA, .faceB, .faceX, .faceY,
                                        .shoulderL, .shoulderR, .start, .select]),
        screens: [LogicalScreen(id: "main", width: 480, height: 272)],
        availability: .deferred(reason: .requiresJIT))

    // MARK: NEC

    /// HuCard only. Buttons "I" (right, the A role) and "II"; Run is Start.
    /// HuCards carry no save memory: progress lives in save states.
    public static let pcEngine = SystemDescriptor(
        id: .pcEngine, name: "PC Engine", shortName: "PCE", manufacturer: "NEC",
        fileExtensions: ["pce"], preferredCoreID: "mesen2",
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .start, .select],
                                       labels: [.faceA: "I", .faceB: "II", .start: "RUN"]),
        screens: [LogicalScreen(id: "main", width: 256, height: 239, aspectRatio: 4.0 / 3.0)],
        saveMemory: .none,
        availability: .playable)

    public static let pcEngineCD = SystemDescriptor(
        id: .pcEngineCD, name: "PC Engine CD", shortName: "PCECD", manufacturer: "NEC",
        fileExtensions: ["cue", "chd"], packaging: .discPackage,
        inputLayout: padTwoButtons,
        screens: [LogicalScreen(id: "main", width: 256, height: 239, aspectRatio: 4.0 / 3.0)],
        firmware: [FirmwareRequirement(id: "pce-system-card", displayName: "PC Engine CD system card",
                                       expectedFileNames: ["syscard3.pce"])],
        availability: .deferred(reason: .copyleftReviewRequired))

    // MARK: Other handhelds

    /// Two four-way clusters: X (the pad, `.dPad`) and Y (`.cPad`), plus A, B
    /// and Start. Games that are held upright rotate the picture and swap the
    /// roles of the clusters; the driver follows the game's own orientation.
    private static let wonderSwanControls = SystemInputLayout([.dPad, .cPad, .faceA, .faceB, .start],
                                                              labels: [.cPad: "Y"])

    public static let wonderSwan = SystemDescriptor(
        id: .wonderSwan, name: "WonderSwan", shortName: "WS", manufacturer: "Bandai",
        fileExtensions: ["ws"], preferredCoreID: "mesen2",
        inputLayout: wonderSwanControls,
        screens: [LogicalScreen(id: "main", width: 224, height: 144)],
        availability: .playable)

    public static let wonderSwanColor = SystemDescriptor(
        id: .wonderSwanColor, name: "WonderSwan Color", shortName: "WSC", manufacturer: "Bandai",
        fileExtensions: ["wsc"], preferredCoreID: "mesen2",
        inputLayout: wonderSwanControls,
        screens: [LogicalScreen(id: "main", width: 224, height: 144)],
        availability: .playable)

    public static let neoGeoPocket = SystemDescriptor(
        id: .neoGeoPocket, name: "Neo Geo Pocket", shortName: "NGP", manufacturer: "SNK",
        fileExtensions: ["ngp"],
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .start]),
        screens: [LogicalScreen(id: "main", width: 160, height: 152)],
        availability: .deferred(reason: .copyleftReviewRequired))

    public static let neoGeoPocketColor = SystemDescriptor(
        id: .neoGeoPocketColor, name: "Neo Geo Pocket Color", shortName: "NGPC", manufacturer: "SNK",
        fileExtensions: ["ngc"],
        inputLayout: SystemInputLayout([.dPad, .faceA, .faceB, .start]),
        screens: [LogicalScreen(id: "main", width: 160, height: 152)],
        availability: .deferred(reason: .copyleftReviewRequired))

    public static let all: [SystemDescriptor] = [
        gameBoy, gameBoyColor, gameBoyAdvance, nes, snes, nintendo64, nintendoDS,
        masterSystem, gameGear, megaDrive,
        playStation, playStationPortable,
        pcEngine, pcEngineCD,
        wonderSwan, wonderSwanColor, neoGeoPocket, neoGeoPocketColor,
    ]

    /// The systems a player can actually play today. This is what the library
    /// UI offers; deferred systems are never presented as playable.
    public static var playable: [SystemDescriptor] { all.filter(\.isPlayable) }

    public static func descriptor(for id: SystemID) -> SystemDescriptor? {
        all.first { $0.id == id }
    }

    /// Systems whose content uses `fileExtension` (case-insensitive, no dot).
    /// Several systems may share an extension; callers decide how to disambiguate.
    public static func systems(forFileExtension fileExtension: String) -> [SystemDescriptor] {
        let ext = fileExtension.lowercased()
        return all.filter { $0.fileExtensions.contains(ext) }
    }
}
