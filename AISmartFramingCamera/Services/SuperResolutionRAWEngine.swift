import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Kept in the existing Xcode source file so replacing files needs no target
/// membership changes. High-resolution reconstruction now belongs to the native
/// AVCapturePhotoOutput ISP; this helper only displays processed JPEG/HEIF files.
/// Sensor DNG bytes must never enter a custom RAW developer or Metal colour pass.
public final class SuperResolutionRAWEngine {
    private init() {}

    public static func isDNGData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return false }
        let identifier = type as String
        if identifier == "com.adobe.raw-image" { return true }
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return false }
        return metadata[kCGImagePropertyDNGDictionary as String] != nil
    }

    public static func decodeProcessedPhoto(_ data: Data, context: CIContext) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let sourceType = CGImageSourceGetType(source),
              let type = UTType(sourceType as String),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let value = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: value) ?? .up
        guard orientation != .up else { return image }
        // ImageIO returns encoded pixel order here. Apply EXIF exactly once.
        // No 4032px thumbnail ceiling, arbitrary right rotation or vertical flip.
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let outputSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(oriented, from: oriented.extent,
                                     format: .RGBA8, colorSpace: outputSpace)
    }
}
