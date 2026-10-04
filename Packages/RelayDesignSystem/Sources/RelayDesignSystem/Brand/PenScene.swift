// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  PenScene.swift
//
//  Pen-on-paper drawings, in the website's hand, allowed in a fixed set of places:
//  empty states, the first-import hint, "Which formats work?", problem and recovery
//  cards. Nowhere else. They are decorative and hidden from VoiceOver; anything the
//  player must read is a real, translatable label beside the drawing, never inside it.
//
//  Scenes are described in a 200 × 132 design box and scaled to the frame, so one
//  definition serves an iPhone empty state and an Apple TV one.

import SwiftUI

/// The drawings Relay owns. Each is one idea; there is no general-purpose set.
public enum PenScene: String, Sendable, CaseIterable {
    /// A game file dropping into an open tray. Empty library, first import.
    case dropIn
    /// A phone handing the baton to a TV. Continuity states, cloud-only, tvOS empty.
    case handoff
    /// Three cartridges, one ticked. "Which formats work?".
    case formats
    /// Two cartridges that disagree. Two versions.
    case twoVersions
    /// An empty shelf. Search and Favorites with no result.
    case emptyShelf
    /// A phone, a tablet and a television in a row, the pen running through all
    case welcome
}

/// One drawn scene. `ink` is the line, `pen` is the single Ember accent per scene.
public struct PenSceneView: View {
    private let scene: PenScene
    private let width: CGFloat

    public init(_ scene: PenScene, width: CGFloat = 200) {
        self.scene = scene
        self.width = width
    }

