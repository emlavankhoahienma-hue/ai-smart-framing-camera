//
//  UltraSharpService.swift
//  AISmartFramingCamera
//
//  Dịch vụ Tổng thể Điều phối Chụp & Xử lý Đa khung hình "Ultra Sharp" (Bậc 1)
//  - Quản lý toàn bộ chu trình: Thu chùm N frame -> Chọn frame gốc -> Căn chỉnh Sub-pixel -> Gộp Robust -> Làm nét kẹp Halo -> Xuất ảnh
//  - Cơ chế Tự Phục hồi & Fallback an toàn 100%: Nếu < 3 frame hợp lệ hoặc GPU lỗi, tự động lưu Frame gốc nguyên bản (Tuyệt đối không lưu file hỏng)
//

import Foundation
import CoreGraphics
import CoreVideo
import Metal
import AVFoundation

public final class UltraSharpService: @unchecked Sendable {
    public static let shared = UltraSharpService()

    private let captureController = UltraSharpCaptureController.shared
    private let frameSelector = UltraSharpFrameSelector.shared
    private let metalEngine = UltraSharpMetalEngine.shared
    private let processingQueue = DispatchQueue(label: "com.alignstudio.ultrasharp.processing", qos: .userInitiated)

    private let stateLock = NSLock()
    private var isProcessing: Bool = false
    private var isCancelled: Bool = false

    public init() {}

