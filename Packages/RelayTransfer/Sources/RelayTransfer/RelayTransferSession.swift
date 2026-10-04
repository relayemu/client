// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayHostedSync

private final class TransferSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A native account bearer must never follow a signaling redirect.
        completionHandler(nil)
    }
}

/// One foreground waiting presence, one account, and at most one transfer.
/// No vault/provider selection is involved. Call stop on dismissal/background.
public actor RelayTransferSession {
    public nonisolated let events: AsyncStream<TransferEvent>
    private let continuation: AsyncStream<TransferEvent>.Continuation
    private let account: RelayHostedAccountSession, accountID: UUID, kind: HostedDeviceKind
    private let root: URL
    private let availableBytes: @Sendable () throws -> Int64
    private let duplicate: @Sendable (TransferFile) async -> TransferImportResult?
    private let importFiles: @Sendable ([URL]) async -> TransferImportResult
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?, presenceID: UUID?
    private var peer: NativePeerConnection?, receiver: TransferReceiver?
    private var readTask: Task<Void, Never>?, nativeTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?, authority: Task<Void, Never>?
    private var candidates: [(String, String)] = []
    private var localCandidates: [[String: String]] = []
    private var offered = false, answered = false, opened = false, finished = false
    private var active = false, started = false, generation = UUID()
    private var route: TransferRoute?

    public init(account: RelayHostedAccountSession, accountID: UUID, deviceKind: HostedDeviceKind,
                stagingDirectory: URL, availableBytes: @escaping @Sendable () throws -> Int64,
                duplicate: @escaping @Sendable (TransferFile) async -> TransferImportResult? = { _ in nil },
                importFiles: @escaping @Sendable ([URL]) async -> TransferImportResult) {
        self.account = account; self.accountID = accountID; kind = deviceKind
        root = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.availableBytes = availableBytes; self.duplicate = duplicate; self.importFiles = importFiles
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        urlSession = URLSession(configuration: configuration, delegate: TransferSocketDelegate(), delegateQueue: nil)
        let stream = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream; continuation = stream.continuation
    }

    public func start() async throws {
        guard !started, kind != .unknown else { throw TransferError.connectionFailed }
        started = true; active = true; let token = generation
        do {
            try await announce()
            guard active, generation == token, let presenceID else { throw TransferError.interrupted }
            socket = try await account.makeTransferWebSocket(expectedAccountID: accountID, presenceID: presenceID, urlSession: urlSession)
            socket?.maximumMessageSize = 128 * 1024; socket?.resume()
            continuation.yield(.waiting)
            readTask = Task { [weak self] in await self?.readSignals(token) }
            timer = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)); ticks += 1
                        try await self?.tick(token: token, renew: ticks % 3 == 0)
                    } catch { await self?.fail(error, token: token); return }
                }
            }
            authority = Task { [weak self, account, accountID] in
                for await state in await account.stateUpdates() {
                    guard !Task.isCancelled else { return }
                    guard case .connected(let snapshot) = state, snapshot.accountID == accountID else {
                        await self?.stop(reason: "auth_lost"); return
                    }
                }
            }
        } catch { await stop(); throw error }
    }

    public func stop(reason: String = "cancelled") async {
        guard active else { return }; active = false; generation = UUID()
        readTask?.cancel(); nativeTask?.cancel(); timer?.cancel(); authority?.cancel()
        readTask = nil; nativeTask = nil; timer = nil; authority = nil
        if let socket {
            let data = try? JSONEncoder().encode(["type": "bye", "reason": reason])
            // A blocked socket must not hold dismissal or account revocation open.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { if let data { try? await socket.send(.string(String(decoding: data, as: UTF8.self))) } }
                group.addTask { try? await Task.sleep(for: .milliseconds(250)); socket.cancel(with: .goingAway, reason: nil) }
                await group.next(); group.cancelAll()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        peer?.close(); peer = nil
        await receiver?.stop(); receiver = nil
        if let presenceID {
            _ = try? await account.makeHTTPClient(expectedAccountID: accountID).send(method: "DELETE", path: "/v1/transfer/presence/" + presenceID.uuidString.lowercased())
        }
        presenceID = nil; urlSession.invalidateAndCancel(); continuation.finish()
    }

    private func announce() async throws {
        struct Presence: Encodable { let deviceKind: HostedDeviceKind; let presenceID: UUID? }
        struct Response: Decodable { let presenceID: UUID }
        let body = try JSONEncoder().encode(Presence(deviceKind: kind, presenceID: presenceID))
        let data = try await account.makeHTTPClient(expectedAccountID: accountID).send(method: "POST", path: "/v1/transfer/presence", body: body)
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let presenceID, presenceID != response.presenceID { throw TransferError.invalidMessage }
        presenceID = response.presenceID
    }

    private func readSignals(_ token: UUID) async {
        do {
            while active, token == generation, let socket {
                let frame = try await socket.receive()
                guard active, token == generation else { return }
                try await account.validateAccount(expectedAccountID: accountID)
                guard case .string(let value) = frame, let data = value.data(using: .utf8), data.count <= 128 * 1024,
                      let object = try? TransferJSON.object(data), let type = object["type"] as? String else { throw TransferError.invalidMessage }
                switch type {
                case "session":
                    guard peer == nil else { throw TransferError.invalidMessage }
                    struct Session: Decodable { let sessionID: UUID; let iceServers: [TransferICEServer] }
                    let session = try JSONDecoder().decode(Session.self, from: data)
                    guard session.iceServers.count <= 3 else { throw TransferError.invalidMessage }
                    var bindAddress: String?
                    var relayOnly = false
                    #if DEBUG
                    if account.environment.apiOrigin.scheme == "http", account.environment.apiOrigin.host == "127.0.0.1" {
                        bindAddress = "127.0.0.1"
                        relayOnly = ProcessInfo.processInfo.environment["TRANSFER_TEST_RELAY_ONLY"] == "1"
                    }
                    #endif
                    let peer = try NativePeerConnection(iceServers: session.iceServers, relayOnly: relayOnly, bindAddress: bindAddress)
                    self.peer = peer; continuation.yield(.connecting)
                    receiver = TransferReceiver(root: root, availableBytes: availableBytes, send: { try peer.send($0) },
                        event: { [weak self, continuation] value in
                            continuation.yield(value)
                            if case .failed(let error) = value { Task { await self?.fail(error, token: token) } }
                        }, duplicate: duplicate, importFiles: importFiles)
                    nativeTask = Task { [weak self] in await self?.readNative(peer, token: token) }
                case "offer":
                    guard !offered, let peer, let sdp = object["sdp"] as? String, sdp.utf8.count <= 65536 else { throw TransferError.invalidMessage }
                    offered = true; try peer.applyOffer(sdp)
                    for (candidate, mid) in candidates { try peer.addCandidate(candidate, mid: mid) }; candidates.removeAll()
                case "candidate":
                    guard let candidate = object["candidate"] as? String, let mid = object["mid"] as? String,
                          candidate.utf8.count <= 4096, mid.utf8.count <= 64 else { throw TransferError.invalidMessage }
                    if offered { try peer?.addCandidate(candidate, mid: mid) }
                    else { guard candidates.count < 50 else { throw TransferError.limitsExceeded }; candidates.append((candidate, mid)) }
                case "end-of-candidates": break
                case "bye":
                    finished = await receiver?.isComplete ?? finished
                    if !finished { continuation.yield(.failed(.interrupted)) }
                    await stop(reason: finished ? "completed" : "interrupted"); return
                default: throw TransferError.invalidMessage
                }
            }
        } catch { await fail(error, token: token) }
    }

    private func readNative(_ native: NativePeerConnection, token: UUID) async {
        do {
            for await value in native.events {
                guard active, token == generation else { return }
                switch value {
                case .description(let sdp):
                    guard !answered else { throw TransferError.invalidMessage }; answered = true
                    try await sendSignal(["type": "answer", "sdp": sdp])
                    for message in localCandidates { try await sendSignal(message) }; localCandidates.removeAll()
                case .candidate(let candidate, let mid):
                    let message = ["type": "candidate", "candidate": candidate, "mid": mid]
                    if answered { try await sendSignal(message) }
                    else { guard localCandidates.count < 50 else { throw TransferError.limitsExceeded }; localCandidates.append(message) }
                case .gatheringComplete:
                    if answered { try await sendSignal(["type": "end-of-candidates"]) }
                    else { localCandidates.append(["type": "end-of-candidates"]) }
                case .opened:
                    if !opened { opened = true; try await sendSignal(["type": "connected"]); continuation.yield(.connected) }
                    updateRoute(native)
                case .text(let data):
                    try await receiver?.text(data)
                    finished = await receiver?.isComplete ?? false
                case .binary(let data): try await receiver?.binary(data)
                case .closed:
                    finished = await receiver?.isComplete ?? finished
                    if !finished { throw TransferError.interrupted }
                }
            }
            finished = await receiver?.isComplete ?? finished
            if active && !finished { throw TransferError.interrupted }
        } catch { await fail(error, token: token) }
    }

    private func tick(token: UUID, renew: Bool) async throws {
        guard active, generation == token else { return }
        try await account.validateAccount(expectedAccountID: accountID)
        if renew { try await announce() }
        if opened, let peer { updateRoute(peer) }
        try await receiver?.tick()
    }
    private func updateRoute(_ peer: NativePeerConnection) {
        guard let selected = peer.selectedRoute(), selected != route else { return }
        route = selected; continuation.yield(.route(selected))
    }
    private func sendSignal(_ value: [String: String]) async throws {
        guard let socket else { throw TransferError.interrupted }
        let data = try JSONEncoder().encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func fail(_ error: Error, token: UUID) async {
        guard active, generation == token else { return }
        // Signaling/ICE teardown can race the browser's completed bye. Once
        // every file has a verified terminal import result, teardown must not
        // turn those results into an interrupted transfer.
        let completed = await receiver?.isComplete ?? finished
        guard active, generation == token else { return }
        if completed {
            finished = true
            await stop(reason: "completed")
            return
        }
        continuation.yield(.failed(error as? TransferError ?? .connectionFailed))
        await stop(reason: "connection_failed")
    }
}
