// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftUI
import RelayDomain
@testable import RelayDesignSystem

/// These checks use SwiftUI's native renderer. They protect the shelf-width and
/// action-reflow regressions; screenshots and real input still qualify the UX.
@MainActor
final class LongContentLayoutTests: XCTestCase {
    private let titles = [
        "Orbit",
        "The Clockwork Orchard — A Journey Beyond the Last Lighthouse (Europe)",
        "Les Voyageurs de l’aube — L’énigme du phare oublié, édition complète (Europe) (En,Fr,De,Es,It,Nl,Ja) [Révision 12] [Homebrew 2026]",
        String(repeating: "UnbrokenReleaseTitle_", count: 12),
    ]
    private let hue = SystemAccent.hue(for: .gameBoyAdvance)

    func testShelfTitleAndMetadataCannotWidenTheArtworkColumn() throws {
        for locale in ["en", "fr"] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                for title in titles {
                    let card = GameCardModel(
                        id: GameID(), title: title, system: .gameBoyAdvance,
                        systemName: "Game Boy Advance", hue: hue,
                        meta: "En, Fr, De, Es, It, Nl, Ja · Complete homebrew release"
                    )
                    // An unbounded horizontal shelf proposes its child's ideal
                    // size. Before the fix, the title made this hundreds of
                    // points wider than the 135-point artwork.
                    let image = try render(
                        GameCard(label: card, artworkHeight: 180)
                            .environment(\.locale, Locale(identifier: locale))
                            .environment(\.dynamicTypeSize, typeSize)
                            .fixedSize()
                    )
                    XCTAssertEqual(image.width, 135, "\(locale) / \(typeSize) / \(title)")
                    XCTAssertGreaterThan(image.height, 180, "The caption must remain below the artwork")
                }
            }
        }
    }

    func testLongFrenchActionsGrowIntoSeparateRowsAtNarrowWidth() throws {
        let narrow = try render(actions.frame(width: 260))
        let wide = try render(actions.frame(width: 900))
        XCTAssertEqual(narrow.width, 260)
        XCTAssertEqual(wide.width, 900)
        XCTAssertGreaterThan(narrow.height, wide.height + Int(RelaySpacing.s),
                             "Two long actions must reflow instead of shrinking side by side")
    }

    func testShelfMetadataReflowsWithoutWideningTheCard() throws {
        func card(_ system: String, meta: String?) -> GameCardModel {
            GameCardModel(id: GameID(), title: "Nine Rivers", system: .snes,
                          systemName: system, hue: hue, meta: meta)
        }
        let short = try render(GameCard(label: card("SNES", meta: nil), artworkHeight: 180)
            .environment(\.dynamicTypeSize, .accessibility3).fixedSize())
        let full = try render(GameCard(label: card("Super Nintendo Entertainment System",
                                                 meta: "Joué sur iPhone · Il y a deux heures"),
                                       artworkHeight: 180)
            .environment(\.dynamicTypeSize, .accessibility3).fixedSize())
        XCTAssertEqual(short.width, 135)
        XCTAssertEqual(full.width, short.width)
        XCTAssertGreaterThan(full.height, short.height + 30,
                             "The full system and status must grow vertically, not ellipsize into one line")
    }

    func testNarrowCardsKeepConsoleNamesOnOneLine() throws {
        func card(_ system: SystemID, name: String) -> GameCardModel {
            GameCardModel(id: GameID(), title: "Orbit", system: system,
                          systemName: name, hue: hue)
        }
        for width in [90.0, 110.0, 135.0] {
            let short = try render(GameCard(label: card(.gameBoy, name: "Game Boy"))
                .frame(width: width).fixedSize())
            let long = try render(GameCard(label: card(.gameBoyColor, name: "Game Boy Color"))
                .frame(width: width).fixedSize())
            XCTAssertEqual(long.width, short.width)
            XCTAssertEqual(long.height, short.height,
                           "Narrow cards use the catalog abbreviation instead of wrapping console metadata")
        }
    }

    func testOversizedTextActionsKeepTheirOuterLinesOverTheButtonFill() throws {
        let rendered = [
            try render(oversizedAction(EmberButtonStyle())),
            try render(oversizedAction(QuietButtonStyle())),
        ]
        for image in rendered {
            XCTAssertEqual(image.width, 320)
            XCTAssertGreaterThan(image.height, 100, "The selected large text must grow vertically")
            // This point is inside the canonical 16-point corner but outside a
            // tall capsule's fill. It is also left of the text padding, so text
            // pixels cannot conceal the old transparent-background regression.
            XCTAssertEqual(try alpha(in: image, x: 12, y: 20), 255,
                           "Accessibility action lines need the button's fill behind them")
        }
    }

    func testContinueCardKeepsItsWidthAndGrowsForAccessibilityText() throws {
        let model = ContinueCardModel(
            id: GameID(), title: titles[2],
            statusLine: "Joué sur iPhone · Il y a deux heures · Pas encore synchronisé",
            hue: hue, system: .gameBoyAdvance, systemName: "Game Boy Advance",
            screenshotLoader: nil, artworkLoader: nil, capsule: .download,
            deviceSymbol: .deviceIPhone
        )
        let regular = try render(ContinueCard(model) {}.frame(width: 280))
        let accessible = try render(
            ContinueCard(model) {}.frame(width: 280)
                .environment(\.dynamicTypeSize, .accessibility3)
                .environment(\.locale, Locale(identifier: "fr"))
        )
        XCTAssertEqual(regular.width, 280)
        XCTAssertEqual(accessible.width, 280)
        #if os(iOS)
        // The UIKit text-size environment scales these fonts. macOS and tvOS
        // use their platform typography and need their own rendered inspection.
        XCTAssertGreaterThan(accessible.height, regular.height)
        #endif
    }

    private var actions: some View {
        AdaptiveActionRow {
            Button {} label: { Text(verbatim: "Télécharger et jouer") }.buttonStyle(.ember)
            Button {} label: { Text(verbatim: "Quels formats fonctionnent ?") }.buttonStyle(.quiet)
        }
    }

    private func oversizedAction<S: ButtonStyle>(_ style: S) -> some View {
        Button {} label: {
            Label("Télécharger et jouer", systemImage: "play.fill")
                // Explicit size also exercises the geometry on Mac, whose
                // platform typography does not follow UIKit's AX categories.
                .font(.system(size: 64))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(style)
        .frame(width: 320)
        .environment(\.dynamicTypeSize, .accessibility5)
    }

    private func alpha(in image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                                  bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: CGFloat(-x), y: CGFloat(-y),
                                          width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return pixel[3]
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "SwiftUI must produce a native render")
    }
}
