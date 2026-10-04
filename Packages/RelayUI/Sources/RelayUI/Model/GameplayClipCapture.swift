// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) || os(macOS)
import AVFoundation
import ReplayKit
import Foundation
import RelayEmulation
#if os(iOS)
import UIKit
#endif

/// Serial, disk-backed native encoder. At most four callbacks can be pending;
/// the callback path never waits for the encoder. Only game pixels are sampled.
/// ReplayKit screen buffers and microphone buffers never enter this object.
final class GameplayClipWriter: @unchecked Sendable {
    /// ReplayKit delivers immutable ready samples. Retain one for the bounded
    /// serial handoff; no code mutates its timing, format or backing memory.
    private struct AppAudioSample: @unchecked Sendable { let buffer: CMSampleBuffer }
    static let framesPerSecond: Double = 30
    // Leave room for the writer's final tables and other app writes. This is
    // free space on the volume, not a maximum recording size.
    static let minimumFreeBytes: Int64 = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "app.relayemu.share.encoder", qos: .userInitiated)
    private let admission = NSLock()
    private var accepting = true
    private var pending = 0
    private let sources: [VideoFrameSource]
    private let composition: GameplayShareComposition
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let limits: GameplayClipLimits
    private let availableBytes: @Sendable (URL) -> Int64?
    private let onStop: @Sendable (GameplayShareError) -> Void
    private let lease: GameplayShareLease
    private var resourceStopped = false
    private var firstTime: CMTime?
    private var lastVideo = CMTime.invalid
    private var videoFrames = 0
    private var audioFrames = 0
    #if DEBUG
    private var offeredAudioBuffers = 0
    private var nonzeroOfferedAudioBuffers = 0
    private var diagnosticPCM = Data()
    private let diagnosticID = UUID().uuidString
    private var diagnosticObserver: (@Sendable (GameplayClipDiagnostic) -> Void)?
    private var reportedFailure = false
    private var lastAudio = CMTime.invalid
    private var lastAudioEnd = CMTime.invalid
    #endif
    private var failure: GameplayShareError?
    let url: URL

    init(sources: [VideoFrameSource], composition: GameplayShareComposition, url: URL,
         limits: GameplayClipLimits = .free,
         availableBytes: @escaping @Sendable (URL) -> Int64? = { GameplayClipWriter.availableBytes($0) },
         onStop: @escaping @Sendable (GameplayShareError) -> Void = { _ in }) throws {
        self.sources = sources
        self.composition = composition
        self.url = url
        self.limits = limits
        self.availableBytes = availableBytes
        self.onStop = onStop
        self.lease = GameplayShareLease(url: url)
        guard let bytes = availableBytes(url.deletingLastPathComponent()) else { throw GameplayShareError.storageUnavailable }
        guard bytes >= Self.minimumFreeBytes else { throw GameplayShareError.storageLow }
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = limits.duration != nil
        if limits.duration == nil {
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        }
        writer.metadata = []
        let width = Int(composition.size.width), height = Int(composition.size.height)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000,
                                               AVVideoExpectedSourceFrameRateKey: 30,
                                               AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw GameplayShareError.encoding }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            #if DEBUG
            recordDiagnostic(operation: "startWriting", isFailure: true)
            #endif
            throw GameplayShareError.encoding
        }
    }

    /// Video time only, deliberately no ReplayKit screen image reference.
    func offerVideo(at time: CMTime) {
        enqueue { self.appendVideo(at: time) }
    }

    func offerAppAudio(_ buffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(buffer), CMSampleBufferGetTotalSampleSize(buffer) <= 512 * 1024 else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--relay-skins-share-qualification"),
           let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0, total = 0
            var bytes: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                           totalLengthOut: &total, dataPointerOut: &bytes) == noErr,
               length == total, let bytes {
                let nonzero = UnsafeBufferPointer(start: bytes, count: length).contains { $0 != 0 }
                admission.lock()
                offeredAudioBuffers += 1
                if nonzero { nonzeroOfferedAudioBuffers += 1 }
                let first = offeredAudioBuffers == 1
                admission.unlock()
                if first, let description = CMSampleBufferGetFormatDescription(buffer),
                   let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    print("RELAY-SHARE appAudio rate=\(format.pointee.mSampleRate) channels=\(format.pointee.mChannelsPerFrame) bits=\(format.pointee.mBitsPerChannel) flags=\(format.pointee.mFormatFlags) bytes=\(length)")
                }
            }
        }
        #endif
        let sample = AppAudioSample(buffer: buffer)
        enqueue { self.appendAudio(sample.buffer) }
    }

    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        admission.lock()
        guard accepting, pending < 4 else { admission.unlock(); return }
        pending += 1
        admission.unlock()
        queue.async {
            autoreleasepool { work() }
            self.admission.lock()
            self.pending -= 1
            self.admission.unlock()
        }
    }

    /// Close admission synchronously before Pause or another UI can appear.
    func seal() {
        admission.lock()
        accepting = false
        admission.unlock()
    }

    func drain() async {
        seal()
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func appendVideo(at time: CMTime) {
        guard failure == nil, !resourceStopped, time.isNumeric else { return }
        guard writer.status == .writing else { fail(.encoding, operation: "appendVideo.writerState", time: time); return }
        if let firstTime {
            let elapsed = CMTimeGetSeconds(time - firstTime)
            guard elapsed >= 0, limits.duration.map({ elapsed < $0 }) ?? true else { return }
        }
        if lastVideo.isNumeric, CMTimeGetSeconds(time - lastVideo) < 1 / Self.framesPerSecond - 0.001 { return }
        guard video.isReadyForMoreMediaData else { return }
        if firstTime == nil {
            firstTime = time
            writer.startSession(atSourceTime: time)
        }
        guard let pool = adaptor.pixelBufferPool else { fail(.encoding, operation: "appendVideo.pixelPool", time: time); return }
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &pixel)
        if result == kCVReturnWouldExceedAllocationThreshold { return }
        guard result == kCVReturnSuccess, let pixel,
              let image = composition.image(from: sources) else { fail(.frameUnavailable, operation: "appendVideo.frame", time: time); return }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: CVPixelBufferGetWidth(pixel),
                                      height: CVPixelBufferGetHeight(pixel), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { fail(.encoding, operation: "appendVideo.context", time: time); return }
        context.draw(image, in: CGRect(origin: .zero, size: composition.size))
        guard adaptor.append(pixel, withPresentationTime: time) else { fail(.encoding, operation: "appendVideo.append", time: time); return }
        lastVideo = time
        videoFrames += 1
        if videoFrames % 30 == 0 {
            if let maximum = limits.maximumBytes, (fileBytes() ?? 0) > maximum { fail(.encoding); return }
            let bytes = availableBytes(url.deletingLastPathComponent())
            if bytes == nil || bytes! < Self.minimumFreeBytes {
                resourceStopped = true
                seal()
                onStop(bytes == nil ? .storageUnavailable : .storageLow)
            }
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer) {
        guard failure == nil, !resourceStopped, let firstTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard writer.status == .writing else { fail(.encoding, operation: "appendAudio.writerState", time: time); return }
        let elapsed = CMTimeGetSeconds(time - firstTime)
        // Derive PCM duration from its frame count: ReplayKit sample timing may
        // omit duration even though the audio format is fully specified.
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mSampleRate > 0 else { return }
        let duration = Double(CMSampleBufferGetNumSamples(buffer)) / format.pointee.mSampleRate
        let end = elapsed + duration
        guard elapsed.isFinite, elapsed >= 0, limits.duration.map({ end <= $0 }) ?? true,
              audio.isReadyForMoreMediaData else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--relay-skins-share-qualification"),
           ProcessInfo.processInfo.arguments.contains("--relay-share-audio-dump"),
           diagnosticPCM.count < 256 * 1024, let block = CMSampleBufferGetDataBuffer(buffer) {
            let count = min(CMBlockBufferGetDataLength(block), 256 * 1024 - diagnosticPCM.count)
            var data = Data(count: count)
            let copied = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            if copied == noErr { diagnosticPCM.append(data) }
        }
        #endif
        guard audio.append(buffer) else { fail(.encoding, operation: "appendAudio.append", time: time); return }
        #if DEBUG
        lastAudio = time
        lastAudioEnd = time + CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
        #endif
        audioFrames += CMSampleBufferGetNumSamples(buffer)
    }

    private func fail(_ error: GameplayShareError, operation: String = #function, time: CMTime? = nil) {
        guard failure == nil else { return }
        #if DEBUG
        recordDiagnostic(operation: operation, time: time, isFailure: true)
        #endif
        failure = error
        seal()
        onStop(error)
    }

    #if DEBUG
    /// Install before offering samples. Observer and receipts share the writer
    /// queue so the first failure is captured before cancellation/cleanup.
    func observeDiagnostics(_ observer: @escaping @Sendable (GameplayClipDiagnostic) -> Void) {
        queue.async { self.diagnosticObserver = observer }
    }

    private func recordDiagnostic(operation: String, time: CMTime? = nil,
                                  isFailure: Bool = false, captureErrors: [GameplayClipDiagnostic.NativeError] = []) {
        guard diagnosticObserver != nil || ProcessInfo.processInfo.arguments.contains("--relay-skins-share-qualification") else { return }
        let firstFailure = isFailure && !reportedFailure
        if isFailure { reportedFailure = true }
        admission.lock()
        let isAccepting = accepting, pendingCallbacks = pending
        admission.unlock()
        let event = GameplayClipDiagnostic(
            recordingID: diagnosticID, operation: operation, firstFailure: firstFailure,
            writerStatus: writer.status.rawValue, accepting: isAccepting, pendingCallbacks: pendingCallbacks,
            videoFrames: videoFrames, audioFrames: audioFrames,
            sourceStart: .init(firstTime), attemptedTime: .init(time), lastVideo: .init(lastVideo),
            lastAudio: .init(lastAudio), lastAudioEnd: .init(lastAudioEnd),
            writerErrors: GameplayClipDiagnostic.errorCodes(writer.error), captureErrors: captureErrors)
        diagnosticObserver?(event)
        if ProcessInfo.processInfo.arguments.contains("--relay-skins-share-qualification") { print(event.line) }
    }
    #endif

    /// ReplayKit callbacks are outside the encoder queue. Retain only sanitized
    /// codes and timing, never the Error/userInfo object or its media buffer.
    func recordCaptureError(_ error: Error, operation: String, time: CMTime? = nil) {
        #if DEBUG
        let codes = GameplayClipDiagnostic.errorCodes(error)
        queue.async { self.recordDiagnostic(operation: operation, time: time, isFailure: true, captureErrors: codes) }
        #endif
    }

    /// URL resource values can cache a zero size while AVAssetWriter still has
    /// the file open. A fresh stat is required for both growth and final limits.
    private func fileBytes() -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    static func availableBytes(_ directory: URL) -> Int64? {
        // A fresh URL avoids cached values during a long recording. No disk
        // capacity or derived information is logged or transmitted.
        let fresh = URL(fileURLWithPath: directory.path, isDirectory: true)
        return (try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    func finish() async throws -> URL {
        seal()
        let output: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                #if DEBUG
                print("RELAY-SHARE finish frames=\(self.videoFrames) audio=\(self.audioFrames) status=\(self.writer.status.rawValue) failure=\(String(describing: self.failure))")
                self.admission.lock()
                print("RELAY-SHARE offeredAudioBuffers=\(self.offeredAudioBuffers) nonzeroOfferedAudioBuffers=\(self.nonzeroOfferedAudioBuffers)")
                self.admission.unlock()
                if !self.diagnosticPCM.isEmpty {
                    try? self.diagnosticPCM.write(to: self.url.deletingLastPathComponent().appendingPathComponent("Qualification App Audio.pcm"))
                }
                #endif
                #if DEBUG
                self.recordDiagnostic(operation: "finish.begin")
                #endif
                guard self.writer.status == .writing else {
                    #if DEBUG
                    self.recordDiagnostic(operation: "finish.writerState", isFailure: true)
                    #endif
                    // Background expiration may cancel while ReplayKit is still
                    // stopping. Never end a session on an already cancelled writer.
                    if self.writer.status != .completed {
                        try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent())
                    }
                    continuation.resume(throwing: GameplayShareError.encoding)
                    return
                }
                guard self.failure == nil, self.videoFrames >= 2, self.audioFrames > 0 else {
                    let error = self.failure ?? (self.videoFrames < 2 ? .tooShort : .noAudio)
                    #if DEBUG
                    self.recordDiagnostic(operation: "finish.validation", isFailure: true)
                    #endif
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent())
                    continuation.resume(throwing: error)
                    return
                }
                // Bound the track's final sample even when capture scheduling
                // or a route interruption delivers late audio.
                if let first = self.firstTime {
                    var end = self.lastVideo + CMTime(value: 1, timescale: 30)
                    if let duration = self.limits.duration {
                        end = min(first + CMTime(seconds: duration, preferredTimescale: 60_000), end)
                    }
                    #if DEBUG
                    self.recordDiagnostic(operation: "finish.endSession", time: end)
                    #endif
                    self.writer.endSession(atSourceTime: end)
                }
                self.video.markAsFinished()
                self.audio.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        #if DEBUG
                        print("RELAY-SHARE finalized status=\(self.writer.status.rawValue) errorCode=\((self.writer.error as NSError?)?.code ?? 0)")
                        self.recordDiagnostic(operation: "finishWriting.completion", isFailure: self.writer.status != .completed)
                        #endif
                        if self.writer.status == .completed,
                           let bytes = self.fileBytes(),
                           bytes > 0, self.limits.maximumBytes.map({ bytes <= $0 }) ?? true {
                            continuation.resume(returning: self.url)
                        } else {
                            try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent())
                            continuation.resume(throwing: GameplayShareError.encoding)
                        }
                    }
                }
            }
        }
        // Retention begins at completion, including recordings over an hour.
        try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: output.deletingLastPathComponent().path)
        return output
    }

    func cancel() {
        seal()
        queue.async {
            // A late background-task expiration must not delete a movie whose
            // finalization has already succeeded.
            guard self.writer.status != .completed else { return }
            #if DEBUG
            self.recordDiagnostic(operation: "cancel.before", isFailure: self.writer.status == .failed)
            #endif
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent())
        }
    }
}

