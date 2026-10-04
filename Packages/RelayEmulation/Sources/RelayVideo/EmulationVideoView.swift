// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  EmulationVideoView.swift
//  RelayVideo
//
//  SwiftUI wrapper around MetalFrameView for all three platforms.

import SwiftUI
import RelayEmulation

#if canImport(UIKit)
import UIKit

public struct EmulationVideoView: UIViewRepresentable {
    private let source: VideoFrameSource?
    private let counter: PresentationCounter?
    private let options: DisplayOptions
    public init(source: VideoFrameSource?, counter: PresentationCounter? = nil, options: DisplayOptions = .standard) {
        self.source = source; self.counter = counter; self.options = options
    }

    public func makeUIView(context: Context) -> MetalFrameView {
        let view = MetalFrameView()
        view.frameSource = source
        view.presentationCounter = counter
        view.displayOptions = options
        return view
    }
    public func updateUIView(_ uiView: MetalFrameView, context: Context) {
        if uiView.frameSource !== source { uiView.frameSource = source }
        uiView.presentationCounter = counter
        uiView.displayOptions = options
    }
}
#elseif canImport(AppKit)
import AppKit

public struct EmulationVideoView: NSViewRepresentable {
    private let source: VideoFrameSource?
    private let counter: PresentationCounter?
    private let options: DisplayOptions
    public init(source: VideoFrameSource?, counter: PresentationCounter? = nil, options: DisplayOptions = .standard) {
        self.source = source; self.counter = counter; self.options = options
    }

    public func makeNSView(context: Context) -> MetalFrameView {
        let view = MetalFrameView()
        view.frameSource = source
        view.presentationCounter = counter
        view.displayOptions = options
        return view
    }
    public func updateNSView(_ nsView: MetalFrameView, context: Context) {
        if nsView.frameSource !== source { nsView.frameSource = source }
        nsView.presentationCounter = counter
        nsView.displayOptions = options
    }
}
#endif
