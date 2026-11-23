import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import ImageIO
import UIKit

/// Bộ ghi khung hình hậu trường tốc độ cao (~18 FPS, độ nét 460px, bộ đệm 120 khung/ô + cache CGImage giải mã sẵn)
/// để tạo Video Photobooth 30 FPS (1.25x · 1.5x · 2x) siêu mượt, không giật hình và không chạm vào CameraService bị khóa.
public final class PhotoboothTimelapseRecorder: @unchecked Sendable {
    public static let shared = PhotoboothTimelapseRecorder()

    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.alignai.photobooth.timelapse.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true,
        .cacheIntermediates: false
    ])

    private var framesBySlot: [Int: [PhotoboothTimelapseClipFrame]] = [:]
    private var decodedImagesBySlot: [Int: [CGImage]] = [:]
    private var maxFramesPerSlot: Int = 120
    private var lastCaptureTime: CFTimeInterval = 0
    private var isSamplingBusy: Bool = false

    private init() {}

    public func resetAll() {
        lock.withLock {
            framesBySlot.removeAll()
            decodedImagesBySlot.removeAll()
            lastCaptureTime = 0
        }
    }

    public func clearSlot(_ slotIndex: Int) {
        lock.withLock {
            framesBySlot[slotIndex] = []
            decodedImagesBySlot[slotIndex] = []
        }
    }

    public func totalRecordedFrameCount() -> Int {
        lock.withLock {
            framesBySlot.values.reduce(0) { $0 + $1.count }
        }
    }

    public func snapshotFramesBySlot() -> [Int: [PhotoboothTimelapseClipFrame]] {
        lock.withLock { framesBySlot }
    }

    public func snapshotDecodedImagesBySlot() -> [Int: [CGImage]] {
        lock.withLock { decodedImagesBySlot }
    }

    /// Lấy mẫu 1 khung từ `CVPixelBuffer` đang phát live (throttle >= 55ms ~18 FPS, lưu trực tiếp CGImage sắc nét + dữ liệu JPEG).
    public func samplePixelBufferIfDue(
        _ pixelBuffer: CVPixelBuffer,
        slotIndex: Int,
        activeFilmPreset: FilmPreset,
        filmIntensity: Float,
        isFilmActive: Bool
    ) {
        let now = CACurrentMediaTime()
        let shouldProceed: Bool = lock.withLock {
            if isSamplingBusy || (now - lastCaptureTime) < 0.055 {
                return false
            }
            lastCaptureTime = now
            isSamplingBusy = true
            return true
        }
        guard shouldProceed else { return }

        struct PixelBufferBox: @unchecked Sendable {
            let buffer: CVPixelBuffer
        }
        let box = PixelBufferBox(buffer: pixelBuffer)

        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.isSamplingBusy = false }
            }

            autoreleasepool {
                var ci = CIImage(cvPixelBuffer: box.buffer)
                let extent = ci.extent
                guard extent.width > 32, extent.height > 32 else { return }

                // Giữ độ nét 460px cạnh ngang cho từng ô ảnh để video xuất ra sắc nét, không vỡ hạt
                let targetMaxW: CGFloat = 460.0
                if extent.width > targetMaxW {
                    let s = targetMaxW / extent.width
                    ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
                }

                // Chỉ chạy filter khi người dùng thật sự bật màu phim hoặc Photographic Style
                if isFilmActive && activeFilmPreset != .standard {
                    if let graded = FilmFilterEngine.shared.applyPreset(
                        to: ci,
                        preset: activeFilmPreset,
                        intensity: filmIntensity,
                        isRealtimePreview: true
                    ) {
                        ci = graded
                    }
                } else if !FilmFilterEngine.shared.activePhotographicStyle.isIdentity {
                    ci = FilmFilterEngine.shared.applyPhotographicStyle(
                        to: ci,
                        style: FilmFilterEngine.shared.activePhotographicStyle
                    )
                }

                guard let cg = self.ciContext.createCGImage(ci, from: ci.extent.integral) else { return }
                let jpegData = Self.encodeFastJPEG(cg, quality: 0.72) ?? Data()

                let clipFrame = PhotoboothTimelapseClipFrame(
                    slotIndex: slotIndex,
                    timestamp: now,
                    jpegData: jpegData
                )

                self.lock.withLock {
                    var arr = self.framesBySlot[slotIndex] ?? []
                    arr.append(clipFrame)
                    if arr.count > self.maxFramesPerSlot {
                        arr.removeFirst(arr.count - self.maxFramesPerSlot)
                    }
                    self.framesBySlot[slotIndex] = arr

                    var cgArr = self.decodedImagesBySlot[slotIndex] ?? []
                    cgArr.append(cg)
                    if cgArr.count > self.maxFramesPerSlot {
                        cgArr.removeFirst(cgArr.count - self.maxFramesPerSlot)
                    }
                    self.decodedImagesBySlot[slotIndex] = cgArr
                }
            }
        }
    }

    private static func encodeFastJPEG(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
        }
        return data as Data
    }
}

