// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  OnboardingState.swift
//  RelayUI — whether this device has seen the current first-run experience.
//
//  A version, not a flag. Relay records which onboarding a device completed;
//  the first launch shows the current one, a later Relay that changes what a
//  player needs to know raises `currentVersion` and shows it again, and a
//  player can replay it from Settings at any time. The value is local to the
//  device (UserDefaults, never iCloud key-value storage) and nothing in the
//  library, the saves or sync reads it: onboarding explains Relay, it never
//  gates it.

import Foundation

public struct OnboardingState {
    /// The onboarding a fresh device is shown today. Raise it only when the
    /// content changes enough that an existing player should see it again.
    public static let currentVersion = 1

    private static let key = "relay.onboarding.completedVersion"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The version this device completed, 0 when it never did.
    public var completedVersion: Int {
        defaults.integer(forKey: Self.key)
    }

    /// True until the current version has been completed on this device.
    public var needsOnboarding: Bool {
        completedVersion < Self.currentVersion
    }

    /// Records that the current version was seen through (or skipped: a player
    /// who chose to skip has been told where to find it again).
    public func complete() {
        defaults.set(Self.currentVersion, forKey: Self.key)
    }

    /// Forgets the completion, so the next launch shows onboarding again.
    /// Used by tests and the Debug reset hook; the product replays through
    /// `RelayActions.replayOnboarding()` without touching the record.
    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
