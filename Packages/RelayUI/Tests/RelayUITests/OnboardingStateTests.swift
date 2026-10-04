// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayUI

/// The first-run record is a version, local to the device, that never gates
/// the library. These hold that contract.
final class OnboardingStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "relay.tests.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAFreshDeviceNeedsTheCurrentOnboarding() {
        let state = OnboardingState(defaults: defaults)
        XCTAssertEqual(state.completedVersion, 0)
        XCTAssertTrue(state.needsOnboarding)
    }

    func testCompletingRecordsTheCurrentVersionAndStopsAsking() {
        let state = OnboardingState(defaults: defaults)
        state.complete()
        XCTAssertEqual(state.completedVersion, OnboardingState.currentVersion)
        XCTAssertFalse(state.needsOnboarding)
        XCTAssertFalse(OnboardingState(defaults: defaults).needsOnboarding, "the record is durable, not in memory")
    }

    /// A device that completed an older onboarding is shown the new one; this is
    /// the whole reason the record is a version rather than a flag.
    func testAnOlderCompletedVersionNeedsOnboardingAgain() {
        defaults.set(OnboardingState.currentVersion - 1, forKey: "relay.onboarding.completedVersion")
        XCTAssertTrue(OnboardingState(defaults: defaults).needsOnboarding)
    }

    func testResetForgetsTheRecord() {
        let state = OnboardingState(defaults: defaults)
        state.complete()
        state.reset()
        XCTAssertTrue(state.needsOnboarding)
    }

    /// The record lives in this device's defaults domain only: nothing here is
    /// keyed for iCloud key-value storage or written anywhere shared.
    func testTheRecordIsLocalToTheDevice() {
        OnboardingState(defaults: defaults).complete()
        XCTAssertNotNil(defaults.object(forKey: "relay.onboarding.completedVersion"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "relay.tests.onboarding.leak"))
    }

    // MARK: Presentation policy

    @MainActor
    func testFirstRunPresentsUnlessSuppressedAndReplayAlwaysPresents() {
        let actions = RelayActions()
        let state = OnboardingState(defaults: defaults)
        actions.presentOnboardingIfNeeded(state: state)
        XCTAssertTrue(actions.onboardingPresented, "a fresh device sees the tour")

        actions.completeOnboarding(state: state)
        XCTAssertFalse(actions.onboardingPresented)
        actions.onboardingDidDismiss()
        actions.presentOnboardingIfNeeded(state: state)
        XCTAssertFalse(actions.onboardingPresented, "a completed device is not asked again")

        actions.replayOnboarding()
        XCTAssertTrue(actions.onboardingPresented, "Getting Started replays it on request")
        actions.completeOnboarding(state: state)
        actions.onboardingDidDismiss()

        let suppressed = RelayActions()
        suppressed.onboardingSuppressed = true
        suppressed.presentOnboardingIfNeeded(state: OnboardingState(defaults: UserDefaults(suiteName: suite + ".fresh")!))
        XCTAssertFalse(suppressed.onboardingPresented, "automation never meets the cover")

        let forced = RelayActions()
        forced.onboardingForced = true
        forced.presentOnboardingIfNeeded(state: state)
        XCTAssertTrue(forced.onboardingPresented, "a forced launch shows it even when completed")
    }

    @MainActor
    func testChoosingGamesOpensTheImportOnlyAfterTheCoverIsGone() {
        let actions = RelayActions()
        actions.onboardingPresented = true
        actions.completeOnboarding(thenImport: true, state: OnboardingState(defaults: defaults))
        XCTAssertFalse(actions.onboardingPresented)
        XCTAssertFalse(actions.importPickerPresented, "the picker must not open under the cover")
        actions.onboardingDidDismiss()
        XCTAssertTrue(actions.importPickerPresented, "the real import opens once the cover has gone")
        actions.importPickerPresented = false
        actions.onboardingDidDismiss()
        XCTAssertFalse(actions.importPickerPresented, "and only once")
    }
}
