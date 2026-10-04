// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RelayDomain
import RelayAchievementInterfaces
import CRetroAchievements

/// Owns one official client. Its recursive lock serializes frame evaluation,
/// server completions and UI snapshots. The frame callback never waits for HTTP
/// or Keychain. No core or memory pointer escapes the synchronous frame call.
final class RcheevosRuntime: EmulationAchievementRuntime, @unchecked Sendable {
    struct Events: Sendable {
        var unlocks: [Achievement] = []
        var disconnected = false
        var storageFailure = false
        var serverFailure = false
        var challenges: [UInt32: Achievement] = [:]
        var progress: Achievement?
        var leaderboardResult: AchievementLeaderboardResult?
        var resetRequired = false
    }

    private let lock = NSRecursiveLock()
    private var client: OpaquePointer!
    private let transport: any AchievementHTTPTransport
    private let vault: AchievementVault
    private let generation: UUID
    private let userAgent: String
    private var system: SystemID?
    private var reader: AchievementMemoryReader?
    private var closed = false
    private var mode: AchievementMode
    private var loadSerial: UInt64 = 0
    private var loginCompletion: ((Result<AchievementCredentials, AchievementServiceError>) -> Void)?
    private var loadCompletion: ((Result<AchievementGame, AchievementServiceError>) -> Void)?
    private var events = Events()
    private var notified: Set<String> = []
    private var activeAwards: Set<String> = []
    private var localUnlocks: Set<String> = []
    private var pendingRestoredProgress: Data?
    private var resetWhenLoaded = false

    init(transport: any AchievementHTTPTransport, vault: AchievementVault, generation: UUID, userAgent: String, mode: AchievementMode = .casual) {
        self.mode = mode
        self.transport = transport
        self.vault = vault
        self.generation = generation
        self.userAgent = userAgent
        client = rc_client_create({ address, buffer, length, client in
            guard let client, let buffer, let raw = rc_client_get_userdata(client) else { return 0 }
            let owner = Unmanaged<RcheevosRuntime>.fromOpaque(raw).takeUnretainedValue()
            guard let reader = owner.reader, let system = owner.system else { return 0 }
            return UInt32(AchievementSystem.read(system: system, address: address,
                          buffer: UnsafeMutableRawBufferPointer(start: buffer, count: Int(length)), using: reader))
        }, { request, callback, data, client in
            guard let client, let request, let callback, let raw = rc_client_get_userdata(client) else { return }
            Unmanaged<RcheevosRuntime>.fromOpaque(raw).takeUnretainedValue().callServer(request.pointee, callback: callback, data: data)
        })
        precondition(client != nil, "Cannot allocate achievement runtime")
        rc_client_set_userdata(client, Unmanaged.passUnretained(self).toOpaque())
        rc_client_set_host(client, "https://retroachievements.org")
        rc_client_set_hardcore_enabled(client, mode == .hardcore ? 1 : 0)
        rc_client_set_unofficial_enabled(client, 0)
        rc_client_set_allow_background_memory_reads(client, 0)
        // rcheevos logging is deliberately never enabled: its messages may
        // include service responses, account information or request details.
        rc_client_set_event_handler(client, { event, client in
            guard let event, let client, let raw = rc_client_get_userdata(client) else { return }
            Unmanaged<RcheevosRuntime>.fromOpaque(raw).takeUnretainedValue().receive(event.pointee)
        })
    }

    deinit { rc_client_destroy(client) }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func login(username: String, password: String? = nil, token: String? = nil) async throws -> AchievementCredentials {
        try await withCheckedThrowingContinuation { continuation in
            locked {
                guard !closed, loginCompletion == nil else {
                    continuation.resume(throwing: AchievementServiceError.cancelled); return
                }
                loginCompletion = { continuation.resume(with: $0.mapError { $0 as Error }) }
                let callback: rc_client_callback_t = { result, _, client, _ in
                    guard let client, let raw = rc_client_get_userdata(client) else { return }
                    let owner = Unmanaged<RcheevosRuntime>.fromOpaque(raw).takeUnretainedValue()
                    let completion = owner.loginCompletion
                    owner.loginCompletion = nil
                    guard !owner.closed else { completion?(.failure(.cancelled)); return }
                    guard result == RC_OK, let user = rc_client_get_user_info(client),
                          let username = user.pointee.username, let token = user.pointee.token else {
                        completion?(.failure(RcheevosRuntime.error(result))); return
                    }
                    completion?(.success(.init(username: String(cString: username), token: String(cString: token))))
                }
                if let password {
                    rc_client_begin_login_with_password(client, username, password, callback, nil)
                } else if let token {
                    rc_client_begin_login_with_token(client, username, token, callback, nil)
                } else {
                    loginCompletion = nil
                    continuation.resume(throwing: AchievementServiceError.invalidCredentials)
                }
            }
        }
    }

