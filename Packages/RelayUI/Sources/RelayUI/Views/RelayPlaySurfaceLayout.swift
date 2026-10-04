// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import RelayDomain
import RelayVideo
import RelayDesignSystem

/// Geometry of the current play container, never of a device model or screen.
/// The control canvas stays canonical even when the pictures fit a tighter stack,
/// so existing custom coordinates and an editor save describe the same surface.
struct RelayPlaySurfaceLayout: Equatable {
    let size: CGSize
    let isWide: Bool
    let controlScale: CGFloat
    let contentFrame: CGRect
    let gameFrame: CGRect
    let controlFrame: CGRect
    let touchLayout: TouchLayout
    /// Presentation only. The caller retains the original custom layout for
    /// saving and for restoring its placement when the window grows again.
    let usesCustomLayoutFallback: Bool

    init(size: CGSize, safeArea: EdgeInsets = EdgeInsets(), showsTouchControls: Bool,
         controls: SystemInputLayout? = nil, screens: [LogicalScreen] = [],
         preferredArrangement: ScreenArrangement? = nil, scaling: DisplayScaling = .fit,
         displayScale: CGFloat = 1, customTouchLayout: TouchLayout? = nil) {
        self.size = size
        let isWide = size.width > size.height
        self.isWide = isWide
        let controlScale: CGFloat = min(size.width, size.height) >= 600 ? 1.2 : 1
        self.controlScale = controlScale
        // SwiftUI callers already receive safe content bounds. Explicit insets
        // remain available for containers that have not excluded system edges.
        let usable = CGRect(x: max(0, safeArea.leading), y: max(0, safeArea.top),
                            width: max(0, size.width - max(0, safeArea.leading) - max(0, safeArea.trailing)),
                            height: max(0, size.height - max(0, safeArea.top) - max(0, safeArea.bottom)))
        contentFrame = usable
        let fallback = controls.map { TouchLayout.layout(for: $0, portrait: !isWide, scale: controlScale) }
            ?? TouchLayout(elements: [])
        let minimumControlHeight = fallback.minimumReachHeight(portrait: !isWide)
        var deckHeight = showsTouchControls && !isWide
            ? min(usable.height, max(min(usable.height * 0.48, 320 * controlScale),
                                    minimumControlHeight > 0 ? minimumControlHeight + 24 : 0)) : 0
        func controlCanvas(_ height: CGFloat) -> CGRect {
            let area = height > 0
                ? CGRect(x: usable.minX, y: usable.maxY - height, width: usable.width, height: height) : usable
            let horizontalMargin = min(24, area.width / 4)
            let bottomMargin = min(24, area.height / 4)
            return CGRect(x: area.minX + horizontalMargin, y: area.minY,
                          width: max(0, area.width - 2 * horizontalMargin),
                          height: max(0, area.height - bottomMargin))
        }
        func defaultLayout(_ template: TouchLayout, in frame: CGRect) -> TouchLayout {
            let anchored = template.anchoredForReach(in: frame.size, portrait: !isWide)
            return isWide ? anchored : Self.separatingDefaultDPad(anchored, in: frame)
        }
        var canonicalControls = controlCanvas(deckHeight)
        var baselineLayout = defaultLayout(fallback, in: canonicalControls)
        // A short portrait can compress the deck just enough that the cross
        // cannot clear Y without hitting Start/Select. Restore only the missing
        // space, up to the existing normal deck bound, before accepting that
        // placement. Point sizes and saved normalized coordinates are unchanged.
        let normalDeckHeight = min(usable.height, 320 * controlScale)
        while showsTouchControls && !isWide && deckHeight < normalDeckHeight
                && !Self.hasUsableControlTargets(baselineLayout, in: canonicalControls) {
            deckHeight = min(normalDeckHeight, ceil(deckHeight) + 1)
            canonicalControls = controlCanvas(deckHeight)
            baselineLayout = defaultLayout(fallback, in: canonicalControls)
        }
        // A narrow/short resizable window may not fit the full cross beside
        // the other groups. Keep every button's size and reduce only the
        // default cross, down to the existing supported D-pad size bounds.
        // Custom data is neither scaled nor rewritten.
        if !Self.hasUsableControlTargets(baselineLayout, in: canonicalControls),
           let pad = fallback.elements.first(where: { if case .dpad = $0.shape { return true }; return false }) {
            let minimumSpan = (pad.shape.size.width <= 112 * controlScale ? 96 : 112) * controlScale
            let reduction = Int(max(0, ceil(pad.shape.size.width - minimumSpan)))
            for points in 0..<reduction {
                let span = max(minimumSpan, pad.shape.size.width - CGFloat(points + 1))
                let smaller = TouchLayoutElement(pad.control, .dpad(span: span), at: pad.center, label: pad.label)
                let candidate = defaultLayout(fallback.replacing(smaller), in: canonicalControls)
                if Self.hasUsableControlTargets(candidate, in: canonicalControls) {
                    baselineLayout = candidate
                    break
                }
            }
        }
        let baselineGame = showsTouchControls && isWide && !baselineLayout.elements.isEmpty
            ? Self.landscapePictureArea(in: usable, controls: baselineLayout, frame: canonicalControls)
            : CGRect(x: usable.minX, y: usable.minY, width: usable.width,
                     height: max(0, usable.height - deckHeight))
        controlFrame = canonicalControls
        // Repair only in memory. Fitting is a rendering operation, not a rewrite
        // of valid normalized custom coordinates when the container resizes.
        let custom = customTouchLayout?.repaired(using: fallback)
        guard showsTouchControls else {
            gameFrame = baselineGame
            touchLayout = TouchLayout(elements: [])
            usesCustomLayoutFallback = false
            return
        }
        let portrait: (game: CGRect, layout: TouchLayout)?
        if !isWide, preferredArrangement == nil || preferredArrangement == .stacked,
           screens.count == 2, screens[1].acceptsTouch {
            portrait = Self.portraitStack(in: usable, baselineGame: baselineGame,
                                          controlFrame: canonicalControls, baselineLayout: baselineLayout,
                                          screens: screens, scaling: scaling, displayScale: displayScale)
        } else {
            portrait = nil
        }
        let currentDefault = portrait?.layout ?? baselineLayout
        let needsFallback = custom.map { layout in
            !Self.hasUsableControlTargets(layout, in: canonicalControls)
                || (!Self.isClear(layout, in: canonicalControls, of: baselineGame, minimumGap: 0)
                    && !(portrait.map { Self.isClear(layout, in: canonicalControls, of: $0.game) } ?? false))
        } ?? false
        usesCustomLayoutFallback = needsFallback && Self.hasUsableControlTargets(currentDefault, in: canonicalControls)
        let effectiveCustom = usesCustomLayoutFallback ? nil : custom
        if let portrait {
            let effective = effectiveCustom ?? portrait.layout
            if Self.isClear(effective, in: canonicalControls, of: portrait.game) {
                gameFrame = portrait.game
                touchLayout = effective
                return
            }
        }
        gameFrame = baselineGame
        touchLayout = effectiveCustom ?? baselineLayout
    }

