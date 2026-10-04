// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CoverKey.swift
//  RelayLibrary
//
//  The name of a catalog game's cover on Relay's cover mirror:
//  "<system>/" + hex(SHA-256("<system>/<catalog name>")). Every device derives
//  the same key from a public catalog title; it names no player and no file.

import Foundation
import RelayDomain
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum CoverKey {
    public static func make(system: SystemID, catalogName: String) -> String {
        let digest = SHA256.hash(data: Data("\(system.rawValue)/\(catalogName)".utf8))
        return system.rawValue + "/" + LookupDigester.hex(digest)
    }

    public static func isValid(_ key: String) -> Bool {
        key.range(of: #"^[a-z0-9]{1,8}/[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}
