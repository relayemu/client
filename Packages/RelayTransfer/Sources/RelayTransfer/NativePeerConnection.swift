// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDataChannel

enum NativePeerEvent: Sendable {
    case description(String), candidate(String, String), gatheringComplete, opened
    case text(Data), binary(Data), closed
}

// A user pointer is an opaque context key, never dereferenced memory. Lookup
// retains its peer under a lock; late callbacks after removal safely disappear.
// This avoids a use-after-free race between C's pointer lookup and Swift teardown.
private final class PeerContexts: @unchecked Sendable {
    static let shared = PeerContexts()
    private let lock = NSLock()
    private var next = 1
    private var peers: [Int: NativePeerConnection] = [:]
    func insert(_ peer: NativePeerConnection) -> UnsafeMutableRawPointer {
        lock.lock(); defer { lock.unlock() }; let key = next; next += 1; peers[key] = peer
        return UnsafeMutableRawPointer(bitPattern: key)!
    }
    func peer(_ pointer: UnsafeMutableRawPointer?) -> NativePeerConnection? {
        guard let pointer else { return nil }; lock.lock(); defer { lock.unlock() }
        return peers[Int(bitPattern: pointer)]
    }
    func remove(_ pointer: UnsafeMutableRawPointer) { lock.lock(); defer { lock.unlock() }; peers.removeValue(forKey: Int(bitPattern: pointer)) }
}

final class NativePeerConnection: @unchecked Sendable {
    let events: AsyncStream<NativePeerEvent>
    private let continuation: AsyncStream<NativePeerEvent>.Continuation
    private let lock = NSRecursiveLock()
    private var pc: Int32 = -1, dc: Int32 = -1
    private var pointer: UnsafeMutableRawPointer?
    private var closing = false

    init(iceServers: [TransferICEServer], relayOnly: Bool = false, bindAddress: String? = nil) throws {
        let stream = AsyncStream<NativePeerEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = stream.stream; continuation = stream.continuation
        let strings = iceServers.flatMap { $0.nativeURLs() }.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var servers: [UnsafePointer<CChar>?] = strings.map { value in value.map { UnsafePointer<CChar>($0) } }
        var config = rtcConfiguration()
        let binding = bindAddress.flatMap { strdup($0) }
        defer { free(binding) }
        config.bindAddress = binding.map { UnsafePointer<CChar>($0) }
        config.iceServersCount = Int32(servers.count); config.maxMessageSize = 262144
        config.iceTransportPolicy = relayOnly ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL
        // Native diagnostic callbacks can contain addresses and credentials.
        rtcInitLogger(RTC_LOG_NONE, { _, _ in })
        pc = servers.withUnsafeMutableBufferPointer { buffer in
            config.iceServers = buffer.baseAddress; return rtcCreatePeerConnection(&config)
        }
        guard pc >= 0 else { throw TransferError.connectionFailed }
        pointer = PeerContexts.shared.insert(self); rtcSetUserPointer(pc, pointer)
        rtcSetLocalDescriptionCallback(pc) { _, sdp, _, context in
            guard let sdp, let peer = PeerContexts.shared.peer(context) else { return }
            peer.emit(.description(String(cString: sdp)))
        }
        rtcSetLocalCandidateCallback(pc) { _, candidate, mid, context in
            guard let candidate, let mid, let peer = PeerContexts.shared.peer(context) else { return }
            peer.emit(.candidate(String(cString: candidate), String(cString: mid)))
        }
        rtcSetGatheringStateChangeCallback(pc) { _, state, context in
            if state == RTC_GATHERING_COMPLETE { PeerContexts.shared.peer(context)?.emit(.gatheringComplete) }
        }
        rtcSetStateChangeCallback(pc) { _, state, context in
            if state == RTC_FAILED || state == RTC_CLOSED { PeerContexts.shared.peer(context)?.emit(.closed) }
        }
        rtcSetDataChannelCallback(pc) { _, channel, context in
            guard let peer = PeerContexts.shared.peer(context) else { _ = rtcDeleteDataChannel(channel); return }
            peer.accept(channel)
        }
    }

