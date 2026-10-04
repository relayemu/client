// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  TouchControlKit.swift
//  RelayDesignSystem — §8.12 TouchControlKit (iOS only) and IPHONE_UX §6.
//
//  A UIKit view that draws controller-style controls with the Relay material
//  vocabulary and turns raw multi-touch into press/release events for logical
//  controls. Layouts are data (`TouchLayout`) so systems and orientations are
//  presets, not code paths. No emulation types here: the caller maps
//  `TouchControl` to its input model.

import CoreGraphics
import Foundation
import RelayDomain

// MARK: - Layout data (every platform; tested on the macOS host)

/// Logical controls a layout can contain.
public enum TouchControl: String, Hashable, Codable, Sendable, CaseIterable {
    case up, down, left, right
    case a, b, x, y
    case l, r
    case l2, r2, l3, r3
    case leftStick, rightStick
    case start, select
    /// The second four-way cluster (WonderSwan Y, Nintendo 64 C).
    case cUp, cDown, cLeft, cRight
}

/// One element of a layout, positioned in a unit square of the control area.
public struct TouchLayoutElement: Hashable, Codable, Sendable {
    public enum Shape: Hashable, Codable, Sendable {
        /// A round face button of the given diameter.
        case round(diameter: CGFloat)
        /// A capsule (Start/Select, shoulders).
        case capsule(width: CGFloat, height: CGFloat)
        /// The eight-way D-pad cross of the given span; `control` is ignored.
        case dpad(span: CGFloat)
        /// A continuous thumbstick with a fixed origin and a movable thumb.
        case stick(diameter: CGFloat)
    }

    public let control: TouchControl
    public let shape: Shape
    /// Centre in unit coordinates of the control area (0…1 each axis).
    public let center: CGPoint
    public let label: String

    public init(_ control: TouchControl, _ shape: Shape, at center: CGPoint, label: String) {
        self.control = control
        self.shape = shape
        self.center = center
        self.label = label
    }
}

/// A complete layout for one system family and orientation (IPHONE_UX §6.1).
public struct TouchLayout: Hashable, Codable, Sendable {
    public let elements: [TouchLayoutElement]

    public init(elements: [TouchLayoutElement]) { self.elements = elements }

    /// The layout for a system, built from the controls its hardware has
    /// (`SystemInputLayout`), so no system's shape is copied into another's.
    /// D-pad left, face buttons staggered right (two, or four in a diamond),
    /// shoulders at the top corners when the hardware has them, Start/Select
    /// capsules centred at the bottom; a system without Select centres Start.
    public static func layout(for controls: SystemInputLayout, portrait: Bool, scale: CGFloat = 1) -> TouchLayout {
        if controls.has(.leftStick) || controls.has(.rightStick) {
            return analogLayout(for: controls, portrait: portrait, scale: scale)
        }
        let face: CGFloat = 56 * scale
        let dpad: CGFloat = 152 * scale
        let shoulder = TouchLayoutElement.Shape.capsule(width: 96 * scale, height: 40 * scale)
        let system = TouchLayoutElement.Shape.capsule(width: 64 * scale, height: 32 * scale)
        var elements: [TouchLayoutElement] = []
        // What the hardware prints on a button, when the system says so.
        func name(_ control: SystemControl, _ fallback: String) -> String { controls.label(for: control) ?? fallback }

        // Shoulders sit above everything else, in the top corners.
        if controls.has(.shoulderL) {
            elements.append(.init(.l, shoulder, at: CGPoint(x: portrait ? 0.18 : 0.10, y: portrait ? 0.10 : 0.12), label: "L"))
        }
        if controls.has(.shoulderR) {
            elements.append(.init(.r, shoulder, at: CGPoint(x: portrait ? 0.82 : 0.90, y: portrait ? 0.10 : 0.12), label: "R"))
        }

        if controls.has(.dPad) {
            elements.append(.init(.up, .dpad(span: dpad), at: CGPoint(x: portrait ? 0.24 : 0.12, y: portrait ? 0.50 : 0.58), label: ""))
        }

        // A second four-way cluster (WonderSwan Y) sits below the pad as four
        // small round buttons in a diamond, labelled with the cluster's name.
        if controls.has(.cPad) {
            let small: CGFloat = 40 * scale
            let centre = CGPoint(x: portrait ? 0.24 : 0.12, y: portrait ? 0.80 : 0.86)
            let step: CGFloat = portrait ? 0.075 : 0.06
            let cluster = name(.cPad, "C")
            elements.append(.init(.cUp, .round(diameter: small), at: CGPoint(x: centre.x, y: centre.y - step), label: cluster + "1"))
            elements.append(.init(.cRight, .round(diameter: small), at: CGPoint(x: centre.x + step, y: centre.y), label: cluster + "2"))
            elements.append(.init(.cDown, .round(diameter: small), at: CGPoint(x: centre.x, y: centre.y + step), label: cluster + "3"))
            elements.append(.init(.cLeft, .round(diameter: small), at: CGPoint(x: centre.x - step, y: centre.y), label: cluster + "4"))
        }

        // Face buttons: B lower-left, A upper-right for a two-button system;
        // a four-button system adds Y left of B and X above A, in a diamond.
        let bCenter = CGPoint(x: portrait ? 0.70 : 0.84, y: portrait ? 0.58 : 0.66)
        let aCenter = CGPoint(x: portrait ? 0.86 : 0.93, y: portrait ? 0.42 : 0.48)
        if controls.faceButtonCount >= 4 {
            let dx = aCenter.x - bCenter.x, dy = bCenter.y - aCenter.y
            elements.append(.init(.y, .round(diameter: face), at: CGPoint(x: bCenter.x - dx, y: bCenter.y - dy), label: name(.faceY, "Y")))
            elements.append(.init(.x, .round(diameter: face), at: CGPoint(x: aCenter.x - dx, y: aCenter.y - dy), label: name(.faceX, "X")))
        }
        if controls.has(.faceB) { elements.append(.init(.b, .round(diameter: face), at: bCenter, label: name(.faceB, "B"))) }
        if controls.has(.faceA) { elements.append(.init(.a, .round(diameter: face), at: aCenter, label: name(.faceA, "A"))) }

        // Start and Select share the bottom edge; alone, Start takes the middle.
        let bottom: CGFloat = portrait ? 0.90 : 0.92
        switch (controls.has(.select), controls.has(.start)) {
        case (true, true):
            elements.append(.init(.select, system, at: CGPoint(x: portrait ? 0.40 : 0.42, y: bottom), label: name(.select, "SELECT")))
            elements.append(.init(.start, system, at: CGPoint(x: portrait ? 0.60 : 0.58, y: bottom), label: name(.start, "START")))
        case (false, true):
            elements.append(.init(.start, system, at: CGPoint(x: 0.50, y: bottom), label: name(.start, "START")))
        case (true, false):
            elements.append(.init(.select, system, at: CGPoint(x: 0.50, y: bottom), label: name(.select, "SELECT")))
        case (false, false):
            break
        }
        return TouchLayout(elements: elements)
    }

