// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  LicensesDatasetTests.swift — the app shows exactly what ships, and never a stale list.
import XCTest
@testable import RelayUI

final class LicensesDatasetTests: XCTestCase {
    /// Repository root from this file: Tests/RelayUITests → Tests → RelayUI → Packages → root.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testBundledDatasetDecodes() throws {
        let dataset = try XCTUnwrap(LicensesDataset.bundled(), "licenses.json missing from the RelayUI bundle")
        XCTAssertEqual(dataset.schemaVersion, 1)
        XCTAssertEqual(dataset.relayLicense, "GPL-3.0-or-later")
        XCTAssertEqual(dataset.sourceRepository, "https://github.com/relayemu/client")
        XCTAssertFalse(dataset.categories.isEmpty)
    }

    /// The bundled copy and the canonical generated file are one file.
    func testBundledDatasetIsTheCanonicalOne() throws {
        let bundledURL = try XCTUnwrap(Bundle.module.url(forResource: "licenses", withExtension: "json"))
        let bundled = try Data(contentsOf: bundledURL)
        let canonical = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Licenses/licenses.json"))
        XCTAssertEqual(bundled, canonical, "run Scripts/relay-licenses.py; the bundled dataset drifted")
    }

    func testEveryShippedComponentIsComplete() throws {
        let dataset = try XCTUnwrap(LicensesDataset.bundled())
        for component in dataset.shippedComponents {
            XCTAssertFalse(component.name.isEmpty)
            XCTAssertFalse(component.version.isEmpty, "\(component.id) has no version")
            XCTAssertFalse(component.license.isEmpty, "\(component.id) has no licence")
            XCTAssertFalse(component.copyright.isEmpty, "\(component.id) has no copyright line")
            XCTAssertFalse(component.upstream.isEmpty, "\(component.id) has no upstream")
            XCTAssertFalse(component.licenseText.isEmpty, "\(component.id) has no licence text")
            XCTAssertTrue(component.shipped)
        }
        let ids = dataset.shippedComponents.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate component ids")
    }

    /// Every enabled core in the manifest appears in the dataset at its exact revision.
    func testEnabledCoresAppearAtTheirPinnedRevision() throws {
        let dataset = try XCTUnwrap(LicensesDataset.bundled())
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("Resources/CoreManifest.json"))) as? [String: Any]
        let cores = try XCTUnwrap(manifest?["cores"] as? [[String: Any]])
        for core in cores where core["relayStatus"] as? String == "enabled" {
            let id = try XCTUnwrap(core["id"] as? String)
            let shown = try XCTUnwrap(dataset.shippedComponents.first { $0.id == id }, "\(id) missing from the licence list")
            XCTAssertEqual(shown.revision, core["revision"] as? String)
            XCTAssertEqual(shown.license, core["license"] as? String)
            XCTAssertEqual(shown.category, "cores")
        }
    }

    /// The SBOM describes the same set of components the app shows.
    func testSBOMMatchesTheDataset() throws {
        let dataset = try XCTUnwrap(LicensesDataset.bundled())
        let sbom = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("SBOM.spdx.json"))) as? [String: Any]
        let packages = try XCTUnwrap(sbom?["packages"] as? [[String: Any]])
        let sbomNames = Set(packages.compactMap { $0["name"] as? String })
        XCTAssertEqual(sbomNames, Set(dataset.shippedComponents.map(\.name)))
        XCTAssertEqual(sbom?["spdxVersion"] as? String, "SPDX-2.3")
    }

    func testRepositoryLinksPointAtTheCanonicalRepository() {
        let repo = "https://github.com/relayemu/client"
        XCTAssertEqual(LicensesDataset.Link.sourceCode.url(repository: repo).absoluteString, repo)
        XCTAssertEqual(LicensesDataset.Link.relayLicense.url(repository: repo).absoluteString, repo + "/blob/main/LICENSE")
        XCTAssertEqual(LicensesDataset.Link.thirdParty.url(repository: repo).absoluteString, repo + "/blob/main/THIRD_PARTY_LICENSES.md")
        XCTAssertEqual(LicensesDataset.Link.trademarks.url(repository: repo).absoluteString, repo + "/blob/main/TRADEMARKS.md")
    }
}
