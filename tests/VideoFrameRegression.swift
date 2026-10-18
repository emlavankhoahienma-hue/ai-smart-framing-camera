import Foundation
import AVFoundation
import CoreImage
import CoreVideo

@main
enum VideoFrameRegression {
    struct Failure: Error { let message: String }
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func source(at url: URL, fps: Int32) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        guard writer.canAdd(input) else { throw Failure(message: "Cannot add writer") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Cannot start writer") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            try autoreleasepool {
                var pixels: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
                    nil, &pixels) == kCVReturnSuccess, let pixels,
                    CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess,
                    let base = CVPixelBufferGetBaseAddress(pixels) else { throw Failure(message: "Pixel allocation") }
                let stride = CVPixelBufferGetBytesPerRow(pixels)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<360 { for x in 0..<640 {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8((x / 80 + y / 45) % 2 == 0 ? 40 : 200)
                    bytes[offset + 1] = UInt8(y * 255 / 359)
                    bytes[offset + 2] = UInt8(x * 255 / 639)
                    bytes[offset + 3] = 255
                } }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                    throw writer.error ?? Failure(message: "Append failed")
                }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Synthetic video did not finish")
    }

    static func snapshot(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(value: 1, timescale: 3)).image
    }

    static func samples(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let canvas = CGContext(data: storage.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.interpolationQuality = .high
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        try require(drawn, "Cannot sample image")
        return bytes
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for fps in [Int32(30), 60] {
            let original = directory.appendingPathComponent("source-\(fps).mov")
            try await source(at: original, fps: fps)
            let sourceImage = try await snapshot(original)
            try require(sourceImage.width == 360 && sourceImage.height == 640, "Source orientation is wrong")
            let aspects: [CGFloat] = [9.0 / 16, 1, 3.0 / 4]
            for aspect in aspects {
                let asset = AVURLAsset(url: original)
                let window = VideoFrameRenderer.Window(focalLength: 48, baseZoom: 1,
                    outputAspect: aspect, center: CGPoint(x: 0.32, y: 0.68))
                let composition = try await VideoFrameRenderer.composition(asset: asset, window: window, filter: { $0 })
                let output = directory.appendingPathComponent("crop-\(fps)-\(aspect).mov")
                try await VideoFrameRenderer.export(asset: asset, composition: composition, to: output)
                let image = try await snapshot(output)
                try require(abs(CGFloat(image.width) / CGFloat(image.height) - aspect) < 0.012, "Export aspect changed")
                guard let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first else { throw Failure(message: "Missing export") }
                let rate = try await track.load(.nominalFrameRate)
                try require(abs(rate - Float(fps)) < 0.5, "Export changed frame rate")
                let normalized = CaptureViewportGeometry.crop(focalLength: 48, baseZoom: 1,
                    sourceAspect: 9.0 / 16, outputAspect: aspect, center: window.center)!
                let ci = CIImage(cgImage: sourceImage)
                let rect = CaptureViewportGeometry.pixels(normalized, extent: ci.extent, bottomLeft: true)!
                guard let expected = context.createCGImage(ci.cropped(to: rect), from: rect) else { throw Failure(message: "Expected crop") }
                let left = try samples(expected), right = try samples(image)
                let error = zip(left, right).enumerated().filter { $0.offset % 4 != 3 }
                    .reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / (32 * 32 * 3)
                try require(error < 12, "Saved crop moved or rotated; pixel MAE \(error)")
                // Color rerender uses the same immutable original, so geometry
                // cannot compound even when the user repeats crop/color actions.
                let repeated = try await VideoFrameRenderer.composition(asset: asset, window: window, filter: { $0 })
                try require(repeated.renderSize == composition.renderSize, "Repeated rendering compounded crop")
                reports.append(["fps": fps, "aspect": aspect, "width": image.width, "height": image.height,
                    "pixelMAE": error, "measuredFPS": rate])
            }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("Video export: \(reports.count) rotated-track crop/FPS/pixel cases passed")
    }
}