    private static func analogLayout(for controls: SystemInputLayout, portrait: Bool, scale: CGFloat) -> TouchLayout {
        var elements: [TouchLayoutElement] = []
        func add(_ control: TouchControl, _ systemControl: SystemControl, _ shape: TouchLayoutElement.Shape,
                 _ x: CGFloat, _ y: CGFloat, _ fallback: String) {
            guard controls.has(systemControl) else { return }
            elements.append(.init(control, shape.scaled(by: scale), at: CGPoint(x: x, y: y), label: controls.label(for: systemControl) ?? fallback))
        }
        let left: CGFloat = portrait ? 0.20 : 0.10, right: CGFloat = 1 - left
        let shoulder = TouchLayoutElement.Shape.capsule(width: 88, height: 36)
        add(.l, .shoulderL, shoulder, left, portrait ? 0.07 : 0.08125, "L1")
        add(.r, .shoulderR, shoulder, right, portrait ? 0.07 : 0.08125, "R1")
        add(.l2, .triggerL, shoulder, left, portrait ? 0.21 : 0.23125, "L2")
        add(.r2, .triggerR, shoulder, right, portrait ? 0.21 : 0.23125, "R2")
        let padY: CGFloat = portrait ? 0.46 : 0.50
        add(.up, .dPad, .dpad(span: 112), left, padY, "")
        let face: CGFloat = 44, dx: CGFloat = portrait ? 0.11 : 0.05, dy: CGFloat = 0.11
        add(.a, .faceA, .round(diameter: face), right + dx, padY, "A")
        add(.b, .faceB, .round(diameter: face), right, padY + dy, "B")
        add(.x, .faceX, .round(diameter: face), right, padY - dy, "X")
        add(.y, .faceY, .round(diameter: face), right - dx, padY, "Y")
        add(.leftStick, .leftStick, .stick(diameter: 84), left, portrait ? 0.77 : 0.84375, "L")
        add(.rightStick, .rightStick, .stick(diameter: 84), right, portrait ? 0.77 : 0.84375, "R")
        add(.l3, .leftStickClick, .round(diameter: 36), portrait ? 0.425 : 0.22, 0.78, "L3")
        add(.r3, .rightStickClick, .round(diameter: 36), portrait ? 0.575 : 0.78, 0.78, "R3")
        let system = TouchLayoutElement.Shape.capsule(width: 64, height: 32)
        add(.select, .select, system, 0.40, 0.96, "SELECT")
        add(.start, .start, system, 0.60, 0.96, "START")
        return TouchLayout(elements: elements)
    }

    /// The Game Boy Advance layout, kept for callers and previews that name it.
    public static func gba(portrait: Bool, scale: CGFloat = 1) -> TouchLayout {
        layout(for: SystemCatalog.gameBoyAdvance.inputLayout, portrait: portrait, scale: scale)
    }

    /// The controls this layout draws.
    public var controls: Set<TouchControl> { Set(elements.map(\.control)) }

    /// Space needed by the two direction clusters and the bottom system row.
    /// Ordinary presets keep their existing deck height. This excludes the
    /// enclosing surface's margins and uses the actual point-sized controls.
    public func minimumReachHeight(portrait: Bool) -> CGFloat {
        if let stick = elements.first(where: { if case .stick = $0.shape { return true }; return false }) {
            return (portrait ? 372 : 332) * stick.shape.size.height / 84
        }
        guard let dimensions = secondaryPadDimensions else { return 0 }
        let clusters = portrait ? dimensions.pad.height + 16 + dimensions.span
            : max(dimensions.pad.height, dimensions.span)
        return 8 + clusters + 16 + dimensions.system + 8
    }

