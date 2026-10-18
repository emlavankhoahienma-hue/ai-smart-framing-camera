import Foundation
import AVFoundation
import CoreImage
import os

/// Always render from the original recording. Crop coordinates refer to its
/// upright image, after AVFoundation applies the track's preferred transform.
enum VideoFrameRenderer {
    /// AVAssetExportSession predates Sendable. Its setup finishes before this
    /// owner starts; every subsequent operation is serialized on this queue.
    private final class ExportOperation: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let queue = DispatchQueue(label: "com.alignai.video-export")
        private var cancelled = false
        private var started = false
        private var finished = false

        init(session: AVAssetExportSession) { self.session = session }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async {
                guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.started = true
                self.session.exportAsynchronously {
                    self.queue.async {
                        self.finished = true
                        if self.cancelled { continuation.resume(throwing: CancellationError()) }
                        else if self.session.status == .completed { continuation.resume() }
                        else { continuation.resume(throwing: self.session.error ?? CocoaError(.fileWriteUnknown)) }
                    }
                }
            }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                if self.started && !self.finished { self.session.cancelExport() }
            }
        }
    }

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
        let operation = ExportOperation(session: session)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { operation.start($0) }
            } onCancel: { operation.cancel() }
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { Logger(subsystem: "com.aismartframing.camera", category: "Video").error("Export cleanup failed: \(error.localizedDescription, privacy: .public)") }
            }
            throw error
        }
    }
}