    /// Project the same fitted control center into an editor canvas. Preview
    /// scaling must not add another unscaled margin or move saved coordinates.
    func previewCenter(for element: TouchLayoutElement, in canvas: CGSize) -> CGPoint {
        let center = element.fittedCenter(in: controlFrame.size)
        return CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
    }

    func previewSize(for element: TouchLayoutElement, in canvas: CGSize) -> CGSize {
        let factor = canvas.width / max(1, controlFrame.width)
        return CGSize(width: element.shape.size.width * factor, height: element.shape.size.height * factor)
    }

    var pauseButtonFrame: CGRect {
        let side: CGFloat = 40, margin: CGFloat = 16
        let preferred = CGRect(x: contentFrame.maxX - margin - side,
                               y: contentFrame.minY + margin, width: side, height: side)
        let excluded = touchLayout.elements.map {
            Self.visibleBox($0, in: controlFrame).insetBy(dx: -(Self.hitExpansion + 4), dy: -(Self.hitExpansion + 4))
        }
        if excluded.allSatisfy({ !$0.intersects(preferred) }) { return preferred }
        // Prefer the nearest free position on the same top row; if needed,
        // consider the edges of actual controls instead of a device-specific
        // offset. Even the hidden button's reveal point must not press R.
        let xs = [preferred.minX, contentFrame.minX + margin]
            + excluded.flatMap { [$0.minX - side, $0.maxX] }
        let ys = [preferred.minY, contentFrame.maxY - margin - side]
            + excluded.flatMap { [$0.minY - side, $0.maxY] }
        let candidates = xs.flatMap { x in ys.map { CGRect(x: x, y: $0, width: side, height: side) } }
            .filter { candidate in contentFrame.insetBy(dx: margin, dy: margin).contains(candidate)
                && excluded.allSatisfy { !$0.intersects(candidate) } }
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = frame.minX - preferred.minX, dy = frame.minY - preferred.minY
            return dx * dx + dy * dy
        }
        let topRow = candidates.filter { $0.minY == preferred.minY }
        return (topRow.isEmpty ? candidates : topRow).min { distance($0) < distance($1) } ?? preferred
    }

    /// A saved/editor layout must not put a game button over a picture or its
    /// direct-touch surface. Invalid placement is presentation-only fallback;
    /// the caller keeps the original persisted coordinates.
    func acceptsControls(_ layout: TouchLayout) -> Bool {
        Self.hasUsableControlTargets(layout, in: controlFrame)
            && Self.isClear(layout, in: controlFrame, of: gameFrame, minimumGap: 0)
    }

    /// Landscape has explicit left/right grips and a bottom system-button row.
    /// The picture receives the remaining rectangle, never the whole container
    /// with an assumption that its letterboxing will happen to clear controls.
    private static func landscapePictureArea(in usable: CGRect, controls: TouchLayout, frame: CGRect) -> CGRect {
        var left = usable.minX, right = usable.maxX, bottom = usable.maxY
        let leftControls: Set<TouchControl> = [.up, .l, .l2, .leftStick, .l3, .cUp, .cDown, .cLeft, .cRight]
        for element in controls.elements {
            let exclusion = visibleBox(element, in: frame)
                .insetBy(dx: -(hitExpansion + pictureClearance), dy: -(hitExpansion + pictureClearance))
            if [.start, .select].contains(element.control) {
                bottom = min(bottom, exclusion.minY)
            } else if leftControls.contains(element.control) {
                left = max(left, exclusion.maxX)
            } else {
                right = min(right, exclusion.minX)
            }
        }
        return CGRect(x: min(usable.maxX, left), y: usable.minY,
                      width: max(0, right - left), height: max(0, bottom - usable.minY))
    }

    /// A button's center must activate that button alone. D-pad direction
    /// targets must also remain independent, and visible shapes must be clear.
    /// The touch kit still accepts full expanded rectangles, including D-pad
    /// corners, for rolling input; overlapping hit-box edges alone are allowed.
    static func hasUsableControlTargets(_ layout: TouchLayout, in frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return layout.elements.isEmpty }
        let boxes = layout.elements.map { visibleBox($0, in: frame) }
        let hits = boxes.map { $0.insetBy(dx: -hitExpansion, dy: -hitExpansion) }
        for index in layout.elements.indices {
            let element = layout.elements[index], box = boxes[index]
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0,
                  frame.contains(hits[index]) else { return false }
            var targets = [CGPoint(x: box.midX, y: box.midY)]
            if case .dpad(let span) = element.shape {
                let step = span * 0.32
                targets += [CGPoint(x: -step, y: 0), CGPoint(x: step, y: 0),
                            CGPoint(x: 0, y: -step), CGPoint(x: 0, y: step)].map {
                    CGPoint(x: box.midX + $0.x, y: box.midY + $0.y)
                }
            }
            for other in layout.elements.indices where other != index {
                if targets.contains(where: { hits[other].contains($0) }) { return false }
                // Leave visible air around even the two-point high-contrast
                // strokes, not merely non-overlapping mathematical fill paths.
                if visibleClearance(element, layout.elements[other], in: frame) < 4 - 0.000001 { return false }
            }
        }
        return true
    }

    private struct RoundedRegion {
        let core: CGRect
        let radius: CGFloat

        init(_ box: CGRect, radius: CGFloat) {
            core = box.insetBy(dx: radius, dy: radius)
            self.radius = radius
        }
    }

    /// Matches the UIKit control paths: circles, capsules, and the union of
    /// two rounded arms for the D-pad (34% span, corner radius 30% arm).
    private static func visibleRegions(_ element: TouchLayoutElement, in frame: CGRect) -> [RoundedRegion] {
        let box = visibleBox(element, in: frame)
        if case .dpad = element.shape {
            let arm = box.width * 0.34, radius = arm * 0.3
            return [RoundedRegion(CGRect(x: box.midX - arm / 2, y: box.minY, width: arm, height: box.height), radius: radius),
                    RoundedRegion(CGRect(x: box.minX, y: box.midY - arm / 2, width: box.width, height: arm), radius: radius)]
        }
        return [RoundedRegion(box, radius: min(box.width, box.height) / 2)]
    }

    static func visibleClearance(_ first: TouchLayoutElement, _ second: TouchLayoutElement, in frame: CGRect) -> CGFloat {
        var clearance = CGFloat.greatestFiniteMagnitude
        for left in visibleRegions(first, in: frame) {
            for right in visibleRegions(second, in: frame) {
                let dx = max(0, max(left.core.minX - right.core.maxX, right.core.minX - left.core.maxX))
                let dy = max(0, max(left.core.minY - right.core.maxY, right.core.minY - left.core.maxY))
                clearance = min(clearance, (dx * dx + dy * dy).squareRoot() - left.radius - right.radius)
            }
        }
        return clearance
    }

    /// If a narrow default grip puts its cross into a face button, lower only
    /// the D-pad by the amount required by the actual rounded outlines. The
    /// footer bounds that move; neither the deck nor the pictures grow/shrink.
    private static func separatingDefaultDPad(_ layout: TouchLayout, in frame: CGRect) -> TouchLayout {
        let gap: CGFloat = 4
        guard frame.width > 0, frame.height > 0,
              let pad = layout.elements.first(where: { if case .dpad = $0.shape { return true }; return false }),
              let footerTop = layout.elements.filter({ [.start, .select].contains($0.control) })
                .map({ visibleBox($0, in: frame).minY }).min() else { return layout }
        let conflicts = layout.elements.filter { $0.control != pad.control && visibleClearance(pad, $0, in: frame) < gap }
        guard !conflicts.isEmpty else { return layout }
        let padBox = visibleBox(pad, in: frame)
        let maximumY = footerTop - gap - padBox.height / 2
        var requiredMove: CGFloat = 0
        for other in conflicts {
            for arm in visibleRegions(pad, in: frame) {
                for region in visibleRegions(other, in: frame) {
                    let dx = max(0, max(arm.core.minX - region.core.maxX, region.core.minX - arm.core.maxX))
                    let distance = arm.radius + region.radius + gap
                    if dx < distance {
                        let dy = (distance * distance - dx * dx).squareRoot()
                        requiredMove = max(requiredMove, region.core.maxY + dy - arm.core.minY)
                    }
                }
            }
        }
        // A still smaller canvas may have no such placement. Keep the original
        // geometry in that case rather than shrinking pictures or raw controls.
        guard requiredMove > 0, padBox.midY + requiredMove <= maximumY else { return layout }
        let y = min(maximumY, frame.minY + ceil(padBox.midY - frame.minY + requiredMove))
        let moved = pad.moved(to: CGPoint(x: pad.center.x, y: (y - frame.minY) / frame.height))
        let candidate = layout.replacing(moved)
        guard candidate.elements.filter({ $0.control != pad.control }).allSatisfy({ visibleClearance(moved, $0, in: frame) >= gap }),
              hasUsableControlTargets(candidate, in: frame) else { return layout }
        return candidate
    }

    // Match the touch kit's hit expansion; the 7.5-point picture separation
    // accommodates the half-point grid without an exception for a device/size.
    private static let hitExpansion: CGFloat = 6
    private static let pictureClearance: CGFloat = 7.5

    private static func visibleBox(_ element: TouchLayoutElement, in frame: CGRect) -> CGRect {
        let point = element.fittedCenter(in: frame.size)
        return CGRect(x: frame.minX + point.x * frame.width - element.shape.size.width / 2,
                      y: frame.minY + point.y * frame.height - element.shape.size.height / 2,
                      width: element.shape.size.width, height: element.shape.size.height)
    }

    private static func isClear(_ layout: TouchLayout, in frame: CGRect, of game: CGRect,
                                minimumGap: CGFloat = pictureClearance) -> Bool {
        layout.elements.allSatisfy { element in
            let hit = visibleBox(element, in: frame).insetBy(dx: -hitExpansion, dy: -hitExpansion)
            let horizontalGap = max(game.minX - hit.maxX, hit.minX - game.maxX)
            let verticalGap = max(game.minY - hit.maxY, hit.minY - game.maxY)
            return frame.contains(hit) && max(horizontalGap, verticalGap) >= minimumGap
        }
    }

    private static func portraitStack(in usable: CGRect, baselineGame: CGRect, controlFrame: CGRect,
                                       baselineLayout: TouchLayout, screens: [LogicalScreen],
                                       scaling: DisplayScaling, displayScale: CGFloat) -> (game: CGRect, layout: TouchLayout)? {
        guard usable.width > 0, usable.height > 0, controlFrame.width > 0, controlFrame.height > 0,
              let screen = screens.first, screen.width > 0, screen.height > 0,
              screen.aspectRatio.isFinite, screen.aspectRatio > 0,
              screens.allSatisfy({ $0.width == screen.width && $0.height == screen.height && $0.aspectRatio == screen.aspectRatio }),
              scaling != .fill, displayScale.isFinite, displayScale > 0,
              baselineLayout.controls == Set<TouchControl>([.up, .a, .b, .x, .y, .l, .r, .start, .select]) else { return nil }
        let elements = Dictionary(uniqueKeysWithValues: baselineLayout.elements.map { ($0.control, $0) })
        guard let pad = elements[.up], let left = elements[.l], let right = elements[.r],
              let start = elements[.start], let select = elements[.select] else { return nil }
        func fitted(_ element: TouchLayoutElement, at point: CGPoint) -> TouchLayoutElement {
            let moved = element.moved(to: CGPoint(x: (point.x - controlFrame.minX) / controlFrame.width,
                                                  y: (point.y - controlFrame.minY) / controlFrame.height))
            return moved.moved(to: moved.fittedCenter(in: controlFrame.size))
        }
        // Use actual fitted shoulder edges: a requested outer inset of 24 can
        // become larger inside the canonical canvas's own padded bounds.
        let leftInset = fitted(left, at: CGPoint(x: usable.minX + 24 + left.shape.size.width / 2,
                                                y: visibleBox(left, in: controlFrame).midY))
        let rightInset = fitted(right, at: CGPoint(x: usable.maxX - 24 - right.shape.size.width / 2,
                                                  y: visibleBox(right, in: controlFrame).midY))
        let leftEdge = visibleBox(leftInset, in: controlFrame).maxX + hitExpansion + pictureClearance
        let rightEdge = visibleBox(rightInset, in: controlFrame).minX - hitExpansion - pictureClearance
        let availableWidth = 2 * min(usable.midX - leftEdge, rightEdge - usable.midX)
        let face = baselineLayout.elements.filter { [.a, .b, .x, .y].contains($0.control) }
            .map { visibleBox($0, in: controlFrame) }
        guard let faceTop = face.map(\.minY).min(), let faceBottom = face.map(\.maxY).max() else { return nil }
        let clusterHeight = max(pad.shape.size.height, faceBottom - faceTop)
        let systemHeight = max(start.shape.size.height, select.shape.size.height)
        // The lower picture remains eight points clear of expanded button hit
        // boxes, while control sizes, diamond spacing and footer stay bounded.
        let lowerGap = RelaySpacing.xs + hitExpansion
        let deck = lowerGap + clusterHeight + RelaySpacing.m + systemHeight + RelaySpacing.xs + 24
        let aspect = CGFloat(screen.aspectRatio)
        let limit = min(availableWidth, (usable.height - deck - RelaySpacing.xs) * aspect / 2)
        guard limit > 0 else { return nil }
        func pictureWidth(fitting width: CGFloat) -> CGFloat {
            if scaling == .integer {
                return CGFloat(screen.width) * max(1, floor(width * displayScale / CGFloat(screen.width))) / displayScale
            }
            return width
        }
        let width = pictureWidth(fitting: limit)
        let baselineWidth = pictureWidth(fitting: min(baselineGame.width, (baselineGame.height - RelaySpacing.xs) * aspect / 2))
        guard width <= limit, width >= baselineWidth else { return nil }
        let panelHeight = width / aspect
        let pairHeight = 2 * panelHeight + RelaySpacing.xs
        let pair = CGRect(x: usable.midX - width / 2, y: usable.maxY - deck - pairHeight,
                          width: width, height: pairHeight)
        guard usable.contains(pair) else { return nil }
        let clusterY = usable.maxY - deck + lowerGap + clusterHeight / 2
        let systemY = usable.maxY - 24 - RelaySpacing.xs - systemHeight / 2
        let layout = TouchLayout(elements: baselineLayout.elements.map { element in
            let old = visibleBox(element, in: controlFrame)
            var center = CGPoint(x: old.midX, y: old.midY)
            switch element.control {
            case .up: center.y = clusterY
            case .a, .b, .x, .y: center.y += clusterY - (faceTop + faceBottom) / 2
            case .start, .select: center.y = systemY
            case .l:
                center = CGPoint(x: usable.minX + 24 + old.width / 2,
                                 y: pair.maxY - RelaySpacing.xs - old.height / 2)
            case .r:
                center = CGPoint(x: usable.maxX - 24 - old.width / 2,
                                 y: pair.maxY - RelaySpacing.xs - old.height / 2)
            default: break
            }
            return fitted(element, at: center)
        })
        guard isClear(layout, in: controlFrame, of: pair),
              hasUsableControlTargets(layout, in: controlFrame) else { return nil }
        return (pair, layout)
    }
}

