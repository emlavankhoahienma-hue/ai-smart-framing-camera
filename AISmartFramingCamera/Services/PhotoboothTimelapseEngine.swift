import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import UIKit

/// Bộ ghi khung hình hậu trường siêu nhẹ (~6–7 FPS, nén JPEG nhỏ <= 420px, giới hạn vòng 36 khung/ô)
/// để tạo Video Tua Nhanh kiểu Life4Cuts / Photoism sau khi chụp Photobooth mà không chạm vào CameraService bị khóa.
public final class PhotoboothTimelapseRecorder: @unchecked Sendable {
    public static let shared = PhotoboothTimelapseRecorder()

    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.alignai.photobooth.timelapse.capture", qos: .utility)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: true, .cacheIntermediates: false])

    private var framesBySlot: [Int: [PhotoboothTimelapseClipFrame]] = [:]
    private var maxFramesPerSlot: Int = 36
    private var lastCaptureTime: CFTimeInterval = 0
    private var isSamplingBusy: Bool = false

    private init() {}

    public func resetAll() {
        lock.withLock {
            framesBySlot.removeAll()
            lastCaptureTime = 0
        }
    }

    public func clearSlot(_ slotIndex: Int) {
        lock.withLock {
            framesBySlot[slotIndex] = []
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

    /// Lấy mẫu 1 khung từ `CVPixelBuffer` đang phát live (throttle >= 140ms ~7 FPS, áp nhẹ màu phim/Photographic Style đang chọn).
    public func samplePixelBufferIfDue(
        _ pixelBuffer: CVPixelBuffer,
        slotIndex: Int,
        activeFilmPreset: FilmPreset,
        filmIntensity: Float,
        isFilmActive: Bool
    ) {
        let now = CACurrentMediaTime()
        let shouldProceed: Bool = lock.withLock {
            if isSamplingBusy || (now - lastCaptureTime) < 0.145 {
                return false
            }
            lastCaptureTime = now
            isSamplingBusy = true
            return true
        }
        guard shouldProceed else { return }

        // CVPixelBuffer được retain tự động trong closure cho đến khi nén xong sang JPEG nhẹ
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

                // Thu nhỏ về tối đa 420px cạnh ngang để giữ RAM thấp (~25–35KB/khung) và xuất MP4 cực nhanh
                let targetMaxW: CGFloat = 420.0
                if extent.width > targetMaxW {
                    let s = targetMaxW / extent.width
                    ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
                }

                // Áp đồng bộ màu live (Photographic Styles / Film Simulation đang bật)
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
                let ui = UIImage(cgImage: cg)
                guard let jpeg = ui.jpegData(compressionQuality: 0.68) else { return }

                let clipFrame = PhotoboothTimelapseClipFrame(
                    slotIndex: slotIndex,
                    timestamp: now,
                    jpegData: jpeg
                )

                self.lock.withLock {
                    var arr = self.framesBySlot[slotIndex] ?? []
                    arr.append(clipFrame)
                    if arr.count > self.maxFramesPerSlot {
                        arr.removeFirst(arr.count - self.maxFramesPerSlot)
                    }
                    self.framesBySlot[slotIndex] = arr
                }
            }
        }
    }
}

/// Bộ kết xuất Video Tua Nhanh Photobooth chuẩn dọc 9:16 Full HD (1080×1920 · 30 FPS · H.264 MP4)
/// sẵn sàng đăng ngay lên TikTok / Instagram Reels / Facebook Story.
public enum PhotoboothTimelapseExporter {
    public enum ExportError: LocalizedError {
        case noPhotosAvailable
        case writerInitializationFailed(String)
        case pixelBufferPoolUnavailable
        case writerFinalizationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPhotosAvailable:
                return "Cần ít nhất 1 khung ảnh để tạo video tua nhanh."
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

        // Kích thước dải ảnh tỉ lệ gọn khớp màn hình 1080×1920 (giữ margin đẹp, đủ chỗ bóng đổ & viền)
        let outW: CGFloat = 1080
        let outH: CGFloat = 1920
        let stripAspect = config.layout.aspectRatio
        let maxStripW = outW * 0.80
        let maxStripH = outH * 0.86
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
        return UIColor(red: 0.05 + r * 0.24, green: 0.05 + g * 0.24, blue: 0.06 + b * 0.24, alpha: 1.0)
    }

