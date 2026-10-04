// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import RelayDomain
import RelayDesignSystem
import RelayEmulation
import RelayVideo

/// The entire public-media boundary: pixels and ordinary display names. Never a
/// Game, save, account, diagnostics object, metadata dictionary or library URL.
struct GameplayShareSnapshot {
    let image: CGImage
    let title: String
    let systemName: String
    let systemID: SystemID
}

enum GameplayShareError: Error {
    case unavailable, frameUnavailable, encoding, capture, noAudio, tooShort, storageLow, storageUnavailable
}

/// A fixed frame composition for a recording, independent of later window
/// rotation. All logical screens stay visible. Live source geometry is fitted,
/// never allowed to resize a movie track or allocate an unbounded frame.
struct GameplayShareComposition {
    let size: CGSize
    let frames: [CGRect]

    init(screens: [LogicalScreen], arrangement: ScreenArrangement?, maximumEdge: Int = 1440) {
        let aspect = screens.first?.aspectRatio ?? 1.5
        let safeAspect = aspect.isFinite && aspect > 0 ? min(4, max(0.25, aspect)) : 1.5
        let dual = screens.count == 2
        let preferred = arrangement ?? .stacked
        let ratio = dual ? (preferred == .stacked ? safeAspect / 2 : preferred == .sideBySide ? safeAspect * 2 : safeAspect) : safeAspect
        let edge = CGFloat(min(1440, max(64, maximumEdge)))
        // H.264 dimensions must be even.
        let width = max(2, floor((ratio >= 1 ? edge : edge * ratio) / 2) * 2)
        let height = max(2, floor((ratio >= 1 ? edge / ratio : edge) / 2) * 2)
        size = CGSize(width: width, height: height)
        if dual {
            frames = RelayLogicalScreenLayout(size: size, screens: screens, preferred: preferred, gap: 4).frames
        } else {
            frames = [CGRect(origin: .zero, size: size)]
        }
    }

    func image(from sources: [VideoFrameSource]) -> CGImage? {
        guard sources.count == frames.count, !sources.isEmpty,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .none
        for index in sources.indices.sorted(by: { frames[$0].width * frames[$0].height > frames[$1].width * frames[$1].height }) {
            let source = sources[index]
            guard let image = FrameCapture.image(from: source) else { return nil }
            let box = frames[index]
            // Composition uses SwiftUI's top-down screen order; CoreGraphics is
            // bottom-up. Draw the primary first except for a large lower screen.
            let rect = CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height)
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }
}

/// Active writers and previews keep their file out of cache pruning, even when
/// a Pro recording or an open share lasts longer than the cache grace period.
final class GameplayShareLease: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var references: [URL: Int] = [:]
    }
    private static let registry = Registry()
    private let directory: URL

    init(url: URL) {
        directory = url.deletingLastPathComponent().standardizedFileURL
        Self.registry.lock.lock()
        Self.registry.references[directory, default: 0] += 1
        Self.registry.lock.unlock()
    }

    deinit {
        Self.registry.lock.lock()
        if let count = Self.registry.references[directory], count > 1 { Self.registry.references[directory] = count - 1 }
        else { Self.registry.references.removeValue(forKey: directory) }
        Self.registry.lock.unlock()
    }

    static func contains(_ directory: URL) -> Bool {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.references[directory.standardizedFileURL] != nil
    }
}

/// Owned scratch exports use generic filenames, no title-derived paths and no
/// source metadata. Native sharing needs files after presentation dismisses, so
/// prune day-old exports on the next export and apply an approximate 128 MB
/// cache budget, with a grace period for recent native share consumers.
struct GameplayShareFile: Identifiable {
    let id = UUID()
    let url: URL
    let kind: Kind
    let cardSnapshot: GameplayShareSnapshot?
    private let lease: GameplayShareLease
    enum Kind { case screenshot, card, clip }

    init(url: URL, kind: Kind, cardSnapshot: GameplayShareSnapshot? = nil) {
        self.url = url
        self.kind = kind
        self.cardSnapshot = cardSnapshot
        self.lease = GameplayShareLease(url: url)
    }

    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("RelayShare", isDirectory: true) }

    static func destination(_ kind: Kind, root: URL = Self.root) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        prune(root: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name: String
        switch kind {
        case .screenshot: name = "Relay Screenshot.png"
        case .card: name = "Relay Card.png"
        case .clip: name = "Relay Gameplay Clip.mp4"
        }
        return directory.appendingPathComponent(name)
    }

    static func png(_ image: CGImage, kind: Kind, root: URL = Self.root) throws -> Self {
        let url = try destination(kind, root: root)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GameplayShareError.encoding
        }
        // CGImage has no EXIF, account, path or save metadata to copy.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw GameplayShareError.encoding
        }
        return Self(url: url, kind: kind)
    }

    private static func prune(root: URL) {
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var total = 0
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !GameplayShareLease.contains(directory) else { continue }
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            total += files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            // Never prune an in-flight share or a just-completed recording.
            if Date().timeIntervalSince(created) > 86_400 || (total > 128 * 1024 * 1024 && Date().timeIntervalSince(created) > 3600) {
                try? manager.removeItem(at: directory)
            }
        }
    }
}

/// A Relay play receipt: canonical Baton, generous
/// game area and a restrained title. Fixed export typography is independent of
/// Dynamic Type; the native sharing controls retain the user's text size.
struct RelayShareCard: View {
    let snapshot: GameplayShareSnapshot
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 14) {
                RelayMark(lead: RelayColor.offWhite).frame(width: 96, height: 96)
                Text(verbatim: "Relay").font(.system(size: 72, weight: .bold))
                Spacer(minLength: 20)
                Text(snapshot.systemName).font(.system(size: 24, weight: .medium))
                    .multilineTextAlignment(.trailing).lineLimit(2)
                    .foregroundStyle(RelayColor.offWhite.opacity(0.8))
            }
            Image(decorative: snapshot.image, scale: 1)
                .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
                .background(.black, in: RoundedRectangle(cornerRadius: RelayRadius.l))
            Text(snapshot.title)
                .font(.system(size: 40, weight: .semibold))
                .lineLimit(3).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !caption.isEmpty {
                Text(verbatim: Self.wrappingCaption(caption))
                    .font(.system(size: 32, weight: .medium))
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "relayemu.app")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(RelayColor.offWhite.opacity(0.65))
        }
        .padding(56)
        .frame(width: 1200, height: 1320)
        .background(RelayColor.ink)
        .foregroundStyle(RelayColor.offWhite)
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }

    @MainActor static func image(_ snapshot: GameplayShareSnapshot, caption: String = "") -> CGImage? {
        let renderer = ImageRenderer(content: Self(snapshot: snapshot, caption: caption))
        // Render typography and the vector mark at export resolution rather
        // than enlarging a 1x bitmap on Retina displays. The layout stays fixed.
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.cgImage
    }

    /// Give long words/URLs explicit soft breaks without changing the player's
    /// editable text. Ordinary words retain normal word wrapping.
    private static func wrappingCaption(_ caption: String) -> String {
        var output = ""
        var word = ""
        func flushWord() {
            output += word.count > 24 ? word.map(String.init).joined(separator: "\u{200B}") : word
            word = ""
        }
        for character in caption {
            if character.isWhitespace { flushWord(); output.append(character) }
            else { word.append(character) }
        }
        flushWord()
        return output
    }
}
