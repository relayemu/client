// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Each open file owns one serial disk/hash queue. The receiver admits at most
/// two writers and bounds their combined queued payload before dispatching.
final class TransferFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.relayemu.transfer.file", qos: .utility)
    private let handle: FileHandle
    private var hash = SHA256(), received: Int64 = 0
    private var failure: Error?
    private var closed = false

    init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }

    func append(_ data: Data, completion: @escaping @Sendable (Result<Int64, Error>) -> Void) {
        queue.async { [self] in
            do {
                if let failure { throw failure }
                guard !closed else { throw TransferError.interrupted }
                try handle.write(contentsOf: data); hash.update(data: data)
                received += Int64(data.count); completion(.success(received))
            } catch { failure = error; completion(.failure(error)) }
        }
    }

    func finish() async throws -> (Int64, String) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    guard !closed else { throw TransferError.interrupted }
                    try handle.synchronize(); try handle.close(); closed = true
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: (received, digest))
                } catch { try? handle.close(); closed = true; continuation.resume(throwing: error) }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !closed { try? handle.close(); closed = true }
                continuation.resume()
            }
        }
    }
}
