// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import RelayDomain
@testable import RelayUI

@MainActor
final class PresentationOwnershipTests: XCTestCase {
    func testPauseToolBlocksGlobalCommandsUntilNativeDismissalCompletes() {
        let actions = RelayActions()
        XCTAssertTrue(actions.beginPresentation(.playTool))
        actions.whichFormats()
        actions.openDiagnostics()
        actions.openPlaySaves()
        actions.openRelayPro()
        actions.compare(GameID())
        XCTAssertFalse(actions.formatsSheetPresented)
        XCTAssertFalse(actions.diagnosticsPresented)
        XCTAssertFalse(actions.playSavesPresented)
        XCTAssertFalse(actions.relayProPresented)
        XCTAssertNil(actions.compareGameID)
        XCTAssertFalse(actions.canPresentRelaySurface)

        actions.presentationDidDismiss(.playTool)
        actions.openDiagnostics()
        XCTAssertTrue(actions.diagnosticsPresented)
        XCTAssertEqual(actions.activePresentation, .diagnostics)
    }

    func testRootSheetReservesItsLayerAfterBindingTurnsFalse() {
        let actions = RelayActions()
        actions.openRelayPro()
        actions.relayProPresented = false
        XCTAssertFalse(actions.canPresentRelaySurface, "closing animation still owns the layer")
        XCTAssertFalse(actions.beginPresentation(.librarySaves))
        actions.presentationDidDismiss(.pro)
        XCTAssertTrue(actions.beginPresentation(.librarySaves))
    }

    func testStaleDismissalCannotReleaseAnotherSurface() {
        let actions = RelayActions()
        XCTAssertTrue(actions.beginPresentation(.librarySaves))
        actions.presentationDidDismiss(.playTool)
        XCTAssertEqual(actions.activePresentation, .librarySaves)
        XCTAssertFalse(actions.canPresentRelaySurface)
    }

    func testDirectVerificationPresentationStillBlocksOrdinaryCommands() {
        let actions = RelayActions()
        actions.relayProPresented = true
        XCTAssertFalse(actions.beginPresentation(.playTool))
        actions.whichFormats()
        XCTAssertFalse(actions.formatsSheetPresented)
    }

    func testSystemImportPickerBlocksNewRelaySheetsWhileOpen() {
        let actions = RelayActions()
        actions.importFiles()
        XCTAssertTrue(actions.importPickerPresented)
        actions.openDiagnostics()
        actions.openRelayPro()
        XCTAssertFalse(actions.diagnosticsPresented)
        XCTAssertFalse(actions.relayProPresented)
        actions.importPickerPresented = false
        XCTAssertTrue(actions.canPresentRelaySurface)
    }

    func testSettingsReplayTransfersTheLayerOnlyAfterDismissal() {
        let actions = RelayActions()
        actions.openSettings()
        actions.replayOnboarding()
        XCTAssertFalse(actions.settingsPresented)
        XCTAssertFalse(actions.onboardingPresented)
        XCTAssertEqual(actions.activePresentation, .settings)
        actions.openDiagnostics()
        XCTAssertFalse(actions.diagnosticsPresented)
        actions.settingsDidDismiss()
        XCTAssertTrue(actions.onboardingPresented)
        XCTAssertEqual(actions.activePresentation, .onboarding)
    }

    func testStorageFailureWaitsForTheCurrentSurfaceAndKeepsItsRecovery() throws {
        let actions = RelayActions()
        let message = ProductMessage(headline: "Storage", message: "Try again", action: .showDiagnostics)
        XCTAssertTrue(actions.beginPresentation(.compare))
        XCTAssertNil(RelayRootAlert.pending(play: nil, storage: message, dismissedStorageID: nil,
                                            presentationOccupied: !actions.canPresentRelaySurface))
        actions.presentationDidDismiss(.compare)
        let pending = try XCTUnwrap(RelayRootAlert.pending(play: nil, storage: message, dismissedStorageID: nil,
                                                         presentationOccupied: !actions.canPresentRelaySurface))
        XCTAssertEqual(pending.id, message.id)
        XCTAssertEqual(pending.message.action, .showDiagnostics)
    }

    func testInlineAcknowledgementDoesNotHideANewerStorageFailure() {
        let actions = RelayActions()
        let first = ProductMessage(headline: "First", message: "Shown in Saves")
        let second = ProductMessage(headline: "Second", message: "Still needs attention")
        actions.acknowledgeStorageError(first.id)
        XCTAssertNil(RelayRootAlert.pending(play: nil, storage: first,
                                            dismissedStorageID: actions.acknowledgedStorageErrorID))
        XCTAssertEqual(RelayRootAlert.pending(play: nil, storage: second,
                                             dismissedStorageID: actions.acknowledgedStorageErrorID)?.id, second.id)
    }

    func testPlayerFailureDefersAndAcknowledgesOnlyTheVisibleIdentity() {
        let actions = RelayActions()
        let first = ProductMessage(headline: "First", message: "Shown in Cheats")
        let second = ProductMessage(headline: "Second", message: "New failure")
        XCTAssertNil(RelayPlayerAlert.pending(problem: first, acknowledgedID: nil, presentationOccupied: true))
        XCTAssertEqual(RelayPlayerAlert.pending(problem: first, acknowledgedID: nil, presentationOccupied: false)?.id, first.id)
        actions.acknowledgePlayError(first.id)
        XCTAssertNil(RelayPlayerAlert.pending(problem: first, acknowledgedID: actions.acknowledgedPlayErrorID,
                                              presentationOccupied: false))
        XCTAssertEqual(RelayPlayerAlert.pending(problem: second, acknowledgedID: actions.acknowledgedPlayErrorID,
                                               presentationOccupied: false)?.id, second.id)
    }

    func testDeferredSaveRequestIsTakenOnceAndCancellationCannotReplayIt() throws {
        let state = SaveState(gameID: GameID(), coreID: CoreID(rawValue: "fixture"), coreVersion: "1",
                              kind: .manual, createdAt: Date(timeIntervalSince1970: 0),
                              location: try ContentLocation(root: .managedLibrary, relativePath: "fixture.state"))
        var transfer = RelayDeferredSaveLaunch()
        XCTAssertNil(transfer.takeAfterDismissal(), "closing Saves without Load does not launch")
        transfer.request(state)
        XCTAssertEqual(try XCTUnwrap(transfer.takeAfterDismissal()).id, state.id)
        XCTAssertNil(transfer.takeAfterDismissal(), "a later dismissal cannot repeat the old launch")
    }
}
