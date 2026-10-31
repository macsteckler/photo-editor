import Foundation
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
import Photos

/// Turns RAW sensor data into a scene-linear float texture, with Apple's "look" switched off:
/// no tone-curve boost, no local tone mapping, no sharpening, no contrast/detail enhancement.
/// The film pipeline then does all of the tonal and colour rendering.
enum RawDeveloper {
    struct Developed {
        let texture: MTLTexture          // rgba16Float, scene-linear (linear sRGB primaries)
        let isRaw: Bool
        let properties: [String: Any]    // EXIF/GPS etc. for the saved file
        let description: String
    }

    enum DevelopError: LocalizedError {
        case unreadable
        var errorDescription: String? { "This file could not be read as a photo." }
    }

    static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let ciContext = CIContext(mtlDevice: FilmRenderer.shared.device, options: [
        .workingColorSpace: linearSRGB,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// - Parameter maxPixels: larger images (48 MP ProRAW) are scaled down while developing.
    static func develop(data: Data, maxPixels: Double = 24_000_000) throws -> Developed {
        var image: CIImage
        var isRaw = false
        var properties: [String: Any] = [:]
        var description = "Processed image"

        if let raw = CIRAWFilter(imageData: data, identifierHint: nil) {
            isRaw = true
            raw.boostAmount = 0                 // linear response; our film curve does the tone
            raw.extendedDynamicRangeAmount = 1  // keep highlight headroom above 1.0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if raw.isContrastSupported { raw.contrastAmount = 0 }
            if raw.isDetailSupported { raw.detailAmount = 0 }
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0.15 }
            raw.isGamutMappingEnabled = false
            let native = raw.nativeSize
            let px = Double(native.width * native.height)
            if px > maxPixels { raw.scaleFactor = Float((maxPixels / px).squareRoot()) }
            guard let out = raw.outputImage else { throw DevelopError.unreadable }
            image = out
            properties = (raw.properties as? [String: Any]) ?? [:]
            description = "RAW · \(Int(native.width))×\(Int(native.height))"
        } else {
            guard let img = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw DevelopError.unreadable }
            image = img
            properties = img.properties
        }

        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        // Core Image's origin is bottom-left; Metal textures are top-left.
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h)))

        let renderer = FilmRenderer.shared
        let tex = renderer.makeTexture(width: w, height: h, format: .rgba16Float, mipmapped: true)
        guard let cb = renderer.queue.makeCommandBuffer() else { throw DevelopError.unreadable }
        ciContext.render(image, to: tex, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: linearSRGB)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return Developed(texture: tex, isRaw: isRaw, properties: properties, description: description)
    }

    /// Encode the developed CGImage as JPEG, carrying over EXIF/GPS (orientation is baked in).
    static func jpegData(_ image: CGImage, properties: [String: Any], quality: Double = 0.93) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary] {
            if var d = properties[key as String] as? [String: Any] {
                d.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
                props[key as String] = d
            }
        }
        props[kCGImagePropertyOrientation as String] = 1
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

enum PhotoSaver {
    /// Saves the developed JPEG; if `raw` is given it is attached as the RAW original (RAW+JPEG pair).
    static func save(jpeg: Data, raw: Data?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Nitrate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo library access was denied. Allow it in Settings → Nitrate → Photos."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: jpeg, options: nil)
            if let raw {
                let opts = PHAssetResourceCreationOptions()
                opts.uniformTypeIdentifier = "com.adobe.raw-image"
                req.addResource(with: .alternatePhoto, data: raw, options: opts)
            }
        }
    }
}
