import UIKit
import CoreImage
import SwiftUI

public final class PresetThumbnailProvider {
    public static let shared = PresetThumbnailProvider()
    
    private var thumbnailCache: [FilmPreset: UIImage] = [:]
    
    private init() {
        preheatThumbnails()
    }
    
    public func thumbnail(for preset: FilmPreset) -> UIImage {
        if let cached = thumbnailCache[preset] {
            return cached
        }
        let generated = generateThumbnail(for: preset)
        thumbnailCache[preset] = generated
        return generated
    }
    
    private func preheatThumbnails() {
        for preset in FilmPreset.allCases {
            thumbnailCache[preset] = generateThumbnail(for: preset)
        }
    }
    
    private func generateThumbnail(for preset: FilmPreset) -> UIImage {
        let size = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let baseImage = renderer.image { ctx in
            let cg = ctx.cgContext
            
            // 1. Nền bầu trời / hoàng hôn gradient đa tầng
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bgColors = [
                UIColor(red: 0.28, green: 0.58, blue: 0.88, alpha: 1.0).cgColor,
                UIColor(red: 0.88, green: 0.68, blue: 0.48, alpha: 1.0).cgColor,
                UIColor(red: 0.95, green: 0.52, blue: 0.35, alpha: 1.0).cgColor,
                UIColor(red: 0.38, green: 0.55, blue: 0.32, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.45, 0.75, 1.0]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 80, y: 160), options: [])
            }
            
            // 2. Kiến trúc & Cửa sổ hậu cảnh (Độ sâu không gian)
            cg.setFillColor(UIColor(red: 0.20, green: 0.26, blue: 0.34, alpha: 0.80).cgColor)
            cg.fill(CGRect(x: 12, y: 45, width: 40, height: 80))
            cg.fill(CGRect(x: 108, y: 28, width: 42, height: 95))
            
            // Cửa sổ ánh sáng ấm
            cg.setFillColor(UIColor(red: 0.98, green: 0.88, blue: 0.62, alpha: 0.70).cgColor)
            for row in 0..<4 {
                cg.fill(CGRect(x: 116, y: 38 + row * 16, width: 11, height: 9))
                cg.fill(CGRect(x: 133, y: 38 + row * 16, width: 11, height: 9))
            }
            
            // 3. Tán cây thiên nhiên
            cg.setFillColor(UIColor(red: 0.22, green: 0.52, blue: 0.26, alpha: 0.90).cgColor)
            cg.fillEllipse(in: CGRect(x: 6, y: 85, width: 50, height: 50))
            
            // 4. Chủ thể chân dung nghệ thuật (Portrait Model)
            // Thân áo
            cg.setFillColor(UIColor(red: 0.18, green: 0.20, blue: 0.26, alpha: 0.95).cgColor)
            cg.fillEllipse(in: CGRect(x: 40, y: 110, width: 80, height: 65))
            
            // Cổ & Khuôn mặt (Tone da tiêu chuẩn để thể hiện chính xác khả năng tôn da của Preset)
            cg.setFillColor(UIColor(red: 0.93, green: 0.78, blue: 0.66, alpha: 1.0).cgColor)
            cg.fillEllipse(in: CGRect(x: 58, y: 55, width: 44, height: 54))
            
            // Má hồng nhẹ
            cg.setFillColor(UIColor(red: 0.95, green: 0.62, blue: 0.58, alpha: 0.40).cgColor)
            cg.fillEllipse(in: CGRect(x: 60, y: 78, width: 12, height: 8))
            cg.fillEllipse(in: CGRect(x: 88, y: 78, width: 12, height: 8))
            
            // Mái tóc
            cg.setFillColor(UIColor(red: 0.16, green: 0.11, blue: 0.09, alpha: 1.0).cgColor)
            cg.fillEllipse(in: CGRect(x: 55, y: 50, width: 50, height: 36))
            
            // Môi hồng tự nhiên
            cg.setFillColor(UIColor(red: 0.82, green: 0.38, blue: 0.38, alpha: 0.90).cgColor)
            cg.fillEllipse(in: CGRect(x: 74, y: 90, width: 13, height: 6))
            
            // Ánh sáng ven tóc vàng ấm (Golden Rim Light)
            cg.setFillColor(UIColor(red: 1.0, green: 0.94, blue: 0.78, alpha: 0.70).cgColor)
            cg.fillEllipse(in: CGRect(x: 53, y: 52, width: 14, height: 35))
        }
        
        guard let cg = baseImage.cgImage else { return baseImage }
        
        if preset == .aiFullAuto {
            let aiParams = AIColorParameters(
                warmthShift: 0.05,
                tintShift: 0.01,
                saturationBoost: 1.10,
                contrastCurve: 1.05,
                shadowLift: 0.03,
                highlightRoll: 0.97,
                filmGrainIntensity: 0.06,
                vignetteIntensity: 0.12,
                colorBoost: 0.06
            )
            if let processed = FilmFilterEngine.shared.applyAIColorParameters(to: cg, params: aiParams) {
                return UIImage(cgImage: processed)
            }
            return baseImage
        }
        
        if let filtered = FilmFilterEngine.shared.applyPreset(to: cg, preset: preset) {
            return UIImage(cgImage: filtered)
        }
        
        return baseImage
    }
}