    private var secondaryPadDimensions: (pad: CGSize, button: CGFloat, span: CGFloat, system: CGFloat, face: CGFloat)? {
        let second = elements.filter { [.cUp, .cDown, .cLeft, .cRight].contains($0.control) }
        guard second.count == 4, let button = second.map({ $0.shape.size.width }).max(),
              let pad = elements.first(where: { if case .dpad = $0.shape { return true }; return false }) else { return nil }
        // The UIKit hit boxes extend six points on each side. Sixteen points
        // between visible shapes leaves four points between their hit boxes.
        let span = button + 2 * (button + 16)
        let system = elements.filter { [.start, .select].contains($0.control) }.map { $0.shape.size.height }.max() ?? 0
        let face = elements.filter { [.a, .b, .x, .y].contains($0.control) }.map { $0.shape.size.width }.max() ?? 0
        return (pad.shape.size, button, span, system, face)
    }

    /// Default controls stay in bounded grip areas as the canvas grows. Sizes
    /// remain points; only the default centers are projected from a bounded
    /// reference area. Custom layouts deliberately do not use this projection.
    public func anchoredForReach(in size: CGSize, portrait: Bool) -> TouchLayout {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return self }
        let referenceWidth = min(size.width, portrait ? 420 : 850)
        // Analog controls grow on larger touch surfaces. Their vertical grip
        // must grow with their point sizes rather than compressing larger
        // sticks/buttons into the phone's unscaled reference height.
        let analogScale = elements.first(where: { if case .stick = $0.shape { return true }; return false })
            .map { $0.shape.size.height / 84 } ?? 1
        let referenceHeight = min(size.height, (portrait ? 360 : 480) * analogScale)
        let systemButtons = elements.filter { [.start, .select].contains($0.control) }
        let systemWidth = systemButtons.reduce(CGFloat.zero) { $0 + $1.shape.size.width } + CGFloat(max(0, systemButtons.count - 1)) * 16
        let second = secondaryPadDimensions
        let sideBySide = second.map { !portrait && size.width >= 16 + $0.pad.width + 16 + $0.span + 16 + 2 * $0.face + 16 } ?? false
        let projected = TouchLayout(elements: elements.map { element in
            var x = element.center.x < 0.5
                ? element.center.x * referenceWidth
                : element.center.x > 0.5 ? size.width - (1 - element.center.x) * referenceWidth : size.width / 2
            var y = size.height - (1 - element.center.y) * referenceHeight
            if let index = systemButtons.firstIndex(where: { $0.control == element.control }) {
                // Start and Select form one centered group; a lone button is
                // centered, and expanding the view never separates the pair.
                let preceding = systemButtons.prefix(index).reduce(CGFloat.zero) { $0 + $1.shape.size.width + 16 }
                x = (size.width - systemWidth) / 2 + preceding + element.shape.size.width / 2
                y = size.height - 8 - element.shape.size.height / 2
            }
            if let second {
                let bottom = size.height - 8 - second.system - 16
                let step = second.button + 16
                let clusterX = sideBySide ? 8 + second.pad.width + 16 + second.span / 2
                    : 8 + max(second.pad.width, second.span) / 2
                let clusterY = bottom - (sideBySide ? max(second.pad.height, second.span) : second.span) / 2
                switch element.control {
                case .up:
                    x = 8 + second.pad.width / 2
                    y = sideBySide ? clusterY : bottom - second.span - 16 - second.pad.height / 2
                case .cUp: x = clusterX; y = clusterY - step
                case .cDown: x = clusterX; y = clusterY + step
                case .cLeft: x = clusterX - step; y = clusterY
                case .cRight: x = clusterX + step; y = clusterY
                case .a:
                    x = size.width - 8 - second.face / 2
                    y = bottom - second.face / 2 - second.face - 16
                case .b:
                    x = size.width - 8 - second.face / 2 - second.face - 16
                    y = bottom - second.face / 2
                case .start, .select: y = size.height - 8 - element.shape.size.height / 2
                default: break
                }
            }
            return element.moved(to: CGPoint(x: x / size.width, y: y / size.height))
        })
        return projected.separatingReachGroups(in: size)
    }

    /// Clamp a face diamond as one group between the shoulders and sticks.
    /// Individual clamping distorted the diamond on narrow canvases and
    /// let X touch R. Saved layouts do not pass through this default projection.
    private func separatingReachGroups(in size: CGSize) -> TouchLayout {
        func box(_ element: TouchLayoutElement, fitted: Bool = true) -> CGRect {
            let c = fitted ? element.fittedCenter(in: size) : element.center
            return CGRect(x: c.x * size.width - element.shape.size.width / 2,
                          y: c.y * size.height - element.shape.size.height / 2,
                          width: element.shape.size.width, height: element.shape.size.height)
        }
        var result = self
        let faces = elements.filter { [.a, .b, .x, .y].contains($0.control) }
        if faces.count == 4 {
            let bounds = faces.reduce(CGRect.null) { $0.union(box($1, fitted: false)) }
            let dx = bounds.minX < 8 ? 8 - bounds.minX : min(0, size.width - 8 - bounds.maxX)
            let shoulders = elements.filter { [.l, .r, .l2, .r2].contains($0.control) }.map { box($0) }
            let sticks = elements.filter { if case .stick = $0.shape { return true }; return false }.map { box($0) }
            var minimumY = 8 - bounds.minY
            var maximumY = size.height - 8 - bounds.maxY
            for face in faces {
                let frame = box(face, fitted: false).offsetBy(dx: dx, dy: 0)
                for shoulder in shoulders where frame.maxX > shoulder.minX && frame.minX < shoulder.maxX {
                    minimumY = max(minimumY, shoulder.maxY + 4 - frame.minY)
                }
                for stick in sticks where frame.maxX > stick.minX && frame.minX < stick.maxX {
                    maximumY = min(maximumY, stick.minY - 4 - frame.maxY)
                }
            }
            if minimumY <= maximumY {
                let dy = min(maximumY, max(0, minimumY))
                for face in faces {
                    result = result.replacing(face.moved(to: CGPoint(x: face.center.x + dx / size.width,
                                                                     y: face.center.y + dy / size.height)))
                }
            }
        }
        // Stick-click buttons share the middle row. On a narrow canvas move
        // that row up, not inward where L3 and R3 would collide with each other.
        let pairs: [(TouchControl, TouchControl)] = [(.leftStick, .l3), (.rightStick, .r3)]
        var clickRow = CGFloat.greatestFiniteMagnitude
        for (stickID, clickID) in pairs {
            guard let stick = result.elements.first(where: { $0.control == stickID }),
                  let click = result.elements.first(where: { $0.control == clickID }) else { continue }
            let a = box(stick), b = box(click)
            let distance = (a.width + b.width) / 2 + 4
            let dx = abs(a.midX - b.midX), dy = abs(a.midY - b.midY)
            if dx * dx + dy * dy < distance * distance {
                clickRow = min(clickRow, a.midY - sqrt(max(0, distance * distance - dx * dx)) - 0.5)
            }
        }
        if clickRow.isFinite, clickRow < .greatestFiniteMagnitude {
            for (_, clickID) in pairs {
                guard let click = result.elements.first(where: { $0.control == clickID }),
                      clickRow - click.shape.size.height / 2 >= 8 else { continue }
                result = result.replacing(click.moved(to: CGPoint(x: click.center.x, y: clickRow / size.height)))
            }
        }
        return result
    }

    /// Repairs persisted/untrusted layout data against the Relay default. Every
    /// required control remains reachable, duplicates are removed, centres stay
    /// within the padded control area, and sizes stay useful on phone and iPad.
    public func repaired(using fallback: TouchLayout) -> TouchLayout {
        let required = fallback.controls
        var seen: Set<TouchControl> = []
        var repaired: [TouchLayoutElement] = []
        let fallbackByControl = Dictionary(uniqueKeysWithValues: fallback.elements.map { ($0.control, $0) })
        for element in elements where required.contains(element.control) && !seen.contains(element.control) {
            seen.insert(element.control)
            let defaultCenter = fallbackByControl[element.control]?.center ?? CGPoint(x: 0.5, y: 0.5)
            func normalized(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
                guard value.isFinite else { return fallback.isFinite ? min(1, max(0, fallback)) : 0.5 }
                // Retain valid edge coordinates: concrete rendering fits the
                // complete shape. Out-of-range legacy data keeps its repair.
                return (0...1).contains(value) ? value : min(0.92, max(0.08, value))
            }
            let center = CGPoint(x: normalized(element.center.x, fallback: defaultCenter.x),
                                 y: normalized(element.center.y, fallback: defaultCenter.y))
            repaired.append(TouchLayoutElement(element.control, element.shape.clamped, at: center,
                                               label: fallbackByControl[element.control]?.label ?? element.label))
        }
        for element in fallback.elements where !seen.contains(element.control) {
            repaired.append(element)
        }
        return TouchLayout(elements: repaired)
    }

    /// Also fits every repaired control inside a concrete presentation area.
    /// Persisted coordinates are normalized, while control sizes are points;
    /// this second pass keeps a large control reachable on a smaller phone or
    /// after an orientation change.
    public func repaired(using fallback: TouchLayout, fitting size: CGSize, padding: CGFloat = 8) -> TouchLayout {
        let repaired = repaired(using: fallback)
        guard size.width > 0, size.height > 0 else { return repaired }
        return TouchLayout(elements: repaired.elements.map { element in
            element.moved(to: element.fittedCenter(in: size, padding: padding))
        })
    }

    public func replacing(_ replacement: TouchLayoutElement) -> TouchLayout {
        TouchLayout(elements: elements.map { $0.control == replacement.control ? replacement : $0 })
    }
}