    /// Hashing runs off the main/emulation threads, before the client lock is
    /// taken. Relay SHA-256 identity is untouched; RA gets its own canonical hash.
    func load(system: SystemID, romURL: URL,
              completion: @escaping @Sendable (Result<AchievementGame, AchievementServiceError>) -> Void) {
        guard let console = AchievementSystem.consoleID(system) else { completion(.failure(.unsupported)); return }
        let serial: UInt64 = locked {
            loadSerial &+= 1
            loadCompletion?(.failure(.cancelled)); loadCompletion = nil
            rc_client_unload_game(client)
            self.system = system
            return loadSerial
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var hash = [CChar](repeating: 0, count: 33)
            var iterator = rc_hash_iterator_t()
            romURL.path.withCString { rc_hash_initialize_iterator(&iterator, $0, nil, 0) }
            let identified = rc_hash_generate(&hash, console, &iterator)
            rc_hash_destroy_iterator(&iterator)
            locked {
                guard !closed, serial == loadSerial else { completion(.failure(.cancelled)); return }
                guard identified != 0 else { completion(.failure(.unidentified)); return }
                loadCompletion?(.failure(.cancelled))
                rc_client_unload_game(client)
                loadCompletion = completion
                // Reassert the product policy on every game; never inherit the
                // library default (Hardcore on) or another session's mode.
                rc_client_set_hardcore_enabled(client, mode == .hardcore ? 1 : 0)
                rc_client_begin_load_game(client, hash, { result, _, client, _ in
                    guard let client, let raw = rc_client_get_userdata(client) else { return }
                    let owner = Unmanaged<RcheevosRuntime>.fromOpaque(raw).takeUnretainedValue()
                    let completion = owner.loadCompletion
                    owner.loadCompletion = nil
                    guard !owner.closed else { completion?(.failure(.cancelled)); return }
                    guard result == RC_OK, let game = owner.snapshotLocked(), game.id != 0 else {
                        completion?(.failure(result == RC_OK ? .unidentified : RcheevosRuntime.error(result))); return
                    }
                    if owner.resetWhenLoaded {
                        owner.restoreProgressLocked(owner.pendingRestoredProgress)
                        owner.pendingRestoredProgress = nil
                        owner.resetWhenLoaded = false
                    }
                    for item in game.achievements where item.isUnlocked { owner.notified.insert("\(game.hash):\(item.id):\(owner.mode.rawValue)") }
                    completion?(.success(game))
                }, nil)
            }
        }
    }

    func evaluateFrame(readMemory: AchievementMemoryReader) {
        locked {
            guard !closed, system != nil, !events.resetRequired else { return }
            withoutActuallyEscaping(readMemory) { read in
                reader = read
                defer { reader = nil }
                rc_client_do_frame(client)
            }
        }
    }

    func idle() {
        locked {
            // Activation validates memory. Only a real frame callback has a
            // valid reader; idle must not activate a game while it is paused.
            if !closed && loadCompletion == nil { rc_client_idle(client) }
        }
    }

    func captureProgress() -> Data? {
        locked {
            guard !closed, rc_client_is_game_loaded(client) != 0 else { return nil }
            let size = rc_client_progress_size(client)
            guard size > 0, size <= 4 * 1024 * 1024 else { return nil }
            var bytes = Data(count: size)
            let result = bytes.withUnsafeMutableBytes {
                rc_client_serialize_progress_sized(client, $0.bindMemory(to: UInt8.self).baseAddress, size)
            }
            return result == RC_OK ? bytes : nil
        }
    }

    func restoreProgress(_ data: Data?) {
        locked {
            guard mode != .hardcore else { return }
            guard !closed else { return }
            if rc_client_is_game_loaded(client) == 0 {
                pendingRestoredProgress = data
                resetWhenLoaded = true
            } else { restoreProgressLocked(data) }
        }
    }

