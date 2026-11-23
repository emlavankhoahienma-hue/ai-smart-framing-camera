import Foundation
import UIKit
import CoreGraphics

/// Bộ kết xuất dải ảnh Photobooth chuẩn in 300 DPI bằng CoreGraphics thuần (100% sắc nét, ô vuông sắc cạnh chuẩn máy in thật).
/// Hỗ trợ toàn bộ 8 Bố cục (gồm 2×4 & 2×4 Đôi), 25 Khung in thật (với 8 chất liệu giấy/vải studio), Sticker & Date Stamp.
public enum PhotoboothStripRenderer {
    @MainActor
    public static func renderStrip(
        slots: [PhotoboothSlotPhoto?],
        config: PhotoboothStripConfig,
        stickers: [PlacedPhotoboothSticker],
        assetManager: PhotoboothAssetManager,
        targetWidth: CGFloat? = nil
    ) -> CGImage? {
        let baseSize = config.layout.canvasSize
        let renderScale = targetWidth.map { max(0.25, $0 / max(1.0, baseSize.width)) } ?? 1.0
        let canvasSize = CGSize(
            width: round(baseSize.width * renderScale),
            height: round(baseSize.height * renderScale)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let uiImage = UIGraphicsImageRenderer(size: canvasSize, format: format).image { uikitCtx in
            let cg = uikitCtx.cgContext
            let w = canvasSize.width
            let h = canvasSize.height
            let fullRect = CGRect(origin: .zero, size: canvasSize)

            // 1. Nền Khung & Chất liệu giấy/vải studio thật
            drawEditorialFrameBackground(
                cg: cg,
                rect: fullRect,
                config: config,
                assetManager: assetManager
            )

            // 2. Vẽ từng ô ảnh chuẩn tỷ lệ Aspect-Fill với góc vuông sắc cạnh 90° (không bo góc giả)
            let slotRects = config.layout.slotRects(in: canvasSize, marginScale: config.marginScale)
            let slotCorner = config.slotCornerRadiusRatio > 0.0005 ? (min(w, h) * config.slotCornerRadiusRatio) : 0.0

            for (rectIdx, rect) in slotRects.enumerated() {
                let photoIdx = config.layout.photoIndex(forRenderedRectIndex: rectIdx)
                cg.saveGState()
                if slotCorner > 0.5 {
                    let clipPath = UIBezierPath(roundedRect: rect, cornerRadius: slotCorner)
                    cg.addPath(clipPath.cgPath)
                    cg.clip()
                } else {
                    cg.clip(to: rect)
                }

                if photoIdx < slots.count, let slot = slots[photoIdx] {
                    drawAspectFillCGImage(slot.displayImage, in: rect, mirrored: slot.isMirrored, context: cg)
                } else {
                    UIColor(white: config.frameStyle.usesLightInk ? 0.14 : 0.90, alpha: 1.0).setFill()
                    cg.fill(rect)
                }
                cg.restoreGState()

                // Đường viền mảnh gọn (chỉ vẽ rõ trên nền màu/vải, không làm thô ảnh)
                if config.frameStyle == .denimScrapbook || config.frameStyle == .coquettePinstripe || config.frameStyle == .pinkPlushRibbon {
                    cg.saveGState()
                    UIColor.white.withAlphaComponent(0.88).setStroke()
                    let borderPath = UIBezierPath(rect: rect)
                    borderPath.lineWidth = max(1.5, w * 0.0028)
                    borderPath.stroke()
                    cg.restoreGState()
                } else if config.frameStyle == .boardingPass {
                    drawBoardingPassSlotDivider(cg: cg, rect: rect, index: photoIdx, canvasWidth: w)
                }

                if config.frameStyle == .kodak35mmSprocket {
                    drawFilmFrameIndex(index: photoIdx + 1, slotRect: rect, canvasWidth: w)
                }
            }

            // Nếu là bản 2×4 Đôi (2 dải 4×1 song song): vẽ đường kẻ cắt đôi tinh tế ở chính giữa
            if config.layout == .twin2x4 {
                cg.saveGState()
                let cutInk = config.frameStyle.usesLightInk ? UIColor.white.withAlphaComponent(0.28) : UIColor.black.withAlphaComponent(0.20)
                cutInk.setStroke()
                cg.setLineWidth(max(1.0, w * 0.0014))
                cg.setLineDash(phase: 0, lengths: [max(5, h * 0.006), max(4, h * 0.005)])
                cg.move(to: CGPoint(x: w * 0.5, y: h * 0.015))
                cg.addLine(to: CGPoint(x: w * 0.5, y: h * 0.985))
                cg.strokePath()
                cg.restoreGState()
            }

            // Điểm nhấn đồ họa biên tập đặc trưng của từng khung (vòng chữ mờ Life4Cuts, hoa tiết ren, v.v.)
            drawEditorialFrameOverDetails(cg: cg, rect: fullRect, slotRects: slotRects, config: config)

            // 3. Chân trang biên tập (Logo Oldmoon / Mã QR Life4Cuts / Caption / Date Stamp / Mã vạch)
            drawEditorialFooter(
                cg: cg,
                rect: fullRect,
                slotRects: slotRects,
                config: config
            )

            // 4. Sticker Trang Trí
            for sticker in stickers {
                guard let stUI = assetManager.cachedImage(for: sticker.assetSource, id: sticker.assetID),
                      let stCG = stUI.cgImage else { continue }

                let targetW = max(16.0, w * sticker.scale)
                let aspect = CGFloat(stCG.height) / CGFloat(max(1, stCG.width))
                let targetH = targetW * aspect
                let cx = sticker.normalizedX * w
                let cy = sticker.normalizedY * h

                cg.saveGState()
                cg.translateBy(x: cx, y: cy)
                cg.rotate(by: CGFloat(sticker.rotationDegrees * .pi / 180.0))
                cg.setAlpha(CGFloat(sticker.opacity))
                cg.setShadow(
                    offset: CGSize(width: 0, height: w * 0.003),
                    blur: w * 0.010,
                    color: UIColor.black.withAlphaComponent(0.22).cgColor
                )
                let drawBox = CGRect(x: -targetW * 0.5, y: -targetH * 0.5, width: targetW, height: targetH)
                stUI.draw(in: drawBox)
                cg.restoreGState()
            }

            // 5. Hiệu ứng bề mặt giấy in
            drawPaperFinishOverlay(cg: cg, rect: fullRect, finish: config.paperFinish)
        }
        return uiImage.cgImage
    }

    /// Kết xuất riêng nền khung + chân trang (dùng làm lớp tĩnh cho Video Tua Nhanh để xuất nhanh gấp 3 lần).
    @MainActor
    public static func renderFrameBackgroundAndFooter(
        config: PhotoboothStripConfig,
        assetManager: PhotoboothAssetManager,
        canvasSize: CGSize
    ) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let fullRect = CGRect(origin: .zero, size: canvasSize)
        let slotRects = config.layout.slotRects(in: canvasSize, marginScale: config.marginScale)

        let img = UIGraphicsImageRenderer(size: canvasSize, format: format).image { uikitCtx in
            let cg = uikitCtx.cgContext
            drawEditorialFrameBackground(cg: cg, rect: fullRect, config: config, assetManager: assetManager)
            for (rectIdx, rect) in slotRects.enumerated() {
                let photoIdx = config.layout.photoIndex(forRenderedRectIndex: rectIdx)
                if config.frameStyle == .kodak35mmSprocket {
                    drawFilmFrameIndex(index: photoIdx + 1, slotRect: rect, canvasWidth: canvasSize.width)
                } else if config.frameStyle == .boardingPass {
                    drawBoardingPassSlotDivider(cg: cg, rect: rect, index: photoIdx, canvasWidth: canvasSize.width)
                }
            }
            if config.layout == .twin2x4 {
                cg.saveGState()
                let cutInk = config.frameStyle.usesLightInk ? UIColor.white.withAlphaComponent(0.28) : UIColor.black.withAlphaComponent(0.20)
                cutInk.setStroke()
                cg.setLineWidth(max(1.0, canvasSize.width * 0.0014))
                cg.setLineDash(phase: 0, lengths: [max(5, canvasSize.height * 0.006), max(4, canvasSize.height * 0.005)])
                cg.move(to: CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.015))
                cg.addLine(to: CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.985))
                cg.strokePath()
                cg.restoreGState()
            }
            drawEditorialFooter(cg: cg, rect: fullRect, slotRects: slotRects, config: config)
        }
        return img.cgImage
    }

    /// Kết xuất riêng lớp Sticker nền trong suốt (vẽ 1 lần rồi phủ lên mỗi khung hình Video Tua Nhanh).
    @MainActor
    public static func renderStickersOverlay(
        stickers: [PlacedPhotoboothSticker],
        assetManager: PhotoboothAssetManager,
        canvasSize: CGSize
    ) -> CGImage? {
        guard !stickers.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let w = canvasSize.width
        let h = canvasSize.height

        let img = UIGraphicsImageRenderer(size: canvasSize, format: format).image { uikitCtx in
            let cg = uikitCtx.cgContext
            for sticker in stickers {
                guard let stUI = assetManager.cachedImage(for: sticker.assetSource, id: sticker.assetID),
                      let stCG = stUI.cgImage else { continue }
                let targetW = max(12.0, w * sticker.scale)
                let aspect = CGFloat(stCG.height) / CGFloat(max(1, stCG.width))
                let targetH = targetW * aspect
                let cx = sticker.normalizedX * w
                let cy = sticker.normalizedY * h

                cg.saveGState()
                cg.translateBy(x: cx, y: cy)
                cg.rotate(by: CGFloat(sticker.rotationDegrees * .pi / 180.0))
                cg.setAlpha(CGFloat(sticker.opacity))
                cg.setShadow(
                    offset: CGSize(width: 0, height: w * 0.003),
                    blur: w * 0.010,
                    color: UIColor.black.withAlphaComponent(0.22).cgColor
                )
                stUI.draw(in: CGRect(x: -targetW * 0.5, y: -targetH * 0.5, width: targetW, height: targetH))
                cg.restoreGState()
            }
        }
        return img.cgImage
    }

    // MARK: - Editorial Frame Background Painters

    @MainActor
    private static func drawEditorialFrameBackground(
        cg: CGContext,
        rect: CGRect,
        config: PhotoboothStripConfig,
        assetManager: PhotoboothAssetManager
    ) {
        let w = rect.width
        let h = rect.height

        if let hex = config.customBackgroundHex, let customCol = UIColor(hexString: hex) {
            customCol.setFill()
            cg.fill(rect)
            return
        }

        if config.frameStyle == .customAITexture,
           let fname = config.customAITextureFilename,
           let texUI = assetManager.loadFrameTextureImage(filename: fname),
           let texCG = texUI.cgImage {
            drawAspectFillCGImage(texCG, in: rect, mirrored: false, context: cg)
            return
        }

        // Chất liệu vải / giấy studio đóng gói sẵn (Denim, Pinstripe, Đêm Sao Velvet, Hồng Tim, Matcha Linen, Bạc Foil, Lavender, Kraft)
        if let bundledTexName = config.frameStyle.bundledTextureFilename,
           let texUI = assetManager.bundledFrameTextureImage(filename: bundledTexName),
           let texCG = texUI.cgImage {
            drawAspectFillCGImage(texCG, in: rect, mirrored: false, context: cg)
            if config.frameStyle == .starryVelvet {
                drawStarryHeaderText(w: w, h: h)
            }
            return
        }

        switch config.frameStyle {
        case .oldmoonWhite:
            UIColor(red: 0.992, green: 0.992, blue: 0.992, alpha: 1.0).setFill()
            cg.fill(rect)

        case .life4CutsCream, .customAITexture:
            UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1.0).setFill()
            cg.fill(rect)

        case .photoismObsidian:
            UIColor(red: 0.055, green: 0.058, blue: 0.066, alpha: 1.0).setFill()
            cg.fill(rect)

        case .boardingPass:
            UIColor(red: 0.105, green: 0.112, blue: 0.132, alpha: 1.0).setFill()
            cg.fill(rect)
            // Thanh đầu vé máy bay chuẩn Photo Time Airline
            let hdrInk = UIColor(white: 0.92, alpha: 0.85)
            let hdrAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: max(7.0, w * 0.017), weight: .bold),
                .foregroundColor: hdrInk
            ]
            NSString(string: "BOARDING PASS").draw(at: CGPoint(x: w * 0.068, y: h * 0.008), withAttributes: hdrAttrs)
            NSString(string: "ALIGN AIR").draw(at: CGPoint(x: w * 0.72, y: h * 0.008), withAttributes: hdrAttrs)
            UIColor.white.withAlphaComponent(0.24).setFill()
            cg.fill(CGRect(x: w * 0.068, y: h * 0.024, width: w * 0.864, height: max(1.0, h * 0.0008)))

        case .denimScrapbook:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.44, green: 0.57, blue: 0.71, alpha: 1.0),
                bottom: UIColor(red: 0.30, green: 0.42, blue: 0.56, alpha: 1.0))

        case .starryVelvet:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1.0),
                bottom: UIColor(red: 0.11, green: 0.15, blue: 0.30, alpha: 1.0))
            drawStarryHeaderText(w: w, h: h)

        case .coquettePinstripe:
            UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0).setFill()
            cg.fill(rect)
            let stripeW = max(10.0, w * 0.045)
            UIColor(red: 0.78, green: 0.88, blue: 0.96, alpha: 0.55).setFill()
            var sx: CGFloat = 0
            while sx < w {
                cg.fill(CGRect(x: sx, y: 0, width: stripeW * 0.5, height: h))
                sx += stripeW
            }

        case .pinkPlushRibbon:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.99, green: 0.89, blue: 0.92, alpha: 1.0),
                bottom: UIColor(red: 0.96, green: 0.80, blue: 0.86, alpha: 1.0))

        case .haruSkyBlue:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.87, green: 0.93, blue: 0.98, alpha: 1.0),
                bottom: UIColor(red: 0.72, green: 0.84, blue: 0.96, alpha: 1.0))

        case .butterCream:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.99, green: 0.95, blue: 0.78, alpha: 1.0),
                bottom: UIColor(red: 0.96, green: 0.89, blue: 0.64, alpha: 1.0))

        case .kodak35mmSprocket:
            UIColor(red: 0.06, green: 0.06, blue: 0.065, alpha: 1.0).setFill()
            cg.fill(rect)
            let holeW = w * 0.036
            let holeH = holeW * 1.42
            let stepY = holeH * 1.95
            let leftX = w * 0.015
            let rightX = w - w * 0.015 - holeW
            UIColor(red: 0.92, green: 0.90, blue: 0.86, alpha: 1.0).setFill()
            var y = h * 0.025
            while y + holeH < h * 0.975 {
                UIBezierPath(roundedRect: CGRect(x: leftX, y: y, width: holeW, height: holeH), cornerRadius: holeW * 0.22).fill()
                UIBezierPath(roundedRect: CGRect(x: rightX, y: y, width: holeW, height: holeH), cornerRadius: holeW * 0.22).fill()
                y += stepY
            }

        case .dailyNewspaper:
            UIColor(red: 0.925, green: 0.898, blue: 0.842, alpha: 1.0).setFill()
            cg.fill(rect)
            let ink = UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1.0)
            ink.setFill()
            cg.fill(CGRect(x: w * 0.068, y: h * 0.023, width: w * 0.864, height: max(1.5, w * 0.0038)))
            cg.fill(CGRect(x: w * 0.068, y: h * 0.027, width: w * 0.864, height: max(0.8, w * 0.0016)))
            let mastAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia-Bold", size: max(9, w * 0.024)) ?? UIFont.boldSystemFont(ofSize: w * 0.024),
                .foregroundColor: ink
            ]
            let title = NSString(string: "THE ALIGN DAILY")
            let tSize = title.size(withAttributes: mastAttrs)
            title.draw(at: CGPoint(x: (w - tSize.width) * 0.5, y: h * 0.005), withAttributes: mastAttrs)

        case .vintageCinemaTicket:
            UIColor(red: 0.945, green: 0.885, blue: 0.765, alpha: 1.0).setFill()
            cg.fill(rect)
            let border = rect.insetBy(dx: w * 0.028, dy: w * 0.028)
            UIColor(red: 0.58, green: 0.20, blue: 0.18, alpha: 0.65).setStroke()
            let bp = UIBezierPath(rect: border)
            bp.lineWidth = max(1.0, w * 0.0028)
            bp.stroke()
            UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0).setFill()
            let notchR = w * 0.026
            for ny in [h * 0.25, h * 0.50, h * 0.75] {
                cg.fillEllipse(in: CGRect(x: -notchR, y: ny - notchR, width: notchR * 2, height: notchR * 2))
                cg.fillEllipse(in: CGRect(x: w - notchR, y: ny - notchR, width: notchR * 2, height: notchR * 2))
            }

        case .thermalReceipt:
            UIColor(red: 0.975, green: 0.976, blue: 0.968, alpha: 1.0).setFill()
            cg.fill(rect)
            let toothW = w / 28.0
            let toothH = max(5.0, w * 0.014)
            UIColor(red: 0.86, green: 0.86, blue: 0.84, alpha: 1.0).setFill()
            let topPath = UIBezierPath()
            topPath.move(to: CGPoint(x: 0, y: 0))
            for i in 0..<28 {
                topPath.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) * toothW, y: toothH))
                topPath.addLine(to: CGPoint(x: CGFloat(i + 1) * toothW, y: 0))
            }
            topPath.close()
            topPath.fill()

        case .cafeGingham:
            UIColor(red: 0.99, green: 0.96, blue: 0.95, alpha: 1.0).setFill()
            cg.fill(rect)
            let cell = max(16.0, w * 0.068)
            UIColor(red: 0.89, green: 0.44, blue: 0.46, alpha: 0.14).setFill()
            var x: CGFloat = 0
            while x < w {
                cg.fill(CGRect(x: x, y: 0, width: cell * 0.5, height: h))
                x += cell
            }
            var y: CGFloat = 0
            while y < h {
                cg.fill(CGRect(x: 0, y: y, width: w, height: cell * 0.5))
                y += cell
            }

        case .y2kBrushedChrome:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.84, green: 0.86, blue: 0.89, alpha: 1.0),
                bottom: UIColor(red: 0.68, green: 0.71, blue: 0.76, alpha: 1.0))

        case .lavenderWatercolor:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.90, green: 0.87, blue: 0.98, alpha: 1.0),
                bottom: UIColor(red: 0.82, green: 0.87, blue: 0.98, alpha: 1.0))

        case .vintageKraftPaper:
            UIColor(red: 0.94, green: 0.90, blue: 0.82, alpha: 1.0).setFill()
            cg.fill(rect)

        case .coquetteSilkRibbon:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.988, green: 0.910, blue: 0.928, alpha: 1.0),
                bottom: UIColor(red: 0.955, green: 0.835, blue: 0.868, alpha: 1.0))

        case .matchaGarden:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.86, green: 0.90, blue: 0.80, alpha: 1.0),
                bottom: UIColor(red: 0.74, green: 0.82, blue: 0.66, alpha: 1.0))

        case .berryNightFlash:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.25, green: 0.055, blue: 0.095, alpha: 1.0),
                bottom: UIColor(red: 0.14, green: 0.03, blue: 0.055, alpha: 1.0))

        case .cocoaVintage:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.24, green: 0.17, blue: 0.14, alpha: 1.0),
                bottom: UIColor(red: 0.16, green: 0.11, blue: 0.09, alpha: 1.0))

        case .sunsetSilk:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.98, green: 0.86, blue: 0.76, alpha: 1.0),
                bottom: UIColor(red: 0.95, green: 0.69, blue: 0.62, alpha: 1.0))

        case .softPearl:
            UIColor(red: 0.988, green: 0.988, blue: 0.992, alpha: 1.0).setFill()
            cg.fill(rect)
        }
    }

    private static func drawStarryHeaderText(w: CGFloat, h: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let font = UIFont(name: "Georgia-Italic", size: max(9.0, w * 0.024)) ?? UIFont.italicSystemFont(ofSize: max(9.0, w * 0.024))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 0.95, green: 0.93, blue: 0.84, alpha: 0.90),
            .paragraphStyle: para
        ]
        NSString(string: "Make Your Own Special Memories").draw(
            in: CGRect(x: w * 0.05, y: h * 0.008, width: w * 0.90, height: h * 0.024),
            withAttributes: attrs
        )
    }

    private static func drawBoardingPassSlotDivider(cg: CGContext, rect: CGRect, index: Int, canvasWidth: CGFloat) {
        let labels = ["FLIGHT  AL-04", "SEAT  12A", "GATE  04B", "BOARDING"]
        let tag = labels[index % labels.count]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(6.5, canvasWidth * 0.013), weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.58)
        ]
        NSString(string: tag).draw(at: CGPoint(x: rect.minX + 2, y: rect.maxY + 2), withAttributes: attrs)
        _ = cg
    }

    private static func drawEditorialFrameOverDetails(
        cg: CGContext,
        rect: CGRect,
        slotRects: [CGRect],
        config: PhotoboothStripConfig
    ) {
        let w = rect.width
        let h = rect.height

        // Vòng dấu tròn tinh tế trên nền Đen Life4Cuts (như dải đen trong ảnh mẫu)
        if config.frameStyle == .photoismObsidian && slotRects.count >= 3 {
            let r = min(w, h) * 0.14
            let cx = w * 0.5
            let cy = (slotRects[1].maxY + slotRects[2].minY) * 0.5
            cg.saveGState()
            UIColor.white.withAlphaComponent(0.24).setStroke()
            cg.setLineWidth(max(1.0, w * 0.0018))
            cg.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            cg.setLineWidth(max(0.7, w * 0.0010))
            cg.strokeEllipse(in: CGRect(x: cx - r * 0.86, y: cy - r * 0.86, width: r * 1.72, height: r * 1.72))
            cg.restoreGState()
        }

        // Đường viền ren lượn sóng nhẹ cho khung Sọc Ren Coquette
        if config.frameStyle == .coquettePinstripe {
            cg.saveGState()
            UIColor.white.withAlphaComponent(0.72).setStroke()
            let inset = rect.insetBy(dx: w * 0.020, dy: w * 0.020)
            let p = UIBezierPath(rect: inset)
            p.lineWidth = max(1.2, w * 0.0024)
            p.setLineDash([max(4, w * 0.010), max(3, w * 0.008)], count: 2, phase: 0)
            p.stroke()
            cg.restoreGState()
        }
    }

    private static func drawFilmFrameIndex(index: Int, slotRect: CGRect, canvasWidth: CGFloat) {
        let ink = UIColor(red: 0.94, green: 0.67, blue: 0.24, alpha: 0.88)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(7.0, canvasWidth * 0.016), weight: .bold),
            .foregroundColor: ink
        ]
        NSString(string: "\(index)A").draw(at: CGPoint(x: slotRect.minX + 4, y: slotRect.maxY + 2), withAttributes: attrs)
    }

    private static func drawEditorialFooter(
        cg: CGContext,
        rect: CGRect,
        slotRects: [CGRect],
        config: PhotoboothStripConfig
    ) {
        let w = rect.width
        let h = rect.height
        let bottomSlotY = slotRects.map(\.maxY).max() ?? (h * 0.85)
        let footerTop = bottomSlotY + h * 0.012
        let footerH = max(14.0, h - footerTop)
        let ink = config.frameStyle.usesLightInk
            ? UIColor(white: 0.95, alpha: 0.92)
            : UIColor(white: 0.12, alpha: 0.90)
        let subInk = ink.withAlphaComponent(0.58)

        let rawCaption = config.customCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultCaption: String = {
            switch config.frameStyle {
            case .denimScrapbook: return "Photo Story"
            case .boardingPass: return "PHOTO TIME"
            case .oldmoonWhite: return "ALIGN STUDIO"
            default: return "ALIGN STUDIO"
            }
        }()
        let displayCaption = rawCaption.isEmpty ? defaultCaption : rawCaption

        let df = DateFormatter()
        df.dateFormat = "yyyy . MM . dd"
        let dateStr = df.string(from: Date())

        // Nếu là bản 2×4 Đôi: vẽ chân trang cân đối cho CẢ 2 dải trái & phải!
        let footerColumns: [CGRect] = (config.layout == .twin2x4)
            ? [CGRect(x: 0, y: footerTop, width: w * 0.5, height: footerH), CGRect(x: w * 0.5, y: footerTop, width: w * 0.5, height: footerH)]
            : [CGRect(x: 0, y: footerTop, width: w, height: footerH)]

        for colRect in footerColumns {
            let cw = colRect.width
            let cx0 = colRect.minX

            if config.frameStyle == .thermalReceipt {
                let barW = cw * 0.44
                let barX = cx0 + (cw - barW) * 0.5
                let barY = footerTop + footerH * 0.44
                let barH = footerH * 0.28
                ink.setFill()
                var bx = barX
                var k = 0
                while bx < barX + barW {
                    let lw = CGFloat(((k * 7 + 3) % 4) + 1) * max(1.0, cw * 0.003)
                    if k % 2 == 0 {
                        cg.fill(CGRect(x: bx, y: barY, width: lw, height: barH))
                    }
                    bx += lw + max(1.0, cw * 0.002)
                    k += 1
                }
            }

            // Huy hiệu oval tối giản chuẩn Oldmoon (ảnh mẫu 3)
            if config.frameStyle == .oldmoonWhite {
                let ovalW = cw * 0.44
                let ovalH = min(footerH * 0.52, cw * 0.13)
                let ovalRect = CGRect(x: cx0 + (cw - ovalW) * 0.5, y: footerTop + footerH * 0.22, width: ovalW, height: ovalH)
                cg.saveGState()
                ink.setStroke()
                cg.setLineWidth(max(1.2, cw * 0.0032))
                cg.strokeEllipse(in: ovalRect)
                cg.restoreGState()
            }

            // Mã QR vuông sắc nét góc chân trang (chuẩn Life4Cuts & Photo Time Boarding Pass)
            if config.frameStyle == .photoismObsidian || config.frameStyle == .boardingPass {
                let qrSize = min(footerH * 0.56, cw * 0.13)
                let qrX = (config.frameStyle == .boardingPass) ? (cx0 + cw * 0.068) : (cx0 + cw - cw * 0.068 - qrSize)
                let qrY = footerTop + (footerH - qrSize) * 0.5
                drawCrispStudioQR(cg: cg, rect: CGRect(x: qrX, y: qrY, width: qrSize, height: qrSize), fg: ink, bg: config.frameStyle.usesLightInk ? UIColor.black : UIColor.white)
            }

            let titleFontSize = max(9.0, cw * (config.frameStyle == .denimScrapbook ? 0.036 : 0.028))
            let dateFontSize = max(7.0, cw * 0.018)

            let para = NSMutableParagraphStyle()
            para.alignment = .center

            let titleFont: UIFont = {
                if config.frameStyle == .denimScrapbook {
                    return UIFont(name: "Georgia-BoldItalic", size: titleFontSize) ?? UIFont.italicSystemFont(ofSize: titleFontSize)
                } else if config.frameStyle == .oldmoonWhite {
                    return UIFont(name: "Georgia-Bold", size: titleFontSize * 0.92) ?? UIFont.boldSystemFont(ofSize: titleFontSize * 0.92)
                }
                return UIFont.systemFont(ofSize: titleFontSize, weight: .bold)
            }()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: ink,
                .kern: NSNumber(value: Double(cw * (config.frameStyle == .denimScrapbook ? 0.001 : 0.004))),
                .paragraphStyle: para
            ]
            let textToDraw = (config.frameStyle == .denimScrapbook) ? displayCaption : displayCaption.uppercased()
            let titleY: CGFloat = {
                if config.frameStyle == .thermalReceipt { return footerTop + footerH * 0.08 }
                if config.frameStyle == .oldmoonWhite { return footerTop + footerH * 0.34 }
                return footerTop + footerH * 0.24
            }()
            let titleRect = CGRect(x: cx0 + cw * 0.08, y: titleY, width: cw * 0.84, height: titleFontSize * 1.4)
            NSString(string: textToDraw).draw(in: titleRect, withAttributes: titleAttrs)

            if config.showDateStamp && config.frameStyle != .oldmoonWhite {
                let dateAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: dateFontSize, weight: .medium),
                    .foregroundColor: subInk,
                    .paragraphStyle: para
                ]
                let dateY = config.frameStyle == .thermalReceipt ? (footerTop + footerH * 0.76) : (titleRect.maxY + 2)
                let dateRect = CGRect(x: cx0 + cw * 0.08, y: dateY, width: cw * 0.84, height: dateFontSize * 1.3)
                NSString(string: dateStr).draw(in: dateRect, withAttributes: dateAttrs)
            }
        }
    }

    private static func drawCrispStudioQR(cg: CGContext, rect: CGRect, fg: UIColor, bg: UIColor) {
        cg.saveGState()
        bg.withAlphaComponent(0.92).setFill()
        cg.fill(rect)
        let pad = rect.width * 0.10
        let inner = rect.insetBy(dx: pad, dy: pad)
        let grid = 9
        let cell = inner.width / CGFloat(grid)
        fg.setFill()
        // 3 góc finder chuẩn QR + các điểm dữ liệu hình học sắc nét
        let pattern: [[Int]] = [
            [1,1,1,0,1,0,1,1,1],
            [1,0,1,0,0,1,1,0,1],
            [1,1,1,0,1,0,1,1,1],
            [0,0,0,1,0,1,0,0,0],
            [1,0,1,1,1,0,1,0,1],
            [0,1,0,0,1,1,0,1,0],
            [1,1,1,0,1,0,1,0,1],
            [1,0,1,0,0,1,0,1,0],
            [1,1,1,0,1,0,1,1,1],
        ]
        for r in 0..<grid {
            for c in 0..<grid where pattern[r][c] == 1 {
                cg.fill(CGRect(x: inner.minX + CGFloat(c) * cell, y: inner.minY + CGFloat(r) * cell, width: cell * 0.96, height: cell * 0.96))
            }
        }
        cg.restoreGState()
    }

    private static func drawAspectFillCGImage(_ img: CGImage, in targetRect: CGRect, mirrored: Bool, context cg: CGContext) {
        let srcW = CGFloat(img.width)
        let srcH = CGFloat(img.height)
        guard srcW > 0, srcH > 0, targetRect.width > 0, targetRect.height > 0 else { return }

        let scale = max(targetRect.width / srcW, targetRect.height / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = targetRect.midX - drawW * 0.5
        let drawY = targetRect.midY - drawH * 0.5

        cg.saveGState()
        cg.interpolationQuality = .high
        if mirrored {
            cg.translateBy(x: targetRect.midX, y: 0)
            cg.scaleBy(x: -1.0, y: 1.0)
            cg.translateBy(x: -targetRect.midX, y: 0)
        }
        UIImage(cgImage: img).draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        cg.restoreGState()
    }

    private static func drawVerticalGradient(cg: CGContext, rect: CGRect, top: UIColor, bottom: UIColor) {
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) else {
            top.setFill()
            cg.fill(rect)
            return
        }
        cg.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    }

    private static func drawPaperFinishOverlay(cg: CGContext, rect: CGRect, finish: PhotoboothPaperFinish) {
        switch finish {
        case .mattePaper:
            return
        case .glossyBooth:
            cg.saveGState()
            let colors = [
                UIColor.white.withAlphaComponent(0.13).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.05).cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.45, 1.0]) {
                cg.drawLinearGradient(
                    grad,
                    start: CGPoint(x: rect.minX, y: rect.minY),
                    end: CGPoint(x: rect.maxX, y: rect.maxY * 0.72),
                    options: []
                )
            }
            cg.restoreGState()
        case .filmGrain:
            cg.saveGState()
            UIColor(white: 0.5, alpha: 0.042).setFill()
            let step = max(6.0, rect.width * 0.012)
            var y: CGFloat = 0
            var idx = 13
            while y < rect.height {
                var x: CGFloat = 0
                while x < rect.width {
                    idx = (idx &* 1103515245 &+ 12345) & 0x7FFFFFFF
                    if (idx % 3) == 0 {
                        cg.fill(CGRect(x: x, y: y, width: max(1.0, step * 0.35), height: max(1.0, step * 0.35)))
                    }
                    x += step
                }
                y += step
            }
            cg.restoreGState()
        }
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let val = UInt64(cleaned, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
