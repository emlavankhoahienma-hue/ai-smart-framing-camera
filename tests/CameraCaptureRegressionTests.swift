import XCTest
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import AISmartFramingCamera

/// Add to the existing iOS unit-test target. These tests have not been run on
/// Windows; they exercise the production gate and decoder on an Apple SDK.
final class CameraCaptureRegressionTests: XCTestCase {
    func testHandheldTremorReachesReadyAtEveryDeliveryRate() {
        for fps in [15.0, 30, 60, 120] {
            for hz in [9.0, 9.5, 10] {
                var gate = AlignmentCaptureGate()
                var firstReady: Double?
                for i in 0...Int(fps) {
                    let t = Double(i) / fps
                    let distance = 0.009 + 0.006 * abs(sin(2 * .pi * hz * t))
                    if gate.update(time: t, distance: distance, radius: 0.038,
                                   freshEvidence: true) == .ready, firstReady == nil {
                        firstReady = t
                    }
                }
                XCTAssertNotNil(firstReady)
                XCTAssertLessThanOrEqual(firstReady ?? .infinity, 0.40)
            }
        }
    }

    func testFastPassAcrossCenterDoesNotCapture() {
        var gate = AlignmentCaptureGate()
        for i in 0...60 {
            let t = Double(i) / 60
            let distance = abs(t - 0.5) * 0.8
            XCTAssertNotEqual(gate.update(time: t, distance: distance,
                radius: 0.038, freshEvidence: true), .ready)
        }
    }

    func testOneMissingOpticalFramePausesDwell() {
        var gate = AlignmentCaptureGate()
        for i in 0...10 {
            XCTAssertNotEqual(gate.update(time: Double(i) / 60, distance: 0.01,
                radius: 0.038, freshEvidence: true), .ready)
        }
        XCTAssertEqual(gate.update(time: 11.0 / 60, distance: 0.01,
            radius: 0.038, freshEvidence: false), .holding)
        XCTAssertTrue(gate.isAligned)
        var state = AlignmentCaptureGate.State.outside
        for i in 12...20 {
            state = gate.update(time: Double(i) / 60, distance: 0.01,
                                radius: 0.038, freshEvidence: true)
        }
        XCTAssertEqual(state, .ready)
    }

    func testPredictedOnlyTargetNeverUnlocksShutter() {
        var gate = AlignmentCaptureGate()
        for i in 0...300 {
            XCTAssertEqual(gate.update(time: Double(i) / 60, distance: 0,
                radius: 0.038, freshEvidence: false), .outside)
        }
    }

    func testResetAndLongGapRequireNewDwell() {
        var gate = AlignmentCaptureGate()
        for i in 0...30 {
            _ = gate.update(time: Double(i) / 60, distance: 0,
                            radius: 0.038, freshEvidence: true)
        }
        XCTAssertEqual(gate.update(time: 4, distance: 0, radius: 0.038,
                                   freshEvidence: true), .holding)
        gate.reset()
        XCTAssertFalse(gate.isAligned)
        XCTAssertEqual(gate.update(time: 5, distance: 0, radius: 0.038,
                                   freshEvidence: true), .holding)
        XCTAssertEqual(gate.update(time: 4, distance: 0, radius: 0.038,
                                   freshEvidence: true), .holding)
    }

    func testInvalidInputAndLargeExcursionResetAlignment() {
        var gate = AlignmentCaptureGate()
        _ = gate.update(time: 0, distance: 0, radius: 0.038, freshEvidence: true)
        XCTAssertEqual(gate.update(time: 0.01, distance: 0.2, radius: 0.038,
                                   freshEvidence: true), .outside)
        for distance in [Double.nan, .infinity] {
            XCTAssertEqual(gate.update(time: 1, distance: distance, radius: 0.038,
                                       freshEvidence: true), .outside)
        }
        XCTAssertFalse(gate.isAligned)
    }

    private func makeImage(width: Int = 80, height: Int = 48) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1,0,0), (0,1,0), (0,0,1), (1,1,0)]
        for row in 0...1 {
            for col in 0...1 {
                let color = colors[row * 2 + col]
                context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
                context.fill(CGRect(x: col * width / 2, y: row * height / 2,
                                    width: width / 2, height: height / 2))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func jpeg(_ image: CGImage, orientation: Int? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        var metadata: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1]
        if let orientation { metadata[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let context = CIContext()
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!,
                rowBytes: image.width * 4, bounds: CGRect(x: 0, y: 0,
                    width: image.width, height: image.height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes
    }

    @MainActor
    func testAllEightExifOrientationsMatchUIKitReference() throws {
        let mapping: [UIImage.Orientation] = [.up, .upMirrored, .down, .downMirrored,
                                              .leftMirrored, .right, .rightMirrored, .left]
        let original = try makeImage()
        for exif in 1...8 {
            let data = try jpeg(original, orientation: exif)
            let decoded = try XCTUnwrap(SuperResolutionRAWEngine.decodeProcessedPhoto(data, context: CIContext()))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let encoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let size = exif >= 5 ? CGSize(width: original.height, height: original.width) :
                                  CGSize(width: original.width, height: original.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let reference = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: encoded, scale: 1, orientation: mapping[exif - 1])
                    .draw(in: CGRect(origin: .zero, size: size))
            }
            XCTAssertEqual(decoded.width, Int(size.width))
            XCTAssertEqual(decoded.height, Int(size.height))
            let a = rgba(decoded), b = rgba(try XCTUnwrap(reference.cgImage))
            XCTAssertEqual(a.count, b.count)
            let error = zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.reduce(0, +)
            XCTAssertLessThan(Double(error) / Double(a.count), 3, "EXIF \(exif)")
        }
    }

    func testNoThumbnailCeilingAndNoDefaultQuarterTurn() throws {
        let image = try makeImage(width: 8064, height: 8)
        let data = try jpeg(image)
        let decoded = try XCTUnwrap(SuperResolutionRAWEngine.decodeProcessedPhoto(data, context: CIContext()))
        XCTAssertEqual(decoded.width, 8064)
        XCTAssertEqual(decoded.height, 8)
    }

    func testJpegAndInvalidDataAreNeverReportedAsDNG() throws {
        XCTAssertFalse(SuperResolutionRAWEngine.isDNGData(try jpeg(makeImage())))
        XCTAssertFalse(SuperResolutionRAWEngine.isDNGData(Data([0, 1, 2])))
        XCTAssertNil(SuperResolutionRAWEngine.decodeProcessedPhoto(Data([0, 1, 2]), context: CIContext()))
    }
}
