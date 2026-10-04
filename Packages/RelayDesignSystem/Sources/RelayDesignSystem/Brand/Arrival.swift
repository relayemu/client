// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  Arrival.swift
//
//  Relay's whole promise is that progress moves between screens, so movement is the
//  one thing the app is allowed to be theatrical about — once, briefly, and only
//  when something genuinely arrived from somewhere else.
//
//  The gesture is the mark itself: the Ember capsule of the Baton sweeps across the
//  surface along the mark's own −45° diagonal, the way the trail capsule follows the
//  lead one. Healthy, quiet, already-seen sync animates nothing at all (§10 of the
//  brief: "healthy sync remains quiet").

import SwiftUI

public extension View {
    /// Play the arrival once when `active` becomes true. Reduce Motion keeps the
    /// meaning and drops the movement: the edge lights up and fades, nothing travels.
    func relayArrival(_ active: Bool, reduceMotion: Bool) -> some View {
        modifier(RelayArrival(active: active, reduceMotion: reduceMotion))
    }
}

struct RelayArrival: ViewModifier {
    let active: Bool
    let reduceMotion: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay { if active { sweep } }
            .onAppear { start() }
            .onChange(of: active) { _, now in if now { phase = 0; start() } }
    }

    private func start() {
        guard active else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.5) : .relayArrival.delay(0.08)) { phase = 1 }
    }

    @ViewBuilder
    private var sweep: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: RelayRadius.l, style: .continuous)
                .strokeBorder(RelayColor.ember, lineWidth: 2)
                .opacity(1 - Double(phase))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            GeometryReader { proxy in
                let travel = proxy.size.width + proxy.size.height
                Capsule(style: .continuous)
                    .fill(RelayColor.ember)
                    .frame(width: travel * 0.34, height: max(3, proxy.size.height * 0.045))
                    .rotationEffect(.degrees(-45))
                    .offset(x: -travel * 0.35 + travel * 1.1 * phase,
                            y: travel * 0.35 - travel * 1.1 * phase)
                    // In at the start, out at the end: the pass is a glance, not a banner.
                    .opacity(phase <= 0.001 ? 0 : Double(min(phase * 4, 1) * min((1 - phase) * 3.2, 1)))
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
