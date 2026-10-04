// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PlayPreferences.swift
//  touch-control behaviour, rewind duration. UserDefaults-backed; values are
//  plain and portable.

import Foundation
import RelayDomain
import RelayEmulation
import RelayVideo
import RelayInput
import RelayDesignSystem
import RelayEntitlements

public struct PlayPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Display (per system)

    public func displayOptions(for system: SystemID) -> DisplayOptions {
        var options = DisplayOptions.standard
        // Sharing a container between multiple pictures makes whole-pixel
        // steps waste substantial space on compact displays. Fit is the fresh
        // default; a saved per-system or per-game choice still wins below.
        if let descriptor = SystemCatalog.descriptor(for: system), descriptor.screens.count > 1 {
            options.scaling = .fit
        }
        if let raw = defaults.string(forKey: "relay.display.scaling.\(system.rawValue)"), let v = DisplayScaling(rawValue: raw) { options.scaling = v }
        if let raw = defaults.string(forKey: "relay.display.filter.\(system.rawValue)"), let v = DisplayFilter(rawValue: raw) { options.filter = v }
        return options
    }

    public func setDisplayOptions(_ options: DisplayOptions, for system: SystemID) {
        defaults.set(options.scaling.rawValue, forKey: "relay.display.scaling.\(system.rawValue)")
        defaults.set(options.filter.rawValue, forKey: "relay.display.filter.\(system.rawValue)")
    }

    public func displayOptions(for system: SystemID, gameID: GameID?, policy: RelayAccessPolicy) -> DisplayOptions {
        let stored: DisplayOptions
        if policy.allows(.advancedDisplay), let gameID,
           let perGame: DisplayOptions = decode("relay.display.game.\(gameID)") {
            stored = perGame
        } else {
            stored = displayOptions(for: system)
        }
        guard policy.allows(.advancedDisplay) else {
            return DisplayOptions(
                scaling: stored.scaling.isAdvanced ? .fit : stored.scaling,
                filter: stored.filter.isAdvanced ? .original : stored.filter
            )
        }
        return stored
    }

    public func setDisplayOptions(_ options: DisplayOptions, for gameID: GameID) {
        encode(options, key: "relay.display.game.\(gameID)")
    }

    public func clearDisplayOptions(for gameID: GameID) {
        defaults.removeObject(forKey: "relay.display.game.\(gameID)")
    }

    // MARK: Screens (per system)

    /// How a two-screen system is laid out; nil means "whatever fits the orientation".
    public func screenArrangement(for system: SystemID) -> ScreenArrangement? {
        defaults.string(forKey: "relay.display.screens.\(system.rawValue)").flatMap(ScreenArrangement.init(rawValue:))
    }

    public func setScreenArrangement(_ arrangement: ScreenArrangement?, for system: SystemID) {
        defaults.set(arrangement?.rawValue, forKey: "relay.display.screens.\(system.rawValue)")
    }

    public func screenArrangement(for system: SystemID, gameID: GameID?, policy: RelayAccessPolicy) -> ScreenArrangement? {
        let stored: ScreenArrangement?
        if policy.allows(.advancedDisplay), let gameID,
           let raw = defaults.string(forKey: "relay.display.screens.game.\(gameID)") {
            stored = ScreenArrangement(rawValue: raw)
        } else {
            stored = screenArrangement(for: system)
        }
        guard policy.allows(.advancedDisplay) else {
            return stored == .secondaryPrimary ? .primarySecondary : stored
        }
        return stored
    }

    public func setScreenArrangement(_ arrangement: ScreenArrangement?, for gameID: GameID) {
        defaults.set(arrangement?.rawValue, forKey: "relay.display.screens.game.\(gameID)")
    }

    public func clearScreenArrangement(for gameID: GameID) {
        defaults.removeObject(forKey: "relay.display.screens.game.\(gameID)")
    }

    // MARK: Touch controls

    public var touchHaptics: Bool {
        get { defaults.object(forKey: "relay.touch.haptics") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "relay.touch.haptics") }
    }

    public var touchOpacity: Double {
        get { defaults.object(forKey: "relay.touch.opacity") as? Double ?? 0.55 }
        nonmutating set { defaults.set(min(1, max(0.2, newValue)), forKey: "relay.touch.opacity") }
    }

    public func effectiveTouchOpacity(policy: RelayAccessPolicy) -> Double {
        policy.allows(.touchLayoutEditing) ? touchOpacity : 0.55
    }

    public func touchLayout(for system: SystemDescriptor, portrait: Bool, scale: CGFloat,
                            policy: RelayAccessPolicy, fitting size: CGSize? = nil) -> TouchLayout {
        let fallback = TouchLayout.layout(for: system.inputLayout, portrait: portrait, scale: scale)
        guard let custom = effectiveCustomTouchLayout(for: system.id, portrait: portrait, policy: policy) else {
            return size.map { fallback.anchoredForReach(in: $0, portrait: portrait) } ?? fallback
        }
        // Rendering may clamp a control to the current bounds, but resizing
        // never rewrites the user's normalized positions or point sizes.
        return custom.repaired(using: fallback)
    }

    /// The decoded custom canvas is effective only while the existing editing
    /// policy allows it. Resolution and resizing never write this preference.
    func effectiveCustomTouchLayout(for system: SystemID, portrait: Bool,
                                    policy: RelayAccessPolicy) -> TouchLayout? {
        guard policy.allows(.touchLayoutEditing) else { return nil }
        return decode(touchLayoutKey(system, portrait: portrait))
    }

    public func setTouchLayout(_ layout: TouchLayout, for system: SystemDescriptor,
                               portrait: Bool, scale: CGFloat) {
        let key = touchLayoutKey(system.id, portrait: portrait)
        if let stored: TouchLayout = decode(key), stored == layout { return }
        let fallback = TouchLayout.layout(for: system.inputLayout, portrait: portrait, scale: scale)
        encode(layout.repaired(using: fallback), key: key)
    }

    public func resetTouchLayout(for system: SystemID, portrait: Bool) {
        defaults.removeObject(forKey: touchLayoutKey(system, portrait: portrait))
    }

    public var showTouchControlsWithController: Bool {
        get { defaults.bool(forKey: "relay.touch.showWithController") }
        nonmutating set { defaults.set(newValue, forKey: "relay.touch.showWithController") }
    }

    public var twoFingerTapTogglesControls: Bool {
        get { defaults.object(forKey: "relay.touch.twoFingerToggle") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "relay.touch.twoFingerToggle") }
    }

    // MARK: Skins (per system; reads never erase a saved Pro choice)

    public func storedSkin(for system: SystemID) -> RelaySkinConfiguration {
        decode("relay.skin.v1.\(system.rawValue)") ?? .standard
    }

    public func skin(for system: SystemID, policy: RelayAccessPolicy) -> RelaySkinConfiguration {
        let stored = storedSkin(for: system)
        guard policy.allows(.touchLayoutEditing) else {
            return RelaySkinConfiguration(enabled: stored.enabled)
        }
        return stored
    }

    public func setSkinEnabled(_ enabled: Bool, for system: SystemID) {
        var stored = storedSkin(for: system)
        stored.enabled = enabled
        encode(stored, key: "relay.skin.v1.\(system.rawValue)")
    }

    public func setSkin(_ skin: RelaySkinConfiguration, for system: SystemID, policy: RelayAccessPolicy) {
        guard policy.allows(.touchLayoutEditing) else { return }
        encode(skin, key: "relay.skin.v1.\(system.rawValue)")
    }

    // MARK: Rewind and speed

    /// Seconds of history (Settings ▸ Rewind). 0 turns rewind off.
    public var rewindDuration: TimeInterval {
        get { defaults.object(forKey: "relay.rewind.duration") as? Double ?? 10 }
        nonmutating set { defaults.set(max(0, newValue), forKey: "relay.rewind.duration") }
    }

    public func rewindConfiguration(policy: RelayAccessPolicy) -> RewindConfiguration {
        var configuration = RewindConfiguration.standard
        configuration.duration = min(rewindDuration, policy.allows(.extendedRewind) ? 60 : 10)
        return configuration
    }

    /// The preset the Speed control switches to (2× or Max).
    public var fastForwardSpeed: EmulationSpeed {
        get { defaults.string(forKey: "relay.speed.fastForward").flatMap(EmulationSpeed.init(rawValue:)) ?? .double }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "relay.speed.fastForward") }
    }

    public func effectiveFastForwardSpeed(policy: RelayAccessPolicy, supported: Set<EmulationSpeed>) -> EmulationSpeed {
        let candidate = fastForwardSpeed
        if candidate == .double { return supported.contains(.double) ? .double : .normal }
        guard policy.allows(.advancedSpeeds), supported.contains(candidate) else {
            return supported.contains(.double) ? .double : .normal
        }
        return candidate
    }

    // MARK: Controller mappings

    public func controllerMapping(for system: SystemDescriptor, gameID: GameID?, policy: RelayAccessPolicy) -> ControllerMappingProfile {
        guard policy.allows(.advancedControllerMapping) else { return .init() }
        if let gameID, let perGame: ControllerMappingProfile = decode("relay.controller.game.\(gameID)") {
            return perGame.repaired(for: system.inputLayout)
        }
        let profile: ControllerMappingProfile = decode("relay.controller.system.\(system.id.rawValue)") ?? .init()
        return profile.repaired(for: system.inputLayout)
    }

    public func setControllerMapping(_ profile: ControllerMappingProfile, for system: SystemDescriptor) {
        encode(profile.repaired(for: system.inputLayout), key: "relay.controller.system.\(system.id.rawValue)")
    }

    public func setControllerMapping(_ profile: ControllerMappingProfile, for gameID: GameID,
                                     system: SystemDescriptor) {
        encode(profile.repaired(for: system.inputLayout), key: "relay.controller.game.\(gameID)")
    }

    public func hasControllerMapping(for gameID: GameID) -> Bool {
        defaults.data(forKey: "relay.controller.game.\(gameID)") != nil
    }

    public func clearControllerMapping(for gameID: GameID) {
        defaults.removeObject(forKey: "relay.controller.game.\(gameID)")
    }

    public func resetControllerMapping(for system: SystemID) {
        defaults.removeObject(forKey: "relay.controller.system.\(system.rawValue)")
    }

    // MARK: Cheats (per game)

    public func cheats(for gameID: GameID) -> [CheatDefinition] {
        decode("relay.cheats.game.\(gameID)") ?? []
    }

    public func setCheats(_ cheats: [CheatDefinition], for gameID: GameID) {
        encode(cheats, key: "relay.cheats.game.\(gameID)")
    }

    // MARK: Saves

    public var continueFromLatestSave: Bool {
        get { defaults.object(forKey: "relay.saves.continueFromLatest") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "relay.saves.continueFromLatest") }
    }

    private func touchLayoutKey(_ system: SystemID, portrait: Bool) -> String {
        "relay.touch.layout.\(system.rawValue).\(portrait ? "portrait" : "landscape")"
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