    private func restoreProgressLocked(_ data: Data?) {
        guard let data, !data.isEmpty else {
            rc_client_deserialize_progress_sized(client, nil, 0); return
        }
        let result = data.withUnsafeBytes {
            rc_client_deserialize_progress_sized(client, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if result != RC_OK { rc_client_deserialize_progress_sized(client, nil, 0) }
    }

    func canPause() -> Bool { locked { closed || mode != .hardcore || rc_client_can_pause(client, nil) != 0 } }

    func disableHardcore() { locked { mode = .casual; rc_client_set_hardcore_enabled(client, 0) } }

    func resetProgress() { locked { if !closed { rc_client_reset(client) } } }

    func close() {
        locked {
            guard !closed else { return }
            closed = true
            loadSerial &+= 1
            loginCompletion?(.failure(.cancelled)); loginCompletion = nil
            loadCompletion?(.failure(.cancelled)); loadCompletion = nil
            rc_client_logout(client)
            events = Events()
            reader = nil
        }
    }

    func snapshot() -> AchievementGame? { locked { closed ? nil : snapshotLocked() } }

    private func snapshotLocked() -> AchievementGame? {
        guard let game = rc_client_get_game_info(client), game.pointee.id != 0 else { return nil }
        guard let list = rc_client_create_achievement_list(client, Int32(RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE),
                                                         Int32(RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_PROGRESS)) else { return nil }
        defer { rc_client_destroy_achievement_list(list) }
        var achievements: [Achievement] = []
        for index in 0..<Int(list.pointee.num_buckets) {
            let bucket = list.pointee.buckets[index]
            for index in 0..<Int(bucket.num_achievements) {
                if let item = bucket.achievements[index] {
                    var achievement = Self.achievement(item.pointee, mode: mode)
                    if localUnlocks.contains("\(Self.string(game.pointee.hash)):\(achievement.id):\(mode.rawValue)") {
                        achievement.isUnlocked = true
                    }
                    achievements.append(achievement)
                }
            }
        }
        var snapshot = AchievementGame(id: game.pointee.id, hash: Self.string(game.pointee.hash),
                               title: Self.string(game.pointee.title), achievements: achievements, updatedAt: Date())
        snapshot.mode = mode
        snapshot.leaderboards = leaderboardsLocked()
        var presence = [CChar](repeating: 0, count: 512)
        _ = rc_client_get_rich_presence_message(client, &presence, presence.count)
        snapshot.richPresence = String(cString: presence)
        return snapshot
    }

    func takeEvents() -> Events {
        locked {
            let value = events
            events.unlocks = []
            events.leaderboardResult = nil
            return value
        }
    }

    private func receive(_ event: rc_client_event_t) {
        guard !closed else { return }
        switch Int(event.type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            guard let item = event.achievement, let game = rc_client_get_game_info(client) else { return }
            let key = "\(Self.string(game.pointee.hash)):\(item.pointee.id):\(mode.rawValue)"
            localUnlocks.insert(key)
            if notified.insert(key).inserted { events.unlocks.append(Self.achievement(item.pointee, mode: mode)) }
        case RC_CLIENT_EVENT_DISCONNECTED: events.disconnected = true
        case RC_CLIENT_EVENT_RECONNECTED: events.disconnected = false; events.serverFailure = false
        case RC_CLIENT_EVENT_SERVER_ERROR: events.serverFailure = true
        case RC_CLIENT_EVENT_RESET:
            // An unexpected upgrade request cannot turn an existing timeline
            // into Hardcore. Stop evaluation and require a fresh core launch.
            events.resetRequired = true
            rc_client_set_hardcore_enabled(client, 0)
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
            if let item = event.achievement { events.challenges[item.pointee.id] = Self.achievement(item.pointee, mode: mode) }
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
            if let item = event.achievement { events.challenges.removeValue(forKey: item.pointee.id) }
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW, RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
            if let item = event.achievement { events.progress = Self.achievement(item.pointee, mode: mode) }
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE: events.progress = nil
        case RC_CLIENT_EVENT_LEADERBOARD_SCOREBOARD:
            if var result = event.leaderboard_scoreboard?.pointee {
                events.leaderboardResult = .init(id: result.leaderboard_id, score: Self.inlineString(&result.submitted_score),
                                                rank: result.new_rank, entries: result.num_entries)
            }
        default: break
        }
    }

    private static func inlineString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private func leaderboardsLocked() -> [AchievementLeaderboard] {
        guard let list = rc_client_create_leaderboard_list(client, Int32(RC_CLIENT_LEADERBOARD_LIST_GROUPING_NONE)) else { return [] }
        defer { rc_client_destroy_leaderboard_list(list) }
        var result: [AchievementLeaderboard] = []
        for index in 0..<Int(list.pointee.num_buckets) {
            let bucket = list.pointee.buckets[index]
            for index in 0..<Int(bucket.num_leaderboards) {
                guard let item = bucket.leaderboards[index]?.pointee else { continue }
                result.append(.init(id: item.id, title: Self.string(item.title), description: Self.string(item.description),
                                    value: Self.string(item.tracker_value), isTracking: item.state == RC_CLIENT_LEADERBOARD_STATE_TRACKING,
                                    isSupported: item.state != RC_CLIENT_LEADERBOARD_STATE_DISABLED))
            }
        }
        return result
    }

    private static func achievement(_ value: rc_client_achievement_t, mode: AchievementMode) -> Achievement {
        var progress = value.measured_progress
        let text = withUnsafeBytes(of: &progress) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let unlocked = mode == .hardcore ? (value.unlocked & UInt8(RC_CLIENT_ACHIEVEMENT_UNLOCKED_HARDCORE)) != 0 : value.unlocked != 0
        let url = URL(string: string(unlocked ? value.badge_url : value.badge_locked_url))
        let safeURL = url.flatMap { $0.scheme == "https" && $0.host == "media.retroachievements.org" ? $0 : nil }
        return Achievement(id: value.id, title: string(value.title), description: string(value.description),
                           points: value.points, isUnlocked: unlocked, isHardcore: mode == .hardcore,
                           isSupported: value.state != RC_CLIENT_ACHIEVEMENT_STATE_DISABLED,
                           isChallengeActive: value.bucket == RC_CLIENT_ACHIEVEMENT_BUCKET_ACTIVE_CHALLENGE,
                           progress: text, percent: min(100, max(0, Double(value.measured_percent))), badgeURL: safeURL)
    }

    private static func string(_ value: UnsafePointer<CChar>?) -> String { value.map(String.init(cString:)) ?? "" }
    private static func error(_ result: Int32) -> AchievementServiceError {
        switch Int(result) {
        case RC_INVALID_CREDENTIALS, RC_EXPIRED_TOKEN, RC_ACCESS_DENIED: return .invalidCredentials
        case RC_NOT_FOUND, RC_NO_GAME_LOADED: return .unidentified
        case RC_ABORTED: return .cancelled
        default: return .unavailable
        }
    }

    private struct ServerCompletion: @unchecked Sendable {
        let callback: rc_client_server_callback_t
        let data: UnsafeMutableRawPointer?
    }

    private func callServer(_ value: rc_api_request_t, callback: @escaping rc_client_server_callback_t, data: UnsafeMutableRawPointer?) {
        let completion = ServerCompletion(callback: callback, data: data)
        let request = Self.request(value, userAgent: userAgent)
        let award = request.flatMap(Self.award)
        if let award { activeAwards.insert(award.key) }
        // Copy all C-owned request bytes before returning. rcheevos destroys
        // the rc_api_request_t immediately after this callback returns.
        Task { [self] in
            let response: AchievementHTTPResponse
            if locked({ closed }) || request == nil {
                response = .init(status: -1, body: Data("{\"Success\":false,\"Error\":\"Session unavailable\"}".utf8))
            } else {
                if let award {
                    do { try await vault.record(award, generation: generation) }
                    catch { locked { events.storageFailure = true } }
                }
                if locked({ closed }) {
                    response = .init(status: -1, body: Data("{\"Success\":false,\"Error\":\"Session unavailable\"}".utf8))
                } else {
                    response = await transport.send(request!)
                    if let award, Self.awardSucceeded(response, id: award.achievementID) {
                        do { try await vault.acknowledge(award, generation: generation) }
                        catch { locked { events.storageFailure = true } }
                    }
                }
            }
            locked { Self.withResponse(response) { completion.callback($0, completion.data) } }
        }
    }

    private static func request(_ value: rc_api_request_t, userAgent: String) -> URLRequest? {
        guard let url = URL(string: string(value.url)), AchievementURLSessionTransport.accepts(url),
              let body = value.post_data else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(String(cString: body).utf8)
        request.setValue(string(value.content_type), forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fields(_ request: URLRequest) -> [String: String] {
        guard let data = request.httpBody, let body = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return fields
    }

    private static func award(_ request: URLRequest) -> PendingAchievementAward? {
        let parts = fields(request)
        guard parts["r"] == "awardachievement", (parts["h"] == "0" || parts["h"] == "1"), let name = parts["u"],
              let id = parts["a"].flatMap(UInt32.init), let hash = parts["m"], hash.count == 32 else { return nil }
        let elapsed = parts["o"].flatMap(TimeInterval.init) ?? 0
        return .init(username: name, achievementID: id, gameHash: hash, earnedAt: Date().addingTimeInterval(-elapsed), hardcore: parts["h"] == "1")
    }

    private static func withResponse<T>(_ response: AchievementHTTPResponse,
                                        _ body: (UnsafePointer<rc_api_server_response_t>) -> T) -> T {
        if let bytes = response.body {
            // C parsers require a zero terminator in addition to body_length.
            var terminated = bytes; terminated.append(0)
            return terminated.withUnsafeBytes { raw in
                var value = rc_api_server_response_t(body: raw.bindMemory(to: CChar.self).baseAddress,
                                                     body_length: bytes.count, http_status_code: Int32(response.status))
                return body(&value)
            }
        }
        var value = rc_api_server_response_t(body: nil, body_length: 0, http_status_code: Int32(response.status))
        return body(&value)
    }

    private static func awardSucceeded(_ response: AchievementHTTPResponse, id: UInt32) -> Bool {
        withResponse(response) { raw in
            var result = rc_api_award_achievement_response_t()
            let status = rc_api_process_award_achievement_server_response(&result, raw)
            defer { rc_api_destroy_award_achievement_response(&result) }
            return status == RC_OK && result.response.succeeded != 0 && result.awarded_achievement_id == id
        }
    }

    /// Only replays securely recorded official unlocks from an earlier runtime.
    /// Live unlock retries remain entirely owned by rc_client's backoff queue.
    func restorePendingUnlocks(username: String) async {
        guard let pending = try? await vault.pending(username: username) else { return }
        locked {
            for award in pending {
                remember(award)
            }
        }
    }

    private func remember(_ award: PendingAchievementAward) {
        let modes: [AchievementMode] = award.isHardcore ? [.hardcore, .casual] : [.casual]
        for mode in modes {
            let key = "\(award.gameHash):\(award.achievementID):\(mode.rawValue)"
            notified.insert(key); localUnlocks.insert(key)
        }
    }

    func retryPersistedAwards(credentials: AchievementCredentials) async {
        guard let pending = try? await vault.pending(username: credentials.username) else { return }
        for award in pending.prefix(16) {
            let shouldRetry = locked { () -> Bool in
                remember(award)
                return !closed && !activeAwards.contains(award.key)
            }
            guard shouldRetry else { continue }
            let request: URLRequest? = credentials.username.withCString { username in
                credentials.token.withCString { token in
                    award.gameHash.withCString { hash in
                        var params = rc_api_award_achievement_request_t(username: username, api_token: token,
                            achievement_id: award.achievementID, hardcore: award.isHardcore ? 1 : 0, game_hash: hash,
                            seconds_since_unlock: UInt32(clamping: Int(max(0, Date().timeIntervalSince(award.earnedAt)))))
                        return Self.httpsAwardRequest(&params, userAgent: userAgent)
                    }
                }
            }
            guard let request, !locked({ closed }) else { continue }
            let response = await transport.send(request)
            if Self.awardSucceeded(response, id: award.achievementID) {
                try? await vault.acknowledge(award, generation: generation)
            } else { break } // Bound work and stop at an unavailable/rejecting service.
        }
    }

    private static func httpsAwardRequest(_ params: UnsafePointer<rc_api_award_achievement_request_t>, userAgent: String) -> URLRequest? {
        "https://retroachievements.org".withCString { host in
            var hosting = rc_api_host_t(host: host, media_host: nil)
            var raw = rc_api_request_t()
            let status = rc_api_init_award_achievement_request_hosted(&raw, params, &hosting)
            defer { rc_api_destroy_request(&raw) }
            return status == RC_OK ? request(raw, userAgent: userAgent) : nil
        }
    }
}
