// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RewindBuffer.swift
//  RelayEmulation
//
//  Bounded in-memory history of machine states for rewind. Stores the newest
//  full state once and every older state as an LZ4-compressed XOR delta against
//  its successor, so stepping back is "pop, decompress, XOR". Consecutive
//  states of the same machine differ in a small fraction of bytes, which is
//  what makes the ring cheap; the byte budget is a hard cap and the oldest
//  entries go first. Nothing here touches the disk (spec §13, §19).

import Foundation
import Compression

public final class RewindBuffer: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        public var entries: Int
        public var bytes: Int
        public var maxBytes: Int
        /// Wall-clock span between the newest and oldest retained captures.
        public var retainedSeconds: TimeInterval
    }

    private struct Entry {
        /// LZ4-compressed XOR delta (or a full state when sizes differed).
        let payload: Data
        let isFullState: Bool
        let decodedLength: Int
        let capturedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var newest: Data?
    private var newestCapturedAt: TimeInterval?
    private var bytesHeld = 0
    private var byteBudget: Int
    private var entryBudget: Int
    private var durationBudget: TimeInterval?

    /// - Parameters:
    ///   - maxBytes: hard cap on compressed bytes held (the newest full state is not counted).
    ///   - maxEntries: cap on the number of steps kept (duration ÷ capture interval).
    /// `maxDuration` is monotonic wall-clock history. It is independent of the
    /// expected capture cadence because serializing a large core state also
    /// consumes time (notably melonDS on physical devices).
    public init(maxBytes: Int, maxEntries: Int, maxDuration: TimeInterval? = nil) {
        byteBudget = max(0, maxBytes)
        entryBudget = max(1, maxEntries)
        durationBudget = maxDuration.map { max(0, $0) }
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        let retained = if let newestCapturedAt, let oldest = entries.first?.capturedAt {
            max(0.0, newestCapturedAt - oldest)
        } else {
            0.0
        }
        return Statistics(entries: entries.count, bytes: bytesHeld, maxBytes: byteBudget,
                          retainedSeconds: retained)
    }

    /// Records `state` as the newest point in history.
    public func append(_ state: Data, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard let previous = newest else {
            newest = state
            newestCapturedAt = capturedAt
            return
        }
        let previousCapturedAt = newestCapturedAt ?? capturedAt
        let entry: Entry
        if previous.count == state.count {
            let delta = Self.xor(previous, state)
            entry = Entry(payload: Self.compress(delta), isFullState: false,
                          decodedLength: delta.count, capturedAt: previousCapturedAt)
        } else {
            entry = Entry(payload: Self.compress(previous), isFullState: true,
                          decodedLength: previous.count, capturedAt: previousCapturedAt)
        }
        entries.append(entry)
        bytesHeld += entry.payload.count
        newest = state
        newestCapturedAt = capturedAt
        evictIfNeeded()
    }

    /// Pops the most recent step and returns the state before it (nil when history is empty).
    public func stepBack() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let current = newest, let entry = entries.popLast() else { return nil }
        bytesHeld -= entry.payload.count
        let decoded = Self.decompress(entry.payload, length: entry.decodedLength)
        let previous = entry.isFullState ? decoded : Self.xor(current, decoded)
        newest = previous
        newestCapturedAt = entry.capturedAt
        return previous
    }

    /// Lowers the byte budget (memory pressure) and drops the oldest entries to fit.
    public func shrink(toBytes bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        byteBudget = max(0, bytes)
        evictIfNeeded()
    }

    /// Updates both hard limits without discarding valid recent history.
    public func setLimits(maxBytes: Int, maxEntries: Int, maxDuration: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        byteBudget = max(0, maxBytes)
        entryBudget = max(1, maxEntries)
        durationBudget = maxDuration.map { max(0, $0) }
        evictIfNeeded()
    }

    /// Changes only the time/entry cap. The capture loop uses this after it
    /// learns a core's adaptive cadence; it must not undo a lower memory cap
    /// applied independently by the memory-pressure handler.
    public func setEntryLimit(_ maxEntries: Int) {
        lock.lock(); defer { lock.unlock() }
        entryBudget = max(1, maxEntries)
        evictIfNeeded()
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        newest = nil
        newestCapturedAt = nil
        bytesHeld = 0
    }

    private func evictIfNeeded() {
        var dropCount = 0
        var held = bytesHeld
        while dropCount < entries.count {
            let tooManyBytes = held > byteBudget
            let tooManyEntries = entries.count - dropCount > entryBudget
            let tooOld = durationBudget.map { budget in
                guard let newestCapturedAt else { return false }
                return newestCapturedAt - entries[dropCount].capturedAt > budget
            } ?? false
            guard tooManyBytes || tooManyEntries || tooOld else { break }
            held -= entries[dropCount].payload.count
            dropCount += 1
        }
        if dropCount > 0 {
            entries.removeFirst(dropCount)
            bytesHeld = held
        }
    }

    // MARK: Byte helpers

    static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count)
        var out = Data(count: a.count)
        out.withUnsafeMutableBytes { o in
            a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in
                    let n = a.count
                    let words = n / 8
                    let oa = pa.bindMemory(to: UInt64.self)
                    let ob = pb.bindMemory(to: UInt64.self)
                    let oo = o.bindMemory(to: UInt64.self)
                    for i in 0..<words { oo[i] = oa[i] ^ ob[i] }
                    for i in (words * 8)..<n { o[i] = pa[i] ^ pb[i] }
                }
            }
        }
        return out
    }

    static func compress(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let capacity = data.count + data.count / 255 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          i.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_LZ4)
            }
        }
        // Equality matters: decode uses payload length to distinguish a raw
        // state from LZ4. Keeping an equal-length encoded result would make a
        // valid compressed delta look raw and corrupt the reconstructed state.
        guard written > 0, written < data.count else { return data }
        // `Data.count = written` may keep the original state-sized capacity.
        // Repeated captures then grow resident memory while `bytesHeld` appears
        // small, defeating the hard budget. Copy into right-sized storage.
        return out.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: written)
        }
    }

    static func decompress(_ data: Data, length: Int) -> Data {
        guard !data.isEmpty, data.count != length else { return data }
        var out = Data(count: length)
        let written = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, length,
                                          i.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_LZ4)
            }
        }
        if written != length { return data }   // was stored raw (incompressible)
        return out
    }
}