public extension TouchLayoutElement {
    func moved(to center: CGPoint) -> TouchLayoutElement {
        TouchLayoutElement(control, shape, at: center, label: label)
    }

    func scaled(by factor: CGFloat) -> TouchLayoutElement {
        TouchLayoutElement(control, shape.scaled(by: factor), at: center, label: label)
    }

    func fittedCenter(in size: CGSize, padding: CGFloat = 8) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return center }
        let halfWidth = min(size.width / 2, shape.size.width / 2 + padding)
        let halfHeight = min(size.height / 2, shape.size.height / 2 + padding)
        let x = min(size.width - halfWidth, max(halfWidth, center.x * size.width)) / size.width
        let y = min(size.height - halfHeight, max(halfHeight, center.y * size.height)) / size.height
        return CGPoint(x: x, y: y)
    }
}

public extension TouchLayoutElement.Shape {
    var size: CGSize {
        switch self {
        case .round(let d): return CGSize(width: d, height: d)
        case .capsule(let w, let h): return CGSize(width: w, height: h)
        case .dpad(let span): return CGSize(width: span, height: span)
        case .stick(let diameter): return CGSize(width: diameter, height: diameter)
        }
    }

    func scaled(by factor: CGFloat) -> TouchLayoutElement.Shape {
        let factor = min(1.6, max(0.6, factor))
        switch self {
        case .round(let diameter): return .round(diameter: diameter * factor)
        case .capsule(let width, let height): return .capsule(width: width * factor, height: height * factor)
        case .dpad(let span): return .dpad(span: span * factor)
        case .stick(let diameter): return .stick(diameter: diameter * factor)
        }
    }