    private func accept(_ channel: Int32) {
        lock.lock(); defer { lock.unlock() }
        var label = [CChar](repeating: 0, count: 128); var reliability = rtcReliability()
        guard !closing, dc < 0, rtcGetDataChannelLabel(channel, &label, Int32(label.count)) >= 0,
              String(cString: label) == "relay-transfer/2", rtcGetDataChannelReliability(channel, &reliability) >= 0,
              !reliability.unordered, !reliability.unreliable else {
            _ = rtcDeleteDataChannel(channel); emit(.closed); return
        }
        dc = channel; rtcSetUserPointer(dc, pointer)
        rtcSetOpenCallback(dc) { _, context in PeerContexts.shared.peer(context)?.emit(.opened) }
        rtcSetClosedCallback(dc) { _, context in PeerContexts.shared.peer(context)?.emit(.closed) }
        rtcSetErrorCallback(dc) { _, _, context in PeerContexts.shared.peer(context)?.emit(.closed) }
        rtcSetMessageCallback(dc) { _, message, size, context in
            guard let message, let peer = PeerContexts.shared.peer(context) else { return }
            if size < 0 {
                // C's text size is -(UTF8 length + terminator), not just -1.
                let count = -Int(size) - 1
                guard count <= 65536 else { peer.emit(.closed); return }
                peer.emit(.text(Data(bytes: message, count: count)))
            } else {
                guard size > 4, size <= 65540 else { peer.emit(.closed); return }
                peer.emit(.binary(Data(bytes: message, count: Int(size))))
            }
        }
        if rtcIsOpen(dc) { emit(.opened) }
    }

    private func emit(_ event: NativePeerEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { return }
        if case .dropped = continuation.yield(event) {
            // Never accumulate unbounded per-chunk Tasks. Tear down outside C callback.
            DispatchQueue.global(qos: .utility).async { [self] in close() }
        }
    }

    func selectedRoute() -> TransferRoute? {
        lock.lock(); defer { lock.unlock() }
        guard !closing, pc >= 0 else { return nil }
        var local = [CChar](repeating: 0, count: 4096), remote = local
        guard rtcGetSelectedCandidatePair(pc, &local, Int32(local.count), &remote, Int32(remote.count)) >= 0 else { return nil }
        // Candidate addresses and credentials stay inside the transport.
        func type(_ value: [CChar]) -> String? {
            let fields = String(cString: value).split(whereSeparator: { $0.isWhitespace })
            guard let index = fields.firstIndex(of: "typ"), fields.indices.contains(index + 1) else { return nil }
            return String(fields[index + 1])
        }
        return TransferRoute.selected(localType: type(local), remoteType: type(remote))
    }

    func applyOffer(_ sdp: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing, sdp.utf8.count <= 65536,
              rtcSetRemoteDescription(pc, sdp, "offer") >= 0 else { throw TransferError.connectionFailed }
    }
    func addCandidate(_ candidate: String, mid: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing, candidate.utf8.count <= 4096, mid.utf8.count <= 64,
              rtcAddRemoteCandidate(pc, candidate, mid) >= 0 else { throw TransferError.connectionFailed }
    }
    func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing, dc >= 0, data.count <= 65536, let string = String(data: data, encoding: .utf8),
              string.withCString({ rtcSendMessage(dc, $0, -1) }) >= 0 else { throw TransferError.connectionFailed }
    }
    func close() {
        lock.lock(); guard !closing else { lock.unlock(); return }; closing = true
        let channel = dc, connection = pc, context = pointer; dc = -1; pc = -1; lock.unlock()
        if channel >= 0 {
            rtcSetMessageCallback(channel, nil); rtcSetOpenCallback(channel, nil)
            rtcSetClosedCallback(channel, nil); rtcSetErrorCallback(channel, nil)
            rtcSetUserPointer(channel, nil); _ = rtcDeleteDataChannel(channel)
        }
        if connection >= 0 {
            rtcSetLocalDescriptionCallback(connection, nil); rtcSetLocalCandidateCallback(connection, nil)
            rtcSetDataChannelCallback(connection, nil); rtcSetStateChangeCallback(connection, nil)
            rtcSetGatheringStateChangeCallback(connection, nil); rtcSetUserPointer(connection, nil)
            _ = rtcDeletePeerConnection(connection)
        }
        if let context { PeerContexts.shared.remove(context) }
        continuation.finish()
    }
}
