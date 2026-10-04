// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  SyncResolution.swift
//  RelaySync
//
//  What to do when the server refuses a save because it holds another
//  on the record's meaning; there is no universal "server wins" or "client wins".

import Foundation
import RelayDomain

enum SyncResolution: Equatable, Sendable {
    /// The server already holds equivalent content: the intent is done.
    case acceptServer
    /// Re-send this merged record.
    case resend(SyncRecord)
    /// Same immutable identity, different bytes: keep local, stop retrying, diagnose.
    case integrityError(String)

    static func resolve(local: SyncRecord, server: SyncRecord?) -> SyncResolution {
        guard let server else { return .resend(local) }
        guard local.key == server.key, local.gameFingerprint == server.gameFingerprint, local.generation == server.generation else {
            return .integrityError("immutable record membership differs")
        }
        switch (local, server) {
        case (.game(let mine), .game(let theirs)):
            guard mine.systemID == theirs.systemID else { return .integrityError("established systemID differs") }
            // Same ordering as the store's merge: updatedAt, then a deterministic tiebreak.
            func rank(_ e: SyncGameEntry) -> (Int64, String, Int) { (e.updatedAt, e.title, e.isFavorite ? 1 : 0) }
            let theirsWin = rank(theirs) >= rank(mine)
            if theirsWin, theirs.addedAt <= mine.addedAt { return .acceptServer }
            var merged = theirsWin ? theirs : mine
            merged.addedAt = min(mine.addedAt, theirs.addedAt)
            merged.contentSize = mine.contentSize ?? theirs.contentSize
            return .resend(.game(merged))
        case (.session(let mine), .session(let theirs)):
            guard mine.installationID == theirs.installationID, mine.coreID == theirs.coreID, mine.startedAt == theirs.startedAt else { return .integrityError("session identity differs") }
            let mineEnded = mine.endedAt ?? 0, theirsEnded = theirs.endedAt ?? 0
            return mineEnded > theirsEnded ? .resend(.session(mine)) : .acceptServer
        case (.tombstone(let mine), .tombstone(let theirs)):
            return mine.deletedAt > theirs.deletedAt ? .resend(.tombstone(mine)) : .acceptServer
        case (.batteryRevision(let mine), .batteryRevision(let theirs)):
            return mine.dataFingerprint == theirs.dataFingerprint && mine.parentIDs == theirs.parentIDs && mine.installationID == theirs.installationID ? .acceptServer : .integrityError("battery revision \(mine.revisionID) exists remotely with different bytes")
        case (.state(let mine), .state(let theirs)):
            return mine.payloadFingerprint == theirs.payloadFingerprint && mine.batteryRevisionID == theirs.batteryRevisionID && mine.installationID == theirs.installationID && mine.coreID == theirs.coreID ? .acceptServer : .integrityError("state \(mine.stateID) exists remotely with different bytes")
        case (.contentIndex(let mine), .contentIndex(let theirs)):
            return mine.size == theirs.size && mine.partCount == theirs.partCount && mine.systemID == theirs.systemID ? .acceptServer : .integrityError("content index \(mine.fingerprint) differs remotely")
        case (.gameContent(let mine), .gameContent(let theirs)):
            return mine.partFingerprint == theirs.partFingerprint ? .acceptServer : .integrityError("content \(mine.fingerprint) part \(mine.partIndex) differs remotely")
        case (.artwork(let mine), .artwork(let theirs)):
            // A preference: the later value wins, in the order every device and Relay Sync use.
            // When theirs wins, the next fetch installs it here through the same order.
            return SyncArtwork.isLater(updatedAt: mine.updatedAt, cover: mine.artworkFingerprint, than: theirs.updatedAt, theirs.artworkFingerprint)
                ? .resend(.artwork(mine)) : .acceptServer
        default:
            return .integrityError("record type mismatch for \(local.key)")
        }
    }
}