    fileprivate var clamped: TouchLayoutElement.Shape {
        switch self {
        case .round(let diameter): return .round(diameter: min(112, max(36, diameter)))
        case .capsule(let width, let height):
            return .capsule(width: min(180, max(56, width)), height: min(72, max(32, height)))
        case .dpad(let span): return .dpad(span: min(200, max(96, span)))
        case .stick(let diameter): return .stick(diameter: min(128, max(64, diameter)))
        }
    }
}

/// The same frame-based resolver is used by UIKit and the focused host tests.
struct TouchHitRegion {
    let element: TouchLayoutElement
    let frame: CGRect

    func containsVisiblePoint(_ point: CGPoint) -> Bool {
        // Include the strongest supported two-point outline, not just the fill.
        guard frame.insetBy(dx: -1, dy: -1).contains(point) else { return false }
        let path = element.shape.outline(in: frame)
        return path.contains(point) || path.copy(strokingWithWidth: 2, lineCap: .round,
            lineJoin: .round, miterLimit: 1).contains(point)
    }
}

extension TouchLayoutElement.Shape {
    /// One path for rendering and touch priority, including the cross's empty corners.
    func outline(in rect: CGRect) -> CGPath {
        switch self {
        case .round, .stick:
            return CGPath(ellipseIn: rect, transform: nil)
        case .capsule:
            return CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                          cornerHeight: rect.height / 2, transform: nil)
        case .dpad:
            let arm = rect.width * 0.34
            let path = CGMutablePath()
            path.addRoundedRect(in: CGRect(x: rect.midX - arm / 2, y: rect.minY, width: arm, height: rect.height),
                                cornerWidth: arm * 0.3, cornerHeight: arm * 0.3)
            path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.midY - arm / 2, width: rect.width, height: arm),
                                cornerWidth: arm * 0.3, cornerHeight: arm * 0.3)
            return path
        }
    }
}

enum TouchHitTesting {
    static func controls(at point: CGPoint, regions: [TouchHitRegion]) -> Set<TouchControl> {
        // A visible control wins over a neighbor's invisible expanded rectangle.
        // Between visible controls, keep the existing forgiving/rolling zones.
        let visible = regions.filter { $0.containsVisiblePoint(point) }
        var result: Set<TouchControl> = []
        for region in visible.isEmpty ? regions : visible {
            guard region.frame.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            switch region.element.shape {
            case .dpad(let span):
                let dx = point.x - region.frame.midX, dy = point.y - region.frame.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance > span * 0.12 else { continue }
                let angle = atan2(-dy, dx)
                let sector = Int(((angle + .pi / 8 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)) / (.pi / 4))
                switch sector {
                case 0: result.insert(.right)
                case 1: result.formUnion([.right, .up])
                case 2: result.insert(.up)
                case 3: result.formUnion([.up, .left])
                case 4: result.insert(.left)
                case 5: result.formUnion([.left, .down])
                case 6: result.insert(.down)
                default: result.formUnion([.down, .right])
                }
            default:
                result.insert(region.element.control)
            }
        }
        return result
    }
}

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - The surface (iOS only)

/// Receives press/release events; called on the main thread.
@MainActor
public protocol TouchControlDelegate: AnyObject {
    func touchControl(_ control: TouchControl, pressed: Bool)
    /// Both axes in -1...1; positive Y points upwards.
    func touchStick(_ control: TouchControl, position: CGPoint)
    /// Two-finger tap on empty space (IPHONE_UX §6.2 toggle).
    func touchControlsTwoFingerTap()
}

public extension TouchControlDelegate {
    func touchStick(_ control: TouchControl, position: CGPoint) {}
}

/// The control surface. Opacity: 55 % while touching, 30 % after 3 s idle (§8.12).
@MainActor
public final class TouchControlView: UIView, UIGestureRecognizerDelegate {
    public weak var delegate: (any TouchControlDelegate)?
    public var hapticsEnabled = true
    public var skin: RelaySkinConfiguration? { didSet { updateSkin() } }
    public var skinSystem: SystemID = .gameBoyAdvance { didSet { updateSkin() } }

    private func updateSkin() {
        for view in elementViews { view.applySkin(skin, system: skinSystem) }
    }
    public var layout: TouchLayout { didSet { rebuild() } }
    /// Base opacity while touching (§8.12: 0.55) — user adjustable in Settings.
    public var activeOpacity: CGFloat = 0.55 { didSet { applyOpacity(animated: false) } }
    public var idleOpacity: CGFloat = 0.30
    public override var isUserInteractionEnabled: Bool {
        didSet {
            twoFingerTap?.isEnabled = isUserInteractionEnabled
            if !isUserInteractionEnabled { releaseAll() }
        }
    }
    /// A separate black control deck does not need to fade to expose the game.
    public var hasDedicatedBackground = false {
        didSet {
            for view in elementViews { view.hasDedicatedBackground = hasDedicatedBackground }
            applyOpacity(animated: false)
        }
    }

