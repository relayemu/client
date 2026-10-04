// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  RewindEngine.swift
//  RelayEmulation
//
//  Captures machine states into a `RewindBuffer` at a fixed cadence while the
//  game runs, and steps back through them while the player holds Rewind. The
//  capture loop runs off the main actor on a background task; the serializer
//  is thread-safe by contract. Playback (stepping back) is driven by the
//  session on the main actor: one step = restore + run one frame. The UI drives
//  those steps at its interaction cadence; a large-state core may therefore
//  move farther through game time per step than a small-state core.

import Foundation

public struct RewindConfiguration: Equatable, Sendable {
    /// How far back the player can go.
    public var duration: TimeInterval
    /// Time between captures; also the reverse playback step.
    public var captureInterval: TimeInterval
    /// Hard cap on compressed bytes held.
    public var memoryBudgetBytes: Int
    /// How many bytes of machine state a second the capture loop may move.
    /// `captureInterval` is the cadence Relay wants; this is the cost it will
    /// pay for it. A Game Boy Advance state is 0.4 MB, so ten a second costs
    /// 4 MB/s and nothing changes; a Nintendo DS state is 19 MB, so the same
    /// cadence would move 190 MB/s through the allocator. Captures of a large
    public var captureBytesPerSecond: Int

    public init(duration: TimeInterval, captureInterval: TimeInterval, memoryBudgetBytes: Int,
                captureBytesPerSecond: Int = 40 * 1024 * 1024) {
        self.duration = duration
        self.captureInterval = captureInterval
        self.memoryBudgetBytes = memoryBudgetBytes
        self.captureBytesPerSecond = captureBytesPerSecond
    }

    /// The cadence a state of `stateBytes` actually gets: the configured one,
    /// or slower when a single capture costs more than the budget allows.
    public func interval(forStateOf stateBytes: Int) -> TimeInterval {
        guard stateBytes > 0, captureBytesPerSecond > 0 else { return captureInterval }
        return max(captureInterval, Double(stateBytes) / Double(captureBytesPerSecond))
    }

    public var maxEntries: Int { max(1, Int((duration / captureInterval).rounded(.down))) }

    /// Keeps the product duration honest when large states force a slower
    /// cadence (notably Nintendo DS). Without this, a 10-second Free buffer at
    /// a 0.46-second cadence could retain roughly 46 seconds.
    public func maxEntries(forStateOf stateBytes: Int) -> Int {
        // Round down: the retained interval must never exceed the advertised
        // Free/Pro duration merely because the core needs a slower cadence.
        max(1, Int((duration / interval(forStateOf: stateBytes)).rounded(.down)))
    }

    /// Baseline capture policy: callers choose the Free/Pro duration, while every
    /// tier stays at 10 captures per second and within the same 48 MB hard cap.
    /// (measured mGBA deltas are a few KB each, see RELAY_PLAY_EXPERIENCE.md).
    public static let standard = RewindConfiguration(duration: 10, captureInterval: 0.1, memoryBudgetBytes: 48 * 1024 * 1024)
    public static let disabled = RewindConfiguration(duration: 0, captureInterval: 0.1, memoryBudgetBytes: 0)
}

@MainActor
final class RewindEngine {
    private(set) var buffer: RewindBuffer
    private let serializer: any EmulationStateSerializer
    private var configuration: RewindConfiguration
    private var captureTask: Task<Void, Never>?
    /// Set by the session while the player rewinds; captures are suspended.
    private(set) var isRewinding = false

    init(serializer: any EmulationStateSerializer, configuration: RewindConfiguration) {
        self.serializer = serializer
        self.configuration = configuration
        buffer = RewindBuffer(maxBytes: configuration.memoryBudgetBytes,
                              maxEntries: configuration.maxEntries,
                              maxDuration: configuration.duration)
    }

    var statistics: RewindBuffer.Statistics { buffer.statistics }
    var isEnabled: Bool { configuration.duration > 0 && configuration.memoryBudgetBytes > 0 }

    /// Starts periodic captures (idempotent).
    func startCapturing() {
        guard isEnabled, captureTask == nil else { return }
        let serializer = self.serializer
        let buffer = self.buffer
        let interval = configuration.captureInterval
        let configuration = self.configuration
        captureTask = Task.detached(priority: .utility) {
            var interval = interval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                if let state = try? serializer.serializeState() {
                    interval = configuration.interval(forStateOf: state.count)
                    buffer.setEntryLimit(configuration.maxEntries(forStateOf: state.count))
                    buffer.append(state)
                }
            }
        }
    }

    func stopCapturing() {
        captureTask?.cancel()
        captureTask = nil
    }

    /// Enters rewind: captures pause; the caller has already paused the core.
    func beginRewind() {
        stopCapturing()
        isRewinding = true
    }

    /// One step backwards: restores the previous state and renders it. Returns
    /// false when history is exhausted.
    func stepBack() -> Bool {
        guard isRewinding, let previous = buffer.stepBack() else { return false }
        do {
            try serializer.restoreState(previous)
            serializer.runSingleFrame()
            return true
        } catch {
            return false
        }
    }

    /// Leaves rewind; history continues from the restored point.
    func endRewind(resumeCapturing: Bool) {
        isRewinding = false
        if resumeCapturing { startCapturing() }
    }

    /// Memory pressure: halve the budget (never below 4 MB) and evict.
    func shrink() {
        let target = max(4 * 1024 * 1024, configuration.memoryBudgetBytes / 2)
        configuration.memoryBudgetBytes = target
        buffer.shrink(toBytes: target)
    }

    /// Applies a live Free/Pro limit change. Recent history survives when the
    /// limit grows; entitlement loss evicts only in-memory entries beyond the
    /// Free cap and never touches a save-state file.
    func reconfigure(_ newConfiguration: RewindConfiguration) {
        let wasCapturing = captureTask != nil
        stopCapturing()
        configuration = newConfiguration
        buffer.setLimits(maxBytes: newConfiguration.memoryBudgetBytes,
                         maxEntries: newConfiguration.maxEntries,
                         maxDuration: newConfiguration.duration)
        if wasCapturing, !isRewinding { startCapturing() }
    }

    /// Discards history (e.g. after a manual state load, which is a new timeline).
    func reset() { buffer.reset() }

    deinit { captureTask?.cancel() }
}
