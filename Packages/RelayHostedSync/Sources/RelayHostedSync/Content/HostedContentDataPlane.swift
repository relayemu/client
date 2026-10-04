// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public protocol HostedContentDataPlane: Sendable {
    func upload(_ capability: HostedPresignedRequest, file: URL, byteCount: Int64,
                progress: @escaping @Sendable (Double) -> Void) async throws -> String?
    func download(_ capability: HostedPresignedRequest, to destination: URL, byteCount: Int64,
                  progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The data plane has no account credentials, cookies, disk cache, or redirects.
public struct HostedURLSessionDataPlane: HostedContentDataPlane {
    public init() {}
    public func upload(_ capability: HostedPresignedRequest, file: URL, byteCount: Int64,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let request = try capability.request(method: "PUT", byteCount: byteCount)
        return try await HostedFileTransfer(byteCount: byteCount, destination: nil, progress: progress).run(request: request, file: file)
    }
    public func download(_ capability: HostedPresignedRequest, to destination: URL, byteCount: Int64,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let request = try capability.request(method: "GET")
        _ = try await HostedFileTransfer(byteCount: byteCount, destination: destination, progress: progress).run(request: request, file: nil)
    }
}

private final class HostedFileTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<String?, Error>?
    private var cancelled = false
    // Remaining fields are accessed only on URLSession's serial delegate queue.
    private var failure: HostedContentError?
    private var responseBytes = 0
    private let byteCount: Int64
    private let destination: URL?
    private let progress: @Sendable (Double) -> Void

    init(byteCount: Int64, destination: URL?, progress: @escaping @Sendable (Double) -> Void) {
        self.byteCount = byteCount; self.destination = destination; self.progress = progress
    }

    func run(request: URLRequest, file: URL?) async throws -> String? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session; self.continuation = continuation
                let task: URLSessionTask
                if let file { task = session.uploadTask(with: request, fromFile: file) }
                else { task = session.downloadTask(with: request) }
                self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        failure = .invalidCapability; completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // PUT success bodies are unused. Bound even a hostile data-plane response.
        responseBytes += data.count
        if responseBytes > 65536 { failure = .transferFailed(status: nil); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(min(1, Double(totalBytesSent) / Double(max(1, byteCount))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > byteCount || totalBytesExpectedToWrite > byteCount {
            failure = .integrityMismatch; downloadTask.cancel(); return
        }
        progress(min(1, Double(totalBytesWritten) / Double(max(1, byteCount))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, failure == nil,
              let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == byteCount else { failure = .integrityMismatch; return }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { failure = .transferFailed(status: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil; self.task = nil; self.session = nil
        let cancelled = cancelled
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        guard let continuation else { return }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        if let failure { continuation.resume(throwing: failure); return }
        let response = task.response as? HTTPURLResponse
        guard error == nil, let response, (200..<300).contains(response.statusCode) else {
            continuation.resume(throwing: HostedContentError.transferFailed(status: response?.statusCode)); return
        }
        progress(1)
        continuation.resume(returning: response.value(forHTTPHeaderField: "ETag"))
    }
}
