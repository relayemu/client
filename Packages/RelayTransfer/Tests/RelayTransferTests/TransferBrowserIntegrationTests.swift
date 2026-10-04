// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RelayHostedSync
import RelayLibrary
import RelayPersistence
@testable import RelayTransfer

private final class BrowserFixtureStore: HostedSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HostedSessionCredential?
    init(_ credential: HostedSessionCredential) { self.credential = credential }
    func load() -> HostedSessionCredential? { lock.lock(); defer { lock.unlock() }; return credential }
    func save(_ value: HostedSessionCredential) { lock.lock(); defer { lock.unlock() }; credential = value }
    func remove() { lock.lock(); defer { lock.unlock() }; credential = nil }
}

final class TransferBrowserIntegrationTests: XCTestCase {
    /// Opt-in real browser → pinned native transport → normal GameImporter.
    /// Fixture credentials never enter console output or the durable test report.
    func testBrowserToNativeImport() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSFER_BROWSER_FIXTURE"] else { throw XCTSkip("Disposable browser fixture not requested") }
        struct Fixture: Decodable { let origin: URL; let accountID: UUID; let installationID: UUID; let nativeToken: String }
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: path) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let environment = try RelayHostedEnvironment.transferTestEnvironment(origin: fixture.origin)
        let account = RelayHostedAccountSession(environment: environment, store: BrowserFixtureStore(.init(accessToken: fixture.nativeToken, expiresAt: Date().addingTimeInterval(3600), relayAccountID: fixture.accountID)), installationID: fixture.installationID, deviceKind: .mac)
        try await account.restore()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("native-library-" + UUID().uuidString, isDirectory: true)
        let location = LibraryLocation(rootURL: root); try location.createDirectories()
        let store = try SQLiteLibraryStore.open(at: location.databaseURL, deviceKind: .mac)
        defer { try? store.close() }
        let importer = GameImporter(store: store, location: location)
        let transfer = RelayTransferSession(account: account, accountID: fixture.accountID, deviceKind: .mac,
            stagingDirectory: location.stagingDirectory, availableBytes: { Int64.max }, importFiles: { urls in
                let report = await importer.importFiles(urls)
                return TransferImportResult.fromImportReport(report, sourceURLs: urls)
            })
        let completed = expectation(description: "Browser transfer received done")
        let evidence = BrowserReceiveEvidence()
        let observer = Task<Bool, Never> {
            for await event in transfer.events {
                switch event {
                case .waiting: print("Fixture native: waiting")
                case .connecting: print("Fixture native: connecting")
                case .connected: print("Fixture native: connected")
                case .route: break
                case .manifest(let files):
                    await evidence.manifest(files)
                    print("Fixture native: manifest " + String(files.count))
                    if ProcessInfo.processInfo.environment["TRANSFER_ROTATE_DURING_RECEIVE"] == "1" {
                        do {
                            try await account.rotateIfNeeded()
                            await evidence.rotated()
                            print("Fixture native: account rotated during receive")
                        } catch {
                            XCTFail("Account rotation failed during transfer")
                            completed.fulfill(); return false
                        }
                    }
                case .status(let status): await evidence.record(status); print("Fixture native: status " + status.state)
                case .outcomes: break
                case .completed: print("Fixture native: completed"); completed.fulfill(); return true
                case .failed(let error): XCTFail("Native transfer failed: \(error)"); completed.fulfill(); return false
                }
            }
            return false
        }
        do { try await transfer.start() }
        catch {
            completed.fulfill(); observer.cancel()
            XCTFail("Transfer start failed: " + String(describing: error))
            return
        }
        try Data("ready".utf8).write(to: URL(fileURLWithPath: path + ".native-ready"))
        await fulfillment(of: [completed], timeout: 1800)
        observer.cancel(); await transfer.stop(reason: "completed")
        let succeeded = await observer.value
        XCTAssertTrue(succeeded, "Native receiver did not complete")
        let games = try await store.games.games(matching: .init())
        let expected = Int(ProcessInfo.processInfo.environment["TRANSFER_EXPECTED_GAMES"] ?? "1") ?? 1
        XCTAssertEqual(games.count, expected, "Normal importer result differs from the selected fixture")
        let parallel = await evidence.maximumAcknowledgedFiles
        if ProcessInfo.processInfo.environment["TRANSFER_EXPECT_PARALLEL"] == "1" { XCTAssertEqual(parallel, 2, "Two files must make disk-acknowledged progress before either finishes") }
        let verifiedBytes = await evidence.verifiedBytes
        let rotated = await evidence.didRotate
        let minimum = ProcessInfo.processInfo.environment["TRANSFER_MINIMUM_VERIFIED_BYTES"].flatMap(Int64.init)
        if let minimum {
            XCTAssertGreaterThanOrEqual(verifiedBytes, minimum, "Large source must pass native SHA-256 verification")
        }
        if ProcessInfo.processInfo.environment["TRANSFER_ROTATE_DURING_RECEIVE"] == "1" { XCTAssertTrue(rotated) }
        let accepted = succeeded && games.count == expected
            && (ProcessInfo.processInfo.environment["TRANSFER_EXPECT_PARALLEL"] != "1" || parallel == 2)
            && (ProcessInfo.processInfo.environment["TRANSFER_ROTATE_DURING_RECEIVE"] != "1" || rotated)
            && (minimum.map { verifiedBytes >= $0 } ?? true)
        let report: [String: Any] = ["succeeded": accepted, "gameCount": games.count, "maximumConcurrentAcknowledgedFiles": parallel, "verifiedBytes": verifiedBytes, "rotatedDuringReceive": rotated, "completedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: path + ".result"))
        try Data("complete".utf8).write(to: URL(fileURLWithPath: path + (accepted ? ".complete" : ".failed")))
    }
}

private actor BrowserReceiveEvidence {
    private var acknowledged = Set<String>()
    private var sizes: [String: Int64] = [:]
    private var verified = Set<String>()
    private(set) var verifiedBytes: Int64 = 0
    private(set) var didRotate = false
    private(set) var maximumAcknowledgedFiles = 0
    func manifest(_ files: [TransferFile]) { sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.size) }) }
    func rotated() { didRotate = true }
    func record(_ status: TransferStatus) {
        // Import starts only after exact length and SHA-256 verification.
        if status.state == "importing", verified.insert(status.id).inserted { verifiedBytes += sizes[status.id] ?? 0 }
        if status.state == "receiving", (status.receivedBytes ?? 0) > 0 { acknowledged.insert(status.id) }
        else if status.state != "receiving" { acknowledged.remove(status.id) }
        maximumAcknowledgedFiles = max(maximumAcknowledgedFiles, acknowledged.count)
    }
}