    /// Thực thi trọn vẹn quy trình chụp và xử lý Ultra Sharp đa khung hình
    public func processUltraSharpCapture(
        cameraService: CameraService,
        requestedBurstCount: Int = 8,
        sharpnessStrength: Float = 0.35,
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
            percentage: 0.05,
            message: "Đang khóa phơi sáng & lấy nét..."
        ))

        // BƯỚC 1: Chụp chùm N frame đồng phơi sáng
        captureController.startBurstCapture(
            cameraService: cameraService,
            requestedCount: requestedBurstCount,
            onFrameReceived: { frame, current, total in
                let pct = 0.05 + 0.40 * (Float(current) / Float(total))
                progressHandler(UltraSharpProgressInfo(
                    phase: .capturing(current: current, total: total),
                    percentage: pct,
                    message: "Đang chụp Ultra Sharp \(current)/\(total)..."
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

                case .success(let capturedFrames):
                    self.processingQueue.async {
                        self.executeFusionPipeline(
                            frames: capturedFrames,
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

    // MARK: - Pipeline Gộp Điện Toán (Metal Compute Fusion Pipeline)

    private func executeFusionPipeline(
        frames: [UltraSharpFrame],
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

        guard !frames.isEmpty else {
            finishWithFailure(error: CameraServiceError.photoProcessingFailed, completion: completion)
            return
        }

        // BƯỚC 2: Chọn Frame tham chiếu & Loại bỏ Frame rung nhòe
        progressHandler(UltraSharpProgressInfo(
            phase: .selectingReference,
            percentage: 0.50,
            message: "Đang phân tích độ nét & chọn frame gốc..."
        ))

        let selection = frameSelector.selectReferenceFrame(from: frames, sharpnessThresholdRatio: 0.60)
        let refFrame = selection.reference
        let validCandidates = selection.validCandidates

        CameraLogger.info("UltraSharp: Đã chọn frame index \(refFrame.index) (Độ nét: \(refFrame.sharpnessScore)). Số frame hợp lệ: \(validCandidates.count)/\(frames.count)", category: .capture)

        // KIỂM TRA ĐIỀU KIỆN FALLBACK AN TOÀN:
        // Nếu số frame đạt chuẩn < 3 frame, không cố gộp mà trả về trực tiếp frame gốc để tránh ảnh lỗi
        if validCandidates.count < 3 {
            CameraLogger.warning("UltraSharp: Số frame đạt chuẩn quá ít (\(validCandidates.count) < 3) -> Kích hoạt Fallback an toàn (Lưu Frame gốc nét nhất)!", category: .capture)
            fallbackToReferenceFrame(
                refFrame: refFrame,
                totalFrames: frames.count,
                startTime: startTime,
                completion: completion
            )
            return
        }

        // BƯỚC 3: Khởi tạo Texture Metal & Bộ tích lũy
        guard let queue = metalEngine.commandQueue,
              let refTexture = metalEngine.makeTexture(from: refFrame.pixelBuffer) else {
            CameraLogger.error("UltraSharp: Không thể tạo Metal texture cho frame gốc -> Fallback!", category: .capture)
            fallbackToReferenceFrame(refFrame: refFrame, totalFrames: frames.count, startTime: startTime, completion: completion)
            return
        }

        guard let initCB = queue.makeCommandBuffer() else {
            fallbackToReferenceFrame(refFrame: refFrame, totalFrames: frames.count, startTime: startTime, completion: completion)
            return
        }

        metalEngine.initializeAccumulator(referenceTexture: refTexture, commandBuffer: initCB)
        initCB.commit()
        initCB.waitUntilCompleted()

        // BƯỚC 4: Căn chỉnh Sub-pixel & Gộp Robust từng frame phụ theo luồng Streaming
        var fusedCount = 1
        var accumulatedError: Float = 0.0

        let secondaryFrames = validCandidates.filter { $0.index != refFrame.index }
        let totalSecondary = secondaryFrames.count

        for (idx, secFrame) in secondaryFrames.enumerated() {
            stateLock.lock()
            let isAborted = self.isCancelled
            stateLock.unlock()

            if isAborted {
                finishWithCancellation(completion: completion)
                return
            }

            let currentStep = idx + 1
            let progressPct = 0.55 + 0.35 * (Float(currentStep) / Float(totalSecondary))
            progressHandler(UltraSharpProgressInfo(
                phase: .aligning(current: currentStep, total: totalSecondary),
                percentage: progressPct,
                message: "Đang căn chỉnh & gộp frame \(currentStep)/\(totalSecondary)..."
            ))

            autoreleasepool {
                guard let secTexture = metalEngine.makeTexture(from: secFrame.pixelBuffer),
                      let frameCB = queue.makeCommandBuffer() else {
                    return
                }

                let alignResult = metalEngine.accumulateFrame(
                    secondaryTexture: secTexture,
                    referenceTexture: refTexture,
                    frameIndex: fusedCount,
                    totalFrames: validCandidates.count,
                    commandBuffer: frameCB
                )

                frameCB.commit()
                frameCB.waitUntilCompleted()

                if alignResult.success {
                    fusedCount += 1
                    accumulatedError += alignResult.qualityError
                }
            }
        }

        // BƯỚC 5: Chuẩn hóa & Làm nét có kiểm soát biên độ kẹp Halo
        progressHandler(UltraSharpProgressInfo(
            phase: .sharpening,
            percentage: 0.93,
            message: "Đang tối ưu chi tiết & triệt tiêu halo..."
        ))

        guard let finalizeCB = queue.makeCommandBuffer(),
              let outputTexture = metalEngine.finalizeAndSharpen(
                totalFrames: fusedCount,
                sharpnessStrength: sharpnessStrength,
                commandBuffer: finalizeCB
              ) else {
            fallbackToReferenceFrame(refFrame: refFrame, totalFrames: frames.count, startTime: startTime, completion: completion)
            return
        }

        finalizeCB.commit()
        finalizeCB.waitUntilCompleted()

        // BƯỚC 6: Trích xuất CGImage đầu ra
        progressHandler(UltraSharpProgressInfo(
            phase: .encodingAndSaving,
            percentage: 0.98,
            message: "Đang lưu ảnh hoàn tất..."
        ))

        guard let finalCGImage = metalEngine.makeCGImage(from: outputTexture) else {
            CameraLogger.error("UltraSharp: Không thể trích xuất CGImage từ outputTexture -> Fallback!", category: .capture)
            fallbackToReferenceFrame(refFrame: refFrame, totalFrames: frames.count, startTime: startTime, completion: completion)
            return
        }

        let totalTime = CACurrentMediaTime() - startTime
        let noiseReduction = sqrt(Float(fusedCount))
        let avgError = (fusedCount > 1) ? (accumulatedError / Float(fusedCount - 1)) : 0.0

        CameraLogger.info("UltraSharp: Gộp thành công \(fusedCount)/\(frames.count) frames trong \(String(format: "%.2f", totalTime))s! Giảm nhiễu lý thuyết: \(String(format: "%.2f", noiseReduction))x", category: .capture)

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
            referenceIndex: refFrame.index,
            usedFrameCount: fusedCount,
            totalCapturedCount: frames.count,
            estimatedNoiseReductionRatio: noiseReduction,
            averageAlignmentError: avgError,
            processingTimeSeconds: totalTime,
            wasFallback: false
        )))
    }

    // MARK: - Cơ chế Fallback an toàn Tuyệt đối

    private func fallbackToReferenceFrame(
        refFrame: UltraSharpFrame,
        totalFrames: Int,
        startTime: Double,
        completion: @escaping @Sendable (Result<UltraSharpFusionResult, Error>) -> Void
    ) {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()

        guard let cg = decodeCGImage(from: refFrame.pixelBuffer) else {
            finishWithFailure(error: CameraServiceError.photoProcessingFailed, completion: completion)
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        completion(.success(UltraSharpFusionResult(
            outputImage: cg,
            referenceIndex: refFrame.index,
            usedFrameCount: 1,
            totalCapturedCount: totalFrames,
            estimatedNoiseReductionRatio: 1.0,
            averageAlignmentError: 0.0,
            processingTimeSeconds: elapsed,
            wasFallback: true
        )))
    }

    private func decodeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        return context.makeImage()
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
