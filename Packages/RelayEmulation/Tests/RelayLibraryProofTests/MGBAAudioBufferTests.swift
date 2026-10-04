// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RelayProvenanceAdapter

@MainActor
final class MGBAAudioBufferTests: XCTestCase {
    func testOverflowPreservesUnreadAudioAndCapacityAcrossWraparound() throws {
        let buffer = try XCTUnwrap(MGBADriver.makeAudioBuffer(length: 16_384))
        let capacity = buffer.availableBytesForWriting
        XCTAssertGreaterThanOrEqual(capacity, 16_384)
        let original = (0..<(capacity - 4)).map { UInt8(truncatingIfNeeded: $0) }
        original.withUnsafeBytes { _ = buffer.write($0.baseAddress!, size: $0.count) }
        let overflow = [UInt8](repeating: 255, count: 8)
        overflow.withUnsafeBytes { _ = buffer.write($0.baseAddress!, size: $0.count) }
        XCTAssertEqual(buffer.availableBytesForReading, original.count)
        XCTAssertEqual(buffer.availableBytesForWriting, 4)
        var recovered = [UInt8](repeating: 0, count: original.count)
        recovered.withUnsafeMutableBytes { _ = buffer.read($0.baseAddress!, preferredSize: $0.count) }
        XCTAssertEqual(recovered, original, "An overrun must not overwrite unread gameplay audio")
        XCTAssertEqual(buffer.availableBytesForReading, 0)
        XCTAssertEqual(buffer.availableBytesForWriting, capacity)
        let wrapped = [UInt8](repeating: 37, count: 16)
        wrapped.withUnsafeBytes { _ = buffer.write($0.baseAddress!, size: $0.count) }
        var result = [UInt8](repeating: 0, count: wrapped.count)
        result.withUnsafeMutableBytes { _ = buffer.read($0.baseAddress!, preferredSize: $0.count) }
        XCTAssertEqual(result, wrapped)
        XCTAssertEqual(buffer.availableBytesForReading, 0)
    }

    func testOversizedWriteIsRejectedAndClearRestoresTheEmptyBuffer() throws {
        let buffer = try XCTUnwrap(MGBADriver.makeAudioBuffer(length: 16_384))
        let capacity = buffer.availableBytesForWriting
        let oversized = [UInt8](repeating: 17, count: capacity + 4)
        oversized.withUnsafeBytes { _ = buffer.write($0.baseAddress!, size: $0.count) }
        XCTAssertEqual(buffer.availableBytesForReading, 0)
        let sample = [UInt8](repeating: 18, count: 2048)
        sample.withUnsafeBytes { _ = buffer.write($0.baseAddress!, size: $0.count) }
        XCTAssertEqual(buffer.availableBytesForReading, sample.count)
        buffer.clear()
        XCTAssertEqual(buffer.availableBytesForReading, 0)
        XCTAssertEqual(buffer.availableBytesForWriting, capacity)
    }
}
