// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoreAudioOutput.swift
//  RelayAudioOutput
//
//  Relay's own audio output for cores that hand Relay their samples: an
//  AVAudioEngine whose source node pulls interleaved stereo Int16 frames from
//  the core's ring buffer on the audio thread. The engine never blocks on the
//  core; when the ring is empty the node renders silence and says so.

import AVFoundation
import Foundation

public final class CoreAudioOutput: @unchecked Sendable {
    /// Fills `buffer` with up to `frames` stereo frames (left, right, …) and
    /// returns how many came from the core; the rest must already be silence.
    /// Called on the audio render thread: no locks the emulation thread holds
    /// for long, no allocation.
    public typealias Reader = @Sendable (_ buffer: UnsafeMutablePointer<Int16>, _ frames: Int) -> Int

    private let engine = AVAudioEngine()
    private let reader: Reader
    private let format: AVAudioFormat
    private var source: AVAudioSourceNode?
    public private(set) var isRunning = false

    public let sampleRate: Double

    public init(sampleRate: Double, reader: @escaping Reader) {
        self.sampleRate = sampleRate
        self.reader = reader
        self.format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: true)!
    }

    public func start() throws {
        guard !isRunning else { return }
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        #endif
        let reader = self.reader
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let base = buffers[0].mData else {
                isSilence.pointee = ObjCBool(true)
                return noErr
            }
            let frames = Int(frameCount)
            let produced = reader(base.assumingMemoryBound(to: Int16.self), frames)
            isSilence.pointee = ObjCBool(produced == 0)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        source = node
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        isRunning = false
    }
}
