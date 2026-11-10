//
//  UltraSharpProtocols.swift
//  AISmartFramingCamera
//
//  Kiến trúc Protocol mở rộng cho hệ thống Computational Photography "Ultra Sharp"
//  Hỗ trợ Bậc 1 (ISP YUV/BGRA) và sẵn sàng cắm thêm Bậc 2 (RAW CFA) & Bậc 3 (Super-Resolution)
//

import Foundation
import CoreGraphics
import CoreVideo
import Metal
import AVFoundation

/// Dữ liệu một frame trong chùm chụp Ultra Sharp
public struct UltraSharpFrame: @unchecked Sendable {
    public let index: Int
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: CMTime
    public let iso: Float
    public let exposureDuration: CMTime
    public let sharpnessScore: Float
    public let metadata: [String: Any]?

    public init(
        index: Int,
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        iso: Float,
        exposureDuration: CMTime,
        sharpnessScore: Float = 0.0,
        metadata: [String: Any]? = nil
    ) {
        self.index = index
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.iso = iso
        self.exposureDuration = exposureDuration
        self.sharpnessScore = sharpnessScore
        self.metadata = metadata
    }
}

/// Kết quả gộp đa khung hình Ultra Sharp
public struct UltraSharpFusionResult: Sendable {
    public let outputImage: CGImage
    public let referenceIndex: Int
    public let usedFrameCount: Int
    public let totalCapturedCount: Int
    public let estimatedNoiseReductionRatio: Float
    public let averageAlignmentError: Float
    public let processingTimeSeconds: Double
    public let wasFallback: Bool

    public init(
        outputImage: CGImage,
        referenceIndex: Int,
        usedFrameCount: Int,
        totalCapturedCount: Int,
        estimatedNoiseReductionRatio: Float,
        averageAlignmentError: Float,
        processingTimeSeconds: Double,
        wasFallback: Bool
    ) {
        self.outputImage = outputImage
        self.referenceIndex = referenceIndex
        self.usedFrameCount = usedFrameCount
        self.totalCapturedCount = totalCapturedCount
        self.estimatedNoiseReductionRatio = estimatedNoiseReductionRatio
        self.averageAlignmentError = averageAlignmentError
        self.processingTimeSeconds = processingTimeSeconds
        self.wasFallback = wasFallback
    }
}

/// Tiến trình thực thi Ultra Sharp phục vụ hiển thị UI
public struct UltraSharpProgressInfo: Sendable {
    public enum Phase: Sendable {
        case lockingCamera
        case capturing(current: Int, total: Int)
        case selectingReference
        case aligning(current: Int, total: Int)
        case fusing(current: Int, total: Int)
        case sharpening
        case encodingAndSaving
        case completed
        case cancelled
        case failed(reason: String)
    }

    public let phase: Phase
    public let percentage: Float
    public let message: String

    public init(phase: Phase, percentage: Float, message: String) {
        self.phase = phase
        self.percentage = percentage
        self.message = message
    }
}

/// Protocol cho bộ chọn Frame tham chiếu (Reference Frame Selector)
public protocol UltraSharpFrameSelectorProtocol: Sendable {
    func evaluateSharpness(of pixelBuffer: CVPixelBuffer) -> Float
    func selectReferenceFrame(from frames: [UltraSharpFrame], sharpnessThresholdRatio: Float) -> (reference: UltraSharpFrame, validCandidates: [UltraSharpFrame])
}

/// Protocol cho bộ căn chỉnh đa quy mô sub-pixel
public protocol UltraSharpAlignmentEngineProtocol: AnyObject {
    func align(
        secondaryTexture: MTLTexture,
        to referenceTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> (success: Bool, qualityScore: Float, warpedTexture: MTLTexture?)
}

/// Protocol cho bộ gộp đa khung hình thích ứng (Robust Wiener Fusion)
public protocol UltraSharpFusionEngineProtocol: AnyObject {
    func reset(referenceTexture: MTLTexture, iso: Float)
    func accumulate(
        warpedTexture: MTLTexture,
        referenceTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    )
    func finalizeFusion(commandBuffer: MTLCommandBuffer) -> MTLTexture?
}

/// Protocol cho bộ làm nét có kiểm soát biên độ (Edge-aware Halo-clamped Sharpening)
public protocol UltraSharpPostProcessorProtocol: AnyObject {
    func applySharpening(
        to inputTexture: MTLTexture,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        strength: Float,
        clampLimit: Float
    )
}

/// Protocol trừu tượng hóa nguồn chụp chùm (Capture Provider)
public protocol UltraSharpCaptureProviderProtocol: AnyObject {
    var maxSupportedBurstCount: Int { get }
    func captureBurst(
        count: Int,
        progressHandler: @escaping @Sendable (Int, Int) -> Void,
        completion: @escaping @Sendable (Result<[UltraSharpFrame], Error>) -> Void
    )
    func cancelBurst()
}
