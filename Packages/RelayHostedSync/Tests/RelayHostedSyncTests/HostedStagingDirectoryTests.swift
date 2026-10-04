// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayHostedSync

final class HostedStagingDirectoryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A persisted marker without an OS-held lock represents the state after its process exited.
    private func orphan(in root: URL, name: String = UUID().uuidString, marker: Data? = nil) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(HostedStagingDirectory.markerName).path
        XCTAssertTrue(FileManager.default.createFile(atPath: path,
            contents: marker ?? Data(HostedStagingDirectory.markerContents), attributes: [.posixPermissions: 0o600]))
        try Data("private scratch".utf8).write(to: directory.appendingPathComponent("payload"))
        return directory
    }

    func testNextLeaseReclaimsKnownOrphan() throws {
        let root = try temporaryDirectory()
        let abandoned = try orphan(in: root)
        let current = try HostedStagingDirectory.acquire(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.directory.path))
        current.remove()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testActivePeerLeaseAndFilesSurviveReclamation() throws {
        let root = try temporaryDirectory()
        let first = try HostedStagingDirectory.acquire(in: root)
        let firstFile = first.directory.appendingPathComponent("active-source")
        try Data("live upload".utf8).write(to: firstFile)
        let second = try HostedStagingDirectory.acquire(in: root)
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 0)
        XCTAssertEqual(try Data(contentsOf: firstFile), Data("live upload".utf8))
        first.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        second.remove()
        second.remove()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnknownLegacyAndPersonalDirectoriesRemainUntouched() throws {
        let root = try temporaryDirectory()
        let legacy = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy source".utf8).write(to: legacy.appendingPathComponent("source"))
        let unknown = try orphan(in: root, marker: Data("unrecognized version".utf8))
        let personal = try orphan(in: root, name: "Personal Documents")
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 0)
        for directory in [legacy, unknown, personal] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testDirectoryAndMarkerSymlinksCannotAuthorizeReclamation() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let personal = try orphan(in: outside)
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: personal)
        let fake = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fake.appendingPathComponent(HostedStagingDirectory.markerName),
                                                   withDestinationURL: personal.appendingPathComponent(HostedStagingDirectory.markerName))
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 0)
        XCTAssertEqual(try Data(contentsOf: personal.appendingPathComponent("payload")), Data("private scratch".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.path))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testReclaimingOwnedDirectoryDoesNotFollowItsPayloadSymlink() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let personal = outside.appendingPathComponent("important")
        try Data("keep".utf8).write(to: personal)
        let abandoned = try orphan(in: root)
        try FileManager.default.createSymbolicLink(at: abandoned.appendingPathComponent("linked-content"), withDestinationURL: outside)
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 1)
        XCTAssertEqual(try Data(contentsOf: personal), Data("keep".utf8))
    }

    func testHardLinkedMarkerCannotAuthorizeReclamation() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let abandoned = try orphan(in: root)
        let marker = abandoned.appendingPathComponent(HostedStagingDirectory.markerName)
        try FileManager.default.linkItem(at: marker, to: outside.appendingPathComponent("marker-copy"))
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testReclamationHasBoundedBatchAndContinuesNextTime() throws {
        let root = try temporaryDirectory()
        for _ in 0..<70 { _ = try orphan(in: root) }
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 64)
        XCTAssertEqual(try HostedStagingDirectory.reclaimAbandoned(in: root), 6)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSymlinkRootAndReplacedMarkerRemainUntouched() throws {
        let parent = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let personal = try orphan(in: outside)
        let root = parent.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        XCTAssertThrowsError(try HostedStagingDirectory.reclaimAbandoned(in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personal.path))

        let lease = try HostedStagingDirectory.acquire(in: parent.appendingPathComponent("scratch"))
        try Data("different owner".utf8).write(to: lease.directory.appendingPathComponent(HostedStagingDirectory.markerName))
        lease.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.directory.path))
    }
}
