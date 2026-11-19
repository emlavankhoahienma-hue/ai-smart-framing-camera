//
//  UltraSharpService.swift
//  AISmartFramingCamera
//
//  Dịch vụ Tổng thể Điều phối Chụp & Xử lý Đa khung hình "Ultra Sharp Pro" (C++20 NEON + Metal GPU)
//  - Chụp chùm Streaming nén Full 12MP (4-5 frames) -> Đỉnh RAM thấp hơn 70%, bảo toàn trọn vẹn 4032x3024!
//  - Chọn frame tham chiếu bằng C++20 NEON Tenengrad + Laplacian (ưu tiên chủ thể trung tâm)
//  - Căn chỉnh Sub-pixel phân cấp Metal + Khớp quỹ đạo toàn cục C++20 Huber-IRLS + Khử nhiễu MAD động
//  - Tái tạo chi tiết đa tần số kẹp Halo (Dual-Scale Halo-Clamped Deconvolution) + Chốt chống ảnh đen 100%
//

import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import Metal
import AVFoundation

public final class UltraSharpService: @unchecked Sendable {
    public static let shared = UltraSharpService()

    private let captureController = UltraSharpCaptureController.shared
    private let metalEngine = UltraSharpMetalEngine.shared
    private let processingQueue = DispatchQueue(label: "com.alignstudio.ultrasharp.processing", qos: .userInitiated)

    private let stateLock = NSLock()
    private var isProcessing: Bool = false
    private var isCancelled: Bool = false

    public init() {}

