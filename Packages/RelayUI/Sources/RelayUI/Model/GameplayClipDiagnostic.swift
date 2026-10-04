// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG && (os(iOS) || os(macOS))
import AVFoundation
import Foundation

struct GameplayClipDiagnostic: Sendable, Codable {
    struct NativeError: Sendable, Codable, Equatable {
        let domain: String
        let code: Int
    }

    struct MediaTime: Sendable, Codable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64
        let seconds: Double?

        init?(_ time: CMTime?) {
            guard let time else { return nil }
            value = time.value; timescale = time.timescale
            flags = time.flags.rawValue; epoch = time.epoch
            let candidate = CMTimeGetSeconds(time)
            seconds = candidate.isFinite ? candidate : nil
        }
    }

    let recordingID: String
    let operation: String
    let firstFailure: Bool
    let writerStatus: Int
    let accepting: Bool
    let pendingCallbacks: Int
    let videoFrames: Int
    let audioFrames: Int
    let sourceStart: MediaTime?
    let attemptedTime: MediaTime?
    let lastVideo: MediaTime?
    let lastAudio: MediaTime?
    let lastAudioEnd: MediaTime?
    let writerErrors: [NativeError]
    let captureErrors: [NativeError]

    var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(self), let json = String(data: bytes, encoding: .utf8) else {
            return "RELAY-SHARE diagnostic unavailable"
        }
        return "RELAY-SHARE diagnostic \(json)"
    }

    static func errorCodes(_ error: Error?) -> [NativeError] {
        guard let error else { return [] }
        var pending = [error as NSError], seen = Set<ObjectIdentifier>(), output: [NativeError] = []
        // Bound cyclic/branching NSError graphs. Never serialize userInfo;
        // follow only the standard underlying-error references.
        while !pending.isEmpty, output.count < 5 {
            let current = pending.removeFirst()
            guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            let domain = current.domain
            let safe = !domain.isEmpty && domain.utf8.count <= 96 && domain.unicodeScalars.allSatisfy(allowed.contains)
            output.append(NativeError(domain: safe ? domain : "redacted", code: current.code))
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                pending.append(contentsOf: multiple.prefix(5 - output.count))
            }
        }
        return output
    }
}
#endif
