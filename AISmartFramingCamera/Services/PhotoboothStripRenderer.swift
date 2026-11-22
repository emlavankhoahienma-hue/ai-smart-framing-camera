import Foundation
import UIKit
import CoreGraphics

/// Bộ kết xuất dải ảnh Photobooth chuẩn in 300 DPI bằng CoreGraphics thuần (100% sắc nét không bị mờ).
/// Hỗ trợ toàn bộ 6 Bố cục, 16 Khung thiết kế biên tập, AI Frame Texture, Sticker xoay/phóng/đổ bóng & Date Stamp.
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

            // 1. Nền Khung & Hoa văn thiết kế đặc trưng (không bị AI hóa lộn xộn)
            drawEditorialFrameBackground(
                cg: cg,
                rect: fullRect,
                config: config,
                assetManager: assetManager
            )

            // 2. Vẽ từng ô ảnh chuẩn tỷ lệ Aspect-Fill (hỗ trợ Lật gương & viền ảnh sắc nét)
            let slotRects = config.layout.slotRects(in: canvasSize, marginScale: config.marginScale)
            let slotCorner = min(w, h) * config.slotCornerRadiusRatio

            for (idx, rect) in slotRects.enumerated() {
                cg.saveGState()
                let clipPath = UIBezierPath(roundedRect: rect, cornerRadius: slotCorner)
                cg.addPath(clipPath.cgPath)
                cg.clip()

                if idx < slots.count, let slot = slots[idx] {
                    drawAspectFillCGImage(slot.displayImage, in: rect, mirrored: slot.isMirrored, context: cg)
                } else {
                    UIColor(white: config.frameStyle.usesLightInk ? 0.14 : 0.88, alpha: 1.0).setFill()
                    cg.fill(rect)
                }
                cg.restoreGState()

                // Viền phân tách mảnh tinh tế quanh mỗi ô ảnh
                cg.saveGState()
                let borderPath = UIBezierPath(roundedRect: rect, cornerRadius: slotCorner)
                let hairColor = config.frameStyle.usesLightInk
                    ? UIColor.white.withAlphaComponent(0.16)
                    : UIColor.black.withAlphaComponent(0.09)
                hairColor.setStroke()
                borderPath.lineWidth = max(1.0, w * 0.0022)
                borderPath.stroke()
                cg.restoreGState()

                // Nếu là khung cuộn phim 35mm: vẽ mã khung 1A, 2A, 3A... ở lề trái
                if config.frameStyle == .kodak35mmSprocket {
                    drawFilmFrameIndex(index: idx + 1, slotRect: rect, canvasWidth: w)
                }
            }

            // 3. Chân trang biên tập (Caption, Date Stamp, Số rạp / Mã vạch)
            drawEditorialFooter(
                cg: cg,
                rect: fullRect,
                slotRects: slotRects,
                config: config
            )

            // 4. Sticker Trang Trí (Đúng tọa độ chuẩn hóa, tỷ lệ, góc xoay & bóng tiếp xúc nhẹ)
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
                    offset: CGSize(width: 0, height: w * 0.004),
                    blur: w * 0.012,
                    color: UIColor.black.withAlphaComponent(0.24).cgColor
                )
                let drawBox = CGRect(x: -targetW * 0.5, y: -targetH * 0.5, width: targetW, height: targetH)
                stUI.draw(in: drawBox)
                cg.restoreGState()
            }

            // 5. Hiệu ứng bề mặt giấy in (Giấy lì / Bóng kính / Hạt phim)
            drawPaperFinishOverlay(cg: cg, rect: fullRect, finish: config.paperFinish)
        }
        return uiImage.cgImage
    }

    /// Kết xuất riêng nền khung + chân trang (dùng làm lớp tĩnh cho Video Tua Nhanh 9:16 để đạt tốc độ xuất siêu nhanh).
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
            for (idx, rect) in slotRects.enumerated() {
                if config.frameStyle == .kodak35mmSprocket {
                    drawFilmFrameIndex(index: idx + 1, slotRect: rect, canvasWidth: canvasSize.width)
                }
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
                    offset: CGSize(width: 0, height: w * 0.004),
                    blur: w * 0.012,
                    color: UIColor.black.withAlphaComponent(0.24).cgColor
                )
                stUI.draw(in: CGRect(x: -targetW * 0.5, y: -targetH * 0.5, width: targetW, height: targetH))
                cg.restoreGState()
            }
        }
        return img.cgImage
    }

    // MARK: - Editorial Frame Painters

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

        switch config.frameStyle {
        case .life4CutsCream, .customAITexture:
            UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1.0).setFill()
            cg.fill(rect)

        case .photoismObsidian:
            UIColor(red: 0.075, green: 0.078, blue: 0.088, alpha: 1.0).setFill()
            cg.fill(rect)

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
            // Authentic 35mm perforated sprocket holes along left & right edges
            let holeW = w * 0.042
            let holeH = holeW * 1.42
            let stepY = holeH * 1.95
            let leftX = w * 0.018
            let rightX = w - w * 0.018 - holeW
            let holeColor = UIColor(red: 0.92, green: 0.90, blue: 0.86, alpha: 1.0)
            holeColor.setFill()
            var y = h * 0.025
            while y + holeH < h * 0.975 {
                UIBezierPath(roundedRect: CGRect(x: leftX, y: y, width: holeW, height: holeH), cornerRadius: holeW * 0.24).fill()
                UIBezierPath(roundedRect: CGRect(x: rightX, y: y, width: holeW, height: holeH), cornerRadius: holeW * 0.24).fill()
                y += stepY
            }

        case .dailyNewspaper:
            UIColor(red: 0.925, green: 0.898, blue: 0.842, alpha: 1.0).setFill()
            cg.fill(rect)
            // Top editorial masthead lines
            let ink = UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1.0)
            ink.setFill()
            cg.fill(CGRect(x: w * 0.08, y: h * 0.024, width: w * 0.84, height: max(1.5, w * 0.004)))
            cg.fill(CGRect(x: w * 0.08, y: h * 0.029, width: w * 0.84, height: max(0.8, w * 0.0018)))
            let mastAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia-Bold", size: max(9, w * 0.024)) ?? UIFont.boldSystemFont(ofSize: w * 0.024),
                .foregroundColor: ink
            ]
            let title = NSString(string: "THE ALIGN DAILY")
            let tSize = title.size(withAttributes: mastAttrs)
            title.draw(at: CGPoint(x: (w - tSize.width) * 0.5, y: h * 0.006), withAttributes: mastAttrs)

        case .vintageCinemaTicket:
            UIColor(red: 0.945, green: 0.885, blue: 0.765, alpha: 1.0).setFill()
            cg.fill(rect)
            // Fine inner crimson/umber ticket frame & punched notches
            let border = rect.insetBy(dx: w * 0.032, dy: w * 0.032)
            let ticketStroke = UIColor(red: 0.58, green: 0.20, blue: 0.18, alpha: 0.65)
            ticketStroke.setStroke()
            let bp = UIBezierPath(rect: border)
            bp.lineWidth = max(1.0, w * 0.003)
            bp.stroke()
            UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0).setFill()
            let notchR = w * 0.028
            for ny in [h * 0.25, h * 0.50, h * 0.75] {
                cg.fillEllipse(in: CGRect(x: -notchR, y: ny - notchR, width: notchR * 2, height: notchR * 2))
                cg.fillEllipse(in: CGRect(x: w - notchR, y: ny - notchR, width: notchR * 2, height: notchR * 2))
            }

        case .thermalReceipt:
            UIColor(red: 0.975, green: 0.976, blue: 0.968, alpha: 1.0).setFill()
            cg.fill(rect)
            // Top perforated sawtooth cut detail
            let toothW = w / 28.0
            let toothH = max(5.0, w * 0.015)
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
            // Fine horizontal brushed metallic streaks
            cg.saveGState()
            UIColor.white.withAlphaComponent(0.10).setFill()
            var sy: CGFloat = 4
            while sy < h {
                cg.fill(CGRect(x: 0, y: sy, width: w, height: max(1.0, h * 0.0012)))
                sy += max(6.0, h * 0.008)
            }
            cg.restoreGState()

        case .coquetteSilkRibbon:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.988, green: 0.910, blue: 0.928, alpha: 1.0),
                bottom: UIColor(red: 0.955, green: 0.835, blue: 0.868, alpha: 1.0))

        case .matchaGarden:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.88, green: 0.92, blue: 0.83, alpha: 1.0),
                bottom: UIColor(red: 0.76, green: 0.83, blue: 0.69, alpha: 1.0))

        case .berryNightFlash:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.25, green: 0.055, blue: 0.095, alpha: 1.0),
                bottom: UIColor(red: 0.14, green: 0.03, blue: 0.055, alpha: 1.0))

        case .sunsetSilk:
            drawVerticalGradient(cg: cg, rect: rect,
                top: UIColor(red: 0.98, green: 0.86, blue: 0.76, alpha: 1.0),
                bottom: UIColor(red: 0.95, green: 0.69, blue: 0.62, alpha: 1.0))

        case .softPearl:
            UIColor(red: 0.988, green: 0.988, blue: 0.992, alpha: 1.0).setFill()
            cg.fill(rect)
        }
    }

    private static func drawFilmFrameIndex(index: Int, slotRect: CGRect, canvasWidth: CGFloat) {
        let ink = UIColor(red: 0.94, green: 0.67, blue: 0.24, alpha: 0.88)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(7.0, canvasWidth * 0.017), weight: .bold),
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
        let footerH = max(12.0, h - footerTop)
        let ink = config.frameStyle.usesLightInk
            ? UIColor(white: 0.95, alpha: 0.90)
            : UIColor(white: 0.13, alpha: 0.88)
        let subInk = ink.withAlphaComponent(0.58)

        let caption = config.customCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCaption = caption.isEmpty ? "ALIGN STUDIO" : caption

        let df = DateFormatter()
        df.dateFormat = "yyyy . MM . dd"
        let dateStr = df.string(from: Date())

        // Thermal receipt vector barcode
        if config.frameStyle == .thermalReceipt {
            let barW = w * 0.44
            let barX = (w - barW) * 0.5
            let barY = footerTop + footerH * 0.42
            let barH = footerH * 0.30
            ink.setFill()
            var bx = barX
            var k = 0
            while bx < barX + barW {
                let lw = CGFloat(((k * 7 + 3) % 4) + 1) * max(1.0, w * 0.003)
                if k % 2 == 0 {
                    cg.fill(CGRect(x: bx, y: barY, width: lw, height: barH))
                }
                bx += lw + max(1.0, w * 0.002)
                k += 1
            }
        }

        let titleFontSize = max(9.0, w * 0.030)
        let dateFontSize = max(7.0, w * 0.020)

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: titleFontSize, weight: .bold),
            .foregroundColor: ink,
            .kern: NSNumber(value: Double(w * 0.004)),
            .paragraphStyle: para
        ]
        let titleRect = CGRect(
            x: w * 0.06,
            y: config.frameStyle == .thermalReceipt ? footerTop + footerH * 0.08 : footerTop + footerH * 0.20,
            width: w * 0.88,
            height: titleFontSize * 1.4
        )
        NSString(string: displayCaption.uppercased()).draw(in: titleRect, withAttributes: titleAttrs)

        if config.showDateStamp {
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: dateFontSize, weight: .medium),
                .foregroundColor: subInk,
                .paragraphStyle: para
            ]
            let dateY = config.frameStyle == .thermalReceipt ? (footerTop + footerH * 0.76) : (titleRect.maxY + 2)
            let dateRect = CGRect(x: w * 0.06, y: dateY, width: w * 0.88, height: dateFontSize * 1.3)
            NSString(string: dateStr).draw(in: dateRect, withAttributes: dateAttrs)
        }
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
                UIColor.white.withAlphaComponent(0.14).cgColor,
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
            UIColor(white: 0.5, alpha: 0.045).setFill()
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