    public var body: some View {
        Canvas { context, size in
            let unit = size.width / PenSceneGeometry.designWidth
            let ink = RelayColor.textPrimary.opacity(0.78)
            for stroke in scene.strokes {
                var path = stroke.path
                path = path.applying(CGAffineTransform(scaleX: unit, y: unit))
                let drawn = path.sketched(seed: stroke.seed, amplitude: 1.15 * unit)
                let color = stroke.isPen ? RelayColor.ember : ink
                if stroke.fillOpacity > 0 {
                    context.fill(drawn, with: .color(color.opacity(stroke.fillOpacity)))
                }
                context.stroke(drawn, with: .color(color),
                               style: StrokeStyle(lineWidth: stroke.lineWidth * unit, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: width, height: width * PenSceneGeometry.designHeight / PenSceneGeometry.designWidth)
        .accessibilityHidden(true)
    }
}

/// A single pen stroke in the design box.
struct PenStroke {
    let path: Path
    let isPen: Bool
    let lineWidth: CGFloat
    let fillOpacity: Double
    let seed: UInt64
}

extension PenStroke {
    /// The same stroke, turned about a point in the design box.
    func rotated(by angle: CGFloat, around origin: CGPoint) -> PenStroke {
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .rotated(by: angle)
            .translatedBy(x: -origin.x, y: -origin.y)
        return PenStroke(path: path.applying(transform), isPen: isPen, lineWidth: lineWidth,
                         fillOpacity: fillOpacity, seed: seed)
    }
}

enum PenSceneGeometry {
    static let designWidth: CGFloat = 200
    static let designHeight: CGFloat = 132
}

private func stroke(_ build: (inout Path) -> Void, pen: Bool = false, width: CGFloat = 2.4,
                    fill: Double = 0, seed: UInt64) -> PenStroke {
    var path = Path()
    build(&path)
    return PenStroke(path: path, isPen: pen, lineWidth: width, fillOpacity: fill, seed: seed)
}

/// A cartridge: the shape every retro library shares, drawn once.
private func cartridge(at origin: CGPoint, size: CGSize, seed: UInt64, pen: Bool = false) -> [PenStroke] {
    let body = CGRect(origin: origin, size: size)
    let label = body.insetBy(dx: size.width * 0.17, dy: size.height * 0.12)
        .offsetBy(dx: 0, dy: -size.height * 0.11)
    return [
        stroke({ $0.addRoundedRect(in: body, cornerSize: CGSize(width: 5, height: 5)) }, pen: pen, seed: seed),
        stroke({ $0.addRoundedRect(in: label, cornerSize: CGSize(width: 3, height: 3)) }, pen: pen, width: 2, seed: seed &+ 1),
        stroke({ path in
            let y = body.maxY - size.height * 0.11
            path.move(to: CGPoint(x: body.minX + size.width * 0.24, y: y))
            path.addLine(to: CGPoint(x: body.minX + size.width * 0.4, y: y))
            path.move(to: CGPoint(x: body.minX + size.width * 0.6, y: y))
            path.addLine(to: CGPoint(x: body.minX + size.width * 0.76, y: y))
        }, pen: pen, width: 2, seed: seed &+ 2),
    ]
}

/// A screen on a stand: the "device" of every Relay drawing.
private func screen(at origin: CGPoint, size: CGSize, seed: UInt64, stand: Bool) -> [PenStroke] {
    let body = CGRect(origin: origin, size: size)
    var strokes = [stroke({ $0.addRoundedRect(in: body, cornerSize: CGSize(width: 6, height: 6)) }, seed: seed)]
    if stand {
        strokes.append(stroke({ path in
            path.move(to: CGPoint(x: body.midX, y: body.maxY))
            path.addLine(to: CGPoint(x: body.midX, y: body.maxY + size.height * 0.16))
            path.move(to: CGPoint(x: body.midX - size.width * 0.18, y: body.maxY + size.height * 0.16))
            path.addLine(to: CGPoint(x: body.midX + size.width * 0.18, y: body.maxY + size.height * 0.16))
        }, width: 2.2, seed: seed &+ 1))
    }
    return strokes
}

/// A pen arrow: the website's red arrow, which is how Relay draws "it moves".
private func arrow(from start: CGPoint, control: CGPoint, to end: CGPoint, seed: UInt64) -> [PenStroke] {
    let angle = atan2(end.y - control.y, end.x - control.x)
    let head: CGFloat = 9
    return [
        stroke({ path in
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
        }, pen: true, width: 2.6, seed: seed),
        stroke({ path in
            path.move(to: CGPoint(x: end.x - cos(angle - 0.5) * head, y: end.y - sin(angle - 0.5) * head))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: end.x - cos(angle + 0.5) * head, y: end.y - sin(angle + 0.5) * head))
        }, pen: true, width: 2.6, seed: seed &+ 1),
    ]
}

extension PenScene {
    var strokes: [PenStroke] {
        switch self {
        case .dropIn:
            // An open box and a game on its way in. The pen shows the way; the two
            // ticks are the fall. This is the drawing a player meets first.
            var all: [PenStroke] = []
            all += cartridge(at: CGPoint(x: 74, y: 4), size: CGSize(width: 52, height: 62), seed: 11)
                .map { $0.rotated(by: -.pi / 22, around: CGPoint(x: 100, y: 35)) }
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 56, y: 26))
                path.addLine(to: CGPoint(x: 48, y: 34))
                path.move(to: CGPoint(x: 146, y: 22))
                path.addLine(to: CGPoint(x: 154, y: 30))
            }, width: 2.2, seed: 21))
            // The box: an open top seen slightly from above, then the front face.
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 60, y: 78))
                path.addLine(to: CGPoint(x: 140, y: 78))
                path.addLine(to: CGPoint(x: 162, y: 96))
                path.addLine(to: CGPoint(x: 38, y: 96))
                path.closeSubpath()
            }, width: 2.4, seed: 31))
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 38, y: 96))
                path.addLine(to: CGPoint(x: 44, y: 122))
                path.addLine(to: CGPoint(x: 156, y: 122))
                path.addLine(to: CGPoint(x: 162, y: 96))
            }, width: 2.6, seed: 32))
            all += arrow(from: CGPoint(x: 128, y: 62), control: CGPoint(x: 142, y: 74), to: CGPoint(x: 122, y: 84), seed: 41)
            return all

        case .handoff:
            // Phone → TV, with the baton crossing between them. Relay in one drawing.
            var all: [PenStroke] = []
            all += screen(at: CGPoint(x: 16, y: 44), size: CGSize(width: 36, height: 62), seed: 41, stand: false)
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 26, y: 100))
                path.addLine(to: CGPoint(x: 42, y: 100))
            }, width: 2, seed: 42))
            all += screen(at: CGPoint(x: 104, y: 34), size: CGSize(width: 80, height: 52), seed: 43, stand: true)
            all += arrow(from: CGPoint(x: 60, y: 52), control: CGPoint(x: 82, y: 20), to: CGPoint(x: 102, y: 44), seed: 51)
            return all

        case .formats:
            var all: [PenStroke] = []
            all += cartridge(at: CGPoint(x: 20, y: 30), size: CGSize(width: 42, height: 54), seed: 61)
            all += cartridge(at: CGPoint(x: 79, y: 24), size: CGSize(width: 42, height: 54), seed: 71)
            all += cartridge(at: CGPoint(x: 138, y: 30), size: CGSize(width: 42, height: 54), seed: 81)
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 86, y: 96))
                path.addLine(to: CGPoint(x: 96, y: 108))
                path.addLine(to: CGPoint(x: 118, y: 82))
            }, pen: true, width: 3, seed: 91))
            return all

        case .twoVersions:
            // Two saves that both matter. Never drawn as a joke: the pen only marks
            // that a person has to choose, it does not decorate the loss.
            var all: [PenStroke] = []
            all += cartridge(at: CGPoint(x: 34, y: 30), size: CGSize(width: 46, height: 58), seed: 101)
            all += cartridge(at: CGPoint(x: 116, y: 30), size: CGSize(width: 46, height: 58), seed: 111, pen: true)
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 92, y: 52))
                path.addQuadCurve(to: CGPoint(x: 108, y: 62), control: CGPoint(x: 108, y: 48))
                path.addLine(to: CGPoint(x: 100, y: 70))
            }, width: 2.6, seed: 121))
            all.append(stroke({ $0.addEllipse(in: CGRect(x: 97.5, y: 78, width: 4, height: 4)) }, width: 2.6, fill: 1, seed: 122))
            return all

        case .emptyShelf:
            var all: [PenStroke] = []
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 30, y: 96))
                path.addLine(to: CGPoint(x: 170, y: 96))
            }, width: 2.6, seed: 131))
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 44, y: 96))
                path.addLine(to: CGPoint(x: 44, y: 110))
                path.move(to: CGPoint(x: 156, y: 96))
                path.addLine(to: CGPoint(x: 156, y: 110))
            }, width: 2.2, seed: 132))
            all += cartridge(at: CGPoint(x: 88, y: 42), size: CGSize(width: 40, height: 52), seed: 141)
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 60, y: 40))
                path.addLine(to: CGPoint(x: 68, y: 32))
                path.move(to: CGPoint(x: 148, y: 40))
                path.addLine(to: CGPoint(x: 140, y: 32))
            }, pen: true, width: 2.4, seed: 151))
            return all

        case .welcome:
            // Three screens, small to large, and one pen line that does not stop
            // at any of them. Nothing else: the promise is the line.
            var all: [PenStroke] = []
            all += screen(at: CGPoint(x: 14, y: 58), size: CGSize(width: 28, height: 50), seed: 161, stand: false)
            all.append(stroke({ path in
                path.move(to: CGPoint(x: 22, y: 103))
                path.addLine(to: CGPoint(x: 34, y: 103))
            }, width: 2, seed: 162))
            all += screen(at: CGPoint(x: 58, y: 46), size: CGSize(width: 54, height: 62), seed: 163, stand: false)
            all += screen(at: CGPoint(x: 126, y: 40), size: CGSize(width: 66, height: 44), seed: 165, stand: true)
            all += arrow(from: CGPoint(x: 20, y: 40), control: CGPoint(x: 96, y: 8), to: CGPoint(x: 176, y: 30), seed: 171)
            return all
        }
    }
}
