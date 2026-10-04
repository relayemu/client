// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  FrameCapture.swift
//  RelayUI — turns the emulator's RGBX8 framebuffer into a CGImage for the

import Foundation
import CoreGraphics
import RelayEmulation

enum FrameCapture {
    static func image(from source: VideoFrameSource) -> CGImage? {
        var image: CGImage?
        source.withCurrentFrame { pointer, d in
            guard d.width > 0, d.height > 0, d.width <= 2048, d.height <= 2048,
                  d.bytesPerRow >= d.width * 4, d.bytesPerRow <= 2048 * 4,
                  d.pixelFormat == .rgbx8 else { return }
            let data = Data(bytes: pointer, count: d.bytesPerRow * d.height)
            guard let provider = CGDataProvider(data: data as CFData) else { return }
            image = CGImage(width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: d.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return image
    }
}
