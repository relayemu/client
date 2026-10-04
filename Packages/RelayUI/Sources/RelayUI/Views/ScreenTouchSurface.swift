// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS)
import SwiftUI
import UIKit
import RelayEmulation
import RelayVideo

/// Direct input for a logical screen that accepts a single stylus. UIKit sends
/// down/up immediately; gesture recognition must not compress a short tap into
/// one emulation frame. The video presenter remains the coordinate authority.
struct ScreenTouchSurface: UIViewRepresentable {
    let source: any VideoFrameSource
    let options: DisplayOptions
    let displayScale: CGFloat
    let isEnabled: Bool
    let onTouch: (Int, Int) -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> ScreenTouchView {
        let view = ScreenTouchView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: ScreenTouchView, context: Context) {
        uiView.configure(source: source, options: options, displayScale: displayScale,
                         isEnabled: isEnabled, onTouch: onTouch, onRelease: onRelease)
    }

    static func dismantleUIView(_ uiView: ScreenTouchView, coordinator: ()) {
        uiView.releaseAll()
    }
}

@MainActor
final class ScreenTouchView: UIView {
    private var source: (any VideoFrameSource)?
    private var options = DisplayOptions.standard
    private var displayScale: CGFloat = 1
    private var onTouch: (Int, Int) -> Void = { _, _ in }
    private var onRelease: () -> Void = {}
    private var trackedTouch: ObjectIdentifier?
    private var stylusDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(source: any VideoFrameSource, options: DisplayOptions, displayScale: CGFloat,
                   isEnabled: Bool, onTouch: @escaping (Int, Int) -> Void, onRelease: @escaping () -> Void) {
        if self.source !== source || self.options != options || self.displayScale != displayScale || !isEnabled {
            // Release through the old callback before changing screen ownership.
            releaseAll()
        }
        self.source = source
        self.options = options
        self.displayScale = displayScale
        self.onTouch = onTouch
        self.onRelease = onRelease
        isUserInteractionEnabled = isEnabled
    }

    override var bounds: CGRect {
        didSet {
            if bounds != oldValue { releaseAll() }
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { releaseAll() }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseAll() }
    }

    /// Letterbox taps belong to the existing reveal surface underneath. The
    /// ancestor two-finger toggle still observes both views without interception.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isUserInteractionEnabled && nativePoint(at: point) != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isUserInteractionEnabled, trackedTouch == nil,
              let first = touches.min(by: { $0.timestamp < $1.timestamp }),
              let point = nativePoint(at: first.location(in: self)) else { return }
        trackedTouch = ObjectIdentifier(first)
        stylusDown = true
        onTouch(point.x, point.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isUserInteractionEnabled,
              let touch = touches.first(where: { ObjectIdentifier($0) == trackedTouch }) else { return }
        if let point = nativePoint(at: touch.location(in: self)) {
            stylusDown = true
            onTouch(point.x, point.y)
        } else {
            // Keep tracking this finger so reentry works, but never hand the
            // stylus to a second finger that began during the same contact.
            releaseStylus()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { ObjectIdentifier($0) == trackedTouch }) { releaseAll() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { ObjectIdentifier($0) == trackedTouch }) { releaseAll() }
    }

    func releaseAll() {
        releaseStylus()
        trackedTouch = nil
    }

    private func releaseStylus() {
        guard stylusDown else { return }
        stylusDown = false
        onRelease()
    }

    private func nativePoint(at point: CGPoint) -> (x: Int, y: Int)? {
        guard bounds.contains(point), let source else { return nil }
        let localPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        return MetalFrameView.nativePoint(for: localPoint, frame: source.frameDescriptor,
                                         in: bounds.size, options: options, displayScale: displayScale)
    }
}
#endif
