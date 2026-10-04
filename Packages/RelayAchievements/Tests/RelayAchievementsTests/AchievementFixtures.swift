// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import RelayAchievements

final class MemorySecureStore: AchievementSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failsWrites = false
    var failsRemoval = false
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failsWrites { throw AchievementServiceError.storage }; values[key] = data
    }
    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failsRemoval { throw AchievementServiceError.storage }; values[key] = nil
    }
}

actor FixtureTransport: AchievementHTTPTransport {
    var requests: [URLRequest] = []
    var offline = false
    var unknown = false
    var rejectLogin = false
    var includeHitAchievement = false
    var competitive = false
    var hardcoreUnlocks: Set<UInt32> = []
    var unlocks: Set<UInt32> = []
    func setOffline(_ value: Bool) { offline = value }
    func setUnknown(_ value: Bool) { unknown = value }
    func setRejectLogin(_ value: Bool) { rejectLogin = value }
    func setCompetitive() { competitive = true }
    func setIncludeHitAchievement() { includeHitAchievement = true }

    static func fields(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").compactMap {
            let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
    }
    func send(_ request: URLRequest) async -> AchievementHTTPResponse {
        requests.append(request)
        if offline { return .unavailable }
        let fields = Self.fields(request)
        let value: [String: Any]
        switch fields["r"] {
        case "login2":
            if rejectLogin { value = ["Success": false, "Error": "Invalid credentials", "Code": "invalid_credentials"] }
            else { value = ["Success": true, "User": "RelayFixture", "Token": "fixture-session", "Score": 0,
                            "SoftcoreScore": 0, "Messages": 0, "Permissions": 1, "AccountType": "Registered"] }
        case "achievementsets":
            if unknown { value = ["Success": false, "Error": "Unknown game", "Code": "not_found"] }
            else {
                value = ["Success": true, "GameId": 900001, "Title": "Relay Fixture", "ConsoleId": 5,
                         "ImageIconUrl": "https://media.retroachievements.org/Images/1.png",
                         "RichPresenceGameId": 900001, "RichPresencePatch": competitive ? "Format:Number\nFormatType=VALUE\n\nDisplay:\n?0xH0006=1?Count: @Number(0xH0002)\nPlaying Relay Fixture" : "", "Sets": [[
                            "AchievementSetId": 900001, "GameId": 900001, "Title": NSNull(), "Type": "core",
                            "ImageIconUrl": "https://media.retroachievements.org/Images/1.png",
                            "Achievements": [
                                ["ID": 1, "Title": "First step", "Description": "Set the first byte.", "Flags": 3,
                                 "Points": 5, "MemAddr": "0xH0001=1", "Author": "Relay", "BadgeName": "00001", "Created": 1, "Modified": 1],
                                ["ID": 2, "Title": "Count to five", "Description": "Fill the progress bar.", "Flags": 3,
                                 "Points": 10, "MemAddr": "M:0xH0002>=5", "Author": "Relay", "BadgeName": "00002", "Created": 1, "Modified": 1]
                            ] + (includeHitAchievement ? [["ID": 3, "Title": "Three frames", "Description": "Accumulate three hits.", "Flags": 3,
                                  "Points": 1, "MemAddr": "0xH0003=1.3.", "Author": "Relay", "BadgeName": "00003", "Created": 1, "Modified": 1]] : []) + (competitive ? [["ID": 4, "Title": "Challenge", "Description": "Hold the challenge.", "Flags": 3,
                                  "Points": 1, "MemAddr": "0xH0004=1_T:0xH0005=1", "Author": "Relay", "BadgeName": "00004", "Created": 1, "Modified": 1]] : []),
                            "Leaderboards": competitive ? [["ID": 44, "Title": "Fixture score", "Description": "Score 17 points.",
                                "Mem": "STA:0xH000B=1::CAN:0xH000C=1::SUB:0xH000D=1::VAL:0x 000E", "Format": "SCORE", "LowerIsBetter": false]] : []
                         ]]]
            }
        case "startsession": value = ["Success": true, "Unlocks": unlocks.map { ["ID": $0, "When": 1] }, "HardcoreUnlocks": hardcoreUnlocks.map { ["ID": $0, "When": 1] }]
        case "awardachievement":
            let id = UInt32(fields["a"] ?? "") ?? 0
            unlocks.insert(id)
            if fields["h"] == "1" { hardcoreUnlocks.insert(id) }
            value = ["Success": true, "AchievementID": id, "Score": 0, "SoftcoreScore": 5, "AchievementsRemaining": 1]
        case "submitlbentry":
            value = ["Success": true, "Response": ["Score": 17, "BestScore": 17,
                     "TopEntries": [["User": "RelayFixture", "Rank": 1, "Score": 17]], "RankInfo": ["Rank": 1, "NumEntries": 1]]]
        case "ping": value = ["Success": true]
        default: value = ["Success": false, "Error": "Unexpected fixture request"]
        }
        return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: value))
    }
}

func fixtureROM() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gba")
    try Data(repeating: 0, count: 1024).write(to: url)
    return url
}

func loadFixtureGame(_ runtime: RcheevosRuntime, romURL: URL) async throws -> AchievementGame {
    let frames = Task {
        while !Task.isCancelled {
            runtime.evaluateFrame { _, _, target in
                target.initializeMemory(as: UInt8.self, repeating: 0)
                return target.count
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    let timeout = Task {
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled { runtime.close() }
    }
    defer { frames.cancel(); timeout.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
        runtime.load(system: .gameBoyAdvance, romURL: romURL) { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
}
