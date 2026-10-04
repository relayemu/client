// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
import AVKit
import SwiftUI
import RelayDomain
@testable import RelayUI

final class GameplayClipWriterTests: XCTestCase {
    func testFrameFailureRequestsImmediateStopForPro() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stopped = expectation(description: "Failed frame ends Pro capture immediately")
        let writer = try GameplayClipWriter(sources: [],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240),
            url: url, limits: .pro, onStop: { reason in
                XCTAssertEqual(reason, .frameUnavailable)
                stopped.fulfill()
            })
        writer.offerVideo(at: .zero)
        await fulfillment(of: [stopped], timeout: 2)
        do { _ = try await writer.finish(); XCTFail("A failed frame was exported") }
        catch GameplayShareError.frameUnavailable { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancellationWhileStoppingCannotEndAnAlreadyCancelledWriter() async throws {
        let url = try GameplayShareFile.destination(.clip)
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url, limits: .pro)
        for frame in 0..<6 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
        writer.cancel()
        await writer.drain()
        do { _ = try await writer.finish(); XCTFail("Cancelled writer succeeded") }
        catch GameplayShareError.encoding { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLateCancellationPreservesTheAlreadyCompletedMovie() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url, limits: .pro)
        for frame in 0..<6 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
        let output = try await writer.finish()
        writer.cancel()
        await writer.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.1)
    }

    func testProWriterEncodesContinuousMediaBeyondFifteenSecondsAndSealStillEndsRecording() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240),
            url: url, limits: .pro)
        // Cross three fragment boundaries with an absolute source timestamp
        // and the physical fixture's 44.1 kHz big-endian PCM format. Feed faster
        // than real time; this is encoding evidence, not live performance.
        for frame in 0..<1050 {
            let time = CMTime(seconds: 12345 + Double(frame) / 30, preferredTimescale: 1_000_000_000)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time, frames: 1470, frequency: 512, bigEndian: true, sampleRate: 44_100))
            try await Task.sleep(for: .milliseconds(5))
        }
        writer.seal()
        writer.offerVideo(at: CMTime(seconds: 12345 + 7200, preferredTimescale: 48_000))
        let output = try await writer.finish()
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 34.9)
        XCTAssertLessThan(duration, 35.1)
    }

    func testLowStorageDuringEncodingStopsAdmissionAndKeepsAPlayableRecording() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let budget = RecordingStorageProbe()
        let stopped = expectation(description: "Low storage requested finalization")
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240),
            url: url, limits: .pro, availableBytes: { _ in budget.availableBytes() }, onStop: { reason in
                XCTAssertEqual(reason, .storageLow)
                stopped.fulfill()
            })
        for frame in 0..<40 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time))
            try await Task.sleep(for: .milliseconds(10))
        }
        await fulfillment(of: [stopped], timeout: 2)
        let output = try await writer.finish()
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.8)
        XCTAssertLessThan(duration, 1.1)
        let image = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: .zero).image
        XCTAssertGreaterThan(image.width, 0)
    }

    func testInsufficientStorageRefusesBeforeStartingTheNativeWriter() throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil),
            url: url, limits: .pro, availableBytes: { _ in 1024 })) {
            XCTAssertEqual($0 as? GameplayShareError, .storageLow)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNativeAACWithAnOffsetCannotExtendTheFreeContainerPastFifteenSeconds() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url)
        for frame in 0..<450 {
            let time = CMTime(seconds: 12345 + Double(frame) / 30, preferredTimescale: 48_000)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time + CMTime(seconds: 0.016, preferredTimescale: 48_000)))
            try await Task.sleep(for: .milliseconds(5))
        }
        let output = try await writer.finish()
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertLessThanOrEqual(duration, 15.001)
        XCTAssertGreaterThan(duration, 14.9)
    }

    func testBigEndianReplayKitPCMRetainsItsToneFrequencyThroughAAC() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url)
        for frame in 0..<45 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time, frames: 1470, frequency: 512, bigEndian: true, sampleRate: 44_100))
            try await Task.sleep(for: .milliseconds(10))
        }
        let asset = AVURLAsset(url: try await writer.finish())
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0, cycles = 0
        var armed = false
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                let values = raw.bindMemory(to: Int16.self)
                for index in stride(from: 0, to: values.count, by: 2) {
                    frames += 1
                    if values[index] < -2000 { armed = true }
                    if armed, values[index] > 2000 { cycles += 1; armed = false }
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(Double(cycles) * 48_000 / Double(frames), 512, accuracy: 3)
    }

    #if DEBUG
    func testDiagnosticCodesExcludePrivateUserInfoAndBoundUnderlyingErrors() throws {
        let privateMarker = "PRIVATE-DIAGNOSTIC-MARKER"
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12909,
                                 userInfo: [NSLocalizedDescriptionKey: privateMarker])
        let error = NSError(domain: AVFoundationErrorDomain, code: -11800,
                            userInfo: [NSUnderlyingErrorKey: underlying,
                                       NSFilePathErrorKey: "/private/" + privateMarker,
                                       NSMultipleUnderlyingErrorsKey: [underlying, NSError(domain: "/private/" + privateMarker, code: 7)]])
        let codes = GameplayClipDiagnostic.errorCodes(error)
        XCTAssertEqual(codes, [.init(domain: AVFoundationErrorDomain, code: -11800),
                               .init(domain: NSOSStatusErrorDomain, code: -12909),
                               .init(domain: "redacted", code: 7)])
        let encoded = String(decoding: try JSONEncoder().encode(codes), as: UTF8.self)
        XCTAssertFalse(encoded.contains(privateMarker))
        var nested = underlying
        for index in 0..<20 { nested = NSError(domain: NSCocoaErrorDomain, code: index, userInfo: [NSUnderlyingErrorKey: nested]) }
        XCTAssertEqual(GameplayClipDiagnostic.errorCodes(nested).count, 5)
    }

    func testFirstFailureDiagnosticPrecedesCleanupAndRetainsAttemptedTime() async throws {
        let url = try GameplayShareFile.destination(.clip)
        let events = ClipDiagnosticEvents()
        let stopped = expectation(description: "frame failure")
        let writer = try GameplayClipWriter(sources: [],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 720),
            url: url, limits: .pro, onStop: { _ in stopped.fulfill() })
        writer.observeDiagnostics { events.append($0) }
        let time = CMTime(value: 12_345_000_000_000, timescale: 1_000_000_000)
        writer.offerVideo(at: time)
        await fulfillment(of: [stopped], timeout: 5)
        do { _ = try await writer.finish(); XCTFail("Missing pixels must fail") }
        catch GameplayShareError.frameUnavailable { }
        let first = try XCTUnwrap(events.values.first(where: \.firstFailure))
        XCTAssertEqual(first.operation, "appendVideo.frame")
        XCTAssertEqual(first.writerStatus, AVAssetWriter.Status.writing.rawValue)
        XCTAssertEqual(first.attemptedTime?.value, time.value)
        XCTAssertEqual(first.attemptedTime?.timescale, time.timescale)
        XCTAssertEqual(first.sourceStart?.value, time.value)
        XCTAssertEqual(first.videoFrames, 0)
        XCTAssertTrue(first.writerErrors.isEmpty, "No native encoder error exists for this deliberately missing frame")
        XCTAssertEqual(events.values.filter(\.firstFailure).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for event in events.values { print(event.line) }
    }

    func testProFragmentsAtNativeAudioCadenceAcrossThreeSequentialRecordings() async throws {
        // Hypotheses: 10-second fragments with absolute ReplayKit-style time
        // and 1024-frame/44.1 kHz PCM; resource reuse after finish/start. Three
        // bounded 25-second media timelines exceed the historical 577 frames.
        // Input is synthetic and accelerated, not physical ReplayKit evidence.
        for attempt in 0..<3 {
            let url = try GameplayShareFile.destination(.clip)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let events = ClipDiagnosticEvents()
            let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
                composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 720),
                url: url, limits: .pro)
            writer.observeDiagnostics { events.append($0) }
            var videoIndex = 0, audioIndex = 0
            var nextFragmentProbe = 12.0, liveFragments = 0
            let origin = 12_345.0 + Double(attempt) * 30
            while true {
                let videoTime = Double(videoIndex) / 30
                let audioTime = Double(audioIndex * 1024) / 44_100
                if min(videoTime, audioTime) >= 25 { break }
                if videoTime <= audioTime {
                    writer.offerVideo(at: CMTime(seconds: origin + videoTime, preferredTimescale: 1_000_000_000))
                    videoIndex += 1
                } else {
                    let time = CMTime(seconds: origin + audioTime, preferredTimescale: 1_000_000_000)
                    writer.offerAppAudio(try tone(at: time, frames: 1024, frequency: 512, bigEndian: true, sampleRate: 44_100))
                    audioIndex += 1
                }
                try await Task.sleep(for: .milliseconds(4))
                if min(videoTime, audioTime) >= nextFragmentProbe {
                    let partial = try Data(contentsOf: url)
                    let count = try mp4FragmentCount(partial, allowIncompleteTail: true)
                    liveFragments = max(liveFragments, count)
                    print("RELAY-LOCAL-FRAGMENT attempt=\(attempt + 1) sourceSeconds=\(nextFragmentProbe) bytes=\(partial.count) moof=\(count)")
                    nextFragmentProbe += 10
                }
            }
            let output = try await writer.finish()
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 20.1, preferredTimescale: 600)).image
            XCTAssertEqual(image.width, 720)
            XCTAssertEqual(image.height, 480)
            XCTAssertGreaterThan(duration, 24)
            XCTAssertLessThan(duration, 25.1)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1)
            let bytes = try Data(contentsOf: output)
            // AVAssetWriter defragments a successfully finished movie. Observe
            // fragments during recording, not in the finalized sample table.
            let finalFragments = try mp4FragmentCount(bytes)
            // The initial interval is represented by the movie table; the
            // subsequent interval supplies the first moof. Its presence after
            // 20 seconds proves an active fragment beyond the initial table.
            XCTAssertGreaterThanOrEqual(liveFragments, 1)
            XCTAssertEqual(finalFragments, 0)
            let completion = try XCTUnwrap(events.values.last { $0.operation == "finishWriting.completion" })
            XCTAssertEqual(completion.writerStatus, AVAssetWriter.Status.completed.rawValue)
            XCTAssertGreaterThan(completion.videoFrames, 577)
            XCTAssertGreaterThan(completion.audioFrames, 0)
            XCTAssertTrue(completion.writerErrors.isEmpty)
            XCTAssertFalse(events.values.contains(where: \.firstFailure))
            for event in events.values { print(event.line) }
            print("RELAY-LOCAL-WRITER attempt=\(attempt + 1) seconds=\(duration) bytes=\(bytes.count) liveMoof=\(liveFragments) finalMoof=\(finalFragments) videoFrames=\(completion.videoFrames) audioFrames=\(completion.audioFrames)")
        }
    }

    private func mp4FragmentCount(_ bytes: Data, allowIncompleteTail: Bool = false) throws -> Int {
        var offset = 0, count = 0
        while offset + 8 <= bytes.count {
            let size32 = bytes[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var size = size32
            if size32 == 1 {
                guard offset + 16 <= bytes.count else {
                    if allowIncompleteTail { break }
                    throw GameplayShareError.encoding
                }
                size = bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 { size = UInt64(bytes.count - offset) }
            guard size >= (size32 == 1 ? 16 : 8) else { throw GameplayShareError.encoding }
            guard size <= UInt64(bytes.count - offset) else {
                if allowIncompleteTail { break }
                throw GameplayShareError.encoding
            }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == "moof" { count += 1 }
            offset += Int(size)
        }
        return count
    }
    #endif

    private func tone(at time: CMTime, frames: Int = 1600, frequency: Double = 440,
                      bigEndian: Bool = false, sampleRate: Double = 48_000) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked | (bigEndian ? kLinearPCMFormatFlagIsBigEndian : 0),
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frames * 4,
            flags: 0, blockBufferOut: &block), noErr)
        let samples: [Int16] = (0..<(frames * 2)).map { index in
            let value = Int16(sin((time.seconds + Double(index / 2) / sampleRate) * 2 * .pi * frequency) * 12_000)
            return bigEndian ? value.bigEndian : value
        }
        try samples.withUnsafeBytes { data in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(data.baseAddress),
                                                        blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0,
                                                        dataLength: data.count), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }

    func testNativeClipEncodesDecodableH264AndAudibleAACWithoutPrivateMetadata() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 720), url: url)
        for frame in 0..<45 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            writer.offerVideo(at: time)
            writer.offerAppAudio(try tone(at: time))
            try await Task.sleep(for: .milliseconds(34))
        }
        print("CLIP-TEST finalize")
        let output: URL
        do { output = try await writer.finish() }
        catch { print("CLIP-TEST finish error: \(error)"); throw error }
        print("CLIP-TEST inspect")
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1)
        XCTAssertLessThanOrEqual(duration.seconds, 15.001)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let size = try await XCTUnwrap(video.first).load(.naturalSize)
        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.height, 480)
        let metadata = try await asset.load(.metadata)
        XCTAssertTrue(metadata.isEmpty)
        print("CLIP-TEST decode video")
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        XCTAssertEqual(image.width, 720)
        #if os(macOS)
        await verifyNativeMacPreview(url: output)
        #endif

        // Decode the written AAC to PCM. A track declaration is insufficient:
        // assert real non-zero audio samples survived the export.
        print("CLIP-TEST decode audio")
        let reader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: try XCTUnwrap(audio.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(audioOutput)
        XCTAssertTrue(reader.startReading())
        var peak: Int = 0
        while let sample = audioOutput.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                for value in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int(value))) }
            }
        }
        XCTAssertGreaterThan(peak, 5_000)
        XCTAssertEqual(reader.status, .completed)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(bytes, 1_000)
        XCTAssertLessThan(bytes, try XCTUnwrap(GameplayClipLimits.free.maximumBytes))
        print("CLIP-TEST copy receipt")
        if let path = ProcessInfo.processInfo.environment["RELAY_SHARE_TEST_OUTPUT"] {
            let destination = URL(fileURLWithPath: path).appendingPathComponent("Relay Gameplay Clip.mp4")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: output, to: destination)
            print("CLIP-TEST complete")
        }
    }

    #if os(macOS)
    @MainActor private func verifyNativeMacPreview(url: URL) {
        // Reproduce the native view-metadata initialization that crashed the
        // owner's clip preview, without XCTest UI Automation or a share action.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: GameplayShareSheet(file: GameplayShareFile(url: url, kind: .clip)))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func containsPlayer(_ view: NSView) -> Bool {
            view is AVPlayerView || view.subviews.contains(where: containsPlayer)
        }
        XCTAssertTrue(containsPlayer(host), "Native clip preview did not mount its AppKit player")
    }
    #endif

    func testMissingAudioFailsExplicitlyAndRemovesPartialMovie() async throws {
        let url = try GameplayShareFile.destination(.clip)
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url)
        for frame in 0..<6 {
            writer.offerVideo(at: CMTime(value: Int64(frame), timescale: 30))
            try await Task.sleep(for: .milliseconds(40))
        }
        do { _ = try await writer.finish(); XCTFail("Missing audio was silently exported") }
        catch GameplayShareError.noAudio { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAdmissionSealRejectsLateFramesAndDurationRemainsBounded() async throws {
        let url = try GameplayShareFile.destination(.clip)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try GameplayClipWriter(sources: [ShareTestFrame()],
            composition: GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil, maximumEdge: 240), url: url)
        for time in [0.0, 0.1, 14.9, 15.0, 60.0] {
            let pts = CMTime(seconds: time, preferredTimescale: 48_000)
            writer.offerVideo(at: pts)
            writer.offerAppAudio(try tone(at: pts))
            try await Task.sleep(for: .milliseconds(80))
        }
        writer.seal()
        for index in 0..<1000 { writer.offerVideo(at: CMTime(seconds: Double(index), preferredTimescale: 30)) }
        let output = try await writer.finish()
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertLessThanOrEqual(duration.seconds, 15.001)
        XCTAssertGreaterThan(duration.seconds, 14)
    }
}

#if DEBUG
private final class ClipDiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GameplayClipDiagnostic] = []
    func append(_ event: GameplayClipDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }
    var values: [GameplayClipDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
#endif

private final class RecordingStorageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func availableBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads == 1 ? GameplayClipWriter.minimumFreeBytes * 2 : 1024
    }
}
#endif
