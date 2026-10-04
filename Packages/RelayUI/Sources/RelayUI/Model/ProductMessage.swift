// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ProductMessage.swift
//  Technical detail never reaches these strings; it goes to the log.

import Foundation
import OSLog
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelaySync

let relayLog = Logger(subsystem: "app.relayemu.relay", category: "library")

/// Headline + one sentence + the next action.
public struct ProductMessage: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case importFiles
        case whichFormats
        case tryAgain
        case showDiagnostics
        case close
        case downloadAndPlay(GameID)
        case manageStorage
        case openSettings
        case compare(GameID)
        case howToAdd
        case syncWithThisAccount
        case relayPro
    }

    public let id = UUID()
    public let headline: String
    public let message: String
    public let action: Action?
    public let isCritical: Bool

    public init(headline: String, message: String, action: Action? = nil, isCritical: Bool = false) {
        self.headline = headline
        self.message = message
        self.action = action
        self.isCritical = isCritical
    }

    public static func == (lhs: ProductMessage, rhs: ProductMessage) -> Bool { lhs.id == rhs.id }

    // MARK: Import outcomes (§9.3)

    static func forImport(_ outcome: ImportOutcome, deviceKind: DeviceKind) -> ProductMessage? {
        let name = outcome.displayName
        switch outcome.result {
        case .added, .duplicate:
            return nil
        case .unsupported:
            return ProductMessage(headline: String(localized: "\(name) isn't a supported format.", bundle: .module),
                                  message: String(localized: "Relay couldn't recognise this file.", bundle: .module),
                                  action: .whichFormats)
        case .invalid(let system):
            let systemName = Formatting.systemName(system)
            return ProductMessage(headline: String(localized: "\(name) looks damaged.", bundle: .module),
                                  message: String(localized: "It has a \(systemName) name but not the contents of a game. Try another copy of the file.", bundle: .module),
                                  action: .importFiles)
        case .archiveRejected(let reason):
            relayLog.notice("archive rejected: \(name, privacy: .public): \(reason, privacy: .public)")
            return ProductMessage(headline: String(localized: "\(name) couldn't be opened.", bundle: .module),
                                  message: String(localized: "The archive is larger than Relay can safely unpack, or it isn't a plain ZIP. Unzip it and import the game files directly.", bundle: .module),
                                  action: .importFiles)
        case .discRejected(let reason):
            let message: String
            switch reason {
            case .missingFiles:
                message = String(localized: "Select the disc file together with all of its tracks. For a multi-disc game, select its playlist and all discs too.", bundle: .module)
            case .tooLarge:
                message = String(localized: "This disc set is larger than Relay can import. The limit is 4 GB per game.", bundle: .module)
            case .unsupportedDisc:
                message = String(localized: "Relay couldn't read this PlayStation disc format. Use a CUE with BIN tracks, or a supported CHD disc.", bundle: .module)
            default:
                message = String(localized: "The PlayStation disc is incomplete or damaged. Select a complete copy of the game and try again.", bundle: .module)
            }
            return ProductMessage(headline: String(localized: "\(name) couldn't be opened.", bundle: .module), message: message, action: .importFiles)
        case .archiveEmpty:
            return ProductMessage(headline: String(localized: "\(name) has no game files.", bundle: .module),
                                  message: String(localized: "The archive opened fine but nothing inside looks like a game.", bundle: .module),
                                  action: .whichFormats)
        case .storageFull:
            return ProductMessage(headline: String(localized: "Not enough space on \(Formatting.thisDevice(deviceKind)).", bundle: .module),
                                  message: String(localized: "Free up some space and try again.", bundle: .module),
                                  action: .tryAgain, isCritical: true)
        case .failed(let detail):
            relayLog.error("import failed: \(name, privacy: .public): \(detail, privacy: .public)")
            return ProductMessage(headline: String(localized: "\(name) couldn't be added.", bundle: .module),
                                  message: String(localized: "Something went wrong while copying it. A report is ready in Diagnostics.", bundle: .module),
                                  action: .tryAgain, isCritical: true)
        }
    }

    // MARK: Launch failures (§19)

    static func forLaunch(_ error: Error, title: String) -> ProductMessage {
        relayLog.error("launch failed for \(title, privacy: .public): \(String(describing: error), privacy: .public)")
        if error is PlayStationFirmwareError || error as? EmulationError == .firmwareInvalid {
            return ProductMessage(headline: L("The PlayStation firmware needs attention."),
                message: L("Open Settings → PlayStation Firmware and import a compatible file again."), action: .close)
        }
        if let resolution = error as? LaunchResolutionError {
            switch resolution {
            case .contentMissing, .missingPrimaryFile:
                return ProductMessage(headline: String(localized: "\(title) is missing its game file.", bundle: .module),
                                      message: String(localized: "The file isn't where Relay keeps it any more. Import it again to play.", bundle: .module),
                                      action: .importFiles, isCritical: true)
            case .gameNotFound:
                return ProductMessage(headline: String(localized: "That game isn't in your library any more.", bundle: .module),
                                      message: String(localized: "It may have been deleted. Import it again to play.", bundle: .module),
                                      action: .importFiles)
            case .noCoreForSystem(let system):
                return ProductMessage(headline: String(localized: "\(Formatting.systemName(system)) games can't be played yet.", bundle: .module),
                                      message: String(localized: "This version of Relay doesn't play this system.", bundle: .module),
                                      action: .close)
            }
        }
        return ProductMessage(headline: String(localized: "This game won't start.", bundle: .module),
                              message: String(localized: "Relay couldn't load it. A report is ready in Diagnostics.", bundle: .module),
                              action: .showDiagnostics, isCritical: true)
    }

    static func relayProRequiredOnMac(title: String) -> ProductMessage {
        ProductMessage(
            headline: String(localized: "Relay Pro plays on Mac.", bundle: .module),
            message: String(localized: "Your library and saves stay available. Get Relay Pro to start or continue \(title) in the native Mac app.", bundle: .module),
            action: .relayPro
        )
    }

    // MARK: Continuity (CONTINUITY_UX §6–8, UX §19)

    /// The file is in iCloud but not here (game-file sync on): offer the download.
    static func cloudOnly(gameID: GameID, title: String, size: Int64, deviceKind: DeviceKind) -> ProductMessage {
        ProductMessage(headline: Formatting.notOnThisDeviceYet(deviceKind),
                       message: String(localized: "It's in your sync storage (\(Formatting.bytes(size))). Download it and play.", bundle: .module),
                       action: .downloadAndPlay(gameID))
    }

    /// Progress exists but the file is on another device (Free, or game-file sync off).
    static func onAnotherDevice(title: String, deviceKind: DeviceKind) -> ProductMessage {
        ProductMessage(headline: Formatting.notOnThisDeviceYet(deviceKind),
                       message: String(localized: "Your progress for \(title) is here. Add the game file on \(Formatting.thisDevice(deviceKind)) to keep playing.", bundle: .module),
                       action: .howToAdd)
    }

    static func downloadFailed(_ error: Error, title: String, deviceKind: DeviceKind) -> ProductMessage {
        relayLog.error("download failed; see sync error category")
        if let content = error as? SyncContentError, content == .notInCloud || content == .unavailable {
            return onAnotherDevice(title: title, deviceKind: deviceKind)
        }
        if let content = error as? SyncContentError, content == .verificationFailed {
            return ProductMessage(headline: String(localized: "The download of \(title) didn't check out.", bundle: .module),
                                  message: String(localized: "The downloaded file doesn't match the game. Nothing on \(Formatting.thisDevice(deviceKind)) was changed.", bundle: .module),
                                  action: .tryAgain, isCritical: true)
        }
        if let content = error as? SyncContentError, content == .unsupportedLayout {
            return ProductMessage(headline: String(localized: "\(title) can't be downloaded by this version of Relay.", bundle: .module),
                                  message: String(localized: "Add the game files on this device to keep playing.", bundle: .module),
                                  action: .howToAdd)
        }
        return ProductMessage(headline: String(localized: "Download paused.", bundle: .module),
                              message: String(localized: "It picks up when you're back online.", bundle: .module),
                              action: .close)
    }

    static func twoVersions(gameID: GameID, title: String, deviceA: DeviceKind, deviceB: DeviceKind) -> ProductMessage {
        ProductMessage(headline: String(localized: "Two versions of your \(title) save.", bundle: .module),
                       message: String(localized: "You played on \(Formatting.deviceName(deviceA)) and \(Formatting.deviceName(deviceB)) while they were out of sync. Choose which progress to keep.", bundle: .module),
                       action: .compare(gameID), isCritical: true)
    }

    static func quotaFull(deviceKind: DeviceKind, hosted: Bool = false) -> ProductMessage {
        ProductMessage(headline: hosted ? L("Relay Sync storage is full.") : L("iCloud storage is full."),
                       message: String(localized: "Your saves are safe on \(Formatting.thisDevice(deviceKind)) but haven't synced yet.", bundle: .module),
                       action: .manageStorage, isCritical: true)
    }

    static func pendingTooLong(count: Int) -> ProductMessage {
        ProductMessage(headline: String(localized: "Some progress hasn't synced yet.", bundle: .module),
                       message: String(localized: "\(count) items are waiting. Relay keeps trying in the background.", bundle: .module),
                       action: .showDiagnostics)
    }

    static func cloudOff(deviceKind: DeviceKind) -> ProductMessage {
        ProductMessage(headline: String(localized: "iCloud is off.", bundle: .module),
                       message: String(localized: "Your games and saves stay on \(Formatting.thisDevice(deviceKind)). Turn on iCloud in Settings to sync them.", bundle: .module),
                       action: .openSettings)
    }

    static func accountChanged(deviceKind: DeviceKind, hosted: Bool = false) -> ProductMessage {
        ProductMessage(headline: hosted ? L("A different Relay account is connected.") : L("A different iCloud account is signed in."),
                       message: String(localized: "Your library stays on \(Formatting.thisDevice(deviceKind)). Nothing is sent to the new account until you say so.", bundle: .module),
                       action: .syncWithThisAccount, isCritical: true)
    }

    // MARK: Saves (§19, owner rule §27)

    static func forSaveFailure(_ error: Error, title: String) -> ProductMessage {
        relayLog.error("save failed for \(title, privacy: .public): \(String(describing: error), privacy: .public)")
        return ProductMessage(headline: String(localized: "Your last save didn't go through.", bundle: .module),
                              message: String(localized: "Relay couldn't write the save for \(title). Your previous save is fine.", bundle: .module),
                              action: .showDiagnostics, isCritical: true)
    }

    static func forStateLoad(_ error: Error) -> ProductMessage {
        relayLog.error("state load refused: \(String(describing: error), privacy: .public)")
        if error as? EmulationError == .stateFirmwareMismatch {
            return ProductMessage(headline: L("This Save uses different PlayStation firmware."),
                message: L("Add the firmware used to create this Save in Settings, then try again."), action: .close)
        }
        if let load = error as? SaveStateLoadError {
            switch load {
            case .incompatible:
                return ProductMessage(headline: String(localized: "This save was made with an older version of Relay and can't be loaded safely.", bundle: .module),
                                      message: String(localized: "Your in-game save is still available.", bundle: .module),
                                      action: .close)
            case .missing:
                return ProductMessage(headline: String(localized: "This save is gone.", bundle: .module),
                                      message: String(localized: "Its file isn't where Relay keeps it any more. Your in-game save is still available.", bundle: .module),
                                      action: .close)
            case .corrupt:
                return ProductMessage(headline: String(localized: "This save is damaged and can't be loaded.", bundle: .module),
                                      message: String(localized: "Your in-game save is still available.", bundle: .module),
                                      action: .close)
            }
        }
        return ProductMessage(headline: String(localized: "This save couldn't be loaded.", bundle: .module),
                              message: String(localized: "Relay couldn't restore it. A report is ready in Diagnostics.", bundle: .module),
                              action: .showDiagnostics)
    }

    static func forStorage(_ error: Error) -> ProductMessage {
        relayLog.error("library storage failure: \(String(describing: error), privacy: .public)")
        return ProductMessage(headline: String(localized: "Relay can't read your library.", bundle: .module),
                              message: String(localized: "Something is wrong with the library database. A report is ready in Diagnostics.", bundle: .module),
                              action: .showDiagnostics, isCritical: true)
    }
}