/// ReplayKit is available on all supported handheld/Mac deployment targets.
/// Apple deprecated it in SDK 27 in favor of the newly cross-platform
/// ScreenCaptureKit; keep the supported deployment-baseline API for V1.
@MainActor
protocol GameplayClipCapturing: AnyObject {
    var available: Bool { get }
    func start(sources: [VideoFrameSource], composition: GameplayShareComposition,
               limits: GameplayClipLimits, onError: @escaping @MainActor @Sendable (GameplayShareError) -> Void) async throws
    func seal()
    func drain() async
    func stop() async throws -> URL
}

@MainActor
final class GameplayClipCapture: GameplayClipCapturing {
    private let recorder = RPScreenRecorder.shared()
    private var writer: GameplayClipWriter?
    private var ownsCapture = false
    var available: Bool { recorder.isAvailable && !recorder.isRecording }

    func start(sources: [VideoFrameSource], composition: GameplayShareComposition,
               limits: GameplayClipLimits, onError: @escaping @MainActor @Sendable (GameplayShareError) -> Void) async throws {
        guard writer == nil, available else { throw GameplayShareError.unavailable }
        let url = try GameplayShareFile.destination(.clip)
        let writer: GameplayClipWriter
        do {
            writer = try GameplayClipWriter(sources: sources, composition: composition, url: url, limits: limits, onStop: { reason in
                Task { @MainActor in onError(reason) }
            })
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
        self.writer = writer
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.startCapture(handler: { buffer, kind, error in
                    if let error {
                        writer.recordCaptureError(error, operation: "ReplayKit.handler", time: CMSampleBufferGetPresentationTimeStamp(buffer))
                        writer.seal()
                        Task { @MainActor in onError(.capture) }
                        return
                    }
                    switch kind {
                    case .video: writer.offerVideo(at: CMSampleBufferGetPresentationTimeStamp(buffer))
                    case .audioApp: writer.offerAppAudio(buffer)
                    case .audioMic: break
                    @unknown default: break
                    }
                }, completionHandler: { error in
                    if let error {
                        writer.recordCaptureError(error, operation: "ReplayKit.startCapture")
                        continuation.resume(throwing: error)
                    }
                    else { continuation.resume() }
                })
            }
            ownsCapture = true
        } catch {
            writer.cancel()
            self.writer = nil
            throw GameplayShareError.capture
        }
    }

    func seal() { writer?.seal() }
    func drain() async { await writer?.drain() }

    func stop() async throws -> URL {
        guard let writer else { throw GameplayShareError.unavailable }
        self.writer = nil
        writer.seal()
        #if os(iOS)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Finish gameplay recording") {
            writer.cancel()
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        #endif
        if ownsCapture {
            ownsCapture = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                recorder.stopCapture { error in
                    if let error { writer.recordCaptureError(error, operation: "ReplayKit.stopCapture") }
                    continuation.resume()
                }
            }
            // ReplayKit may already have stopped after an interruption. Retain
            // the buffers it delivered and let the writer validate the result.
        }
        return try await writer.finish()
    }
}
#endif