/// The raw draft is independent of its current presentation. Resizing and
/// selecting a control never adopt a fallback. The first actual, valid edit
/// starts from what the user sees; subsequent edits keep that working draft.
struct RelayTouchLayoutDraft: Equatable {
    var layout: TouchLayout
    var selected: TouchControl?
    var opacity: Double

    init(layout: TouchLayout = TouchLayout(elements: []), selected: TouchControl? = nil, opacity: Double = 0.55) {
        self.layout = layout
        self.selected = selected
        self.opacity = opacity
    }

    mutating func edit(_ control: TouchControl, on surface: RelayPlaySurfaceLayout,
                       change: (TouchLayoutElement) -> TouchLayoutElement) {
        guard let shown = surface.touchLayout.elements.first(where: { $0.control == control }) else { return }
        // Use the same size/coordinate limits as persistence before showing an
        // edit. Repair legacy missing controls only after an actual edit.
        let changedLayout = TouchLayout(elements: [change(shown)]).repaired(using: TouchLayout(elements: [shown]))
        guard let changed = changedLayout.elements.first, changed != shown else { return }
        let source = surface.usesCustomLayoutFallback ? surface.touchLayout : layout.repaired(using: surface.touchLayout)
        let candidate = source.replacing(changed)
        guard surface.acceptsControls(candidate) else { return }
        layout = candidate
        selected = control
    }
}