    private var elementViews: [ElementView] = []
    private var touchAssignments: [ObjectIdentifier: Set<TouchControl>] = [:]
    private var pressCounts: [TouchControl: Int] = [:]
    private var stickAssignments: [ObjectIdentifier: TouchControl] = [:]
    private var idleTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private var twoFingerTap: UITapGestureRecognizer!

    public init(layout: TouchLayout) {
        self.layout = layout
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = false
        twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        twoFingerTap.delaysTouchesBegan = false
        twoFingerTap.delaysTouchesEnded = false
        twoFingerTap.delegate = self
        rebuild()
        alpha = idleOpacity
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateTwoFingerTapHost()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTwoFingerTapHost()
    }

    public override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { detachTwoFingerTap() }
        super.willMove(toSuperview: newSuperview)
    }

    private func updateTwoFingerTapHost() {
        guard let window, superview != nil else {
            detachTwoFingerTap()
            return
        }
        // A SwiftUI representable may have private wrapper views. Its nearest
        // controller-owned ancestor is a public, stable boundary that also sees
        // the game surface's touches; a recognizer on this pass-through view
        // alone would miss the first finger of a two-finger tap on empty space.
        var ancestor = superview
        var host: UIView = window
        while let candidate = ancestor {
            if candidate.next is UIViewController {
                host = candidate
                break
            }
            ancestor = candidate.superview
        }
        guard twoFingerTap.view !== host else { return }
        detachTwoFingerTap()
        host.addGestureRecognizer(twoFingerTap)
    }

    fileprivate func detachTwoFingerTap() {
        twoFingerTap.view?.removeGestureRecognizer(twoFingerTap)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        for view in elementViews {
            let size = view.element.shape.size
            let normalizedCenter = view.element.fittedCenter(in: bounds.size)
            let center = CGPoint(x: bounds.minX + bounds.width * normalizedCenter.x,
                                 y: bounds.minY + bounds.height * normalizedCenter.y)
            view.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Every control the view currently reports as pressed (for tests and diagnostics).
    public var pressedControls: Set<TouchControl> { Set(pressCounts.filter { $0.value > 0 }.map(\.key)) }

    /// Releases everything (controller took over, view hidden, app backgrounded).
    public func releaseAll() {
        for control in pressedControls { setPressed(control, false) }
        for control in Set(stickAssignments.values) { updateStick(control, position: .zero) }
        stickAssignments.removeAll()
        touchAssignments.removeAll()
        pressCounts.removeAll()
        for view in elementViews { view.setHighlighted([]) }
    }

    // MARK: Touch handling (rolling inputs: the set of controls under each touch is re-evaluated on move)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        showActive()
        for touch in touches { update(touch) }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { update(touch) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { end(touch) }
        if touchAssignments.isEmpty && stickAssignments.isEmpty { scheduleIdle() }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { end(touch) }
        if touchAssignments.isEmpty && stickAssignments.isEmpty { scheduleIdle() }
    }

    /// Only control touches belong to the kit. The ancestor recognizer observes
    /// empty-space taps without changing which view receives either finger.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && !controls(at: point).isEmpty
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === twoFingerTap, isUserInteractionEnabled,
              let host = twoFingerTap.view, window != nil, isDescendant(of: host) else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            if view === host { break }
            ancestor = view.superview
        }
        let point = touch.location(in: self)
        return bounds.contains(point) && controls(at: point).isEmpty
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === twoFingerTap || otherGestureRecognizer === twoFingerTap
    }

    private func update(_ touch: UITouch) {
        let key = ObjectIdentifier(touch)
        let point = touch.location(in: self)
        if let control = stickAssignments[key] {
            moveStick(control, to: point)
            return
        }
        let resolved = controls(at: point)
        if touchAssignments[key] == nil,
           let view = elementViews.first(where: {
               if case .stick = $0.element.shape {
                   return resolved.contains($0.element.control) && $0.frame.contains(point)
               }
               return false
           }), !stickAssignments.values.contains(view.element.control) {
            stickAssignments[key] = view.element.control
            moveStick(view.element.control, to: point)
            return
        }
        let now = resolved.subtracting([.leftStick, .rightStick])
        let before = touchAssignments[key] ?? []
        for control in before.subtracting(now) { adjust(control, by: -1) }
        for control in now.subtracting(before) { adjust(control, by: +1) }
        touchAssignments[key] = now
        refreshHighlights()
    }

    private func end(_ touch: UITouch) {
        let key = ObjectIdentifier(touch)
        if let control = stickAssignments.removeValue(forKey: key) { updateStick(control, position: .zero) }
        for control in touchAssignments[key] ?? [] { adjust(control, by: -1) }
        touchAssignments[key] = nil
        refreshHighlights()
    }

    private func moveStick(_ control: TouchControl, to point: CGPoint) {
        guard let view = elementViews.first(where: { $0.element.control == control }) else { return }
        let radius = max(1, view.bounds.width * 0.35)
        var x = (point.x - view.frame.midX) / radius
        var y = (point.y - view.frame.midY) / radius
        let length = hypot(x, y)
        if length > 1 { x /= length; y /= length }
        if length < 0.12 { x = 0; y = 0 }
        updateStick(control, position: CGPoint(x: x, y: y))
    }

    private func updateStick(_ control: TouchControl, position: CGPoint) {
        elementViews.first(where: { $0.element.control == control })?.setStickPosition(position)
        delegate?.touchStick(control, position: position)
    }

    private func adjust(_ control: TouchControl, by delta: Int) {
        let before = pressCounts[control, default: 0]
        let after = max(0, before + delta)
        pressCounts[control] = after
        if before == 0, after > 0 { setPressed(control, true) }
        if before > 0, after == 0 { setPressed(control, false) }
    }

    private func setPressed(_ control: TouchControl, _ pressed: Bool) {
        if pressed, hapticsEnabled { haptic.impactOccurred(intensity: 0.6) }
        delegate?.touchControl(control, pressed: pressed)
    }

    private func refreshHighlights() {
        let pressed = pressedControls
        for view in elementViews { view.setHighlighted(pressed) }
    }

    /// Controls under `point`: face buttons/capsules by hit area (with a 6-pt margin), the
    /// D-pad by angular zones with 8-way diagonals and a central dead zone.
    func controls(at point: CGPoint) -> Set<TouchControl> {
        TouchHitTesting.controls(at: point, regions: elementViews.map {
            TouchHitRegion(element: $0.element, frame: $0.frame)
        })
    }

    // MARK: Opacity behaviour

    private func showActive() {
        idleTimer?.invalidate()
        applyOpacity(animated: true)
    }

    private func scheduleIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UIView.animate(withDuration: 0.24) { self.alpha = self.restingOpacity }
            }
        }
    }

    private func applyOpacity(animated: Bool) {
        let target = touchAssignments.isEmpty && stickAssignments.isEmpty ? restingOpacity : activeOpacity
        if animated { UIView.animate(withDuration: 0.12) { self.alpha = target } } else { alpha = target }
        if touchAssignments.isEmpty && stickAssignments.isEmpty { scheduleIdle() }
    }

    private var restingOpacity: CGFloat { hasDedicatedBackground ? activeOpacity : idleOpacity }

    @objc private func handleTwoFingerTap() {
        delegate?.touchControlsTwoFingerTap()
    }

    // MARK: Building

    private func rebuild() {
        releaseAll()
        elementViews.forEach { $0.removeFromSuperview() }
        elementViews = layout.elements.map {
            let view = ElementView(element: $0)
            view.hasDedicatedBackground = hasDedicatedBackground
            view.applySkin(skin, system: skinSystem)
            return view
        }
        elementViews.forEach(addSubview)
        setNeedsLayout()
    }
}


