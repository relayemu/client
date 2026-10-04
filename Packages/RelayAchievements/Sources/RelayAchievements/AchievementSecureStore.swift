// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Small secure records only. Passwords never enter this boundary.
public protocol AchievementSecureStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}

public final class AchievementKeychainStore: AchievementSecureStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.relayemu.relay.retroachievements") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AchievementServiceError.storage }
        return data
    }
    public func write(_ data: Data, key: String) throws {
        let q = query(key)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AchievementServiceError.storage }
        } else if status != errSecSuccess { throw AchievementServiceError.storage }
    }
    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AchievementServiceError.storage }
    }
}

/// Serializes secure mutations and fences delayed callbacks after disconnect.
/// Tokens and offline unlocks are device-local, outside Relay Account/Sync.
actor AchievementVault {
    private let store: any AchievementSecureStore
    private var generation = UUID()
    init(store: any AchievementSecureStore) { self.store = store }
    func currentGeneration() -> UUID { generation }
    func credentials() throws -> AchievementCredentials? {
        guard let data = try store.read("session") else { return nil }
        guard let value = try? JSONDecoder().decode(AchievementCredentials.self, from: data),
              !value.username.isEmpty, !value.token.isEmpty else { throw AchievementServiceError.storage }
        return value
    }
    func save(_ credentials: AchievementCredentials, generation expected: UUID) throws {
        guard generation == expected else { throw AchievementServiceError.cancelled }
        try store.write(JSONEncoder().encode(credentials), key: "session")
    }
    func pending(username: String) throws -> [PendingAchievementAward] {
        guard let data = try store.read("pending") else { return [] }
        guard let values = try? JSONDecoder().decode([PendingAchievementAward].self, from: data) else {
            throw AchievementServiceError.storage
        }
        return values.filter { $0.username.caseInsensitiveCompare(username) == .orderedSame }
    }
    func record(_ award: PendingAchievementAward, generation expected: UUID) throws {
        guard generation == expected else { throw AchievementServiceError.cancelled }
        var values = try pending(username: award.username)
        if values.contains(where: { $0.key == award.key }) { return }
        guard values.count < 2048 else { throw AchievementServiceError.storage }
        values.append(award)
        try store.write(JSONEncoder().encode(values), key: "pending")
    }
    func acknowledge(_ award: PendingAchievementAward, generation expected: UUID) throws {
        guard generation == expected else { return }
        let values = try pending(username: award.username).filter { $0.key != award.key }
        if values.isEmpty { try store.remove("pending") }
        else { try store.write(JSONEncoder().encode(values), key: "pending") }
    }
    func disconnect() throws {
        // Invalidate first, even if Keychain is temporarily unavailable. No
        // late login or award may resurrect credentials after this point.
        generation = UUID()
        var failed = false
        do { try store.remove("session") } catch { failed = true }
        do { try store.remove("pending") } catch { failed = true }
        if failed { throw AchievementServiceError.storage }
    }
}
