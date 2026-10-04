// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayDomain
import RelayLibrary
@testable import RelayPersistence

final class CoverCatalogSchemaTests: XCTestCase {
    func testMetadataCoverKeyAndLookupDigestsRoundTrip() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let fingerprint = try ContentFingerprint(sha256: Array(repeating: 7, count: 32))
        let game = Game(systemID: .gameBoyAdvance, title: "a", contentFingerprint: fingerprint, addedAt: Date(timeIntervalSince1970: 1))
        try await store.games.insert(game, files: [])
        let metadata = GameMetadata(gameID: game.id, region: "USA", coverKey: "gba/" + String(repeating: "a", count: 64),
                                    source: "title-catalog", matchedAt: Date(timeIntervalSince1970: 2))
        try await store.games.upsertMetadata(metadata)
        let stored = try await store.games.metadata(for: game.id)
        XCTAssertEqual(stored, metadata)

        let digests = LookupDigests(sha1: String(repeating: "b", count: 40), headerlessSHA1: nil, discSerial: "SLUS-00892")
        try await store.games.setLookupDigests(digests, for: fingerprint)
        let cached = try await store.games.lookupDigests(for: fingerprint)
        XCTAssertEqual(cached, digests)
        let other = try ContentFingerprint(sha256: Array(repeating: 8, count: 32))
        let missing = try await store.games.lookupDigests(for: other)
        XCTAssertNil(missing)
    }
}
