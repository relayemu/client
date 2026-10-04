// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

/// Holds `Resources/CoreManifest.json` — the canonical core data — and the
/// compiled `SystemCatalog` to each other. If either drifts, or if a core
/// whose licence forbids commercial use is ever marked enabled, these fail.
final class CoreManifestTests: XCTestCase {

    /// The repository root, from this file: Tests/RelayDomainTests → Tests →
    /// RelayDomain → Packages → root.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RelayDomainTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // RelayDomain
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repository root

    static let manifestURL = repositoryRoot.appendingPathComponent("Resources/CoreManifest.json")

    private func loadManifest() throws -> CoreManifest {
        let data = try Data(contentsOf: Self.manifestURL)
        return try CoreManifest.decode(from: data)
    }

    // MARK: The file itself

    func testManifestExistsAndDecodes() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertFalse(manifest.cores.isEmpty)
        XCTAssertFalse(manifest.auditedOn.isEmpty)
    }

    func testCoreIdentifiersAreUnique() throws {
        let ids = try loadManifest().cores.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate CoreID in the manifest: \(ids)")
    }

    func testEveryCoreCarriesLicenceMetadata() throws {
        for core in try loadManifest().cores {
            XCTAssertFalse(core.license.isEmpty, "\(core.id) has no licence")
            XCTAssertFalse(core.upstream.isEmpty, "\(core.id) has no upstream")
            XCTAssertFalse(core.revision.isEmpty, "\(core.id) has no pinned revision")
            XCTAssertFalse(core.licenceEvidence.isEmpty, "\(core.id) has no licence evidence")
        }
    }

    /// Every licence judgement must be traceable to bytes that are in the
    /// repository. A judgement whose evidence file is missing is a guess.
    func testLicenceEvidenceFilesExist() throws {
        for core in try loadManifest().cores where core.licenceEvidence.hasPrefix("docs/") {
            let url = Self.repositoryRoot.appendingPathComponent(core.licenceEvidence)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(core.id): licence evidence missing at \(core.licenceEvidence)")
        }
    }

    // MARK: The licensing gate

    func testNoProhibitedCoreIsEnabled() throws {
        for core in try loadManifest().cores where core.isProhibited {
            XCTAssertNotEqual(core.relayStatus, .enabled,
                              "\(core.id) forbids commercial use or is blocked, yet is enabled")
            XCTAssertFalse(core.isReleaseEligible, "\(core.id) must never be Release-eligible")
        }
    }

    /// change cannot quietly reclassify one of them.
    func testKnownNonCommercialCoresStayProhibited() throws {
        let manifest = try loadManifest()
        for id in ["snes9x", "genesis-plus-gx", "picodrive", "duckstation"] as [CoreID] {
            let core = try XCTUnwrap(manifest.entry(for: id), "\(id) missing from the manifest")
            XCTAssertEqual(core.commercialUse, .prohibited, "\(id) must stay commercially prohibited")
            XCTAssertEqual(core.build.mechanism, "prohibited", "\(id) must have no build mechanism")
        }
    }

    func testEnabledCoresArePermittedAndNeedNoFurtherReview() throws {
        for core in try loadManifest().enabled {
            XCTAssertEqual(core.commercialUse, .permitted, "\(core.id) is enabled but not commercially permitted")
            XCTAssertEqual(core.legalReviewStatus, .notRequired, "\(core.id) is enabled with review outstanding")
            XCTAssertEqual(core.clientCompatibility, .compatible, "\(core.id) is enabled but not compatible with the GPL-3.0-or-later client")
            XCTAssertTrue(core.isReleaseEligible)
        }
    }

    /// GPL-2.0-only code cannot join a work that carries Apache-2.0 and GPL-3.0
    /// code; an unread header is not a permission (ADR 0003).
    func testOnlyVerifiedCompatibleCoresCanBeEnabled() throws {
        for core in try loadManifest().cores where core.clientCompatibility != .compatible {
            XCTAssertNotEqual(core.relayStatus, .enabled, "\(core.id) is \(core.clientCompatibility.rawValue) yet enabled")
        }
        for core in try loadManifest().cores where core.commercialUse == .prohibited {
            XCTAssertEqual(core.clientCompatibility, .prohibited, "\(core.id): non-commercial must also be marked prohibited")
        }
    }

    /// A JIT that Relay cannot ship through the App Store is not a detail to
    /// discover at submission time.
    func testNoEnabledCoreRequiresJIT() throws {
        for core in try loadManifest().enabled {
            XCTAssertFalse(core.requiresJIT, "\(core.id) is enabled but needs a JIT")
        }
    }

    func testEnabledCoresBuildFromAPinnedVendoredSource() throws {
        for core in try loadManifest().enabled {
            XCTAssertTrue(["vendored-subtree", "vendored-archive"].contains(core.build.mechanism),
                          "\(core.id): Release cores build from pinned vendored source only (got \(core.build.mechanism))")
            let path = try XCTUnwrap(core.build.path, "\(core.id) has no source path")
            let url = Self.repositoryRoot.appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(core.id): pinned source missing at \(path)")
        }
    }

    // MARK: Agreement with the compiled catalog

    func testOnePreferredCorePerPlayableSystem() throws {
        let manifest = try loadManifest()
        for system in SystemCatalog.playable {
            let preferred = try XCTUnwrap(system.preferredCoreID,
                                          "\(system.id) is playable with no preferred core")
            let core = try XCTUnwrap(manifest.entry(for: preferred),
                                     "\(system.id) prefers \(preferred), which is not in the manifest")
            XCTAssertEqual(core.relayStatus, .enabled, "\(system.id) prefers a core that is not enabled")
            XCTAssertTrue(core.systems.contains(system.id),
                          "\(core.id) does not claim \(system.id)")
        }
    }

    func testNoSystemHasTwoEnabledCores() throws {
        let manifest = try loadManifest()
        for system in SystemCatalog.all {
            let claiming = manifest.enabled.filter { $0.systems.contains(system.id) }
            XCTAssertLessThanOrEqual(claiming.count, 1,
                                     "\(system.id) is claimed by \(claiming.map(\.id))")
        }
    }

    func testDeferredSystemsHaveNoPreferredCore() throws {
        for system in SystemCatalog.all where !system.isPlayable {
            XCTAssertNil(system.preferredCoreID,
                         "\(system.id) is deferred but names a preferred core")
        }
    }

    /// Every system an enabled core claims must be playable in the catalog,
    /// and vice versa. This is what stops the UI offering a system no core runs.
    func testEnabledCoreSystemsAndPlayableSystemsAgree() throws {
        let manifest = try loadManifest()
        let fromManifest = Set(manifest.enabled.flatMap(\.systems))
        let fromCatalog = Set(SystemCatalog.playable.map(\.id))
        XCTAssertEqual(fromManifest, fromCatalog,
                       "manifest says \(fromManifest.map(\.rawValue).sorted()), catalog says \(fromCatalog.map(\.rawValue).sorted())")
    }

    func testEverySystemNamedByTheManifestExistsInTheCatalog() throws {
        for core in try loadManifest().cores {
            for system in core.systems {
                XCTAssertNotNil(SystemCatalog.descriptor(for: system),
                                "\(core.id) claims unknown system '\(system)'")
            }
        }
    }
}

