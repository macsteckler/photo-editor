import Foundation
import Metal
import CoreGraphics
import CoreVideo

/// Runs the film pipeline on the GPU. Shared Metal state; each caller owns a `GlowPyramid`.
final class FilmRenderer {
    static let shared = FilmRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let prefilterPSO: MTLComputePipelineState
    private let downPSO: MTLComputePipelineState
    private let upPSO: MTLComputePipelineState
    private let finalPSO: MTLComputePipelineState

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: FilmShaders.source, options: nil)
            func pso(_ name: String) throws -> MTLComputePipelineState {
                guard let f = lib.makeFunction(name: name) else { fatalError("Missing kernel \(name)") }
                return try device.makeComputePipelineState(function: f)
            }
            prefilterPSO = try pso("prefilter")
            downPSO = try pso("downsample")
            upPSO = try pso("upsample")
            finalPSO = try pso("finalize")
        } catch {
            fatalError("Film shader compile failed: \(error)")
        }
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float,
                     mipmapped: Bool = false, storage: MTLStorageMode = .private) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = storage
        guard let t = device.makeTexture(descriptor: d) else { fatalError("Out of GPU memory") }
        return t
    }

    /// Glow pyramid. Level 0 is at most 1024 px on the long side whatever the source size,
    /// so halation and bloom have the same reach in the viewfinder and in the saved photo.
    final class GlowPyramid {
        static let levels = 7
        var down: [MTLTexture] = []
        var upH: [MTLTexture] = []
        var upB: [MTLTexture] = []
        private(set) var aspectKey: Int = -1

        func ensure(for width: Int, height: Int, renderer: FilmRenderer) {
            let key = Int((Double(width) / Double(max(height, 1)) * 1000).rounded())
            if key == aspectKey { return }
            aspectKey = key
            let longSide = 1024
            let scale = Double(longSide) / Double(max(width, height))
            var w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
            down = []; upH = []; upB = []
            for _ in 0..<Self.levels {
                down.append(renderer.makeTexture(width: w, height: h))
                upH.append(renderer.makeTexture(width: w, height: h))
                upB.append(renderer.makeTexture(width: w, height: h))
                w = max(1, (w + 1) / 2); h = max(1, (h + 1) / 2)
            }
        }
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(pso)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    /// Encode the whole pipeline: `source` (linear or sRGB) -> `destination` (sRGB-encoded).
    /// `glowSource` is the image the halation/bloom are built from (defaults to `source`).
    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture, glowSource: MTLTexture? = nil,
                destination: MTLTexture, uniforms: FilmUniforms, pyramid: GlowPyramid) {
        var u = uniforms
        let glow = glowSource ?? source
        pyramid.ensure(for: destination.width, height: destination.height, renderer: self)
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }

        // Glow source is read at mip 0
        var gu = u; gu.p7.w = 0
        enc.setTexture(glow, index: 0)
        enc.setTexture(pyramid.down[0], index: 1)
        enc.setBytes(&gu, length: MemoryLayout<FilmUniforms>.stride, index: 0)
        dispatch(enc, prefilterPSO, pyramid.down[0].width, pyramid.down[0].height)

        for i in 1..<GlowPyramid.levels {
            enc.setTexture(pyramid.down[i - 1], index: 0)
            enc.setTexture(pyramid.down[i], index: 1)
            dispatch(enc, downPSO, pyramid.down[i].width, pyramid.down[i].height)
        }
        for (chain, radius) in [(pyramid.upH, Float(0.68)), (pyramid.upB, Float(0.82))] {
            var r = radius
            var low = pyramid.down[GlowPyramid.levels - 1]
            for i in stride(from: GlowPyramid.levels - 2, through: 0, by: -1) {
                enc.setTexture(low, index: 0)
                enc.setTexture(pyramid.down[i], index: 1)
                enc.setTexture(chain[i], index: 2)
                enc.setBytes(&r, length: MemoryLayout<Float>.stride, index: 0)
                dispatch(enc, upPSO, chain[i].width, chain[i].height)
                low = chain[i]
            }
        }

        enc.setTexture(source, index: 0)
        enc.setTexture(pyramid.upH[1], index: 1)
        enc.setTexture(pyramid.upB[2], index: 2)
        enc.setTexture(destination, index: 3)
        enc.setBytes(&u, length: MemoryLayout<FilmUniforms>.stride, index: 0)
        dispatch(enc, finalPSO, destination.width, destination.height)
        enc.endEncoding()
    }

    /// Full-resolution render of a linear image to an 8-bit sRGB CGImage.
    func renderImage(linear: MTLTexture, settings: FilmSettingsSnapshot, seed: Float) -> CGImage? {
        let out = makeTexture(width: linear.width, height: linear.height, format: .rgba8Unorm, storage: .shared)
        let pyramid = GlowPyramid()
        guard let cb = queue.makeCommandBuffer() else { return nil }
        let u = settings.uniforms(seed: seed, srgbInput: false, sourceLod: 0)
        encode(commandBuffer: cb, source: linear, destination: out, uniforms: u, pyramid: pyramid)
        cb.commit()
        cb.waitUntilCompleted()

        let w = out.width, h = out.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        out.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