/// One drawn control: thin material fill, 1-pt off-white 30 % stroke, letter label.
@MainActor
final class ElementView: UIView {
    let element: TouchLayoutElement
    var hasDedicatedBackground = false { didSet { updateOutline() } }
    private let fill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let shapeLayer = CAShapeLayer()
    private let pressedOverlay = UIView()
    private let label = UILabel()
    private let stickKnob = UIView()
    private var stickPosition = CGPoint.zero
    private var skin: RelaySkinConfiguration?
    private var skinAccent: UIColor?

    func applySkin(_ configuration: RelaySkinConfiguration?, system: SystemID) {
        skin = configuration?.enabled == true ? configuration : nil
        if let skin {
            let traits = UITraitCollection(userInterfaceStyle: skin.finish == .graphite ? .dark : .light)
            skinAccent = UIColor(skin.accentColor(for: system)).resolvedColor(with: traits)
            fill.effect = nil
            fill.contentView.backgroundColor = UIColor(skin.background).withAlphaComponent(0.92)
            label.textColor = UIColor(skin.foreground)
            pressedOverlay.backgroundColor = skinAccent?.withAlphaComponent(0.42)
        } else {
            skinAccent = nil
            fill.effect = UIBlurEffect(style: .systemThinMaterialDark)
            fill.contentView.backgroundColor = .clear
            label.textColor = UIColor(RelayColor.offWhite)
            pressedOverlay.backgroundColor = UIColor(RelayColor.offWhite).withAlphaComponent(0.25)
        }
        updateOutline()
    }

