// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Formatting.swift
//  RelayUI — localised presentation helpers (system formatters, String Catalog keys).

import Foundation
import RelayDomain
import RelayLibrary
import RelayEmulation
import RelayDesignSystem

/// Localised string from RelayUI's own catalog (LocalizedStringResource literals
/// would resolve against the main bundle).
func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }

enum Formatting {
    /// "2 hours ago", "yesterday" — system relative formatter.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now", bundle: .module) }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// "3 h 12 min" / "45 s".
    static func playDuration(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(max(0, seconds))
        if seconds < 60 {
            return duration.formatted(.units(allowed: [.seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// "Played on this iPhone · 2 h ago" with gendered French device kinds (LOCALIZATION.md §1.8).
    static func playedStatus(deviceKind: DeviceKind, at date: Date, now: Date = Date()) -> String {
        let time = relative(date, now: now)
        switch deviceKind {
        case .iPhone: return String(localized: "Played on this iPhone · \(time)", bundle: .module)
        case .iPad: return String(localized: "Played on this iPad · \(time)", bundle: .module)
        case .appleTV: return String(localized: "Played on this Apple TV · \(time)", bundle: .module)
        case .mac: return String(localized: "Played on this Mac · \(time)", bundle: .module)
        case .unknown: return String(localized: "Played here · \(time)", bundle: .module)
        }
    }

    /// "Played on iPad · 2 h ago" — a session from another device (generic kind, never a personal name).
    static func playedElsewhereStatus(deviceKind: DeviceKind, at date: Date, now: Date = Date()) -> String {
        let time = relative(date, now: now)
        switch deviceKind {
        case .iPhone: return String(localized: "Played on iPhone · \(time)", bundle: .module)
        case .iPad: return String(localized: "Played on iPad · \(time)", bundle: .module)
        case .appleTV: return String(localized: "Played on Apple TV · \(time)", bundle: .module)
        case .mac: return String(localized: "Played on Mac · \(time)", bundle: .module)
        case .unknown: return String(localized: "Played on another device · \(time)", bundle: .module)
        }
    }

    /// Visible last-played metadata uses the end of a finished session. An open or interrupted
    /// session falls back to its known start; stored history ordering remains unchanged.
    static func lastPlayedDate(session: PlaySession) -> Date {
        session.endedAt ?? session.startedAt
    }

    /// Status for a session: "this iPhone" when it happened on this installation, the generic kind otherwise.
    static func playedStatus(session: PlaySession, localInstallation: InstallationID?, thisDevice: DeviceKind, now: Date = Date()) -> String {
        let isLocal = session.origin == .local || (localInstallation != nil && session.installationID == localInstallation)
        let date = lastPlayedDate(session: session)
        return isLocal ? playedStatus(deviceKind: thisDevice, at: date, now: now)
                       : playedElsewhereStatus(deviceKind: session.deviceKind, at: date, now: now)
    }

    /// "this iPhone" as a noun phrase for sentences that name the device.
    static func thisDevice(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: return String(localized: "this iPhone", bundle: .module)
        case .iPad: return String(localized: "this iPad", bundle: .module)
        case .appleTV: return String(localized: "this Apple TV", bundle: .module)
        case .mac: return String(localized: "this Mac", bundle: .module)
        case .unknown: return String(localized: "this device", bundle: .module)
        }
    }

    /// "On this iPhone only" (CONTINUITY_UX §4).
    static func localOnly(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: return String(localized: "On this iPhone only", bundle: .module)
        case .iPad: return String(localized: "On this iPad only", bundle: .module)
        case .appleTV: return String(localized: "On this Apple TV only", bundle: .module)
        case .mac: return String(localized: "On this Mac only", bundle: .module)
        case .unknown: return String(localized: "On this device only", bundle: .module)
        }
    }

    /// "Not on this Apple TV" (Game Detail, content elsewhere).
    static func notOnThisDevice(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: return String(localized: "Not on this iPhone", bundle: .module)
        case .iPad: return String(localized: "Not on this iPad", bundle: .module)
        case .appleTV: return String(localized: "Not on this Apple TV", bundle: .module)
        case .mac: return String(localized: "Not on this Mac", bundle: .module)
        case .unknown: return String(localized: "Not on this device", bundle: .module)
        }
    }

    /// "Not on this iPhone yet." (headline when the content is elsewhere).
    static func notOnThisDeviceYet(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: return String(localized: "Not on this iPhone yet.", bundle: .module)
        case .iPad: return String(localized: "Not on this iPad yet.", bundle: .module)
        case .appleTV: return String(localized: "Not on this Apple TV yet.", bundle: .module)
        case .mac: return String(localized: "Not on this Mac yet.", bundle: .module)
        case .unknown: return String(localized: "Not on this device yet.", bundle: .module)
        }
    }

    /// Curated speed-control labels. Values stay numeric and compact in every locale.
    static func speedLabel(_ speed: EmulationSpeed) -> String {
        switch speed {
        case .quarter: return String(localized: "0.25×", bundle: .module)
        case .half: return String(localized: "0.5×", bundle: .module)
        case .normal: return String(localized: "Normal", bundle: .module)
        case .double: return String(localized: "2×", bundle: .module)
        case .triple: return String(localized: "3×", bundle: .module)
        case .quadruple: return String(localized: "4×", bundle: .module)
        case .maximum: return String(localized: "Max", bundle: .module)
        }
    }

    /// Direction names are words; the letters printed on game buttons stay unchanged.
    static func inputName(_ input: EmulationInput, system: SystemID? = nil) -> String {
        if system == .playStation {
            switch input {
            case .a: return L("Circle")
            case .b: return L("Cross")
            case .x: return L("Triangle")
            case .y: return L("Square")
            case .l: return "L1"
            case .r: return "R1"
            default: break
            }
        }
        switch input {
        case .up: return L("Up")
        case .down: return L("Down")
        case .left: return L("Left")
        case .right: return L("Right")
        case .cUp: return L("C Up")
        case .cDown: return L("C Down")
        case .cLeft: return L("C Left")
        case .cRight: return L("C Right")
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .l3: return "L3"
        case .r3: return "R3"
        case .l2: return "L2"
        case .r2: return "R2"
        case .z: return "Z"
        case .start: return "Start"
        case .select: return "Select"
        case .mode: return "Mode"
        }
    }

    /// Bare device name for save cards ("iPhone · 2 h ago"); generic, never a personal device name.
    static func deviceName(_ kind: DeviceKind) -> String {
        switch kind {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .appleTV: return "Apple TV"
        case .mac: return "Mac"
        case .unknown: return String(localized: "Another device", bundle: .module)
        }
    }

    static func deviceSymbol(_ kind: DeviceKind) -> RelaySymbol {
        switch kind {
        case .iPhone: return .deviceIPhone
        case .iPad: return .deviceIPad
        case .appleTV: return .deviceAppleTV
        case .mac: return .deviceMac
        case .unknown: return .deviceUnknown
        }
    }

    /// A system Relay ships knows its own name. Anything else — a game that arrived
    /// from a device running a newer Relay, say — is shown by its Relay short name
    /// rather than by a raw identifier, which is never something to put on a card.
    static func systemName(_ id: SystemID) -> String {
        SystemCatalog.descriptor(for: id)?.name ?? id.abbreviation
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
