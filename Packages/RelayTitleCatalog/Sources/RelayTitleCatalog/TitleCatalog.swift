// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  TitleCatalog.swift
//  RelayTitleCatalog
//
//  Read-only access to the bundled RelayTitles.sqlite. Opened once; queries are
//  indexed point lookups (primary keys of rom and serial), plus an in-memory
//  title index per system for games known only by their synced title.

import Foundation
import GRDB
import RelayDomain

public struct CatalogTitle: Hashable, Sendable {
    public let id: Int64
    public let system: SystemID
    public let name: String
}

public final class TitleCatalog: Sendable {
    public let revision: String
    private let database: DatabaseQueue
    private let titleIndex = TitleIndex()

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        let schema = try database.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'schema'") }
        guard schema == "1", let revision = try database.read({ try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'source_revision'") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.revision = revision
    }

    public static func bundled() throws -> TitleCatalog {
        guard let url = Bundle.module.url(forResource: "RelayTitles", withExtension: "sqlite") else { throw CocoaError(.fileNoSuchFile) }
        return try TitleCatalog(url: url)
    }

    public func titles(sha1: String) throws -> [CatalogTitle] {
        guard sha1.count == 40, let bytes = Data(hex: sha1) else { return [] }
        return try fetch("SELECT title.id, system, name FROM rom JOIN title ON title.id = rom.title_id WHERE rom.sha1 = ? ORDER BY title.id", bytes)
    }

    public func titles(serial: String) throws -> [CatalogTitle] {
        try fetch("SELECT title.id, system, name FROM serial JOIN title ON title.id = serial.title_id WHERE serial.serial = ? ORDER BY title.id", serial)
    }

    /// Titles of `system` whose display title has this `CatalogName.matchKey`.
    /// The per-system index is built on first use (a few thousand names).
    public func titles(system: SystemID, matchKey: String) throws -> [CatalogTitle] {
        try titleIndex.titles(system: system, key: matchKey) {
            try fetch("SELECT id, system, name FROM title WHERE system = ? ORDER BY id", system.rawValue)
        }
    }

    private func fetch(_ sql: String, _ argument: some DatabaseValueConvertible) throws -> [CatalogTitle] {
        try database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [argument]).map {
                CatalogTitle(id: $0[0], system: SystemID(rawValue: $0[1]), name: $0[2])
            }
        }
    }
}

/// Display-title match keys per system, filled lazily under a lock.
private final class TitleIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var systems: [SystemID: [String: [CatalogTitle]]] = [:]

    func titles(system: SystemID, key: String, load: () throws -> [CatalogTitle]) throws -> [CatalogTitle] {
        try lock.withLock {
            if let index = systems[system] { return index[key] ?? [] }
            let index = Dictionary(grouping: try load()) { CatalogName.matchKey(CatalogName.displayTitle($0.name)) }
            systems[system] = index
            return index[key] ?? []
        }
    }
}

private extension Data {
    init?(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