extension CoreManifestTests {
    /// A core Relay runs must declare the compatibility class its save states
    /// belong to; without it `SaveState.isRestorable(by:)` has nothing to check.
    func testEnabledCoresDeclareAStateCompatibilityVersion() throws {
        for core in try loadManifest().enabled where core.capabilities.contains("saveStates") {
            let declared = try XCTUnwrap(core.stateCompatibilityVersion,
                                         "\(core.id) claims save states without a compatibility version")
            XCTAssertFalse(declared.isEmpty)
        }
    }
}

extension CoreManifestTests {
    /// The licence BOM is generated from the manifest; if someone edits the
    /// manifest and forgets to regenerate, the shipped attribution is stale.
    func testGeneratedLicenceBOMListsExactlyTheEnabledCores() throws {
        struct BOM: Decodable { struct C: Decodable { let id: String; let category: String; let commit: String? }; let components: [C] }
        let url = Self.repositoryRoot.appendingPathComponent("THIRD_PARTY_LICENSES.json")
        let bom = try JSONDecoder().decode(BOM.self, from: Data(contentsOf: url))
        let listedCores = Set(bom.components.filter { $0.category == "cores" }.map(\.id))
        let enabled = Set(try loadManifest().enabled.map(\.id.rawValue))
        XCTAssertEqual(listedCores, enabled, "run Scripts/relay-licenses.py; the generated BOM drifted from the manifest")
        for core in try loadManifest().enabled {
            let listed = try XCTUnwrap(bom.components.first { $0.id == core.id.rawValue })
            XCTAssertEqual(listed.commit, core.revision)
        }
    }
}
