// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) || os(macOS)
import XCTest
import RelayDomain
import RelayEmulation
@testable import RelayUI

@MainActor
private final class SuspendedClipCapture: GameplayClipCapturing {
    var available = true
    var continuation: CheckedContinuation<Void, Error>?
    var errorHandler: (@MainActor @Sendable (GameplayShareError) -> Void)?
    var seals = 0
    var drains = 0
    var stops = 0
    var limits: GameplayClipLimits?
    func start(sources: [VideoFrameSource], composition: GameplayShareComposition,
               limits: GameplayClipLimits, onError: @escaping @MainActor @Sendable (GameplayShareError) -> Void) async throws {
        self.limits = limits
        errorHandler = onError
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func seal() { seals += 1 }
    func drain() async { drains += 1 }
    func stop() async throws -> URL {
        stops += 1
        return URL(fileURLWithPath: "/tmp/Relay Gameplay Clip.mp4")
    }
    func allow() { continuation?.resume(); continuation = nil }
}

@MainActor
final class GameplaySharingLifecycleTests: XCTestCase {
    func testFreeStopsAutomaticallyWhileProContinuesPastFifteenSeconds() async throws {
        let freeCapture = SuspendedClipCapture(), proCapture = SuspendedClipCapture()
        let free = GameplaySharing(capture: freeCapture), pro = GameplaySharing(capture: proCapture)
        let first = Task { await free.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil) }
        let second = Task { await pro.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, limits: .pro) }
        while freeCapture.continuation == nil || proCapture.continuation == nil { await Task.yield() }
        freeCapture.allow()
        proCapture.allow()
        let freeStarted = await first.value, proStarted = await second.value
        XCTAssertTrue(freeStarted && proStarted)
        XCTAssertEqual(freeCapture.limits, .free)
        XCTAssertEqual(proCapture.limits, .pro)
        try await Task.sleep(for: .seconds(16.2))
        XCTAssertEqual(free.state, .idle)
        XCTAssertNotNil(free.clip)
        XCTAssertEqual(pro.state, .recording)
        XCTAssertGreaterThanOrEqual(pro.elapsedSeconds, 15)
        XCTAssertTrue(pro.elapsedTime.hasPrefix("0:"))
        pro.stopClip()
        while pro.state != .idle { await Task.yield() }
        XCTAssertNotNil(pro.clip)
    }

    func testProExpiryFinalizesAndPreservesCompletedRecording() async {
        let capture = SuspendedClipCapture()
        let sharing = GameplaySharing(capture: capture)
        let start = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, limits: .pro) }
        while capture.continuation == nil { await Task.yield() }
        capture.allow()
        _ = await start.value
        sharing.accessDidChange(limits: .free)
        while sharing.state != .idle { await Task.yield() }
        XCTAssertEqual(capture.stops, 1)
        XCTAssertNotNil(sharing.clip)
        XCTAssertNil(sharing.error)
    }

    func testLowStorageFinishesExistingMediaAndKeepsReasonVisible() async {
        let capture = SuspendedClipCapture()
        let sharing = GameplaySharing(capture: capture)
        let start = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, limits: .pro) }
        while capture.continuation == nil { await Task.yield() }
        capture.allow()
        _ = await start.value
        capture.errorHandler?(.storageLow)
        while sharing.state != .idle { await Task.yield() }
        XCTAssertNotNil(sharing.clip)
        XCTAssertEqual(sharing.error, .storageLow)
        XCTAssertEqual(capture.stops, 1)
    }

    func testProExpiryDuringConsentCannotResumeAFreeLongRecording() async {
        let capture = SuspendedClipCapture()
        let sharing = GameplaySharing(capture: capture)
        let start = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, limits: .pro) }
        while capture.continuation == nil { await Task.yield() }
        sharing.accessDidChange(limits: .free)
        capture.allow()
        let resumed = await start.value
        XCTAssertFalse(resumed)
        while sharing.state != .idle { await Task.yield() }
        XCTAssertEqual(capture.stops, 1)
    }

    func testExitDuringAppleConsentDrainsBeforeCoreCanStopAndCannotResumeOrPublishALaterClip() async {
        let capture = SuspendedClipCapture()
        let sharing = GameplaySharing(capture: capture)
        let start = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil) }
        while capture.continuation == nil { await Task.yield() }
        XCTAssertEqual(sharing.state, .starting)
        await sharing.endSession()
        XCTAssertEqual(capture.drains, 1)
        XCTAssertGreaterThan(capture.seals, 0)
        capture.allow()
        let shouldResume = await start.value
        XCTAssertFalse(shouldResume)
        while sharing.state != .idle { await Task.yield() }
        XCTAssertEqual(capture.stops, 1)
        XCTAssertNil(sharing.clip)
        XCTAssertNil(sharing.error)
    }

    func testLateCallbackFromPreviousCaptureCannotEndNewCapture() async {
        let capture = SuspendedClipCapture()
        let sharing = GameplaySharing(capture: capture)
        let first = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil) }
        while capture.continuation == nil { await Task.yield() }
        let staleError = capture.errorHandler
        capture.allow()
        _ = await first.value
        sharing.stopClip()
        while sharing.state != .idle { await Task.yield() }
        XCTAssertNotNil(sharing.clip)
        let second = Task { await sharing.startClip(sources: [ShareTestFrame()], screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil) }
        while capture.continuation == nil { await Task.yield() }
        staleError?(.capture)
        capture.allow()
        let shouldResume = await second.value
        XCTAssertTrue(shouldResume)
        XCTAssertEqual(sharing.state, .recording)
        XCTAssertNil(sharing.error)
        await sharing.endSession()
    }
}
#endif
