import Foundation
import AVFoundation
import CoreImage

/// Always render from the original recording. Crop coordinates refer to its
/// upright image, after AVFoundation applies the track's preferred transform.
enum VideoFrameRenderer {
    struct Window: Sendable {
        let focalLength: Double
        let baseZoom: CGFloat
        let outputAspect: CGFloat
        let center: CGPoint
    }

    static func composition(asset: AVAsset, window: Window?,
                            filter: @escaping @Sendable (CIImage) -> CIImage) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
        guard oriented.width > 0, oriented.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let crop: CGRect
        if let window {
            guard let value = CaptureViewportGeometry.crop(focalLength: window.focalLength,
                baseZoom: window.baseZoom, sourceAspect: oriented.width / oriented.height,
                outputAspect: window.outputAspect, center: window.center) else { throw CocoaError(.coderInvalidValue) }
            crop = value
        } else { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        // Keep native pixels rather than upscaling the crop back to a fictitious
        // full-resolution image. Even dimensions are required by 4:2:0 codecs.
        let size = CGSize(width: max(2, floor(oriented.width * crop.width / 2) * 2),
                          height: max(2, floor(oriented.height * crop.height / 2) * 2))
        let composition = AVVideoComposition(asset: asset) { request in
            let original = request.sourceImage
            guard let rect = CaptureViewportGeometry.pixels(crop, extent: original.extent, bottomLeft: true) else {
                request.finish(with: CocoaError(.coderInvalidValue))
                return
            }
            let graded = filter(original.clampedToExtent()).cropped(to: original.extent)
            let translated = graded.cropped(to: rect).transformed(by:
                CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            // One uniform scale, with at most one encoder-alignment pixel trimmed.
            let scale = max(size.width / rect.width, size.height / rect.height)
            let output = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: CGRect(origin: .zero, size: size))
            request.finish(with: output, context: nil)
        }
        guard let mutable = composition.mutableCopy() as? AVMutableVideoComposition else {
            throw CocoaError(.coderInvalidValue)
        }
        mutable.renderSize = size
        let duration = try await track.load(.minFrameDuration)
        if duration.isValid, duration.seconds.isFinite, duration.seconds > 0 { mutable.frameDuration = duration }
        return mutable
    }

    static func export(asset: AVAsset, composition: AVVideoComposition, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        session.videoComposition = composition
        session.outputURL = url
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: session.error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
    }
}
