// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayEmulation

final class RewindBufferTests: XCTestCase {
    private func state(_ i: Int, size: Int = 64 * 1024) -> Data {
        // Mostly stable bytes with a moving window of change, like a real machine state.
        var d = Data(repeating: 0x5A, count: size)
        let start = (i * 97) % (size - 512)
        for k in 0..<512 { d[start + k] = UInt8((i + k) & 0xFF) }
        return d
    }

    func testStepBackReturnsStatesInReverseOrder() {
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 100)
        let states = (0..<20).map { state($0) }
        for s in states { buffer.append(s) }
        XCTAssertEqual(buffer.statistics.entries, 19)
        for i in stride(from: 18, through: 0, by: -1) {
            XCTAssertEqual(buffer.stepBack(), states[i], "step to state \(i)")
        }
        XCTAssertNil(buffer.stepBack())
        XCTAssertEqual(buffer.statistics.entries, 0)
    }

    func testDeltasAreSmallAndByteBudgetIsHonoured() {
        let buffer = RewindBuffer(maxBytes: 20 * 1024, maxEntries: 1000)
        for i in 0..<200 { buffer.append(state(i)) }
        let stats = buffer.statistics
        XCTAssertLessThanOrEqual(stats.bytes, 20 * 1024)
        XCTAssertGreaterThan(stats.entries, 5, "compressed deltas of a 512-byte change must be far below 4 KB each")
        XCTAssertLessThan(stats.entries, 200, "eviction happened")
        // The newest entries are the ones kept.
        XCTAssertEqual(buffer.stepBack(), state(198))
    }

    func testEntryCapAndShrink() {
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 5)
        for i in 0..<10 { buffer.append(state(i)) }
        XCTAssertEqual(buffer.statistics.entries, 5)
        buffer.shrink(toBytes: 0)
        XCTAssertEqual(buffer.statistics.entries, 0)
        XCTAssertNil(buffer.stepBack(), "no history left, but the newest full state is still known")
        buffer.setEntryLimit(100)
        buffer.append(state(11))
        XCTAssertEqual(buffer.statistics.entries, 0, "changing the time cap must not undo the memory cap")
    }

    func testLiveLimitChangeKeepsNewestHistoryAndHonoursFreeCap() {
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 60)
        for i in 0..<50 { buffer.append(state(i)) }
        buffer.setLimits(maxBytes: 8 * 1024 * 1024, maxEntries: 10)

        XCTAssertEqual(buffer.statistics.entries, 10)
        XCTAssertEqual(buffer.stepBack(), state(48), "the newest valid history survives entitlement loss")
    }

    func testWallClockBudgetEvictsOldCapturesEvenWhenCadenceIsSlow() {
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 1_000, maxDuration: 10)
        buffer.append(state(0), capturedAt: 100)
        buffer.append(state(1), capturedAt: 105)
        buffer.append(state(2), capturedAt: 111)

        XCTAssertEqual(buffer.statistics.entries, 1)
        XCTAssertEqual(buffer.statistics.retainedSeconds, 6)
        XCTAssertEqual(buffer.stepBack(), state(1), "only a state inside the ten-second window remains")
    }

    func testAdaptiveCadenceKeepsDurationCapInWallClockSeconds() {
        let configuration = RewindConfiguration(
            duration: 60,
            captureInterval: 0.1,
            memoryBudgetBytes: 48 * 1024 * 1024,
            captureBytesPerSecond: 40 * 1024 * 1024
        )

        XCTAssertEqual(configuration.maxEntries(forStateOf: 400 * 1024), 600)
        XCTAssertEqual(configuration.maxEntries(forStateOf: 19_228_057), 130)
        XCTAssertLessThanOrEqual(
            Double(configuration.maxEntries(forStateOf: 19_228_057))
                * configuration.interval(forStateOf: 19_228_057),
            configuration.duration
        )
    }

    func testSizeChangeStoresFullState() {
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 10)
        let a = state(1, size: 1024), b = state(2, size: 2048), c = state(3, size: 2048)
        buffer.append(a); buffer.append(b); buffer.append(c)
        XCTAssertEqual(buffer.stepBack(), b)
        XCTAssertEqual(buffer.stepBack(), a)
    }

    func testIncompressibleDataRoundTrips() {
        var rng = SystemRandomNumberGenerator()
        let buffer = RewindBuffer(maxBytes: 8 * 1024 * 1024, maxEntries: 10)
        let a = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let b = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        buffer.append(a); buffer.append(b)
        XCTAssertEqual(buffer.stepBack(), a)
    }
}
