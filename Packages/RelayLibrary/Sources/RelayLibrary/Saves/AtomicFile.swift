// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  AtomicFile.swift
//  RelayLibrary
//
//  Crash-safe file replacement for saves and states (spec §29, owner rule §10):
//  write to a temporary sibling, flush it to stable storage, verify it, then
//  rename it over the destination. `rename(2)` is atomic on APFS, so a crash or
//  kill at any point leaves either the previous complete file or the new
//  complete file — never a truncated one. A failure never touches the
//  destination. The `failureInjection` hook lets tests interrupt each stage.

import Foundation

public struct AtomicFile: Sendable {
    public enum Stage: String, Sendable, CaseIterable {
        case writeTemporary, flush, verify, rename
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case verificationFailed(URL)
        case injected(Stage)

        public var description: String {
            switch self {
            case .verificationFailed(let url): return "Written bytes did not read back identically at \(url.lastPathComponent)"
            case .injected(let stage): return "Injected failure at stage \(stage.rawValue)"
            }
        }
    }

    /// Test hook, called before each stage; throw to simulate an interruption.
    public var failureInjection: (@Sendable (Stage) throws -> Void)?

    public init(failureInjection: (@Sendable (Stage) throws -> Void)? = nil) {
        self.failureInjection = failureInjection
    }

    /// Atomically replaces (or creates) `destination` with `data`.
    public func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        defer { try? fm.removeItem(at: temporary) }

        try failureInjection?(.writeTemporary)
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try failureInjection?(.flush)
            try Self.flush(handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try failureInjection?(.verify)
        let readBack = try Data(contentsOf: temporary, options: .uncached)
        guard readBack == data else { throw Failure.verificationFailed(destination) }

        try failureInjection?(.rename)
        try Self.rename(temporary, to: destination)
        Self.flushDirectory(directory)
    }

    /// Full flush to stable storage (`F_FULLFSYNC` on Apple platforms).
    static func flush(_ handle: FileHandle) throws {
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 {
            try handle.synchronize()
        }
    }

    static func rename(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { s in
            destination.withUnsafeFileSystemRepresentation { d in
                Foundation.rename(s!, d!)
            }
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                           NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
    }

    /// Best effort: make the directory entry durable too.
    static func flushDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
    }
}