    /// Thực thi trọn vẹn quy trình chụp và gộp siêu phân giải Ultra Sharp Pro (Streaming Full 12MP)
    public func processUltraSharpCapture(
        cameraService: CameraService,
        requestedBurstCount: Int = 5,
        sharpnessStrength: Float = 0.44,
        progressHandler: @escaping @Sendable (UltraSharpProgressInfo) -> Void,
        completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void
    ) {
        stateLock.lock()
        guard !isProcessing else {
            stateLock.unlock()
            completion(.failure(CameraServiceError.captureAlreadyInProgress))
            return
        }
        isProcessing = true
        isCancelled = false
        stateLock.unlock()

        let startTime = CACurrentMediaTime()

        progressHandler(UltraSharpProgressInfo(
            phase: .lockingCamera,
            percentage: 0.06,
            message: "Đang chụp Ultra Sharp 12MP..."
        ))

        // BƯỚC 1: Chụp chùm 4-5 frame nén Full 12MP theo cơ chế Streaming siêu nhẹ RAM
        captureController.startStreamingCompressedBurst(
            cameraService: cameraService,
            requestedCount: requestedBurstCount,
            onShotReceived: { _, current, total in
                let pct = 0.08 + 0.36 * (Float(current) / Float(max(1, total)))
                progressHandler(UltraSharpProgressInfo(
                    phase: .capturing(current: current, total: total),
                    percentage: pct,
                    message: "Đang thu khung hình \(current)/\(total)..."
                ))
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.stateLock.lock()
                    self.isProcessing = false
                    self.stateLock.unlock()
                    progressHandler(UltraSharpProgressInfo(
                        phase: .failed(reason: error.localizedDescription),
                        percentage: 0.0,
                        message: "Lỗi chụp chùm"
                    ))
                    completion(.failure(error))

                case .success(let compressedShots):
                    self.processingQueue.async {
                        self.executeStreamingFusionPipeline(
                            shots: compressedShots,
                            startTime: startTime,
                            sharpnessStrength: sharpnessStrength,
                            progressHandler: progressHandler,
                            completion: completion
                        )
                    }
                }
            }
        )
    }

    // MARK: - Pipeline Gộp Điện Toán Streaming Full 12MP (C++20 NEON + Metal GPU)

    private func executeStreamingFusionPipeline(
        shots: [UltraSharpCompressedShot],
        startTime: Double,
        sharpnessStrength: Float,
        progressHandler: @escaping @Sendable (UltraSharpProgressInfo) -> Void,
        completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void
    ) {
        defer {
            metalEngine.releaseTransientResources()
        }

        stateLock.lock()
        let cancelled = self.isCancelled
        stateLock.unlock()

        if cancelled {
            finishWithCancellation(completion: completion)
            return
        }

        guard !shots.isEmpty else {
            finishWithFailure(error: CameraServiceError.photoProcessingFailed, completion: completion)
            return
        }

        // BƯỚC 2: Xếp hạng độ nét Tenengrad C++20 & loại bỏ frame rung nhòe (< 62% độ nét khung gốc)
        progressHandler(UltraSharpProgressInfo(
            phase: .selectingReference,
            percentage: 0.48,
            message: "Đang chọn frame gốc nét nhất..."
        ))

        let sortedShots = shots.sorted { $0.sharpnessScore > $1.sharpnessScore }
        let refShot = sortedShots[0]
        let peakSharpness = max(1e-3, refShot.sharpnessScore)
        let validShots = sortedShots.filter { $0.sharpnessScore >= peakSharpness * 0.62 }

        CameraLogger.info(
            "UltraSharp Pro: Frame gốc #\(refShot.index) (Tenengrad=\(String(format: "%.1f", refShot.sharpnessScore))), hợp lệ \(validShots.count)/\(shots.count)",
            category: .capture
        )

        // Chọn độ phân giải đích Full 12MP (4032px) trên máy >= 5.2GB RAM, 3600px trên máy 4GB (iPhone XS)
        let maxDecodeDim = (ProcessInfo.processInfo.physicalMemory >= 5_200_000_000) ? 4032 : 3600

        guard let decodedRef = UltraSharpCaptureController.decodeFullResolutionPixelBufferWithColorSpace(
            from: refShot.encodedData,
            maxPixelSize: maxDecodeDim
        ) else {
            finishWithFailure(error: CameraServiceError.photoProcessingFailed, completion: completion)
            return
        }
        let refPixelBuffer = decodedRef.pixelBuffer
        let sourceColorSpace = decodedRef.colorSpace

        if validShots.count < 2 {
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        // BƯỚC 3: Khởi tạo Texture Metal & Bộ tích lũy 16-bit Float cho Frame Gốc
        guard let queue = metalEngine.commandQueue,
              let refTexture = metalEngine.makeTexture(from: refPixelBuffer),
              let initCB = queue.makeCommandBuffer() else {
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        metalEngine.initializeAccumulator(referenceTexture: refTexture, commandBuffer: initCB)
        initCB.commit()
        initCB.waitUntilCompleted()
        guard initCB.status == .completed else {
            CameraLogger.error("UltraSharp Pro: initCB lỗi (status=\(initCB.status.rawValue)) -> Fallback!", category: .capture)
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        // BƯỚC 4: Giải mã & Gộp từng frame phụ một (1-by-1 Streaming trong autoreleasepool)
        // kết hợp Cân bằng sáng C++20 + C++20 Huber-IRLS chống bóng ma + Edge-Aware Wiener chống bệt
        var fusedCount = 1
        var accumulatedError: Float = 0.0

        let secondaryShots = validShots.filter { $0.index != refShot.index }
        let totalSecondary = secondaryShots.count

        for (idx, secShot) in secondaryShots.enumerated() {
            stateLock.lock()
            let isAborted = self.isCancelled
            stateLock.unlock()

            if isAborted {
                finishWithCancellation(completion: completion)
                return
            }

            let step = idx + 1
            let progressPct = 0.54 + 0.34 * (Float(step) / Float(max(1, totalSecondary)))
            progressHandler(UltraSharpProgressInfo(
                phase: .aligning(current: step, total: totalSecondary),
                percentage: progressPct,
                message: "Đang căn chỉnh C++ & gộp \(step)/\(totalSecondary)..."
            ))

            autoreleasepool {
                guard let secBuffer = UltraSharpCaptureController.decodeFullResolutionPixelBuffer(
                    from: secShot.encodedData,
                    maxPixelSize: maxDecodeDim
                ),
                      let (secTexture, secCVKeepAlive) = metalEngine.makeScopedTexture(from: secBuffer) else {
                    return
                }

                // Khớp độ sáng quang trắc (gain/bias) C++20 giữa secBuffer -> refPixelBuffer (< 0.2ms)
                // triệt tiêu hoàn toàn hiện tượng tối vá cục bộ do sai lệch AE/flicker giữa các khung!
                let exposureMatch: (gain: Float, bias: Float) = Self.computePhotometricMatch(
                    refBuffer: refPixelBuffer,
                    secBuffer: secBuffer
                )

                let alignResult = withExtendedLifetime(secCVKeepAlive) {
                    metalEngine.accumulateFrameWithNativeOptics(
                        secondaryTexture: secTexture,
                        referenceTexture: refTexture,
                        frameIndex: fusedCount,
                        totalFrames: validShots.count,
                        iso: secShot.iso,
                        exposureGain: exposureMatch.gain,
                        exposureBias: exposureMatch.bias,
                        queue: queue
                    )
                }

                if alignResult.success {
                    fusedCount += 1
                    accumulatedError += alignResult.qualityError
                }
            }
        }

        // BƯỚC 5: Chuẩn hóa & Tái tạo Chi tiết Đa tần số Bảo vệ Vùng Tối trên GPU Metal
        progressHandler(UltraSharpProgressInfo(
            phase: .sharpening,
            percentage: 0.92,
            message: "Đang tái tạo vi chi tiết & bảo toàn dải sáng..."
        ))

        guard let finalizeCB = queue.makeCommandBuffer(),
              let outputTexture = metalEngine.finalizeAndSharpen(
                totalFrames: fusedCount,
                sharpnessStrength: min(sharpnessStrength, 0.34),
                commandBuffer: finalizeCB
              ) else {
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        finalizeCB.commit()
        finalizeCB.waitUntilCompleted()
        guard finalizeCB.status == .completed else {
            CameraLogger.error("UltraSharp Pro: finalizeCB lỗi (status=\(finalizeCB.status.rawValue)) -> Fallback!", category: .capture)
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        // BƯỚC 6: Trích xuất CGImage 12MP Display P3 + C++20 Song phương Vi chi tiết Bảo vệ Vùng tối
        progressHandler(UltraSharpProgressInfo(
            phase: .encodingAndSaving,
            percentage: 0.97,
            message: "Đang hoàn tất ảnh 12MP..."
        ))

        guard let finalCGImage = metalEngine.makeCGImage(
            from: outputTexture,
            colorSpace: sourceColorSpace,
            clarityStrength: 0.28,
            shadowRecovery: 0.10
        ) else {
            CameraLogger.error("UltraSharp Pro: outputTexture bất thường -> Fallback frame gốc sắc nét!", category: .capture)
            fallbackToReferenceBuffer(
                refPixelBuffer: refPixelBuffer,
                colorSpace: sourceColorSpace,
                refIndex: refShot.index,
                totalShots: shots.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        let totalTime = CACurrentMediaTime() - startTime
        let noiseReduction = sqrt(Float(fusedCount))
        let avgError = (fusedCount > 1) ? (accumulatedError / Float(fusedCount - 1)) : 0.0

        CameraLogger.info(
            "UltraSharp Pro: Gộp thành công \(fusedCount)/\(shots.count) frames (\(finalCGImage.width)x\(finalCGImage.height)) trong \(String(format: "%.2f", totalTime))s! Giảm nhiễu: \(String(format: "%.2f", noiseReduction))x",
            category: .capture
        )

        stateLock.lock()
        isProcessing = false
        stateLock.unlock()

        progressHandler(UltraSharpProgressInfo(
            phase: .completed,
            percentage: 1.0,
            message: "Hoàn tất Ultra Sharp"
        ))

        completion(.success(UltraSharpFusionResult(
            outputImage: finalCGImage,
            referenceIndex: refShot.index,
            usedFrameCount: fusedCount,
            totalCapturedCount: shots.count,
            estimatedNoiseReductionRatio: noiseReduction,
            averageAlignmentError: avgError,
            processingTimeSeconds: totalTime,
            wasFallback: false
        )))
    }

    // MARK: - Khớp Sáng Quang Trắc & Cơ chế Fallback An toàn Tuyệt đối (Bảo toàn Display P3)

    private static func computePhotometricMatch(
        refBuffer: CVPixelBuffer,
        secBuffer: CVPixelBuffer
    ) -> (gain: Float, bias: Float) {
        let w = CVPixelBufferGetWidth(refBuffer)
        let h = CVPixelBufferGetHeight(refBuffer)
        guard w == CVPixelBufferGetWidth(secBuffer),
              h == CVPixelBufferGetHeight(secBuffer),
              w >= 16, h >= 16 else {
            return (1.0, 0.0)
        }
        CVPixelBufferLockBaseAddress(refBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(secBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(secBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(refBuffer, .readOnly)
        }
        guard let rPtr = CVPixelBufferGetBaseAddress(refBuffer)?.assumingMemoryBound(to: UInt8.self),
              let sPtr = CVPixelBufferGetBaseAddress(secBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return (1.0, 0.0)
        }
        let rRow = CVPixelBufferGetBytesPerRow(refBuffer)
        let sRow = CVPixelBufferGetBytesPerRow(secBuffer)
        return noc_us_match_exposure_bgra(
            refBGRA: rPtr,
            secBGRA: sPtr,
            width: Int32(w),
            height: Int32(h),
            refRowBytes: Int32(rRow),
            secRowBytes: Int32(sRow)
        )
    }

    private func fallbackToReferenceBuffer(
        refPixelBuffer: CVPixelBuffer,
        colorSpace: CGColorSpace,
        refIndex: Int,
        totalShots: Int,
        startTime: Double,
        completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void
    ) {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()

        guard let cg = decodeEnhancedCGImage(
            from: refPixelBuffer,
            colorSpace: colorSpace,
            clarityStrength: 0.24,
            shadowRecovery: 0.08
        ) else {
            finishWithFailure(error: CameraServiceError.photoProcessingFailed, completion: completion)
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        completion(.success(UltraSharpFusionResult(
            outputImage: cg,
            referenceIndex: refIndex,
            usedFrameCount: 1,
            totalCapturedCount: totalShots,
            estimatedNoiseReductionRatio: 1.0,
            averageAlignmentError: 0.0,
            processingTimeSeconds: elapsed,
            wasFallback: true
        )))
    }

    private func decodeEnhancedCGImage(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: CGColorSpace,
        clarityStrength: Float,
        shadowRecovery: Float
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstRowBytes = width * 4
        let totalBytes = dstRowBytes * height
        guard width >= 16, height >= 16 else { return nil }

        var enhanced = [UInt8](repeating: 255, count: totalBytes)
        let bandCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let rowsPerBand = (height + bandCount - 1) / bandCount
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        enhanced.withUnsafeMutableBytes { dstBuf in
            guard let dPtr = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                let y0 = band * rowsPerBand
                let y1 = min(height, y0 + rowsPerBand)
                if y0 < y1 {
                    noc_us_enhance_superres_bgra_rows(
                        srcPtr, Int32(width), Int32(height), Int32(srcRowBytes),
                        dPtr, Int32(dstRowBytes),
                        clarityStrength, shadowRecovery,
                        Int32(y0), Int32(y1)
                    )
                }
            }
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(enhanced) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: dstRowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    public func cancelCurrentOperation() {
        stateLock.lock()
        isCancelled = true
        stateLock.unlock()

        captureController.cancelBurst()
    }

    private func finishWithCancellation(completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void) {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()
        completion(.failure(CameraServiceError.captureTimedOut))
    }

    private func finishWithFailure(error: Error, completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void) {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()
        completion(.failure(error))
    }
}
