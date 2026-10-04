// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftUI
import ImageIO
import RelayDomain
import RelayDesignSystem
import RelayEmulation
import RelayEntitlements
import RelayVideo
@testable import RelayUI

/// Solid, differently colored logical screens make ordering/cropping errors
/// visible in the actual exported pixels, without including a commercial game.
final class ShareTestFrame: VideoFrameSource, @unchecked Sendable {
    let frameDescriptor: FrameDescriptor
    private let data: Data
    init(width: Int = 240, height: Int = 160, red: UInt8 = 24, green: UInt8 = 150, blue: UInt8 = 220) {
        frameDescriptor = FrameDescriptor(width: width, height: height, bytesPerRow: width * 4, pixelFormat: .rgbx8, aspectRatio: Double(width) / Double(height))
        data = Data((0..<(width * height)).flatMap { _ in [red, green, blue, 0] })
    }
    func withCurrentFrame(_ body: (UnsafeRawPointer, FrameDescriptor) -> Void) {
        data.withUnsafeBytes { body($0.baseAddress!, frameDescriptor) }
    }
}

final class SkinsShareTests: XCTestCase {
    func testSkinChoiceAndLayoutSurviveRevocationAndIndependentSystemChanges() throws {
        let suite = "RelaySkins-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayPreferences(defaults: defaults)
        let pro = RelayAccessPolicy(entitlement: .init(activeProductIDs: [.proOnce]))
        let free = RelayAccessPolicy(entitlement: .free)
        let custom = RelaySkinConfiguration(finish: .mist, accent: .teal)
        preferences.setSkin(custom, for: .gameBoyAdvance, policy: pro)
        preferences.setTouchLayout(.gba(portrait: true), for: SystemCatalog.gameBoyAdvance, portrait: true, scale: 1)
        let stored = defaults.persistentDomain(forName: suite) as NSDictionary?
        XCTAssertEqual(preferences.skin(for: .gameBoyAdvance, policy: free), .standard)
        XCTAssertEqual(preferences.skin(for: .gameBoy, policy: pro), .standard)
        preferences.setSkin(.standard, for: .gameBoyAdvance, policy: free)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, stored)
        preferences.setSkinEnabled(false, for: .gameBoyAdvance)
        XCTAssertFalse(preferences.skin(for: .gameBoyAdvance, policy: free).enabled)
        preferences.setSkinEnabled(true, for: .gameBoyAdvance)
        XCTAssertEqual(preferences.skin(for: .gameBoyAdvance, policy: pro), custom)
        XCTAssertEqual(defaults.data(forKey: "relay.touch.layout.gba.portrait"),
                       stored?["relay.touch.layout.gba.portrait"] as? Data)
    }

    func testUnknownSkinDataFallsBackWithoutDestructiveMigration() throws {
        let suite = "RelaySkins-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = Data("{\"finish\":\"future\",\"enabled\":true}".utf8)
        let key = "relay.skin.v1.\(SystemID.gameBoy.rawValue)"
        defaults.set(raw, forKey: key)
        XCTAssertEqual(PlayPreferences(defaults: defaults).storedSkin(for: .gameBoy), .standard)
        XCTAssertEqual(defaults.data(forKey: key), raw)
    }

    func testEveryLaunchScreenExportsWithEvenBoundedDimensions() throws {
        for system in SystemCatalog.all where system.preferredCoreID != nil && system.id != .playStation {
            for arrangement in [nil, .stacked, .sideBySide, .primarySecondary, .secondaryPrimary] as [ScreenArrangement?] {
                let composition = GameplayShareComposition(screens: system.screens, arrangement: arrangement, maximumEdge: 720)
                XCTAssertLessThanOrEqual(max(composition.size.width, composition.size.height), 720)
                XCTAssertEqual(Int(composition.size.width) % 2, 0)
                XCTAssertEqual(Int(composition.size.height) % 2, 0)
                XCTAssertEqual(composition.frames.count, system.screens.count)
            }
        }
    }

    func testDualScreenExportsKeepBothScreensIncludingLowerScreenLarge() throws {
        let top = ShareTestFrame(red: 255, green: 0, blue: 0)
        let bottom = ShareTestFrame(red: 0, green: 0, blue: 255)
        for arrangement in ScreenArrangement.allCases {
            let composition = GameplayShareComposition(screens: SystemCatalog.nintendoDS.screens, arrangement: arrangement, maximumEdge: 720)
            let image = try XCTUnwrap(composition.image(from: [top, bottom]))
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            var reds = 0, blues = 0
            for y in stride(from: 0, to: image.height, by: 4) {
                for x in stride(from: 0, to: image.width, by: 4) {
                    let i = y * image.bytesPerRow + x * 4
                    if bytes[i] > 200 && bytes[i + 2] < 10 { reds += 1 }
                    if bytes[i + 2] > 200 && bytes[i] < 10 { blues += 1 }
                }
            }
            XCTAssertGreaterThan(reds, 100, "primary screen missing for \(arrangement)")
            XCTAssertGreaterThan(blues, 100, "secondary screen missing for \(arrangement)")
        }
    }

    @MainActor
    func testCardAndScreenshotEncodePixelsAndOnlyPublicMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayShareTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = ShareTestFrame()
        let image = try XCTUnwrap(GameplayShareComposition(screens: SystemCatalog.gameBoyAdvance.screens, arrangement: nil).image(from: [frame]))
        let snapshot = GameplayShareSnapshot(image: image,
            title: "Les voyageurs des brumes — une aventure entre les îles, les étoiles et les souvenirs, édition longue pour jouer ensemble",
            systemName: "Game Boy Advance", systemID: .gameBoyAdvance)
        let card = try XCTUnwrap(RelayShareCard.image(snapshot))
        XCTAssertEqual(card.width, 3600)
        XCTAssertEqual(card.height, 3960)
        for (output, kind) in [(image, GameplayShareFile.Kind.screenshot), (card, .card)] {
            let file = try GameplayShareFile.png(output, kind: kind, root: root)
            XCTAssertTrue(file.url.lastPathComponent.hasPrefix("Relay "))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as NSDictionary
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, output.width)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, output.height)
            // ImageIO synthesizes pixel dimensions and color space. It must
            // never carry source-device, user-comment, time or identity tags.
            let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
            XCTAssertTrue(Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]))
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            if let path = ProcessInfo.processInfo.environment["RELAY_SHARE_TEST_OUTPUT"] {
                let outputRoot = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
                let destination = outputRoot.appendingPathComponent(file.url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: file.url, to: destination)
            }
        }
    }
}