    init(element: TouchLayoutElement) {
        self.element = element
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityName(for: element)
        accessibilityTraits = .button
        fill.isUserInteractionEnabled = false
        addSubview(fill)
        pressedOverlay.backgroundColor = UIColor(white: 0.96, alpha: 0.25)
        pressedOverlay.isHidden = true
        addSubview(pressedOverlay)
        shapeLayer.fillColor = nil
        updateOutline()
        shapeLayer.lineWidth = 1
        layer.addSublayer(shapeLayer)
        label.text = element.label
        // Gameplay artwork keeps its type size; native settings still use Dynamic Type.
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        addSubview(label)
        if case .stick = element.shape {
            stickKnob.backgroundColor = UIColor(white: 0.96, alpha: 0.35)
            stickKnob.isUserInteractionEnabled = false
            addSubview(stickKnob)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func updateOutline() {
        shapeLayer.strokeColor = skinAccent?.withAlphaComponent(0.85).cgColor
            ?? UIColor(red: 0.96, green: 0.95, blue: 0.93,
                       alpha: hasDedicatedBackground ? 0.75 : 0.3).cgColor
        shapeLayer.lineWidth = UIAccessibility.isDarkerSystemColorsEnabled ? 2 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = Self.path(for: element.shape, in: bounds)
        shapeLayer.frame = bounds
        shapeLayer.path = path.cgPath
        let mask = CAShapeLayer(); mask.path = path.cgPath
        fill.frame = bounds
        fill.layer.mask = mask
        let overlayMask = CAShapeLayer(); overlayMask.path = path.cgPath
        pressedOverlay.frame = bounds
        pressedOverlay.layer.mask = overlayMask
        label.frame = bounds
        if case .stick = element.shape {
            let diameter = bounds.width * 0.38
            stickKnob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            stickKnob.layer.cornerRadius = diameter / 2
            stickKnob.center = CGPoint(x: bounds.midX + stickPosition.x * bounds.width * 0.3,
                                      y: bounds.midY + stickPosition.y * bounds.height * 0.3)
        }
    }

    func setStickPosition(_ position: CGPoint) {
        stickPosition = position
        setNeedsLayout()
    }

    func setHighlighted(_ pressed: Set<TouchControl>) {
        let active: Bool
        if case .dpad = element.shape {
            active = !pressed.isDisjoint(with: [.up, .down, .left, .right])
        } else {
            active = pressed.contains(element.control)
        }
        pressedOverlay.isHidden = !active
    }

    static func path(for shape: TouchLayoutElement.Shape, in rect: CGRect) -> UIBezierPath {
        UIBezierPath(cgPath: shape.outline(in: rect))
    }

    static func accessibilityName(for element: TouchLayoutElement) -> String {
        if case .dpad = element.shape { return String(localized: "Directional pad", bundle: .module) }
        switch element.control {
        case .leftStick: return String(localized: "Left analog stick", bundle: .module)
        case .rightStick: return String(localized: "Right analog stick", bundle: .module)
        case .start: return String(localized: "Start", bundle: .module)
        case .select: return String(localized: "Select", bundle: .module)
        default: return element.label
        }
    }
}


/// SwiftUI host for the kit.
public struct TouchControls: UIViewRepresentable {
    private let layout: TouchLayout
    private let haptics: Bool
    private let skin: RelaySkinConfiguration?
    private let skinSystem: SystemID
    private let opacity: Double
    private let hasDedicatedBackground: Bool
    private let isEnabled: Bool
    private let onChange: (TouchControl, Bool) -> Void
    private let onTwoFingerTap: () -> Void
    private let onStick: (TouchControl, CGPoint) -> Void

    public init(layout: TouchLayout, haptics: Bool, opacity: Double, hasDedicatedBackground: Bool = false,
                isEnabled: Bool = true, skin: RelaySkinConfiguration? = nil, skinSystem: SystemID = .gameBoyAdvance,
                onChange: @escaping (TouchControl, Bool) -> Void,
                onStick: @escaping (TouchControl, CGPoint) -> Void = { _, _ in },
                onTwoFingerTap: @escaping () -> Void) {
        self.layout = layout
        self.skin = skin
        self.skinSystem = skinSystem
        self.haptics = haptics
        self.opacity = opacity
        self.hasDedicatedBackground = hasDedicatedBackground
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.onStick = onStick
        self.onTwoFingerTap = onTwoFingerTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onStick: onStick, onTwoFingerTap: onTwoFingerTap) }

    public func makeUIView(context: Context) -> TouchControlView {
        let view = TouchControlView(layout: layout)
        view.delegate = context.coordinator
        view.skinSystem = skinSystem
        view.skin = skin
        view.hapticsEnabled = haptics
        view.activeOpacity = opacity
        view.hasDedicatedBackground = hasDedicatedBackground
        view.isUserInteractionEnabled = isEnabled
        return view
    }

    public func updateUIView(_ uiView: TouchControlView, context: Context) {
        if uiView.skinSystem != skinSystem { uiView.skinSystem = skinSystem }
        if uiView.skin != skin { uiView.skin = skin }
        if uiView.layout != layout { uiView.releaseAll(); uiView.layout = layout }
        uiView.hapticsEnabled = haptics
        uiView.activeOpacity = opacity
        if uiView.hasDedicatedBackground != hasDedicatedBackground {
            uiView.hasDedicatedBackground = hasDedicatedBackground
        }
        if uiView.isUserInteractionEnabled != isEnabled { uiView.isUserInteractionEnabled = isEnabled }
        context.coordinator.onChange = onChange
        context.coordinator.onStick = onStick
        context.coordinator.onTwoFingerTap = onTwoFingerTap
    }

    public static func dismantleUIView(_ uiView: TouchControlView, coordinator: Coordinator) {
        uiView.detachTwoFingerTap()
        uiView.releaseAll()
    }

    @MainActor
    public final class Coordinator: TouchControlDelegate {
        var onChange: (TouchControl, Bool) -> Void
        var onStick: (TouchControl, CGPoint) -> Void
        var onTwoFingerTap: () -> Void
        init(onChange: @escaping (TouchControl, Bool) -> Void, onStick: @escaping (TouchControl, CGPoint) -> Void = { _, _ in }, onTwoFingerTap: @escaping () -> Void) {
            self.onChange = onChange
            self.onStick = onStick
            self.onTwoFingerTap = onTwoFingerTap
        }
        public func touchControl(_ control: TouchControl, pressed: Bool) { onChange(control, pressed) }
        public func touchStick(_ control: TouchControl, position: CGPoint) { onStick(control, position) }
        public func touchControlsTwoFingerTap() { onTwoFingerTap() }
    }
}
#endif
