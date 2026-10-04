// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Security)
import Security
#endif

public protocol HostedSessionStoring: Sendable {
    func load() throws -> HostedSessionCredential?
    func save(_ credential: HostedSessionCredential) throws
    func remove() throws
    func loadObservation() throws -> HostedAccountObservation?
    func saveObservation(_ observation: HostedAccountObservation) throws
}

extension HostedSessionStoring {
    public func loadObservation() throws -> HostedAccountObservation? { nil }
    public func saveObservation(_ observation: HostedAccountObservation) throws {}
}

/// Exact service/account scoping, no synchronizable keychain, and no migration
/// to another device. All calls are made off the main actor by the account actor.
public struct HostedKeychainSessionStore: HostedSessionStoring {
    private let service: String
    private let installationID: UUID
    public init(environment: RelayHostedEnvironment, installationID: UUID) {
        service = environment.keychainService
        self.installationID = installationID
    }

    #if canImport(Security)
    func query(account: String = "api-session") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: installationID.uuidString.lowercased() + "/" + account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    public func load() throws -> HostedSessionCredential? { try read(HostedSessionCredential.self, account: "api-session") }
    public func loadObservation() throws -> HostedAccountObservation? { try read(HostedAccountObservation.self, account: "account-observation") }
    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HostedAuthError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(type, from: data) else {
            throw HostedAuthError.invalidResponse
        }
        return credential
    }
    public func save(_ credential: HostedSessionCredential) throws { try write(credential, account: "api-session") }
    public func saveObservation(_ observation: HostedAccountObservation) throws { try write(observation, account: "account-observation") }
    private func write<T: Encodable>(_ value: T, account: String) throws {
        let query = query(account: account)
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HostedAuthError.keychain(status) }
    }
    public func remove() throws {
        // Remove both precisely scoped records, attempting both even if one fails.
        var failure: OSStatus?
        for account in ["api-session", "account-observation"] {
            let status = SecItemDelete(query(account: account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { failure = status }
        }
        if let failure { throw HostedAuthError.keychain(failure) }
    }
    #else
    public func load() throws -> HostedSessionCredential? { throw HostedAuthError.keychain(-4) }
    public func save(_ credential: HostedSessionCredential) throws { throw HostedAuthError.keychain(-4) }
    public func remove() throws { throw HostedAuthError.keychain(-4) }
    #endif
}
