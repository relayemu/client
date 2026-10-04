// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import RelayDomain
import RelayLibrary
import RelayTransfer
import RelayHostedSync
#if canImport(UIKit)
import UIKit
#endif

@MainActor @Observable
final class TransferModel {
    var files: [TransferFile] = []
    var statuses: [String: TransferStatus] = [:]
    var message = L("Waiting for your computer…")
    var isBusy = false
    var isComplete = false
    var receivedByID: [String: Int64] = [:]
    var counts = TransferCounts()
    var bytesPerSecond: Double = 0
    var route: TransferRoute?
    private var skippedIDs = Set<String>()
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var progressTask: Task<Void, Never>?
    private var session: RelayTransferSession?
    private var boundAccountID: UUID?
    private var updates: Task<Void, Never>?
    private var generation = UUID()

    var totalBytes: Int64 { files.filter { !skippedIDs.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var receivedBytes: Int64 { receivedByID.values.reduce(0, +) }
    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : isComplete ? 1 : 0 }
    var isReceiving: Bool { isBusy && files.contains { !skippedIDs.contains($0.id) && (statuses[$0.id] == nil || statuses[$0.id]?.state == "receiving") } }
    var terminalFileCount: Int { statuses.values.filter(\.isTerminal).count }
    var remainingSeconds: Double? { isReceiving && bytesPerSecond > 0 ? Double(max(0, totalBytes - receivedBytes)) / bytesPerSecond : nil }
    #if canImport(UIKit)
    private var previousIdleTimer: Bool?
    #elseif os(macOS)
    private var awakeActivity: NSObjectProtocol?
    #endif

    func start(library: LibraryModel) async {
        let currentAccountID = library.environment.relayAccount?.accountID
        if session != nil, boundAccountID != currentAccountID {
            await stop(reason: "auth_lost")
            files = []; statuses = [:]; receivedByID = [:]; counts = TransferCounts(); isComplete = false
            route = nil
        }
        guard session == nil, library.environment.relayPro.isPro,
              let account = library.environment.relayAccount, let accountID = account.accountID,
              let authority = account.session else { return }
        let location = library.environment.location
        let kind: HostedDeviceKind
        switch library.environment.deviceKind {
        case .iPhone: kind = .iphone
        case .iPad: kind = .ipad
        case .appleTV: kind = .appletv
        case .mac: kind = .mac
        default: return
        }
        let token = generation
        let transfer = RelayTransferSession(account: authority, accountID: accountID, deviceKind: kind,
            stagingDirectory: location.stagingDirectory, availableBytes: {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: location.rootURL.path)
                guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw TransferError.storageFull }
                return bytes.int64Value
            }, duplicate: { [weak library] file in
                await library?.transferDuplicate(file)
            }, importFiles: { [weak library] urls in
                guard let library else { return TransferImportResult(state: "failed", code: "import_failed", counts: TransferCounts(failed: 1)) }
                let report = await library.importFilesReporting(urls)
                return await Self.result(report, sourceURLs: urls, deviceKind: library.environment.deviceKind)
            })
        session = transfer
        boundAccountID = accountID
        updates = Task { [weak self] in
            for await event in transfer.events {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.receive(event)
            }
            // Completed results stay visible; a fresh account-bound presence
            // lets the same open screen accept another explicit browser transfer.
            guard !Task.isCancelled, let self, self.generation == token, self.isComplete else { return }
            self.session = nil; self.boundAccountID = nil
            await self.start(library: library)
        }
        do { try await transfer.start() }
        catch {
            guard generation == token else { return }
            message = L("Transfer is unavailable. Check your connection and try again.")
            if let error = error as? HostedHTTPError, error.status == 404 {
                message = L("Transfer isn't available on this service yet.")
            }
            await stop()
        }
    }

    func stop(reason: String = "cancelled") async {
        generation = UUID(); let previous = session; session = nil
        boundAccountID = nil
        updates?.cancel(); updates = nil; progressTask?.cancel(); progressTask = nil; isBusy = false; keepAwake(false)
        await previous?.stop(reason: reason)
    }

    func receive(_ event: TransferEvent) {
        switch event {
        case .waiting: if !isComplete { message = L("Waiting for your computer…") }
        case .connecting:
            // Results remain visible while waiting, but belong to the previous
            // transfer once a new computer connection starts.
            files = []; statuses = [:]; receivedByID = [:]; skippedIDs = []; counts = TransferCounts()
            route = nil
            isComplete = false; isBusy = true; bytesPerSecond = 0; samples = []
            progressTask?.cancel(); progressTask = nil; keepAwake(true)
            message = L("Connecting…")
        case .connected: message = L("Connected")
        case .route(let route): self.route = route
        case .manifest(let files):
            self.files = files; statuses = [:]; receivedByID = [:]; skippedIDs = []; counts = TransferCounts()
            isComplete = false; isBusy = true; keepAwake(true); bytesPerSecond = 0
            samples = [(ProcessInfo.processInfo.systemUptime, 0)]
            progressTask?.cancel()
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }; self.updateSpeed()
                }
            }
        case .status(let status):
            if let bytes = status.receivedBytes { receivedByID[status.id] = max(receivedByID[status.id] ?? 0, bytes) }
            else if status.state == "duplicate", receivedByID[status.id] == nil { skippedIDs.insert(status.id) }
            statuses[status.id] = status
            message = isReceiving ? L("Receiving…") : L("Adding games…")
        case .outcomes(let result):
            counts.imported += result.imported; counts.duplicate += result.duplicate
            counts.unsupported += result.unsupported; counts.failed += result.failed
        case .completed:
            isComplete = true; isBusy = false; progressTask?.cancel(); progressTask = nil
            keepAwake(false); message = L("Transfer complete")
        case .failed(let error):
            isBusy = false; isComplete = false; progressTask?.cancel(); progressTask = nil; keepAwake(false)
            for file in files where statuses[file.id]?.isTerminal != true {
                statuses[file.id] = TransferStatus(id: file.id, state: "failed", code: "interrupted",
                                                   receivedBytes: receivedByID[file.id])
            }
            message = error == .storageFull ? L("Free up some space and try again.") : L("Transfer interrupted. Games already added are safe. Try again to send the remaining files.")
        }
    }

    private func updateSpeed() {
        let now = ProcessInfo.processInfo.systemUptime, bytes = receivedBytes
        if samples.last?.bytes != bytes { samples.append((now, bytes)) }
        while samples.count > 2, samples[1].time < now - 30 { samples.removeFirst() }
        guard isReceiving, let first = samples.first, let last = samples.last,
              now - first.time >= 3, now - last.time < 15, bytes > first.bytes else { bytesPerSecond = 0; return }
        bytesPerSecond = Double(bytes - first.bytes) / (now - first.time)
    }

    private func keepAwake(_ enabled: Bool) {
        #if canImport(UIKit)
        if enabled, previousIdleTimer == nil {
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !enabled, let previous = previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previous; previousIdleTimer = nil
        }
        #elseif os(macOS)
        if enabled, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Receiving selected game files")
        } else if !enabled, let previous = awakeActivity {
            ProcessInfo.processInfo.endActivity(previous); awakeActivity = nil
        }
        #endif
    }

    static func stateLabel(_ state: String?) -> String {
        switch state {
        case "receiving": L("Receiving…")
        case "verifying": L("Checking file…")
        case "importing": L("Adding games…")
        case "imported": L("Added")
        case "duplicate": L("Already in your library")
        case "unsupported": L("Unsupported format")
        case "failed": L("Couldn't add this file")
        default: L("Waiting…")
        }
    }

    static func result(_ report: ImportReport, sourceURLs: [URL] = [], deviceKind: DeviceKind) -> TransferImportResult {
        TransferImportResult.fromImportReport(report, sourceURLs: sourceURLs) {
            ProductMessage.forImport($0, deviceKind: deviceKind)?.message
        }
    }
}

extension LibraryModel {
    /// Only a complete local, single-file raw game can be skipped. Disc
    /// packages, archives, and cloud-only metadata are deliberately requested.
    func transferDuplicate(_ file: TransferFile) async -> TransferImportResult? {
        guard file.group == nil, ["gb", "gbc", "gba", "nes", "sfc", "smc", "nds"].contains((file.name as NSString).pathExtension.lowercased()),
              let store = environment.store,
              let fingerprint = try? ContentFingerprint(parsing: "sha256:" + file.sha256),
              let game = try? await store.games.game(fingerprint: fingerprint),
              let localFiles = try? await store.games.files(for: game.id), localFiles.count == 1,
              let primary = localFiles.first, primary.role == .primary, primary.fingerprint == fingerprint,
              primary.sizeInBytes == file.size,
              let actual = try? await SHA256ContentHasher().hash(fileAt: environment.location.url(for: primary.location)),
              actual.fingerprint == fingerprint, actual.sizeInBytes == file.size else { return nil }
        return TransferImportResult(state: "duplicate", title: game.title, counts: TransferCounts(duplicate: 1))
    }
}
