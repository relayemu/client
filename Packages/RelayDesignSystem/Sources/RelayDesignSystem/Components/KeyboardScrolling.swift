// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

#if os(macOS)
import AppKit

private struct RelayKeyboardScrollScopeKey: EnvironmentKey {
    static let defaultValue: RelayKeyboardScrollScope? = nil
}

private extension EnvironmentValues {
    var relayKeyboardScrollScope: RelayKeyboardScrollScope? {
        get { self[RelayKeyboardScrollScopeKey.self] }
        set { self[RelayKeyboardScrollScopeKey.self] = newValue }
    }
}

@MainActor
private struct RelayKeyboardScrollContainer: ViewModifier {
    @State private var scope = RelayKeyboardScrollScope()

    func body(content: Content) -> some View {
        content
            .environment(\.relayKeyboardScrollScope, scope)
            .background {
                RelayNativeKeyboardContainer(scope: scope)
                    .focusable(false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct RelayKeyboardScrollTarget: ViewModifier {
    @Environment(\.relayKeyboardScrollScope) private var scope

    func body(content: Content) -> some View {
        content.background {
            RelayNativeKeyboardTarget(scope: scope)
                .focusable(false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Follow AppKit keyboard traversal and reveal its native control. SwiftUI can
/// leave reverse traversal on a retired, non-key focus proxy at a sheet edge;
/// continue that same native traversal without registering replacement key views.
@MainActor
private final class RelayKeyboardScrollScope {
    private struct WeakTarget {
        weak var view: RelayNativeKeyboardTargetView?
    }

    private var targets: [ObjectIdentifier: WeakTarget] = [:]
    private weak var container: NSView?
    private weak var observedWindow: NSWindow?
    private var keyMonitor: Any?
    private var responderObservation: NSKeyValueObservation?
    private var revealQueued = false
    private var pendingTabIsBackward: Bool?

    func register(_ view: RelayNativeKeyboardTargetView) {
        targets[ObjectIdentifier(view)] = WeakTarget(view: view)
    }

    func unregister(_ view: RelayNativeKeyboardTargetView) {
        targets.removeValue(forKey: ObjectIdentifier(view))
    }

    func observe(window: NSWindow?, in view: NSView) {
        guard container !== view || observedWindow !== window else { return }
        stopObserving()
        container = view
        observedWindow = window
        guard let window else { return }

        // A SwiftUI focus move can leave NSWindow.firstResponder on the same
        // hosting view. Observe native Tab/arrow handling as well as responder
        // changes, always returning the exact event to AppKit.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.observedWindow,
                      event.keyCode == 48 || (123...126).contains(event.keyCode) else { return }
                if event.keyCode == 48 {
                    self.pendingTabIsBackward = event.modifierFlags.contains(.shift)
                }
                self.queueReveal()
            }
            return event
        }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.queueReveal() }
        }
    }

    func stopObserving(in view: NSView) {
        guard container === view else { return }
        stopObserving()
    }

    private func stopObserving() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        responderObservation?.invalidate()
        responderObservation = nil
        observedWindow = nil
        container = nil
        pendingTabIsBackward = nil
    }

    private func queueReveal() {
        guard !revealQueued else { return }
        revealQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revealQueued = false
            if let backward = self.pendingTabIsBackward {
                self.pendingTabIsBackward = nil
                self.continuePastInactiveKeyView(backward: backward)
            }
            self.revealFocusedTarget()
        }
    }

    private func continuePastInactiveKeyView(backward: Bool) {
        guard let window = observedWindow, window.isKeyWindow,
              let container, container.window === window,
              !container.isHiddenOrHasHiddenAncestor,
              let responder = window.firstResponder as? NSView,
              !responder.canBecomeKeyView, !responder.acceptsFirstResponder else { return }
        // AppKit supplies the next valid control, including the sheet toolbar.
        // Never replace a valid SwiftUI control or repeat a failed traversal.
        let next = backward ? responder.previousValidKeyView : responder.nextValidKeyView
        if let next, next !== responder { window.makeFirstResponder(next) }
    }

    private func revealFocusedTarget() {
        guard let window = observedWindow, window.isKeyWindow,
              let container, container.window === window,
              !container.isHiddenOrHasHiddenAncestor else { return }
        let responder = window.firstResponder as? NSView
        // These are in-process AppKit objects, not AXUIElement queries against
        // another application. Different native controls expose focus at
        // different points in this hierarchy.
        var focusFrames = [window.accessibilityFocusedUIElement,
                           responder?.accessibilityFocusedUIElement,
                           NSApplication.shared.accessibilityFocusedUIElement]
            .compactMap { accessibilityFrame(of: $0) }
        if let responder {
            focusFrames.append(window.convertToScreen(responder.convert(responder.bounds, to: nil)))
        }
        focusFrames = focusFrames.filter { !$0.isEmpty && !$0.isInfinite }
        guard !focusFrames.isEmpty else { return }

        // Match only controls registered by this container. SwiftUI may expose
        // a label's bounds rather than the whole styled button; allow contained
        // label bounds, but never treat a window/hosting-view frame as a match.
        targets = targets.filter { $0.value.view != nil }
        let target = targets.values.compactMap { candidate -> (NSView, CGFloat)? in
            guard let view = candidate.view, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, view.enclosingScrollView != nil else { return nil }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            guard !frame.isEmpty else { return nil }
            let score = focusFrames.compactMap { focusFrame -> CGFloat? in
                let overlap = frame.intersection(focusFrame)
                guard !overlap.isEmpty,
                      frame.insetBy(dx: -4, dy: -4).contains(NSPoint(x: focusFrame.midX, y: focusFrame.midY)) else { return nil }
                return overlap.width * overlap.height / max(frame.width * frame.height, focusFrame.width * focusFrame.height)
            }.max()
            guard let score, score >= 0.25 else { return nil }
            return (view, score)
        }.max { $0.1 < $1.1 }?.0
        guard let target else { return }

        // Each rectangle is converted through the actual native hierarchy.
        // This handles a horizontal shelf nested in a vertical page without
        // moving an unrelated scroll view or changing the focused control.
        var scrollView = target.enclosingScrollView
        var visited: Set<ObjectIdentifier> = []
        while let scroll = scrollView, scroll.window === window,
              visited.insert(ObjectIdentifier(scroll)).inserted {
            guard let document = scroll.documentView, target.isDescendant(of: document) else { break }
            let rect = document.convert(target.bounds.insetBy(dx: -4, dy: -4), from: target)
            let viewport = scroll.documentVisibleRect
            // Leave room on both sides of the focused control. A minimum
            // reveal leaves it at the viewport edge, keeping its next native
            // Tab neighbor offscreen and sending traversal to the toolbar.
            let horizontalRoom = document.bounds.width > viewport.width ? max(0, viewport.width - rect.width) / 2 : 0
            let verticalRoom = document.bounds.height > viewport.height ? max(0, viewport.height - rect.height) / 2 : 0
            let revealRect = rect.insetBy(dx: -horizontalRoom, dy: -verticalRoom).intersection(document.bounds)
            document.scrollToVisible(revealRect)
            scrollView = scroll.superview?.enclosingScrollView
        }
    }

    private func accessibilityFrame(of element: Any?) -> NSRect? {
        if let element = element as? any NSAccessibilityProtocol { return element.accessibilityFrame() }
        if let element = element as? any NSAccessibilityElementProtocol { return element.accessibilityFrame() }
        return nil
    }
}

/// Geometry markers are absent from hit testing, accessibility and key views.
private class RelayKeyboardGeometryView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private final class RelayNativeKeyboardContainerView: RelayKeyboardGeometryView {
    let scope: RelayKeyboardScrollScope

    init(scope: RelayKeyboardScrollScope) {
        self.scope = scope
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scope.observe(window: window, in: self)
    }
}

private struct RelayNativeKeyboardContainer: NSViewRepresentable {
    let scope: RelayKeyboardScrollScope

    func makeNSView(context: Context) -> RelayNativeKeyboardContainerView {
        RelayNativeKeyboardContainerView(scope: scope)
    }

    func updateNSView(_ view: RelayNativeKeyboardContainerView, context: Context) {}

    static func dismantleNSView(_ view: RelayNativeKeyboardContainerView, coordinator: ()) {
        view.scope.stopObserving(in: view)
    }
}

private final class RelayNativeKeyboardTargetView: RelayKeyboardGeometryView {
    private weak var scope: RelayKeyboardScrollScope?

    func register(in scope: RelayKeyboardScrollScope?) {
        guard self.scope !== scope else { return }
        self.scope?.unregister(self)
        self.scope = scope
        scope?.register(self)
    }
}

private struct RelayNativeKeyboardTarget: NSViewRepresentable {
    let scope: RelayKeyboardScrollScope?

    func makeNSView(context: Context) -> RelayNativeKeyboardTargetView {
        let view = RelayNativeKeyboardTargetView()
        view.register(in: scope)
        return view
    }

    func updateNSView(_ view: RelayNativeKeyboardTargetView, context: Context) {
        view.register(in: scope)
    }

    static func dismantleNSView(_ view: RelayNativeKeyboardTargetView, coordinator: ()) {
        view.register(in: nil)
    }
}
#endif

public extension View {
    /// Follow native Mac keyboard focus through the control's real scroll views.
    @ViewBuilder func relayKeyboardScrollContainer() -> some View {
        #if os(macOS)
        modifier(RelayKeyboardScrollContainer())
        #else
        self
        #endif
    }

    /// Register geometry only; the existing native control retains its focus.
    @ViewBuilder func relayScrollToKeyboardFocus() -> some View {
        #if os(macOS)
        modifier(RelayKeyboardScrollTarget())
        #else
        self
        #endif
    }
}