/// Keeps each logical screen in the same view while only its rectangle changes.
/// Explicit arrangements win. Automatic selection compares the space available
/// to both pictures, rather than treating every wider-than-tall view as landscape.
struct RelayLogicalScreenLayout {
    let arrangement: ScreenArrangement
    let frames: [CGRect]

    init(size: CGSize, screens: [LogicalScreen], preferred: ScreenArrangement?, gap: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        guard screens.count == 2, size.width > 0, size.height > 0 else {
            arrangement = preferred ?? .stacked
            frames = screens.map { _ in bounds }
            return
        }
        let gap = max(0, min(gap, min(size.width, size.height)))
        let stacked = [CGRect(x: 0, y: 0, width: size.width, height: (size.height - gap) / 2),
                       CGRect(x: 0, y: (size.height + gap) / 2, width: size.width, height: (size.height - gap) / 2)]
        let beside = [CGRect(x: 0, y: 0, width: (size.width - gap) / 2, height: size.height),
                      CGRect(x: (size.width + gap) / 2, y: 0, width: (size.width - gap) / 2, height: size.height)]
        func usefulArea(_ frames: [CGRect]) -> CGFloat {
            zip(frames, screens).map { frame, screen in
                let aspect = CGFloat(screen.aspectRatio)
                guard aspect.isFinite, aspect > 0 else { return CGFloat.zero }
                let height = min(frame.height, frame.width / aspect)
                return height * height * aspect
            }.min() ?? 0
        }
        arrangement = preferred ?? (usefulArea(beside) > usefulArea(stacked) ? .sideBySide : .stacked)
        switch arrangement {
        case .stacked: frames = stacked
        case .sideBySide: frames = beside
        case .primarySecondary, .secondaryPrimary:
            let preview = CGSize(width: size.width / 3, height: size.height / 3)
            let inset = min(16, min(size.width, size.height) / 12)
            let companion = CGRect(x: size.width - preview.width - inset,
                                   y: size.height - preview.height - inset,
                                   width: preview.width, height: preview.height)
            frames = arrangement == .primarySecondary ? [bounds, companion] : [companion, bounds]
        }
    }
}

private struct RelayPlaySurfaceSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var relayPlaySurfaceSize: CGSize {
        get { self[RelayPlaySurfaceSizeKey.self] }
        set { self[RelayPlaySurfaceSizeKey.self] = newValue }
    }
}
