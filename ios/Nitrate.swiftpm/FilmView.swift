import SwiftUI
import MetalKit
import CoreVideo

/// Draws a source (live camera frames or a developed still) through the film pipeline.
final class FilmViewRenderer: NSObject, MTKViewDelegate {
    enum Source {
        case camera(CameraModel)
        case still(MTLTexture)
    }

    var settings: FilmSettings
    var source: Source
    var bypass = false
    var seed: Float = 1
    private let pyramid = FilmRenderer.GlowPyramid()
    private var textureCache: CVMetalTextureCache?

    init(settings: FilmSettings, source: Source) {
        self.settings = settings
        self.source = source
        super.init()
        CVMetalTextureCacheCreate(nil, nil, FilmRenderer.shared.device, nil, &textureCache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let renderer = FilmRenderer.shared
        var sourceTexture: MTLTexture?
        var cvTexture: CVMetalTexture?
        var srgb = false
        switch source {
        case .camera(let camera):
            guard let pb = camera.latestFrame, let cache = textureCache else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTexture)
            if let cvTexture { sourceTexture = CVMetalTextureGetTexture(cvTexture) }
            srgb = true
        case .still(let texture):
            sourceTexture = texture
        }
        guard let src = sourceTexture, let drawable = view.currentDrawable,
              let cb = renderer.queue.makeCommandBuffer() else { return }
        let dst = drawable.texture
        let lod: Float = srgb ? 0 : max(0, log2(Float(src.width) / Float(max(dst.width, 1))))
        let u = settings.snapshot().uniforms(seed: seed, srgbInput: srgb, sourceLod: lod, bypass: bypass)
        renderer.encode(commandBuffer: cb, source: src, destination: dst, uniforms: u, pyramid: pyramid)
        cb.present(drawable)
        let keepAlive = cvTexture
        cb.addCompletedHandler { _ in _ = keepAlive }
        cb.commit()
    }
}

struct FilmMetalView: UIViewRepresentable {
    @ObservedObject var settings: FilmSettings
    let source: FilmViewRenderer.Source
    var bypass = false
    var seed: Float = 1

    func makeCoordinator() -> FilmViewRenderer {
        FilmViewRenderer(settings: settings, source: source)
    }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: FilmRenderer.shared.device)
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 30
        v.isOpaque = true
        v.backgroundColor = .black
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.source = source
        context.coordinator.bypass = bypass
        context.coordinator.seed = seed
    }
}

/// Horizontal list of looks.
struct LookPicker: View {
    @ObservedObject var settings: FilmSettings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Look.all) { look in
                    Button {
                        settings.lookID = look.id
                    } label: {
                        Text(look.name)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(settings.lookID == look.id ? Color.orange : Color.white.opacity(0.08))
                            .foregroundStyle(settings.lookID == look.id ? Color.black : Color.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Colour and texture controls.
struct AdjustSheet: View {
    @ObservedObject var settings: FilmSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Look") {
                    row("Strength", $settings.strength, 0...1)
                }
                Section {
                    row("Exposure", $settings.exposure, -2...2)
                    row("Temperature", $settings.temp, -1...1)
                    row("Tint", $settings.tint, -1...1)
                    row("Contrast", $settings.contrast, 0.6...1.6)
                    row("Fade", $settings.fade, 0...0.12)
                    row("Saturation", $settings.saturation, 0...1.8)
                    row("Split tone", $settings.split, 0...2)
                } header: {
                    HStack { Text("Color"); Spacer(); Button("Reset") { settings.resetColor() }.font(.caption) }
                }
                Section {
                    row("Halation", $settings.halation, 0...2)
                    row("Bloom", $settings.bloom, 0...2)
                    row("Grain", $settings.grain, 0...1.6)
                    row("Grain size", $settings.grainSize, 0.5...3)
                    row("Softness", $settings.softness, 0...1)
                    row("Vignette", $settings.vignette, 0...1)
                } header: {
                    HStack { Text("Texture"); Spacer(); Button("Reset") { settings.resetToLook() }.font(.caption) }
                }
            }
            .navigationTitle(settings.look.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
