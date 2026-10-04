// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import RelayLibrary
@testable import RelayHostedSync

private actor CoverHTTPFixture: HostedHTTPExecuting {
    var requests: [URLRequest] = []
    let response: @Sendable (URLRequest, Int) throws -> (Int, Data, [String: String])
    init(_ response: @escaping @Sendable (URLRequest, Int) throws -> (Int, Data, [String: String])) { self.response = response }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data, headers) = try response(request, requests.count)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

final class HostedCoverArtSourceTests: XCTestCase {
    private let origin = URL(string: "https://sync.example.test")!
    private let key = "gba/11c673d5b4ea0f184639700a14097cd81b5c4e10a4efb92a29ca9ecc83144436"
    private let presigned = "https://objects.example.invalid/covers/gba/11c6.heic?X-Amz-Expires=300&X-Amz-Signature=abc"
    private let cover = Data("heic bytes".utf8)

    private func source(_ fixture: CoverHTTPFixture) throws -> HostedCoverArtSource {
        try XCTUnwrap(HostedCoverArtSource(origin: origin, executor: fixture))
    }

    private func redirecting(then status: Int = 200, body: Data? = nil) -> CoverHTTPFixture {
        let presigned = presigned, cover = body ?? cover
        return CoverHTTPFixture { _, count in
            count == 1 ? (302, Data(), ["Location": presigned, "Cache-Control": "no-store"]) : (status, cover, [:])
        }
    }

    func testFollowsTheRedirectWithoutIdentifyingTheDevice() async throws {
        let fixture = redirecting()
        let result = try await source(fixture).cover(forKey: key)
        XCTAssertEqual(result, .image(cover))
        let requests = await fixture.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), ["https://sync.example.test/v1/covers/\(key)", presigned])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "image/heic, image/jpeg", "User-Agent": "Relay"],
                           "no Authorization, cookie, schema header or identifier")
        }
    }

    func testMissingCoverIsNotFound() async throws {
        let fixture = CoverHTTPFixture { _, _ in (404, Data(), ["Cache-Control": "public, max-age=86400"]) }
        let result = try await source(fixture).cover(forKey: key)
        XCTAssertEqual(result, .notFound)
        let count = await fixture.requests.count
        XCTAssertEqual(count, 1)
    }

    func testServerAndNetworkFailuresAreUnavailable() async throws {
        for status in [429, 500, 502, 503] {
            let lookup = try await source(CoverHTTPFixture { _, _ in (status, Data(), ["Retry-After": "60"]) }).cover(forKey: key)
            XCTAssertEqual(lookup, .unavailable, "lookup \(status)")
        }
        for status in [403, 404, 500] {
            let download = try await source(redirecting(then: status)).cover(forKey: key)
            XCTAssertEqual(download, .unavailable, "presigned \(status)")
        }
        let timeout = try await source(CoverHTTPFixture { _, _ in throw URLError(.timedOut) }).cover(forKey: key)
        XCTAssertEqual(timeout, .unavailable)
    }

    func testUnusableRedirectsAreInvalid() async throws {
        for location in [nil, "http://relay-catalog.example.test/x.heic", "/covers/x.heic", "https://user:pass@relay-catalog.example.test/x.heic"] {
            let headers = location.map { ["Location": $0] } ?? [:]
            let fixture = CoverHTTPFixture { _, _ in (302, Data(), headers) }
            let result = try await source(fixture).cover(forKey: key)
            XCTAssertEqual(result, .invalid, location ?? "no Location")
            let count = await fixture.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testOversizedCoversAreInvalid() async throws {
        let oversized = try await source(redirecting(body: Data(count: CoverImage.maximumBytes + 1))).cover(forKey: key)
        XCTAssertEqual(oversized, .invalid)
        let presigned = presigned
        let bounded = CoverHTTPFixture { _, count in
            if count == 1 { return (302, Data(), ["Location": presigned]) }
            throw HostedHTTPError.invalidResponse
        }
        let refused = try await source(bounded).cover(forKey: key)
        XCTAssertEqual(refused, .invalid)
    }

    func testInvalidKeysAreNeverRequested() async throws {
        let fixture = CoverHTTPFixture { _, _ in (200, Data(), [:]) }
        for bad in ["gba/../../v1/account", "GBA/" + String(repeating: "a", count: 64), "gba/abc", ""] {
            let result = try await source(fixture).cover(forKey: bad)
            XCTAssertEqual(result, .invalid, bad)
        }
        let count = await fixture.requests.count
        XCTAssertEqual(count, 0)
    }

    func testOriginMustBeABareHTTPSOrigin() {
        XCTAssertNotNil(HostedCoverArtSource(origin: URL(string: "https://sync-preprod.relayemu.app")!))
        XCTAssertNotNil(HostedCoverArtSource(origin: URL(string: "https://sync-preprod.relayemu.app/")!))
        for bad in ["http://sync-preprod.relayemu.app", "https://sync-preprod.relayemu.app/api", "https://sync-preprod.relayemu.app?x=1",
                    "https://user@sync-preprod.relayemu.app"] {
            XCTAssertNil(HostedCoverArtSource(origin: URL(string: bad)!), bad)
        }
    }
}
