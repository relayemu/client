// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import RelayUI

/// Local responses through the real official client. All requests stay in this
/// actor; this fixture has no network transport and cannot contact RA.
@MainActor
enum DebugAchievements {
    static func make() -> AchievementsModel? {
        guard let scenario = DevHooks.value(after: "--relay-achievements-fixture") else { return nil }
        guard let rawID = DevHooks.value(after: "--relay-isolated-qualification"),
              let id = UUID(uuidString: rawID), let root = DevHooks.libraryRoot else {
            preconditionFailure("Achievement fixtures require an isolated library identifier")
        }
        let store = AchievementKeychainStore(service: "app.relayemu.relay.retroachievements.fixture." + id.uuidString)
        if ["connected", "offline", "hardcore"].contains(scenario) {
            let credentials = AchievementCredentials(username: "RelayFixture", token: "fixture-session")
            // An unsigned test app cannot use Keychain. Preserve a normal
            // disconnected UI on failure so the test can report the missing
            // signing prerequisite instead of crashing the game launch.
            try? store.write(JSONEncoder().encode(credentials), key: "session")
        }
        let preferences = UserDefaults(suiteName: "relay.achievements.fixture." + id.uuidString)!
        if scenario == "hardcore" { preferences.set(true, forKey: "relay.achievements.hardcore") }
        return AchievementsModel(store: store, transport: DebugAchievementTransport(offline: scenario == "offline"),
                                 cacheDirectory: root.appendingPathComponent("AchievementCache"),
                                 hardcoreValidated: scenario == "hardcore", preferences: preferences)
    }
}

private actor DebugAchievementTransport: AchievementHTTPTransport {

    var offline: Bool
    init(offline: Bool) { self.offline = offline }
    var unknown = false
    var rejectLogin = false
    var unlocks: Set<UInt32> = []
    var hardcoreUnlocks: Set<UInt32> = []
    func setOffline(_ value: Bool) { offline = value }
    func setUnknown(_ value: Bool) { unknown = value }
    func setRejectLogin(_ value: Bool) { rejectLogin = value }

    static func fields(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").compactMap {
            let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
    }
    func send(_ request: URLRequest) async -> AchievementHTTPResponse {
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
                         "RichPresenceGameId": 900001, "RichPresencePatch": "", "Sets": [[
                            "AchievementSetId": 900001, "GameId": 900001, "Title": NSNull(), "Type": "core",
                            "ImageIconUrl": "https://media.retroachievements.org/Images/1.png",
                            "Achievements": [
                                ["ID": 1, "Title": "First step", "Description": "Press A in the Relay fixture.", "Flags": 3,
                                 "Points": 5, "MemAddr": "0xH048000>0", "Author": "Relay", "BadgeName": "00001", "Created": 1, "Modified": 1],
                                ["ID": 2, "Title": "Count to five", "Description": "Fill the progress bar.", "Flags": 3,
                                 "Points": 10, "MemAddr": "M:0xH048000>=5", "Author": "Relay", "BadgeName": "00002", "Created": 1, "Modified": 1]
                            ], "Leaderboards": []
                         ]]]
            }
        case "startsession": value = ["Success": true, "Unlocks": unlocks.map { ["ID": $0, "When": 1] }, "HardcoreUnlocks": hardcoreUnlocks.map { ["ID": $0, "When": 1] }]
        case "awardachievement":
            let id = UInt32(fields["a"] ?? "") ?? 0
            unlocks.insert(id)
            if fields["h"] == "1" { hardcoreUnlocks.insert(id) }
            value = ["Success": true, "AchievementID": id, "Score": 0, "SoftcoreScore": 5, "AchievementsRemaining": 1]
        case "ping": value = ["Success": true]
        default: value = ["Success": false, "Error": "Unexpected fixture request"]
        }
        return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: value))
    }
}

#endif