    // MARK: - Hardware H.264 MP4 Rendering (Off-Main-Thread)

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
        } catch {
            throw ExportError.writerInitializationFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30
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
        let fps: Int32 = 30

        // Giải mã sẵn ảnh hậu trường cho từng ô (nếu người dùng nhập ảnh từ Thư viện thì tự tạo mảng khung mượt từ ảnh chính)
        var decodedClips: [[CGImage]] = Array(repeating: [], count: slotCount)
        for idx in 0..<slotCount {
            if let rawFrames = snapshot.recordedFramesBySlot[idx], !rawFrames.isEmpty {
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
            if decodedClips[idx].isEmpty, let finalImg = snapshot.finalSlotCGs[idx] {
                decodedClips[idx] = [finalImg]
            }
        }

        // Xây dựng kịch bản từng frame ở 30 FPS tùy theo tốc độ tua (2x / 3x / 4x)
        let framesPerSlotMotion: Int = {
            switch snapshot.speed {
            case .x2: return 42   // ~1.4s / ô
            case .x3: return 28   // ~0.93s / ô
            case .x4: return 20   // ~0.66s / ô
            }
        }()
        let flashFrames = 4
        let postSnapHoldFrames = 6
        let simultaneousLoopFrames = (snapshot.style == .movingStrip) ? 45 : 0  // 1.5s tất cả các ô cùng động
        let finalHeroHoldFrames = 52                                            // ~1.7s giữ bản in hoàn chỉnh

        let stripOriginX = (CGFloat(outW) - snapshot.stripCanvasSize.width) * 0.5
        let stripOriginY = (CGFloat(outH) - snapshot.stripCanvasSize.height) * 0.5
        let stripFrameInOut = CGRect(origin: CGPoint(x: stripOriginX, y: stripOriginY), size: snapshot.stripCanvasSize)
        let slotCorner = min(snapshot.stripCanvasSize.width, snapshot.stripCanvasSize.height) * snapshot.stripCornerRadiusRatio

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
                try await Task.sleep(nanoseconds: 5_000_000)
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
                // Đưa hệ tọa độ về chuẩn Top-Left giống UIKit để vẽ đồng nhất 100%
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

        // Helper vẽ dải ảnh với trạng thái khung hình cụ thể của từng ô + hiệu ứng flash
        func drawStripComposite(
            cg: CGContext,
            slotImages: [CGImage?],
            zoomFactors: [CGFloat],
            flashSlotIndex: Int?,
            flashAlpha: CGFloat,
            stripScale: CGFloat = 1.0
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
                cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: UIColor.black.withAlphaComponent(0.55).cgColor)
                drawCGImageUpright(snapshot.frameBackgroundCG, in: stripFrameInOut, cg: cg)
                cg.restoreGState()
            }

            cg.saveGState()
            if abs(stripScale - 1.0) > 0.001 {
                cg.translateBy(x: fullRect.midX, y: fullRect.midY)
                cg.scaleBy(x: stripScale, y: stripScale)
                cg.translateBy(x: -fullRect.midX, y: -fullRect.midY)
            }

            for idx in 0..<min(slotCount, snapshot.slotRectsInStrip.count) {
                let localSlot = snapshot.slotRectsInStrip[idx]
                let dst = localSlot.offsetBy(dx: stripFrameInOut.minX, dy: stripFrameInOut.minY)

                cg.saveGState()
                let clip = CGPath(roundedRect: dst, cornerWidth: slotCorner, cornerHeight: slotCorner, transform: nil)
                cg.addPath(clip)
                cg.clip()

                if idx < slotImages.count, let img = slotImages[idx] {
                    let z = idx < zoomFactors.count ? zoomFactors[idx] : 1.0
                    let mir = idx < snapshot.slotMirrors.count ? snapshot.slotMirrors[idx] : false
                    drawAspectFillUpright(img, in: dst, zoom: z, mirrored: mir, cg: cg)
                } else {
                    let placeholder = snapshot.usesLightInk ? UIColor(white: 0.14, alpha: 1.0) : UIColor(white: 0.88, alpha: 1.0)
                    cg.setFillColor(placeholder.cgColor)
                    cg.fill(dst)
                }

                if flashSlotIndex == idx && flashAlpha > 0.01 {
                    cg.setFillColor(UIColor.white.withAlphaComponent(flashAlpha).cgColor)
                    cg.fill(dst)
                }
                cg.restoreGState()
            }

            // Phủ lớp Sticker trang trí (đã kết xuất sẵn 1 lần) lên trên cùng
            if let stOverlay = snapshot.stickersOverlayCG {
                drawCGImageUpright(stOverlay, in: stripFrameInOut, cg: cg)
            }

            cg.restoreGState()
        }

        // MARK: - Render Phase 1: Từng ô ảnh tua nhanh quá trình tạo dáng & chụp
        for activeSlot in 0..<slotCount {
            let clip = decodedClips[activeSlot]
            let isStaticOnly = clip.count <= 1

            for f in 0..<framesPerSlotMotion {
                let progress = Double(f) / Double(max(1, framesPerSlotMotion - 1))
                let clipIdx = min(max(0, clip.count - 1), Int(progress * Double(max(0, clip.count - 1))))
                let motionZoom: CGFloat = isStaticOnly ? (1.08 - CGFloat(progress) * 0.08) : 1.0

                try await appendFrame { cg in
                    if snapshot.style == .movingStrip {
                        var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                        var zooms: [CGFloat] = Array(repeating: 1.0, count: slotCount)
                        for prev in 0..<activeSlot {
                            slotImgs[prev] = snapshot.finalSlotCGs[prev]
                        }
                        slotImgs[activeSlot] = clip.isEmpty ? snapshot.finalSlotCGs[activeSlot] : clip[clipIdx]
                        zooms[activeSlot] = motionZoom
                        drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: zooms, flashSlotIndex: nil, flashAlpha: 0)
                    } else {
                        // Style 2: Hậu trường Full-Bleed Reels 9:16
                        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
                        if let img = (clip.isEmpty ? snapshot.finalSlotCGs[activeSlot] : clip[clipIdx]) {
                            let mir = activeSlot < snapshot.slotMirrors.count ? snapshot.slotMirrors[activeSlot] : false
                            drawAspectFillUpright(img, in: fullRect, zoom: motionZoom, mirrored: mir, cg: cg)
                        }
                        drawReelsRecBadge(cg: cg, outW: CGFloat(outW), slotIndex: activeSlot + 1, totalSlots: slotCount)
                    }
                }
            }

            // Nháy đèn Flash chụp ảnh sắc nét
            for fl in 0..<flashFrames {
                let alpha = CGFloat(1.0 - Double(fl) / Double(flashFrames)) * 0.92
                try await appendFrame { cg in
                    if snapshot.style == .movingStrip {
                        var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                        for prev in 0...activeSlot {
                            slotImgs[prev] = snapshot.finalSlotCGs[prev]
                        }
                        drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: Array(repeating: 1.0, count: slotCount), flashSlotIndex: activeSlot, flashAlpha: alpha)
                    } else {
                        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
                        if let img = snapshot.finalSlotCGs[activeSlot] {
                            let mir = activeSlot < snapshot.slotMirrors.count ? snapshot.slotMirrors[activeSlot] : false
                            drawAspectFillUpright(img, in: fullRect, zoom: 1.0, mirrored: mir, cg: cg)
                        }
                        cg.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
                        cg.fill(fullRect)
                    }
                }
            }

            // Dừng nhịp ngắn cho người xem thấy tấm ảnh vừa chụp
            for _ in 0..<postSnapHoldFrames {
                try await appendFrame { cg in
                    if snapshot.style == .movingStrip {
                        var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                        for prev in 0...activeSlot {
                            slotImgs[prev] = snapshot.finalSlotCGs[prev]
                        }
                        drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: Array(repeating: 1.0, count: slotCount), flashSlotIndex: nil, flashAlpha: 0)
                    } else {
                        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
                        if let img = snapshot.finalSlotCGs[activeSlot] {
                            let mir = activeSlot < snapshot.slotMirrors.count ? snapshot.slotMirrors[activeSlot] : false
                            drawAspectFillUpright(img, in: fullRect, zoom: 1.0, mirrored: mir, cg: cg)
                        }
                        drawReelsRecBadge(cg: cg, outW: CGFloat(outW), slotIndex: activeSlot + 1, totalSlots: slotCount)
                    }
                }
            }
        }

        // MARK: - Render Phase 2: Tất cả các ô cùng chuyển động đồng bộ (Chữ ký Life4Cuts)
        for f in 0..<simultaneousLoopFrames {
            let t = Double(f) / Double(max(1, simultaneousLoopFrames - 1))
            try await appendFrame { cg in
                var slotImgs: [CGImage?] = Array(repeating: nil, count: slotCount)
                var zooms: [CGFloat] = Array(repeating: 1.0, count: slotCount)
                for idx in 0..<slotCount {
                    let clip = decodedClips[idx]
                    if clip.count > 1 {
                        let cIdx = min(clip.count - 1, Int(t * Double(clip.count - 1)))
                        slotImgs[idx] = clip[cIdx]
                    } else {
                        slotImgs[idx] = snapshot.finalSlotCGs[idx]
                        zooms[idx] = 1.0 + CGFloat(sin(t * .pi)) * 0.04
                    }
                }
                drawStripComposite(cg: cg, slotImages: slotImgs, zoomFactors: zooms, flashSlotIndex: nil, flashAlpha: 0)
            }
        }

        // MARK: - Render Phase 3: Lật ảnh & giữ bản in Photobooth hoàn chỉnh tuyệt đẹp
        for f in 0..<finalHeroHoldFrames {
            let revealT = min(1.0, Double(f) / 14.0)
            let eased = 1.0 - pow(1.0 - revealT, 3.0)
            let scale = (snapshot.style == .btsReelsReveal) ? CGFloat(0.90 + 0.10 * eased) : 1.0
            try await appendFrame { cg in
                drawStripComposite(
                    cg: cg,
                    slotImages: snapshot.finalSlotCGs,
                    zoomFactors: Array(repeating: 1.0, count: slotCount),
                    flashSlotIndex: nil,
                    flashAlpha: 0,
                    stripScale: scale
                )
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

    // MARK: - CoreGraphics Drawing Primitives (Top-Left Flipped Space)

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
                cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: UIColor.black.withAlphaComponent(0.55).cgColor)
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

    /// Vẽ CGImage đứng đúng chiều trong CGContext đã lật trục Y top-left.
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
        let pillRect = CGRect(x: 42, y: 74, width: 224, height: 52)
        cg.saveGState()
        let path = CGPath(roundedRect: pillRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
        cg.addPath(path)
        cg.setFillColor(UIColor.black.withAlphaComponent(0.58).cgColor)
        cg.fillPath()

        cg.setFillColor(UIColor(red: 0.96, green: 0.24, blue: 0.24, alpha: 1.0).cgColor)
        cg.fillEllipse(in: CGRect(x: pillRect.minX + 18, y: pillRect.midY - 7, width: 14, height: 14))

        // Vẽ chỉ báo số ô chụp gọn gàng bằng các thanh chấm (tránh dùng NSString.draw ngoài UIGraphics context)
        let dotY = pillRect.midY - 5
        let startX = pillRect.minX + 48
        let dotW: CGFloat = min(28, (pillRect.width - 72) / CGFloat(max(1, totalSlots)))
        for i in 0..<totalSlots {
            let x = startX + CGFloat(i) * (dotW + 8)
            let isDone = (i + 1) <= slotIndex
            cg.setFillColor((isDone ? UIColor.white : UIColor.white.withAlphaComponent(0.28)).cgColor)
            let bar = CGPath(roundedRect: CGRect(x: x, y: dotY, width: dotW, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil)
            cg.addPath(bar)
            cg.fillPath()
        }
        cg.restoreGState()
        _ = outW
    }
}
