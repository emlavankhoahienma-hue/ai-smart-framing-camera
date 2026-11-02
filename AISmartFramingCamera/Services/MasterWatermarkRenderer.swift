import Foundation
import UIKit
import CoreGraphics

// MARK: - Watermark Theme
public enum WatermarkTheme: String, CaseIterable, Identifiable, Sendable {
    case white = "Trắng Leica"
    case black = "Đen Studio"

    public var id: String { rawValue }

    public var backgroundColor: UIColor {
        switch self {
        case .white: return .white
        case .black: return UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
        }
    }

    public var textColor: UIColor {
        switch self {
        case .white: return UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0)
        case .black: return UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1.0)
        }
    }

    public var dividerColor: UIColor {
        switch self {
        case .white: return UIColor(red: 0.83, green: 0.83, blue: 0.85, alpha: 1.0)
        case .black: return UIColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1.0)
        }
    }
}

// MARK: - Watermark Logo Style
public enum WatermarkLogoStyle: String, CaseIterable, Identifiable, Sendable {
    case leicaRedDot = "Chấm Đỏ Leica"
    case goldBadge = "Vàng Kim Luxury"
    case monochrome = "Đen Tuyền"
    case custom = "Ảnh Tùy Chỉnh"

    public var id: String { rawValue }
}

// MARK: - Photo Watermark Specs
public struct PhotoWatermarkSpecs: Sendable {
    public var focalLength: String
    public var aperture: String
    public var shutterSpeed: String
    public var iso: String

    public init(focalLength: String = "24mm", aperture: String = "f/1.8", shutterSpeed: String = "1/125s", iso: String = "ISO100") {
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
    }

    public static func from(iso: Float, shutterSpeed: Double, focalLength: Double? = nil, aperture: Float? = nil) -> PhotoWatermarkSpecs {
        let isoStr = (iso > 0 && iso.isFinite) ? "ISO\(Int(round(iso)))" : "ISO100"

        let shutterStr: String
        if shutterSpeed > 0 && shutterSpeed.isFinite {
            if shutterSpeed >= 1.0 {
                shutterStr = String(format: "%.1fs", shutterSpeed)
            } else {
                let denom = Int(round(1.0 / shutterSpeed))
                shutterStr = "1/\(denom)s"
            }
        } else {
            shutterStr = "1/125s"
        }

        let focalStr: String
        if let f = focalLength, f > 0 {
            focalStr = "\(Int(round(f)))mm"
        } else {
            focalStr = "24mm"
        }

        let apStr: String
        if let a = aperture, a > 0 {
            apStr = String(format: "f/%.1f", a)
        } else {
            apStr = "f/1.8"
        }

        return PhotoWatermarkSpecs(focalLength: focalStr, aperture: apStr, shutterSpeed: shutterStr, iso: isoStr)
    }
}

// MARK: - Master Watermark Renderer (Xiaomi 15 Ultra Leica Master Frame)
public final class MasterWatermarkRenderer: @unchecked Sendable {
    public static let shared = MasterWatermarkRenderer()

    public init() {}

