// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import RelayEmulation
import RelayDomain
import RelayVideo

@MainActor
@Observable
final class GameplaySharing {
    enum State: Equatable { case idle, starting, recording, finishing }
    private(set) var state: State = .idle
    private(set) var clip: GameplayShareFile?
    private(set) var error: GameplayShareError?
    private(set) var elapsedSeconds = 0
    private var recordingLimits = GameplayClipLimits.free
    private var stopWhenStarted = false
    private var discardResult = false
    private var attemptID: UUID?
    private var timer: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    #if os(iOS) || os(macOS)
    private let capture: any GameplayClipCapturing
    init(capture: (any GameplayClipCapturing)? = nil) { self.capture = capture ?? GameplayClipCapture() }
    #endif

    var busy: Bool { state != .idle }
    var elapsedTime: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds / 60) % 60
        let seconds = elapsedSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
    }
    var canRecord: Bool {
        #if os(iOS) || os(macOS)
        return !busy && capture.available
        #else
        return false
        #endif
    }

    func dismissError() { error = nil }

    func startClip(sources: [VideoFrameSource], screens: [LogicalScreen], arrangement: ScreenArrangement?,
                   limits: GameplayClipLimits = .free) async -> Bool {
        #if os(iOS) || os(macOS)
        guard canRecord, !sources.isEmpty else { error = .unavailable; return false }
        state = .starting
        error = nil
        stopWhenStarted = false
        discardResult = false
        recordingLimits = limits
        let attempt = UUID()
        attemptID = attempt
        do {
            try await capture.start(sources: sources,
                                    composition: GameplayShareComposition(screens: screens, arrangement: arrangement, maximumEdge: 720),
                                    limits: limits) { [weak self] reason in
                guard let self, self.attemptID == attempt else { return }
                self.error = reason
                self.stopClip()
            }
            state = .recording
            elapsedSeconds = 0
            if stopWhenStarted {
                stopClip()
                return false
            }
            timer = Task { [weak self] in
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.state == .recording else { return }
                    self.elapsedSeconds = Int(start.duration(to: .now).components.seconds)
                    if let duration = limits.duration, Double(self.elapsedSeconds) >= duration {
                        self.stopClip()
                        return
                    }
                }
            }
            return true
        } catch {
            if !discardResult { self.error = (error as? GameplayShareError) ?? .capture }
            state = .idle
            return false
        }
        #else
        return false
        #endif
    }

    func accessDidChange(limits: GameplayClipLimits) {
        // Finish under the original writer policy so a long recording made
        // while entitled survives expiry rather than failing the Free cap.
        if busy, recordingLimits == .pro, limits == .free { stopClip() }
    }

    func stopClip() {
        #if os(iOS) || os(macOS)
        if state == .starting { stopWhenStarted = true; capture.seal(); return }
        guard state == .recording else { return }
        capture.seal()
        state = .finishing
        timer?.cancel()
        timer = nil
        stopTask = Task {
            do {
                let url = try await capture.stop()
                if !discardResult { clip = GameplayShareFile(url: url, kind: .clip) }
            } catch {
                if !discardResult { self.error = (error as? GameplayShareError) ?? .capture }
            }
            state = .idle
            stopTask = nil
        }
        #endif
    }

    func endSession() async {
        discardResult = true
        attemptID = nil
        stopClip()
        #if os(iOS) || os(macOS)
        await capture.drain()
        #endif
        // A system recording prompt may still own start. The completion will
        // see stopWhenStarted and cannot resume a stopped game.
        await stopTask?.value
        clip = nil
        error = nil
    }

    func report(_ error: Error) { self.error = (error as? GameplayShareError) ?? .encoding }
}
