import Foundation
import simd

/// A film look. Values match the web app (index.html) so both produce the same result.
struct Look: Identifiable, Equatable {
    let id: String
    let name: String
    var mono = false
    var temp: Float = 0
    var tint: Float = 0
    var contrast: Float = 1
    var fade: Float = 0
    var saturation: Float = 1
    /// Oklab (a, b) offsets for shadows and highlights
    var splitS: SIMD2<Float> = .zero
    var splitH: SIMD2<Float> = .zero
    /// hue shift (degrees), chroma multiplier, lightness multiplier
    var green: SIMD3<Float> = [0, 1, 1]
    var blue: SIMD3<Float> = [0, 1, 1]
    /// hue shift (degrees), chroma multiplier — reds, oranges, skin
    var warm: SIMD2<Float> = [0, 1]
    var halation: Float = 0
    var bloom: Float = 0
    var grain: Float = 0
    var grainSize: Float = 1
    var softness: Float = 0
    var vignette: Float = 0
    var none = false

    static let all: [Look] = [
        Look(id: "monsoon", name: "Monsoon", temp: -0.15, tint: 0.04, contrast: 1.1, fade: 0.022, saturation: 1.12,
             splitS: [-0.018, -0.024], splitH: [0.012, 0.022], green: [-10, 0.7, 0.95], blue: [-12, 0.85, 1.0], warm: [-4, 1.15],
             halation: 1.0, bloom: 0.45, grain: 0.75, grainSize: 1.4, softness: 0.5, vignette: 0.45),
        Look(id: "lantern", name: "Lantern", temp: 0.12, tint: 0.0, contrast: 1.05, fade: 0.014, saturation: 1.06,
             splitS: [-0.014, -0.014], splitH: [0.008, 0.03], green: [-20, 0.8, 0.9], blue: [-6, 1.15, 0.95], warm: [4, 1.15],
             halation: 0.55, bloom: 0.35, grain: 0.5, grainSize: 1.1, softness: 0.35, vignette: 0.35),
        Look(id: "golden", name: "Golden", temp: 0.2, tint: 0.03, contrast: 1.15, fade: 0.01, saturation: 1.15,
             splitS: [-0.006, -0.014], splitH: [0.012, 0.035], green: [-24, 0.95, 0.85], blue: [-10, 0.9, 1.0], warm: [2, 1.2],
             halation: 0.7, bloom: 0.3, grain: 0.42, grainSize: 1.1, softness: 0.3, vignette: 0.4),
        Look(id: "print", name: "Print", contrast: 1.05, fade: 0.012, saturation: 1.05,
             splitS: [-0.008, -0.01], splitH: [0.006, 0.012], green: [-12, 0.85, 0.95], blue: [-6, 1.0, 1.0], warm: [0, 1.08],
             halation: 0.35, bloom: 0.15, grain: 0.32, grainSize: 1.0, softness: 0.25, vignette: 0.25),
        Look(id: "overcast", name: "Overcast", temp: -0.08, contrast: 0.92, fade: 0.04, saturation: 0.8,
             splitS: [-0.012, -0.016], splitH: [0.002, 0.006], green: [-14, 0.7, 0.95], blue: [-10, 0.8, 1.0], warm: [0, 1.05],
             halation: 0.3, bloom: 0.2, grain: 0.5, grainSize: 1.2, softness: 0.4, vignette: 0.3),
        Look(id: "silver", name: "Silver", mono: true, contrast: 1.22, fade: 0.02, saturation: 1.0,
             splitH: [0.002, 0.006], halation: 0.2, bloom: 0.25, grain: 0.85, grainSize: 1.4, softness: 0.3, vignette: 0.4),
        Look(id: "none", name: "None", none: true),
    ]

    static func byID(_ id: String) -> Look { all.first { $0.id == id } ?? all[0] }
}

/// The current look plus the user's adjustments. Persisted between launches.
final class FilmSettings: ObservableObject {
    @Published var lookID: String { didSet { if oldValue != lookID { resetToLook() } } }
    @Published var strength: Float = 1
    @Published var exposure: Float = 0
    @Published var temp: Float = 0
    @Published var tint: Float = 0
    @Published var contrast: Float = 1
    @Published var fade: Float = 0
    @Published var saturation: Float = 1
    @Published var split: Float = 1
    @Published var halation: Float = 0
    @Published var bloom: Float = 0
    @Published var grain: Float = 0
    @Published var grainSize: Float = 1
    @Published var softness: Float = 0
    @Published var vignette: Float = 0

    var look: Look { Look.byID(lookID) }

    init() {
        lookID = UserDefaults.standard.string(forKey: "lookID") ?? "monsoon"
        resetToLook()
    }

    func resetToLook() {
        let l = look
        contrast = l.contrast; fade = l.fade; saturation = l.saturation; split = 1
        halation = l.halation; bloom = l.bloom; grain = l.grain; grainSize = l.grainSize
        softness = l.softness; vignette = l.vignette
        UserDefaults.standard.set(lookID, forKey: "lookID")
    }

    func resetColor() {
        exposure = 0; temp = 0; tint = 0; split = 1
        contrast = look.contrast; fade = look.fade; saturation = look.saturation
    }

    /// A value copy for background rendering.
    func snapshot() -> FilmSettingsSnapshot {
        FilmSettingsSnapshot(look: look, strength: strength, exposure: exposure, temp: temp, tint: tint,
                             contrast: contrast, fade: fade, saturation: saturation, split: split,
                             halation: halation, bloom: bloom, grain: grain, grainSize: grainSize,
                             softness: softness, vignette: vignette)
    }
}

struct FilmSettingsSnapshot {
    var look: Look
    var strength, exposure, temp, tint, contrast, fade, saturation, split: Float
    var halation, bloom, grain, grainSize, softness, vignette: Float

    func uniforms(seed: Float, srgbInput: Bool, sourceLod: Float, bypass: Bool = false) -> FilmUniforms {
        let st: Float = look.none ? 0 : strength
        let wb = Self.wbGains(look.temp * strength + temp, look.tint * strength + tint)
        var u = FilmUniforms()
        u.p0 = SIMD4(wb.x, wb.y, wb.z, exposure)
        u.p1 = SIMD4(contrast, fade, saturation, st)
        u.p2 = SIMD4(look.splitS.x * split, look.splitS.y * split, look.splitH.x * split, look.splitH.y * split)
        u.p3 = SIMD4(look.green.x, look.green.y, look.green.z, look.mono ? 1 : 0)
        u.p4 = SIMD4(look.blue.x, look.blue.y, look.blue.z, bypass ? 1 : 0)
        u.p5 = SIMD4(look.warm.x, look.warm.y, halation * st, bloom * st)
        u.p6 = SIMD4(grain, grainSize, softness * st, vignette * st)
        u.p7 = SIMD4(0, seed, srgbInput ? 1 : 0, sourceLod)
        return u
    }

    static func wbGains(_ t: Float, _ m: Float) -> SIMD3<Float> {
        let r = exp(0.35 * t), g = exp(-0.2 * m), b = exp(-0.35 * t)
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return SIMD3(r / l, g / l, b / l)
    }
}

/// Mirrors `struct FilmUniforms` in FilmShaders.swift (8 × float4).
struct FilmUniforms {
    var p0 = SIMD4<Float>.zero
    var p1 = SIMD4<Float>.zero
    var p2 = SIMD4<Float>.zero
    var p3 = SIMD4<Float>.zero
    var p4 = SIMD4<Float>.zero
    var p5 = SIMD4<Float>.zero
    var p6 = SIMD4<Float>.zero
    var p7 = SIMD4<Float>.zero
}
