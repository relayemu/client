// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  ContentLocation.swift
//  RelayDomain
//
//  Where a piece of Relay-managed content (game file, save, save state,
//  screenshot) lives on the local device, expressed durably: a named root
//  plus a relative POSIX path. Absolute paths are never stored — the app
//  container moves between launches on iOS and simulators, and the same
//  library must be describable on another device or platform.
//
//  Resolving a `ContentLocation` to a concrete URL is the job of the library
//  layer (which knows where the roots are on this device), not of the domain.

import Foundation

public struct ContentLocation: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The named directories Relay manages. Only the managed library exists in
    public enum Root: String, Codable, Sendable, CaseIterable {
        /// Relay's own library directory inside the app container.
        case managedLibrary
    }

    public let root: Root
    /// Forward-slash separated path relative to `root`. Validated: non-empty,
    /// relative, no `.`/`..` components, no empty components, no NUL bytes.
    public let relativePath: String

    public init(root: Root, relativePath: String) throws {
        try Self.validate(relativePath)
        self.root = root
        self.relativePath = relativePath
    }

    /// Path components of `relativePath`.
    public var pathComponents: [String] { relativePath.split(separator: "/").map(String.init) }

    public var description: String { "\(root.rawValue):\(relativePath)" }

    public static func validate(_ path: String) throws {
        guard !path.isEmpty else { throw ContentLocationError.invalidPath(path, reason: "empty") }
        guard !path.hasPrefix("/") else { throw ContentLocationError.invalidPath(path, reason: "absolute") }
        guard !path.contains("\0") else { throw ContentLocationError.invalidPath(path, reason: "contains NUL") }
        guard !path.hasSuffix("/") else { throw ContentLocationError.invalidPath(path, reason: "trailing slash") }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { throw ContentLocationError.invalidPath(path, reason: "empty component") }
            if component == "." || component == ".." { throw ContentLocationError.invalidPath(path, reason: "relative component '\(component)'") }
        }
    }

    // MARK: Codable (keyed: root + relativePath, with validation on decode)

    private enum CodingKeys: String, CodingKey { case root, relativePath }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decode(Root.self, forKey: .root)
        let path = try container.decode(String.self, forKey: .relativePath)
        do {
            try self.init(root: root, relativePath: path)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .relativePath, in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(relativePath, forKey: .relativePath)
    }
}

public enum ContentLocationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPath(String, reason: String)

    public var description: String {
        switch self {
        case .invalidPath(let path, let reason): return "Invalid content path '\(path)': \(reason)"
        }
    }
}
