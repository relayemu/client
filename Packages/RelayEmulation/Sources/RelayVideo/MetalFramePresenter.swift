// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  MetalFramePresenter.swift
//  RelayVideo
//
//  Minimal Metal presenter for software framebuffers. One implementation for
//  iOS, tvOS and macOS: an MTKView that uploads the latest frame into a texture
//  filter (Original = nearest; Sharp = sharp-bilinear, crisp texels with
//  smoothed texel edges for non-integer scales). No shader packs.

import Foundation
import Metal
import MetalKit
import RelayEmulation

/// How the frame fills the view (product-level, remembered per system).
public enum DisplayScaling: String, CaseIterable, Hashable, Codable, Sendable {
    /// Largest whole enlargement that fits; downscale if even 1x would crop.
    case integer
    /// Fills the available area while keeping the aspect ratio.
    case fit
    /// Fills the display while preserving aspect ratio; excess edges crop.
    case fill
}

/// Curated filters; the basic pair stays excellent and Pro adds two restrained
/// presentation choices without exposing vendor renderer settings.
public enum DisplayFilter: String, CaseIterable, Hashable, Codable, Sendable {
    case original
    case sharp
    /// Curated bilinear smoothing for artwork-heavy games.
    case smooth
    /// A restrained scanline treatment; no external shader pack.
    case crtSoft
}

public extension DisplayScaling {
    var isAdvanced: Bool { self == .fill }
}

public extension DisplayFilter {
    var isAdvanced: Bool { self == .smooth || self == .crtSoft }
}

public struct DisplayOptions: Hashable, Codable, Sendable {
    public var scaling: DisplayScaling
    public var filter: DisplayFilter

    public init(scaling: DisplayScaling = .integer, filter: DisplayFilter = .original) {
        self.scaling = scaling
        self.filter = filter
    }

    public static let standard = DisplayOptions()
}

/// Runtime-compiled shaders (keeps the package free of .metal build steps).
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float2 scale;      // clip-space scale of the quad
    float2 texSize;    // frame size in texels
    float2 pixelScale; // drawable pixels per texel (x, y)
    uint   filterMode; // 0 nearest, 1 sharp bilinear, 2 smooth, 3 CRT Soft
};