    public func renderWatermark(
        on image: CGImage,
        deviceName: String = "ALIGN STUDIO ULTRA",
        theme: WatermarkTheme = .white,
        logoStyle: WatermarkLogoStyle = .leicaRedDot,
        customLogo: UIImage? = nil,
        specs: PhotoWatermarkSpecs
    ) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return image }

        let barHeight = round(max(imgW, imgH) * 0.088)
        let canvasSize = CGSize(width: imgW, height: imgH + barHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let renderedImage = renderer.image { ctx in
            let cgContext = ctx.cgContext

            // 1. Vẽ ảnh gốc giữ nguyên 100% độ sắc nét pixel
            UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: imgW, height: imgH))

            // 2. Vẽ dải nền khung bên dưới (Footer Bar)
            let barRect = CGRect(x: 0, y: imgH, width: imgW, height: barHeight)
            theme.backgroundColor.setFill()
            cgContext.fill(barRect)

            let hPadding = imgW * 0.055

            // 3. Bên Trái: Tên Thiết Bị / Thương Hiệu (Geometric Bold Tracking)
            let deviceFontSize = round(barHeight * 0.24)
            let deviceFont = UIFont.systemFont(ofSize: deviceFontSize, weight: .bold)
            let deviceAttrs: [NSAttributedString.Key: Any] = [
                .font: deviceFont,
                .foregroundColor: theme.textColor,
                .kern: NSNumber(value: Float(deviceFontSize * 0.08))
            ]
            let displayName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ALIGN STUDIO ULTRA"
                : deviceName.uppercased()
            let deviceAttrString = NSAttributedString(string: displayName, attributes: deviceAttrs)
            let deviceSize = deviceAttrString.size()
            let deviceY = imgH + (barHeight - deviceSize.height) / 2.0
            deviceAttrString.draw(at: CGPoint(x: hPadding, y: deviceY))

            // 4. Cụm Bên Phải: [Logo Badge]  |  [EXIF Specs]
            let specFontSize = round(barHeight * 0.20)
            let specFont = UIFont.monospacedDigitSystemFont(ofSize: specFontSize, weight: .semibold)
            let specAttrs: [NSAttributedString.Key: Any] = [
                .font: specFont,
                .foregroundColor: theme.textColor,
                .kern: NSNumber(value: Float(specFontSize * 0.04))
            ]
            let specString = "\(specs.focalLength)  \(specs.aperture)  \(specs.shutterSpeed)  \(specs.iso)"
            let specAttrString = NSAttributedString(string: specString, attributes: specAttrs)
            let specSize = specAttrString.size()

            let dividerHeight = round(barHeight * 0.42)
            let dividerWidth = max(1.5, round(barHeight * 0.015))
            let dividerSpacing = round(barHeight * 0.16)

            let logoDiameter = round(barHeight * 0.46)

            let rightClusterWidth = logoDiameter + dividerSpacing + dividerWidth + dividerSpacing + specSize.width
            let rightClusterStartX = imgW - hPadding - rightClusterWidth

            // 4a. Vẽ Logo Badge Tròn
            let logoX = rightClusterStartX
            let logoY = imgH + (barHeight - logoDiameter) / 2.0
            let logoRect = CGRect(x: logoX, y: logoY, width: logoDiameter, height: logoDiameter)
            Self.drawLogoBadge(in: logoRect, context: cgContext, style: logoStyle, customImage: customLogo)

            // 4b. Vẽ Đường Phân Cách Dọc
            let dividerX = logoX + logoDiameter + dividerSpacing
            let dividerY = imgH + (barHeight - dividerHeight) / 2.0
            theme.dividerColor.setFill()
            cgContext.fill(CGRect(x: dividerX, y: dividerY, width: dividerWidth, height: dividerHeight))

            // 4c. Vẽ Thông Số EXIF
            let specX = dividerX + dividerWidth + dividerSpacing
            let specY = imgH + (barHeight - specSize.height) / 2.0
            specAttrString.draw(at: CGPoint(x: specX, y: specY))
        }

        return renderedImage.cgImage
    }

    private static func drawLogoBadge(in rect: CGRect, context: CGContext, style: WatermarkLogoStyle, customImage: UIImage?) {
        context.saveGState()
        let path = UIBezierPath(ovalIn: rect)
        context.addPath(path.cgPath)
        context.clip()

        if style == .custom, let custom = customImage {
            custom.draw(in: rect)
            context.restoreGState()
            return
        }

        let circleColor: UIColor
        let letterColor: UIColor
        switch style {
        case .leicaRedDot:
            circleColor = UIColor(red: 0.89, green: 0.02, blue: 0.07, alpha: 1.0)
            letterColor = .white
        case .goldBadge:
            circleColor = UIColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 1.0)
            letterColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)
        case .monochrome:
            circleColor = UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
            letterColor = .white
        case .custom:
            circleColor = UIColor(red: 0.89, green: 0.02, blue: 0.07, alpha: 1.0)
            letterColor = .white
        }

        circleColor.setFill()
        context.fill(rect)

        let scriptFontSize = round(rect.width * 0.48)
        let font = UIFont(name: "SnellRoundhand-Bold", size: scriptFontSize) ??
                   UIFont(name: "Georgia-BoldItalic", size: scriptFontSize) ??
                   UIFont.systemFont(ofSize: scriptFontSize, weight: .heavy)
        let scriptAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: letterColor
        ]
        let scriptText = "Align"
        let scriptAttrStr = NSAttributedString(string: scriptText, attributes: scriptAttrs)
        let scriptSize = scriptAttrStr.size()
        let scriptPoint = CGPoint(
            x: rect.midX - scriptSize.width / 2.0,
            y: rect.midY - scriptSize.height / 2.0
        )
        scriptAttrStr.draw(at: scriptPoint)

        context.restoreGState()
    }
}
