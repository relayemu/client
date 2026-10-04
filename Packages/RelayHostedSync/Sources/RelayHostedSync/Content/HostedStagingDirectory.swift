// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// A private scratch directory whose ownership survives process death, while its active
/// lifetime is protected by an OS file lock. Unknown and legacy directories are never reclaimed.
final class HostedStagingDirectory: @unchecked Sendable {
    static let markerName = ".relay-hosted-staging-v1"
    static let markerContents = Array("relay-hosted-staging-v1\n".utf8)

    let directory: URL
    private let lock = NSLock()
    private var descriptor: Int32

    private init(directory: URL, descriptor: Int32) {
        self.directory = directory
        self.descriptor = descriptor
    }

    deinit { remove() }

    /// Acquiring a new scope also reclaims marker-owned scopes whose process no longer holds a lock.
    /// Multiple clients may safely share the same scratch root.
    static func acquire(in root: URL) throws -> HostedStagingDirectory {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        _ = try reclaimAbandoned(in: root)
        let rootFD = try openDirectory(root)
        defer { close(rootFD) }
        let name = UUID().uuidString.lowercased()
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directoryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryFD) }
        let descriptor = openat(directoryFD, markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var handedOff = false
        defer { if !handedOff { close(descriptor) } }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = markerContents.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == markerContents.count, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        handedOff = true
        return HostedStagingDirectory(directory: root.appendingPathComponent(name, isDirectory: true), descriptor: descriptor)
    }

    /// Deletes only exact version-one marked, unlocked UUID directories. It does not follow
    /// directory/marker symlinks, accept hard-linked markers, or touch unknown directory layouts.
    @discardableResult
    static func reclaimAbandoned(in root: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let rootFD = try openDirectory(root)
        defer { close(rootFD) }
        let scanFD = dup(rootFD)
        guard scanFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let entries = fdopendir(scanFD) else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(scanFD)
            throw failure
        }
        defer { closedir(entries) }
        var removed = 0
        // Bound work and memory even if a damaged root contains many unrelated entries.
        var inspected = 0
        while inspected < 256, removed < 64, let entry = readdir(entries) {
            inspected += 1
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            guard UUID(uuidString: name) != nil else { continue }
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            let directoryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { continue }
            defer { close(directoryFD) }
            var marker = stat()
            guard fstatat(directoryFD, markerName, &marker, AT_SYMLINK_NOFOLLOW) == 0,
                  marker.st_mode & S_IFMT == S_IFREG else { continue }
            let descriptor = openat(directoryFD, markerName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(descriptor, LOCK_UN) }
            guard markerMatches(descriptor), sameDirectory(directoryFD, rootFD: rootFD, name: name),
                  sameMarker(descriptor, directoryFD: directoryFD) else { continue }
            do {
                try FileManager.default.removeItem(at: candidate)
                removed += 1
            } catch {
                // Reclamation is best effort; a busy/unreadable owned scope can be retried later.
            }
        }
        return removed
    }

    /// Idempotent release of this exact lease. The lock remains held throughout removal.
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directoryFD >= 0 {
            if Self.markerMatches(descriptor), Self.sameMarker(descriptor, directoryFD: directoryFD) {
                try? FileManager.default.removeItem(at: directory)
            }
            close(directoryFD)
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw POSIXError(.EINVAL) }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private static func markerMatches(_ descriptor: Int32) -> Bool {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_mode & 0o777 == 0o600,
              attributes.st_nlink == 1,
              attributes.st_size == markerContents.count else { return false }
        var bytes = [UInt8](repeating: 0, count: markerContents.count)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return count == markerContents.count && bytes == markerContents
    }

    private static func sameMarker(_ descriptor: Int32, directoryFD: Int32) -> Bool {
        var held = stat(), current = stat()
        return fstat(descriptor, &held) == 0 && fstatat(directoryFD, markerName, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFREG && held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }

    private static func sameDirectory(_ descriptor: Int32, rootFD: Int32, name: String) -> Bool {
        var held = stat(), current = stat()
        return fstat(descriptor, &held) == 0 && fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFDIR && held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }
}