vertex VertexOut relay_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 positions[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                            float2(-1,  1), float2(1, -1), float2(1,  1) };
    float2 uvs[6]       = { float2(0, 1), float2(1, 1), float2(0, 0),
                            float2(0, 0), float2(1, 1), float2(1, 0) };
    VertexOut out;
    out.position = float4(positions[vid] * u.scale, 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 relay_fragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
    if (u.filterMode == 0) {
        constexpr sampler nearest(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
        return float4(tex.sample(nearest, in.uv).rgb, 1.0);
    }
    // Sharp bilinear: snap to texel centres, blend only within the last output pixel of each texel edge.
    constexpr sampler linear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (u.filterMode == 2) {
        return float4(tex.sample(linear, in.uv).rgb, 1.0);
    }
    if (u.filterMode == 3) {
        float3 colour = tex.sample(linear, in.uv).rgb;
        float scanline = 0.90 + 0.10 * sin(in.uv.y * u.texSize.y * 3.14159265);
        return float4(colour * scanline, 1.0);
    }
    float2 texel = in.uv * u.texSize;
    float2 base = floor(texel - 0.5) + 0.5;
    float2 f = texel - base;
    float2 s = max(u.pixelScale, float2(1.0));
    float2 edge = clamp(f * s - (s - 1.0) * 0.5, 0.0, 1.0);
    float2 uv = (base + edge) / u.texSize;
    return float4(tex.sample(linear, uv).rgb, 1.0);
}
"""

private struct Uniforms {
    var scale: SIMD2<Float>
    var texSize: SIMD2<Float>
    var pixelScale: SIMD2<Float>
    var filterMode: UInt32
}

/// MTKView subclass that presents frames from a `VideoFrameSource`.
public final class MetalFrameView: MTKView, MTKViewDelegate {
    public var frameSource: VideoFrameSource? {
        didSet { texture = nil }
    }
    public var displayOptions = DisplayOptions.standard
    /// Frames actually presented in the last sampling window (for diagnostics).
    public private(set) var presentedFrameCount: Int = 0
    /// Optional shared counter (owned by the session) bumped per presented frame.
    public var presentationCounter: PresentationCounter?

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var textureDescriptor: FrameDescriptor?

    public init(frame: CGRect = .zero, preferredFramesPerSecond: Int = 60) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        self.delegate = self
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.autoResizeDrawable = true
        #if os(macOS)
        self.layer?.isOpaque = true
        #else
        // A pure display surface: it has never handled a touch, and while it
        // accepted them it silently swallowed every finger that landed on the
        self.isUserInteractionEnabled = false
        #endif
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        buildPipeline()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    #if os(macOS)
    /// The AppKit half of the same rule as `isUserInteractionEnabled = false`
    /// above: the picture is a display surface and must be transparent to input,
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    private func buildPipeline() {
        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "relay_vertex")
            desc.fragmentFunction = library.makeFunction(name: "relay_fragment")
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            pipeline = nil
        }
    }

    private func ensureTexture(for descriptor: FrameDescriptor) -> MTLTexture? {
        if let texture, textureDescriptor == descriptor { return texture }
        guard let device else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: descriptor.width,
                                                          height: descriptor.height,
                                                          mipmapped: false)
        td.usage = [.shaderRead]
        #if os(macOS)
        td.storageMode = .managed
        #else
        td.storageMode = .shared
        #endif
        texture = device.makeTexture(descriptor: td)
        textureDescriptor = descriptor
        return texture
    }

    /// Size of the presented image in drawable pixels for the current options.
    static func presentedSize(frame: FrameDescriptor, drawable: CGSize, options: DisplayOptions) -> CGSize {
        guard drawable.width > 0, drawable.height > 0, frame.width > 0, frame.height > 0 else { return .zero }
        // Aspect-correct height for the frame's width (e.g. 3:2 for GBA).
        let aspectHeight = Double(frame.width) / frame.aspectRatio
        switch options.scaling {
        case .integer:
            let fitting = min(drawable.width / Double(frame.width), drawable.height / aspectHeight)
            // An emphasis companion or resized window can be smaller than one
            // native frame. Prefer whole-pixel enlargement when it fits, but
            // downscale instead of cropping a picture that cannot fit at 1x.
            let scale = fitting >= 1 ? floor(fitting) : fitting
            return CGSize(width: Double(frame.width) * scale, height: aspectHeight * scale)
        case .fit:
            let scale = min(drawable.width / Double(frame.width), drawable.height / aspectHeight)
            return CGSize(width: Double(frame.width) * scale, height: aspectHeight * scale)
        case .fill:
            let scale = max(drawable.width / Double(frame.width), drawable.height / aspectHeight)
            return CGSize(width: Double(frame.width) * scale, height: aspectHeight * scale)
        }
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let source = frameSource, let pipeline, let queue = commandQueue,
              let drawable = currentDrawable, let pass = currentRenderPassDescriptor else { return }

        var uploaded: FrameDescriptor?
        source.withCurrentFrame { pointer, descriptor in
            guard let tex = ensureTexture(for: descriptor) else { return }
            let region = MTLRegionMake2D(0, 0, descriptor.width, descriptor.height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: pointer, bytesPerRow: descriptor.bytesPerRow)
            uploaded = descriptor
        }
        guard let descriptor = uploaded, let tex = texture else { return }

        let presented = Self.presentedSize(frame: descriptor, drawable: drawableSize, options: displayOptions)
        var uniforms = Uniforms(scale: SIMD2<Float>(1, 1),
                                texSize: SIMD2<Float>(Float(descriptor.width), Float(descriptor.height)),
                                pixelScale: SIMD2<Float>(1, 1),
                                filterMode: {
                                    switch displayOptions.filter {
                                    case .original: return 0
                                    case .sharp: return 1
                                    case .smooth: return 2
                                    case .crtSoft: return 3
                                    }
                                }())
        if presented.width > 0, drawableSize.width > 0, drawableSize.height > 0 {
            uniforms.scale = SIMD2<Float>(Float(presented.width / drawableSize.width), Float(presented.height / drawableSize.height))
            uniforms.pixelScale = SIMD2<Float>(Float(presented.width / Double(descriptor.width)), Float(presented.height / Double(descriptor.height)))
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        presentedFrameCount &+= 1
        presentationCounter?.increment()
    }

    /// Returns and resets the presented-frame counter (diagnostics sampling).
    public func takePresentedFrameCount() -> Int {
        let n = presentedFrameCount
        presentedFrameCount = 0
        return n
    }
}