/// Bộ kết xuất Video Tua Hậu Trường Photobooth chuẩn dọc 9:16 HD sắc nét (720×1280 · 30 FPS · H.264 MP4)
/// sử dụng bộ đệm CGImage trực tiếp, tiền-kết-xuất nền tĩnh theo từng ô (slotBaseCanvasCG) và nội suy chuyển động mượt 30 FPS.
public enum PhotoboothTimelapseExporter {
    public enum ExportError: LocalizedError {
        case noPhotosAvailable
        case writerInitializationFailed(String)
        case pixelBufferPoolUnavailable
        case writerFinalizationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPhotosAvailable:
                return "Cần ít nhất 1 khung ảnh để tạo video."
            case .writerInitializationFailed(let detail):
                return "Không khởi tạo được bộ xuất video MP4: \(detail)"
            case .pixelBufferPoolUnavailable:
                return "Không cấp phát được bộ đệm khung hình video."
            case .writerFinalizationFailed(let detail):
                return "Hoàn tất video thất bại: \(detail)"
            }
        }
    }

    private struct RenderJobSnapshot: @unchecked Sendable {
        let layout: PhotoboothLayout
        let slotRectsInStrip: [CGRect]
        let stripCanvasSize: CGSize
        let stripCornerRadiusRatio: CGFloat
        let usesLightInk: Bool
        let backdropTopColor: UIColor
        let backdropBottomColor: UIColor
        let frameBackgroundCG: CGImage
        let stickersOverlayCG: CGImage?
        let finalSlotCGs: [CGImage?]
        let slotMirrors: [Bool]
        let recordedFramesBySlot: [Int: [PhotoboothTimelapseClipFrame]]
        let preDecodedImagesBySlot: [Int: [CGImage]]
        let style: PhotoboothTimelapseStyle
        let speed: PhotoboothTimelapseSpeed
    }

    @MainActor
    public static func exportTimelapseVideo(
        slots: [PhotoboothSlotPhoto?],
        config: PhotoboothStripConfig,
        stickers: [PlacedPhotoboothSticker],
        assetManager: PhotoboothAssetManager,
        recordedFramesBySlot: [Int: [PhotoboothTimelapseClipFrame]],
        style: PhotoboothTimelapseStyle,
        speed: PhotoboothTimelapseSpeed,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let filledCount = slots.prefix(config.layout.slotCount).compactMap { $0 }.count
        guard filledCount > 0 else {
            throw ExportError.noPhotosAvailable
        }

        // 720×1280 @ 30 FPS: khớp đồng bộ tần số quét màn hình iPhone 60Hz/120Hz (không giật 3:2 pulldown), giữ nguyên độ nét cao
        let outW: CGFloat = 720
        let outH: CGFloat = 1280
        let stripAspect = config.layout.aspectRatio
        let maxStripW = outW * 0.82
        let maxStripH = outH * 0.87
        let stripW = min(maxStripW, maxStripH * stripAspect)
        let stripH = stripW / max(0.2, stripAspect)
        let stripRenderSize = CGSize(width: round(stripW), height: round(stripH))
        let slotRects = config.layout.slotRects(in: stripRenderSize, marginScale: config.marginScale)

        guard let frameBgCG = PhotoboothStripRenderer.renderFrameBackgroundAndFooter(
            config: config,
            assetManager: assetManager,
            canvasSize: stripRenderSize
        ) else {
            throw ExportError.writerInitializationFailed("Không vẽ được khung nền Photobooth.")
        }

        let stickersCG = PhotoboothStripRenderer.renderStickersOverlay(
            stickers: stickers,
            assetManager: assetManager,
            canvasSize: stripRenderSize
        )

        let swatchCols = config.frameStyle.swatchColors
        let topUI = swatchCols.first.map { UIColor($0) } ?? UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0)
        let botUI = swatchCols.last.map { UIColor($0) } ?? UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)

        let slotCount = config.layout.slotCount
        var finalCGs: [CGImage?] = Array(repeating: nil, count: slotCount)
        var mirrors: [Bool] = Array(repeating: false, count: slotCount)
        for i in 0..<slotCount {
            if i < slots.count, let s = slots[i] {
                finalCGs[i] = s.displayImage
                mirrors[i] = s.isMirrored
            }
        }

        let preDecoded = PhotoboothTimelapseRecorder.shared.snapshotDecodedImagesBySlot()

        let snapshot = RenderJobSnapshot(
            layout: config.layout,
            slotRectsInStrip: slotRects,
            stripCanvasSize: stripRenderSize,
            stripCornerRadiusRatio: config.slotCornerRadiusRatio,
            usesLightInk: config.frameStyle.usesLightInk,
            backdropTopColor: darkenedBackdropColor(topUI),
            backdropBottomColor: darkenedBackdropColor(botUI),
            frameBackgroundCG: frameBgCG,
            stickersOverlayCG: stickersCG,
            finalSlotCGs: finalCGs,
            slotMirrors: mirrors,
            recordedFramesBySlot: recordedFramesBySlot,
            preDecodedImagesBySlot: preDecoded,
            style: style,
            speed: speed
        )

        return try await Task.detached(priority: .userInitiated) {
            try await renderMP4OffMainThread(snapshot: snapshot, outW: Int(outW), outH: Int(outH), progressHandler: progressHandler)
        }.value
    }

    private static func darkenedBackdropColor(_ color: UIColor) -> UIColor {
        var r: CGFloat = 0.1, g: CGFloat = 0.1, b: CGFloat = 0.12, a: CGFloat = 1.0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: 0.04 + r * 0.22, green: 0.04 + g * 0.22, blue: 0.05 + b * 0.22, alpha: 1.0)
    }

    // MARK: - Hardware H.264 MP4 Rendering (Off-Main-Thread, Zero Main-Thread Lag, 30 FPS Smooth Interpolation)

    private static func renderMP4OffMainThread(
        snapshot: RenderJobSnapshot,
        outW: Int,
        outH: Int,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignAI_BoothTimelapse_\(UUID().uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
        } catch {
            throw ExportError.writerInitializationFailed(error.localizedDescription)
        }

        let fps: Int32 = 30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_800_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pixelAttrs)

        guard writer.canAdd(input) else {
            throw ExportError.writerInitializationFailed("Không gắn được track video vào AVAssetWriter.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerInitializationFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw ExportError.pixelBufferPoolUnavailable
        }

        let slotCount = snapshot.layout.slotCount
        let maxSlotRenderSide: CGFloat = {
            if snapshot.style == .btsReelsReveal {
                return CGFloat(outH)
            }
            let maxRectSide = snapshot.slotRectsInStrip.reduce(CGFloat(280)) { acc, r in
                max(acc, max(r.width, r.height))
            }
            return min(CGFloat(outH), max(360, maxRectSide * 1.45))
        }()

        // Tiền thu nhỏ ảnh chụp gốc 1 lần duy nhất
        var preScaledFinalCGs: [CGImage?] = Array(repeating: nil, count: slotCount)
        for idx in 0..<slotCount {
            if let raw = snapshot.finalSlotCGs[idx] {
                preScaledFinalCGs[idx] = prescaleCGImageIfNeeded(raw, maxSide: maxSlotRenderSide)
            }
        }

        // Ưu tiên lấy trực tiếp mảng CGImage đã cache sẵn trong RAM (0ms giải mã); nếu thiếu mới fallback giải mã JPEG
        var decodedClips: [[CGImage]] = Array(repeating: [], count: slotCount)
        for idx in 0..<slotCount {
            if let cachedImgs = snapshot.preDecodedImagesBySlot[idx], !cachedImgs.isEmpty {
                decodedClips[idx] = cachedImgs
            } else if let rawFrames = snapshot.recordedFramesBySlot[idx], !rawFrames.isEmpty {
                var imgs: [CGImage] = []
                imgs.reserveCapacity(rawFrames.count)
                for f in rawFrames {
                    if let ui = UIImage(data: f.jpegData), let cg = ui.cgImage {
                        imgs.append(cg)
                    }
                }
                if !imgs.isEmpty {
                    decodedClips[idx] = imgs
                }
            }
            if decodedClips[idx].isEmpty, let finalImg = preScaledFinalCGs[idx] {
                decodedClips[idx] = [finalImg]
            }
        }

        // Nhịp tua mượt ở 30 FPS theo đúng 3 tùy chọn tốc độ (1.25x · 1.5x · 2x)
        let baseMotionFrames: Int = {
            switch snapshot.speed {
            case .x1_25: return 64   // ~2.13s / ô — nhịp 1.25x tự nhiên
            case .x1_5:  return 52   // ~1.73s / ô — nhịp 1.5x cân bằng
            case .x2:    return 40   // ~1.33s / ô — nhịp 2x năng động
            }
        }()
        let framesPerSlotMotion: Int = slotCount >= 7 ? max(24, Int(round(Double(baseMotionFrames) * 0.74))) : baseMotionFrames
        let flashFrames = 3
        let postSnapHoldFrames = 6
        let simultaneousLoopFrames = (snapshot.style == .movingStrip) ? 48 : 0  // 1.6s tất cả các ô cùng động ở 30 FPS
        let finalHeroHoldFrames = 54                                            // 1.8s giữ bản in hoàn chỉnh ở 30 FPS

        let stripOriginX = (CGFloat(outW) - snapshot.stripCanvasSize.width) * 0.5
        let stripOriginY = (CGFloat(outH) - snapshot.stripCanvasSize.height) * 0.5
        let stripFrameInOut = CGRect(origin: CGPoint(x: stripOriginX, y: stripOriginY), size: snapshot.stripCanvasSize)
        let slotCorner = snapshot.stripCornerRadiusRatio > 0.0005
            ? (min(snapshot.stripCanvasSize.width, snapshot.stripCanvasSize.height) * snapshot.stripCornerRadiusRatio)
            : 0.0

        // Vẽ sẵn nền tĩnh 9:16 có bóng đổ dưới dải ảnh (tái sử dụng cho mọi frame)
        let staticBackdropCG = buildBackdropCanvas(
            outW: outW,
            outH: outH,
            topColor: snapshot.backdropTopColor,
            bottomColor: snapshot.backdropBottomColor,
            stripFrame: stripFrameInOut,
            frameBackgroundCG: snapshot.frameBackgroundCG,
            includeStripBase: (snapshot.style == .movingStrip)
        )

        let totalEstimatedFrames: Int = {
            let perSlot = framesPerSlotMotion + flashFrames + postSnapHoldFrames
            return max(1, slotCount * perSlot + simultaneousLoopFrames + finalHeroHoldFrames)
        }()

        var frameCursor: Int64 = 0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        func appendFrame(_ drawBlock: (CGContext) -> Void) async throws {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_500_000)
            }
            var pxBufOut: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pxBufOut)
            guard status == kCVReturnSuccess, let pxBuf = pxBufOut else {
                throw ExportError.pixelBufferPoolUnavailable
            }

            CVPixelBufferLockBaseAddress(pxBuf, [])
            defer { CVPixelBufferUnlockBaseAddress(pxBuf, []) }

            if let base = CVPixelBufferGetBaseAddress(pxBuf),
               let cg = CGContext(
                   data: base,
                   width: outW,
                   height: outH,
                   bitsPerComponent: 8,
                   bytesPerRow: CVPixelBufferGetBytesPerRow(pxBuf),
                   space: colorSpace,
                   bitmapInfo: bitmapInfo
               ) {
                cg.translateBy(x: 0, y: CGFloat(outH))
                cg.scaleBy(x: 1.0, y: -1.0)
                cg.interpolationQuality = .high
                drawBlock(cg)
            }

            let pts = CMTime(value: frameCursor, timescale: fps)
            adaptor.append(pxBuf, withPresentationTime: pts)
            frameCursor += 1

            if frameCursor % 6 == 0 || Int(frameCursor) >= totalEstimatedFrames {
                let pct = min(0.98, Double(frameCursor) / Double(max(1, totalEstimatedFrames)))
                await progressHandler(pct)
            }
        }

        // Helper vẽ 1 ô ảnh đơn lẻ với nội suy mượt giữa 2 frame liên tiếp khi clip ngắn hơn số frame xuất
        func drawInterpolatedClipSlot(
            cg: CGContext,
            clip: [CGImage],
            fallbackImage: CGImage?,
            progress: Double,
            dstRect: CGRect,
            zoom: CGFloat,
            mirrored: Bool
        ) {
            cg.saveGState()
            if slotCorner > 0.5 {
                let clipPath = CGPath(roundedRect: dstRect, cornerWidth: slotCorner, cornerHeight: slotCorner, transform: nil)
                cg.addPath(clipPath)
                cg.clip()
            } else {
                cg.clip(to: dstRect)
            }

            if clip.count > 1 {
                let exactPos = max(0.0, min(Double(clip.count - 1), progress * Double(clip.count - 1)))
                let idx0 = min(clip.count - 1, Int(floor(exactPos)))
                let idx1 = min(clip.count - 1, idx0 + 1)
                let frac = CGFloat(exactPos - Double(idx0))

                drawAspectFillUpright(clip[idx0], in: dstRect, zoom: zoom, mirrored: mirrored, cg: cg)
                // Khi clip có ít frame hơn số frame video (ví dụ hẹn giờ 3s mở ở 1.25x), hòa trộn mềm frame kế tiếp để triệt tiêu hiện tượng khựng bậc thang
                if idx1 != idx0 && clip.count < framesPerSlotMotion && frac > 0.06 && frac < 0.94 {
                    cg.setAlpha(frac)
                    drawAspectFillUpright(clip[idx1], in: dstRect, zoom: zoom, mirrored: mirrored, cg: cg)
                    cg.setAlpha(1.0)
                }
            } else if let single = clip.first ?? fallbackImage {
                drawAspectFillUpright(single, in: dstRect, zoom: zoom, mirrored: mirrored, cg: cg)
            } else {
                let placeholder = snapshot.usesLightInk ? UIColor(white: 0.14, alpha: 1.0) : UIColor(white: 0.90, alpha: 1.0)
                cg.setFillColor(placeholder.cgColor)
                cg.fill(dstRect)
            }
            cg.restoreGState()
        }

        // Helper vẽ dải ảnh tổng hợp
        func drawStripComposite(
            cg: CGContext,
            slotImages: [CGImage?],
            zoomFactors: [CGFloat],
            flashSlotIndex: Int?,
            flashAlpha: CGFloat,
            stripScale: CGFloat = 1.0,
            includeStickers: Bool = true
        ) {
            let fullRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
            if let bg = staticBackdropCG, abs(stripScale - 1.0) < 0.001 && snapshot.style == .movingStrip {
                drawCGImageUpright(bg, in: fullRect, cg: cg)
            } else {
                drawGradient(cg: cg, rect: fullRect, top: snapshot.backdropTopColor, bottom: snapshot.backdropBottomColor)
                cg.saveGState()
                if abs(stripScale - 1.0) > 0.001 {
                    cg.translateBy(x: fullRect.midX, y: fullRect.midY)
                    cg.scaleBy(x: stripScale, y: stripScale)
                    cg.translateBy(x: -fullRect.midX, y: -fullRect.midY)
                }
                cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: UIColor.black.withAlphaComponent(0.52).cgColor)
                drawCGImageUpright(snapshot.frameBackgroundCG, in: stripFrameInOut, cg: cg)
                cg.restoreGState()
            }

            cg.saveGState()
            if abs(stripScale - 1.0) > 0.001 {
                cg.translateBy(x: fullRect.midX, y: fullRect.midY)
                cg.scaleBy(x: stripScale, y: stripScale)
                cg.translateBy(x: -fullRect.midX, y: -fullRect.midY)
            }

            for rectIdx in 0..<snapshot.slotRectsInStrip.count {
                let photoIdx = snapshot.layout.photoIndex(forRenderedRectIndex: rectIdx)
                let localSlot = snapshot.slotRectsInStrip[rectIdx]
                let dst = localSlot.offsetBy(dx: stripFrameInOut.minX, dy: stripFrameInOut.minY)

                cg.saveGState()
                if slotCorner > 0.5 {
                    let clip = CGPath(roundedRect: dst, cornerWidth: slotCorner, cornerHeight: slotCorner, transform: nil)
                    cg.addPath(clip)
                    cg.clip()
                } else {
                    cg.clip(to: dst)
                }

                if photoIdx < slotImages.count, let img = slotImages[photoIdx] {
                    let z = photoIdx < zoomFactors.count ? zoomFactors[photoIdx] : 1.0
                    let mir = photoIdx < snapshot.slotMirrors.count ? snapshot.slotMirrors[photoIdx] : false
                    drawAspectFillUpright(img, in: dst, zoom: z, mirrored: mir, cg: cg)
                } else {
                    let placeholder = snapshot.usesLightInk ? UIColor(white: 0.14, alpha: 1.0) : UIColor(white: 0.90, alpha: 1.0)
                    cg.setFillColor(placeholder.cgColor)
                    cg.fill(dst)
                }

                if flashSlotIndex == photoIdx && flashAlpha > 0.01 {
                    cg.setFillColor(UIColor.white.withAlphaComponent(flashAlpha).cgColor)
                    cg.fill(dst)
                }
                cg.restoreGState()
            }

            if includeStickers, let stOverlay = snapshot.stickersOverlayCG {
                drawCGImageUpright(stOverlay, in: stripFrameInOut, cg: cg)
            }

            cg.restoreGState()
        }

        // Helper tạo sẵn 1 khung ảnh phẳng để blit tức thì
        func bakeStaticCompositeFrame(_ drawBlock: (CGContext) -> Void) -> CGImage? {
            guard let cg = CGContext(
                data: nil,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            cg.translateBy(x: 0, y: CGFloat(outH))
            cg.scaleBy(x: 1.0, y: -1.0)
            cg.interpolationQuality = .high
            drawBlock(cg)
            return cg.makeImage()
        }

        let fullCanvasRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))

        // MARK: - Render Phase 1: Từng ô ảnh chuyển động tạo dáng mượt 30 FPS (Pre-Baked Slot Base Canvas)
        for activeSlot in 0..<slotCount {
            let clip = decodedClips[activeSlot]
            let isStaticOnly = clip.count <= 1
            let activeMirrored = activeSlot < snapshot.slotMirrors.count ? snapshot.slotMirrors[activeSlot] : false

            // Tiền-kết-xuất toàn bộ nền + các ô tĩnh đã chụp (0..<activeSlot) 1 lần duy nhất cho cả pha chuyển động của activeSlot!
            let slotBaseCanvasCG: CGImage? = (snapshot.style == .movingStrip) ? bakeStaticCompositeFrame { cg in
                var staticSlotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                for prev in 0..<activeSlot {
                    staticSlotImgs[prev] = preScaledFinalCGs[prev]
                }
                drawStripComposite(
                    cg: cg,
                    slotImages: staticSlotImgs,
                    zoomFactors: Array(repeating: 1.0, count: slotCount),
                    flashSlotIndex: nil,
                    flashAlpha: 0,
                    stripScale: 1.0,
                    includeStickers: false
                )
            } : nil

            // Danh sách các rect trên dải ảnh thuộc về activeSlot (1 rect cho lưới chuẩn, 2 rect cho twin2x4)
            let activeDstRects: [CGRect] = snapshot.slotRectsInStrip.enumerated().compactMap { rectIdx, localSlot in
                guard snapshot.layout.photoIndex(forRenderedRectIndex: rectIdx) == activeSlot else { return nil }
                return localSlot.offsetBy(dx: stripFrameInOut.minX, dy: stripFrameInOut.minY)
            }

            for f in 0..<framesPerSlotMotion {
                let progress = Double(f) / Double(max(1, framesPerSlotMotion - 1))
                let motionZoom: CGFloat = isStaticOnly ? (1.07 - CGFloat(progress) * 0.07) : 1.0

                try await appendFrame { cg in
                    if snapshot.style == .movingStrip {
                        if let baseCG = slotBaseCanvasCG {
                            drawCGImageUpright(baseCG, in: fullCanvasRect, cg: cg)
                            for dst in activeDstRects {
                                drawInterpolatedClipSlot(
                                    cg: cg,
                                    clip: clip,
                                    fallbackImage: preScaledFinalCGs[activeSlot],
                                    progress: progress,
                                    dstRect: dst,
                                    zoom: motionZoom,
                                    mirrored: activeMirrored
                                )
                            }
                            if let stOverlay = snapshot.stickersOverlayCG {
                                drawCGImageUpright(stOverlay, in: stripFrameInOut, cg: cg)
                            }
                        } else {
                            let clipIdx = min(max(0, clip.count - 1), Int(round(progress * Double(max(0, clip.count - 1)))))
                            var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                            var zooms: [CGFloat] = Array(repeating: 1.0, count: slotCount)
                            for prev in 0..<activeSlot {
                                slotImgs[prev] = preScaledFinalCGs[prev]
                            }
                            slotImgs[activeSlot] = clip.isEmpty ? preScaledFinalCGs[activeSlot] : clip[clipIdx]
                            zooms[activeSlot] = motionZoom
                            drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: zooms, flashSlotIndex: nil, flashAlpha: 0)
                        }
                    } else {
                        drawInterpolatedClipSlot(
                            cg: cg,
                            clip: clip,
                            fallbackImage: preScaledFinalCGs[activeSlot],
                            progress: progress,
                            dstRect: fullCanvasRect,
                            zoom: motionZoom,
                            mirrored: activeMirrored
                        )
                        drawReelsRecBadge(cg: cg, outW: CGFloat(outW), slotIndex: activeSlot + 1, totalSlots: slotCount)
                    }
                }
            }

            // Dựng sẵn frame ngay sau khi chụp xong activeSlot để dùng cho cả hiệu ứng Flash và pha giữ nhịp
            let postHoldBaked = bakeStaticCompositeFrame { cg in
                if snapshot.style == .movingStrip {
                    var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                    for prev in 0...activeSlot {
                        slotImgs[prev] = preScaledFinalCGs[prev]
                    }
                    drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: Array(repeating: 1.0, count: slotCount), flashSlotIndex: nil, flashAlpha: 0)
                } else {
                    if let img = preScaledFinalCGs[activeSlot] {
                        drawAspectFillUpright(img, in: fullCanvasRect, zoom: 1.0, mirrored: activeMirrored, cg: cg)
                    }
                    drawReelsRecBadge(cg: cg, outW: CGFloat(outW), slotIndex: activeSlot + 1, totalSlots: slotCount)
                }
            }

            // Nháy đèn Flash chụp ảnh sắc nét
            for fl in 0..<flashFrames {
                let alpha = CGFloat(1.0 - Double(fl) / Double(flashFrames)) * 0.90
                try await appendFrame { cg in
                    if let baked = postHoldBaked {
                        drawCGImageUpright(baked, in: fullCanvasRect, cg: cg)
                    }
                    cg.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                    if snapshot.style == .movingStrip {
                        for dst in activeDstRects {
                            cg.fill(dst)
                        }
                    } else {
                        cg.fill(fullCanvasRect)
                    }
                }
            }

            // Dừng nhịp rõ nét sau mỗi tấm vừa chụp (blit tức thì)
            for _ in 0..<postSnapHoldFrames {
                try await appendFrame { cg in
                    if let baked = postHoldBaked {
                        drawCGImageUpright(baked, in: fullCanvasRect, cg: cg)
                    }
                }
            }
        }

        // MARK: - Render Phase 2: Tất cả các ô cùng chuyển động đồng bộ 30 FPS (Chữ ký Life4Cuts)
        let allSlotsEmptyBackgroundCG: CGImage? = (simultaneousLoopFrames > 0) ? bakeStaticCompositeFrame { cg in
            drawStripComposite(
                cg: cg,
                slotImages: Array(repeating: nil, count: slotCount),
                zoomFactors: Array(repeating: 1.0, count: slotCount),
                flashSlotIndex: nil,
                flashAlpha: 0,
                stripScale: 1.0,
                includeStickers: false
            )
        } : nil

        for f in 0..<simultaneousLoopFrames {
            let t = Double(f) / Double(max(1, simultaneousLoopFrames - 1))
            try await appendFrame { cg in
                if let bg = allSlotsEmptyBackgroundCG {
                    drawCGImageUpright(bg, in: fullCanvasRect, cg: cg)
                    for rectIdx in 0..<snapshot.slotRectsInStrip.count {
                        let photoIdx = snapshot.layout.photoIndex(forRenderedRectIndex: rectIdx)
                        let dst = snapshot.slotRectsInStrip[rectIdx].offsetBy(dx: stripFrameInOut.minX, dy: stripFrameInOut.minY)
                        let clip = decodedClips[photoIdx]
                        let mir = photoIdx < snapshot.slotMirrors.count ? snapshot.slotMirrors[photoIdx] : false
                        let z: CGFloat = clip.count > 1 ? 1.0 : (1.0 + CGFloat(sin(t * .pi)) * 0.035)
                        drawInterpolatedClipSlot(
                            cg: cg,
                            clip: clip,
                            fallbackImage: preScaledFinalCGs[photoIdx],
                            progress: t,
                            dstRect: dst,
                            zoom: z,
                            mirrored: mir
                        )
                    }
                    if let stOverlay = snapshot.stickersOverlayCG {
                        drawCGImageUpright(stOverlay, in: stripFrameInOut, cg: cg)
                    }
                } else {
                    var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                    var zooms: [CGFloat] = Array(repeating: 1.0, count: slotCount)
                    for idx in 0..<slotCount {
                        let clip = decodedClips[idx]
                        if clip.count > 1 {
                            let cIdx = min(clip.count - 1, Int(round(t * Double(clip.count - 1))))
                            slotImgs[idx] = clip[cIdx]
                        } else {
                            slotImgs[idx] = preScaledFinalCGs[idx]
                            zooms[idx] = 1.0 + CGFloat(sin(t * .pi)) * 0.035
                        }
                    }
                    drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: zooms, flashSlotIndex: nil, flashAlpha: 0)
                }
            }
        }

        // MARK: - Render Phase 3: Lật ảnh & giữ bản in Photobooth hoàn chỉnh sắc nét
        let finalHeroBaked = bakeStaticCompositeFrame { cg in
            drawStripComposite(
                cg: cg,
                slotImages: preScaledFinalCGs,
                zoomFactors: Array(repeating: 1.0, count: slotCount),
                flashSlotIndex: nil,
                flashAlpha: 0,
                stripScale: 1.0
            )
        }
        for f in 0..<finalHeroHoldFrames {
            let revealT = min(1.0, Double(f) / 14.0)
            let eased = 1.0 - pow(1.0 - revealT, 3.0)
            let scale = (snapshot.style == .btsReelsReveal) ? CGFloat(0.91 + 0.09 * eased) : 1.0
            try await appendFrame { cg in
                if abs(scale - 1.0) < 0.001, let baked = finalHeroBaked {
                    drawCGImageUpright(baked, in: fullCanvasRect, cg: cg)
                } else {
                    drawStripComposite(
                        cg: cg,
                        slotImages: preScaledFinalCGs,
                        zoomFactors: Array(repeating: 1.0, count: slotCount),
                        flashSlotIndex: nil,
                        flashAlpha: 0,
                        stripScale: scale
                    )
                }
            }
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ExportError.writerFinalizationFailed(writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)")
        }

        await progressHandler(1.0)
        return outputURL
    }

    // MARK: - CoreGraphics Drawing & Pre-Scaling Primitives

    private static func prescaleCGImageIfNeeded(_ img: CGImage, maxSide: CGFloat) -> CGImage {
        let w = CGFloat(max(1, img.width))
        let h = CGFloat(max(1, img.height))
        let longest = max(w, h)
        guard longest > maxSide * 1.15 else { return img }
        let ratio = maxSide / longest
        let nw = max(2, Int(round(w * ratio)))
        let nh = max(2, Int(round(h * ratio)))
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bi) else {
            return img
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? img
    }

    private static func buildBackdropCanvas(
        outW: Int,
        outH: Int,
        topColor: UIColor,
        bottomColor: UIColor,
        stripFrame: CGRect,
        frameBackgroundCG: CGImage,
        includeStripBase: Bool
    ) -> CGImage? {
        let size = CGSize(width: outW, height: outH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: format).image { uikitCtx in
            let cg = uikitCtx.cgContext
            drawGradient(cg: cg, rect: CGRect(origin: .zero, size: size), top: topColor, bottom: bottomColor)
            if includeStripBase {
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: UIColor.black.withAlphaComponent(0.52).cgColor)
                UIImage(cgImage: frameBackgroundCG).draw(in: stripFrame)
                cg.restoreGState()
            }
        }
        return img.cgImage
    }

    private static func drawGradient(cg: CGContext, rect: CGRect, top: UIColor, bottom: UIColor) {
        let cols = [top.cgColor, bottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        } else {
            cg.setFillColor(top.cgColor)
            cg.fill(rect)
        }
    }

    private static func drawCGImageUpright(_ img: CGImage, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1.0, y: -1.0)
        cg.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cg.restoreGState()
    }

    private static func drawAspectFillUpright(_ img: CGImage, in targetRect: CGRect, zoom: CGFloat, mirrored: Bool, cg: CGContext) {
        let srcW = CGFloat(max(1, img.width))
        let srcH = CGFloat(max(1, img.height))
        let scale = max(targetRect.width / srcW, targetRect.height / srcH) * max(1.0, zoom)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = targetRect.midX - drawW * 0.5
        let drawY = targetRect.midY - drawH * 0.5

        cg.saveGState()
        if mirrored {
            cg.translateBy(x: targetRect.midX, y: 0)
            cg.scaleBy(x: -1.0, y: 1.0)
            cg.translateBy(x: -targetRect.midX, y: 0)
        }
        cg.translateBy(x: drawX, y: drawY + drawH)
        cg.scaleBy(x: 1.0, y: -1.0)
        cg.draw(img, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        cg.restoreGState()
    }

    private static func drawReelsRecBadge(cg: CGContext, outW: CGFloat, slotIndex: Int, totalSlots: Int) {
        let safeSlots = max(1, totalSlots)
        let pillW: CGFloat = min(outW - 56, max(160, 44 + CGFloat(safeSlots) * 20))
        let pillRect = CGRect(x: 28, y: 48, width: pillW, height: 36)
        cg.saveGState()
        let path = CGPath(roundedRect: pillRect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        cg.addPath(path)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        cg.fillPath()

        cg.setFillColor(UIColor(red: 0.96, green: 0.24, blue: 0.24, alpha: 1.0).cgColor)
        cg.fillEllipse(in: CGRect(x: pillRect.minX + 13, y: pillRect.midY - 4.5, width: 9, height: 9))

        let startX = pillRect.minX + 32
        let gap: CGFloat = safeSlots > 5 ? 4.5 : 6.0
        let availW = pillRect.width - 46
        let dotW: CGFloat = max(8, (availW - gap * CGFloat(safeSlots - 1)) / CGFloat(safeSlots))
        let dotY = pillRect.midY - 3.5
        for i in 0..<safeSlots {
            let x = startX + CGFloat(i) * (dotW + gap)
            let isDone = (i + 1) <= slotIndex
            cg.setFillColor((isDone ? UIColor.white : UIColor.white.withAlphaComponent(0.28)).cgColor)
            let bar = CGPath(roundedRect: CGRect(x: x, y: dotY, width: dotW, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            cg.addPath(bar)
            cg.fillPath()
        }
        cg.restoreGState()
    }
}
