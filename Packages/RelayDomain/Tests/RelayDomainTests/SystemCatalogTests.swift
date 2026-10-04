// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RelayDomain

/// The catalog is Relay's product description of a system. These hold the
/// invariants the rest of the app relies on: unique identity, honest
/// availability, a screen to draw, and controls that match the real hardware.
final class SystemCatalogTests: XCTestCase {

    func testIdentifiersAndShortNamesAreUnique() {
        let ids = SystemCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate SystemID: \(ids)")
        let shortNames = SystemCatalog.all.map(\.shortName)
        XCTAssertEqual(Set(shortNames).count, shortNames.count, "duplicate short name: \(shortNames)")
    }

    func testEverySystemHasAtLeastOneScreenAndAPositiveAspect() {
        for system in SystemCatalog.all {
            XCTAssertFalse(system.screens.isEmpty, "\(system.id) draws nothing")
            for screen in system.screens {
                XCTAssertGreaterThan(screen.width, 0)
                XCTAssertGreaterThan(screen.height, 0)
                XCTAssertGreaterThan(screen.aspectRatio, 0)
            }
            let screenIDs = system.screens.map(\.id)
            XCTAssertEqual(Set(screenIDs).count, screenIDs.count, "\(system.id) has duplicate screen ids")
        }
    }

    func testEverySystemHasDirectionsAndTwoFaceButtons() {
        for system in SystemCatalog.all {
            let layout = system.inputLayout
            XCTAssertTrue(layout.has(.dPad) || layout.has(.leftStick),
                          "\(system.id) has no way to point")
            XCTAssertGreaterThanOrEqual(layout.faceButtonCount, 2, "\(system.id) has fewer than two face buttons")
            XCTAssertEqual(Set(layout.controls).count, layout.controls.count,
                           "\(system.id) lists a control twice")
        }
    }

    /// V1 exposes the twelve integrated systems.
    func testPlayableSystemsMatchV1() {
        XCTAssertEqual(Set(SystemCatalog.playable.map(\.id)),
                       [.gameBoy, .gameBoyColor, .gameBoyAdvance, .nes, .snes, .nintendoDS,
                        .masterSystem, .gameGear, .pcEngine, .wonderSwan, .wonderSwanColor, .playStation])
    }

    func testDeferredSystemsCarryAReason() {
        for system in SystemCatalog.all where !system.isPlayable {
            guard case .deferred = system.availability else {
                return XCTFail("\(system.id) is not playable and not deferred")
            }
        }
    }

    // MARK: Content shape

    func testDiscSystemsAreTheOnesWithMultiFileContent() {
        let disc = SystemCatalog.all.filter { $0.packaging == .discPackage }.map(\.id)
        XCTAssertEqual(Set(disc), [.playStation, .pcEngineCD])
    }

    /// An extension shared by two systems is allowed, but the identifier must
    /// then be able to tell them apart from the bytes, so record it explicitly.
    func testSharedFileExtensionsAreOnlyTheDiscManifests() {
        var owners: [String: [SystemID]] = [:]
        for system in SystemCatalog.all {
            for ext in system.fileExtensions { owners[ext, default: []].append(system.id) }
        }
        let shared = owners.filter { $0.value.count > 1 }
        XCTAssertEqual(Set(shared.keys), ["cue", "chd"],
                       "unexpected shared extensions: \(shared)")
    }

    func testEveryFileExtensionIsLowercasedAndDotless() {
        for system in SystemCatalog.all {
            for ext in system.fileExtensions {
                XCTAssertEqual(ext, ext.lowercased())
                XCTAssertFalse(ext.hasPrefix("."), "\(system.id) extension '\(ext)' has a dot")
                XCTAssertFalse(ext.isEmpty)
            }
        }
    }

    // MARK: Screens and firmware

    func testOnlyTheDSHasTwoScreensAndOneOfThemTakesTouch() {
        let multiScreen = SystemCatalog.all.filter { $0.screens.count > 1 }.map(\.id)
        XCTAssertEqual(multiScreen, [.nintendoDS])
        let ds = SystemCatalog.nintendoDS
        XCTAssertEqual(ds.screens.count, 2)
        XCTAssertEqual(ds.screens.filter(\.acceptsTouch).count, 1)
        XCTAssertEqual(ds.touchScreen?.id, "bottom")
        XCTAssertTrue(ds.inputLayout.has(.touchScreen))
    }

    /// A system that says it has a touch screen must have a screen that takes
    /// touches, and the reverse. Nothing else may claim touch input.
    func testTouchClaimsAgreeBetweenLayoutAndScreens() {
        for system in SystemCatalog.all {
            XCTAssertEqual(system.inputLayout.has(.touchScreen), system.touchScreen != nil,
                           "\(system.id) disagrees with itself about touch")
        }
    }

    func testFirmwareIsDeclaredOnlyWhereTheHardwareNeedsIt() {
        let withFirmware = SystemCatalog.all.filter { !$0.firmware.isEmpty }.map(\.id)
        XCTAssertEqual(Set(withFirmware), [.playStation, .pcEngineCD])
        for system in SystemCatalog.all {
            for requirement in system.firmware {
                XCTAssertFalse(requirement.expectedFileNames.isEmpty,
                               "\(system.id)/\(requirement.id) names no file")
                if let size = requirement.sizeInBytes { XCTAssertGreaterThan(size, 0) }
            }
        }
    }

    /// No system Relay can play may need a file Relay is not allowed to ship.
    func testPlayableSystemsCanStartWithoutBundledProprietaryFirmware() {
        for system in SystemCatalog.playable {
            XCTAssertFalse(system.firmware.contains(where: \.isRequired),
                          "\(system.id) is playable but needs firmware Relay never bundles")
        }
    }

    // MARK: Analog

    func testAnalogIsDeclaredExactlyForTheSystemsThatHaveAStick() {
        let analog = SystemCatalog.all.filter(\.inputLayout.hasAnalog).map(\.id)
        XCTAssertEqual(Set(analog), [.nintendo64, .playStation, .playStationPortable])
        XCTAssertTrue(SystemControl.leftStick.isAnalog)
        XCTAssertFalse(SystemControl.dPad.isAnalog)
    }

    /// The Game Boy has no shoulder buttons; the Advance does. If this ever
    /// stops being true, a touch layout is drawing a button that does not exist.
    func testGameBoyAndAdvanceLayoutsDiffer() {
        XCTAssertFalse(SystemCatalog.gameBoy.inputLayout.has(.shoulderL))
        XCTAssertFalse(SystemCatalog.gameBoyColor.inputLayout.has(.shoulderL))
        XCTAssertTrue(SystemCatalog.gameBoyAdvance.inputLayout.has(.shoulderL))
        XCTAssertTrue(SystemCatalog.gameBoyAdvance.inputLayout.has(.shoulderR))
    }

    func testDescriptorRoundTripsThroughCodable() throws {
        for system in SystemCatalog.all {
            let data = try JSONEncoder().encode(system)
            XCTAssertEqual(try JSONDecoder().decode(SystemDescriptor.self, from: data), system)
        }
    }
}
