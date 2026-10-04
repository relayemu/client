// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Sketch.swift
//  RelayDesignSystem — the website's pen line, translated for the app.
//
//  The site draws its chrome with a sketch library that re-traces shapes with a
//  are drawn with the same hand, so this file re-implements the wobble natively:
//  give it any `Path` and it returns the same path as if drawn with a pen.
//
//  The wobble is deterministic for a given seed, so a scene never boils, never
//  differs between launches, and renders identically in tests and screenshots.

import SwiftUI

public extension Path {
    /// The same outline, redrawn by hand. `amplitude` is the pen's wander in points.
    func sketched(seed: UInt64, amplitude: CGFloat = 1.1) -> Path {
        var result = Path()
        for (index, polyline) in polylines().enumerated() where polyline.count >= 2 {
            let resampled = Sketch.resample(polyline, spacing: 9)
            guard resampled.count >= 2 else { continue }
            let closed = Sketch.isClosed(polyline)
            let wobbled = Sketch.wobble(resampled, seed: seed &+ UInt64(index &* 7919), amplitude: amplitude, closed: closed)
            Sketch.append(wobbled, closed: closed, to: &result)
        }
        return result
    }

    /// Flattened subpaths. Curves are subdivided so the wobble follows real geometry.
    func polylines() -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func flush() {
            if current.count >= 2 { lines.append(current) }
            current = []
        }
        forEach { element in
            switch element {
            case .move(let to):
                flush()
                current = [to]
                start = to
            case .line(let to):
                current.append(to)
            case .quadCurve(let to, let control):
                let from = current.last ?? start
                for step in 1...12 {
                    let t = CGFloat(step) / 12
                    current.append(Sketch.quad(from, control, to, t))
                }
            case .curve(let to, let control1, let control2):
                let from = current.last ?? start
                for step in 1...16 {
                    let t = CGFloat(step) / 16
                    current.append(Sketch.cubic(from, control1, control2, to, t))
                }
            case .closeSubpath:
                if let first = current.first { current.append(first) }
                flush()
            }
        }
        flush()
        return lines
    }
}

enum Sketch {
    static func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                       y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    static func isClosed(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        return hypot(first.x - last.x, first.y - last.y) < 0.01
    }

    /// Even arc-length resampling: the pen wanders by distance travelled, not by
    /// how many control points the original shape happened to have.
    static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        var lengths: [CGFloat] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = lengths[lengths.count - 1]
        guard total > 0.01 else { return points }
        let count = max(3, Int((total / spacing).rounded()))
        var out: [CGPoint] = []
        var cursor = 1
        for step in 0...count {
            let target = total * CGFloat(step) / CGFloat(count)
            while cursor < lengths.count - 1 && lengths[cursor] < target { cursor += 1 }
            let span = lengths[cursor] - lengths[cursor - 1]
            let t = span > 0 ? (target - lengths[cursor - 1]) / span : 0
            let a = points[cursor - 1], b = points[cursor]
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    /// Displace each sample along the local normal by smooth low-frequency noise.
    static func wobble(_ points: [CGPoint], seed: UInt64, amplitude: CGFloat, closed: Bool) -> [CGPoint] {
        var generator = SplitMix64(seed: seed | 1)
        let controlCount = max(3, points.count / 3)
        let controls = (0...controlCount).map { _ in CGFloat(generator.nextUnit() * 2 - 1) }
        return points.enumerated().map { index, point in
            let position = CGFloat(index) / CGFloat(max(points.count - 1, 1)) * CGFloat(controlCount)
            let lower = Int(position)
            let upper = min(lower + 1, controlCount)
            // Cosine interpolation between control values keeps the line organic, never jagged.
            let blend = (1 - cos((position - CGFloat(lower)) * .pi)) / 2
            let noise = controls[lower] * (1 - blend) + controls[upper] * blend
            // Ends of an open stroke stay put so joints do not drift apart.
            let taper: CGFloat = closed ? 1 : sin(CGFloat(index) / CGFloat(max(points.count - 1, 1)) * .pi)
            let previous = points[max(index - 1, 0)]
            let next = points[min(index + 1, points.count - 1)]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.0001)
            return CGPoint(x: point.x - dy / length * noise * amplitude * taper,
                           y: point.y + dx / length * noise * amplitude * taper)
        }
    }

    /// Rebuild a smooth stroke through the wobbled samples (quadratics through midpoints).
    static func append(_ points: [CGPoint], closed: Bool, to path: inout Path) {
        guard points.count >= 2 else { return }
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        if closed { path.closeSubpath() }
    }
}

/// Small, fast, reproducible generator. Scenes must look the same every launch.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
