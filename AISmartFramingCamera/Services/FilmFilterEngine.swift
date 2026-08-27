import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import CoreGraphics

/// Bộ xử lý màu chuẩn Studio Natural (Leica / Hasselblad True-to-Life Color Science)
/// Tối ưu dải màu da tự nhiên, micro-contrast dịu mắt, không gắt, không lố
public final class FilmFilterEngine {
    public static let shared = FilmFilterEngine()
    
    private let context: CIContext
    
    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            self.context = CIContext(options: [.useSoftwareRenderer: false])
        }
    }
    
    // MARK: - Manual Film Presets (Tinh chỉnh tự nhiên, thanh lịch)
    public func applyPreset(to image: CGImage, preset: FilmPreset) -> CGImage? {
        guard preset != .aiFullAuto && preset != .standard else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset) else { return image }
        return context.createCGImage(filteredCI, from: filteredCI.extent)
    }
    
    public func applyPreset(to inputImage: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .standard, .aiFullAuto: return inputImage
        case .fujiPro400H: return applyFujiPro400H(inputImage)
        case .kodakPortra400: return applyKodakPortra400(inputImage)
        case .cinemaTealOrange: return applyCinemaTealOrange(inputImage)
        case .sunsetGlow: return applySunsetGlow(inputImage)
        case .monochromeNoir: return applyMonochromeNoir(inputImage)
        case .vintageWarm: return applyVintageWarm(inputImage)
        case .streetClassic: return applyStreetClassic(inputImage)
        }
    }
    
    // MARK: - AI Full Color Mode (Leica Natural & Hasselblad True-to-Life Pipeline)
    public func applyAIColorParameters(to image: CGImage, params: AIColorParameters) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let result = applyAIColorParameters(to: ciImage, params: params) else { return image }
        return context.createCGImage(result, from: result.extent)
    }
    
    public func applyAIColorParameters(to inputImage: CIImage, params: AIColorParameters) -> CIImage? {
        var output = inputImage
        
        // 1. Cân bằng trắng vi mô (Subtle Natural White Balance ±200K)
        let subtleWarmth = max(-0.15, min(0.15, params.warmthShift))
        if abs(subtleWarmth) > 0.01 {
            if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
                tempFilter.setValue(output, forKey: kCIInputImageKey)
                let neutralTemp: CGFloat = 6500
                let targetTemp = neutralTemp + subtleWarmth * 600.0 // Giới hạn dải ấm/lạnh tinh tế
                tempFilter.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
                tempFilter.setValue(CIVector(x: targetTemp, y: subtleWarmth * 2.0), forKey: "inputTargetNeutral")
                output = tempFilter.outputImage ?? output
            }
        }
        
        // 2. Tôn màu da tự nhiên qua CIVibrance (bảo vệ sắc da người, không làm cháy cam/vàng)
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(output, forKey: kCIInputImageKey)
            let vibAmount = (params.saturationBoost - 1.0) * 0.4
            vibrance.setValue(max(-0.2, min(0.3, vibAmount)), forKey: "inputAmount")
            output = vibrance.outputImage ?? output
        }
        
        // 3. Micro-Contrast dịu mắt (giữ chi tiết vùng sáng & tối)
        let gentleContrast = max(0.98, min(1.06, params.contrastCurve))
        let gentleSaturation = max(0.98, min(1.05, params.saturationBoost))
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(gentleContrast, forKey: kCIInputContrastKey)
            colorControls.setValue(gentleSaturation, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        
        // 4. Tone Curve mượt mà (Highlight Rolloff dịu êm + Shadow Lift tinh tế)
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(output, forKey: kCIInputImageKey)
            let shadowLift = max(0.0, min(0.03, params.shadowLift))
            let highlightRoll = max(0.96, min(1.0, params.highlightRoll))
            curve.setValue(CIVector(x: 0.0, y: shadowLift), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.25 + shadowLift * 0.4), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.75 * highlightRoll), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: highlightRoll), forKey: "inputPoint4")
            output = curve.outputImage ?? output
        }
        
        // 5. Tối góc vi mô quang học (rất nhẹ, tự nhiên như ống kính cao cấp)
        let gentleVignette = max(0.0, min(0.06, params.vignetteAmount * 0.2))
        if gentleVignette > 0.01 {
            if let vignette = CIFilter(name: "CIVignette") {
                vignette.setValue(output, forKey: kCIInputImageKey)
                vignette.setValue(gentleVignette, forKey: kCIInputIntensityKey)
                vignette.setValue(2.2, forKey: kCIInputRadiusKey)
                output = vignette.outputImage ?? output
            }
        }
        
        return output
    }
    
    // MARK: - Presets Helpers
    
    private func applyFujiPro400H(_ input: CIImage) -> CIImage {
        var out = input
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.02, forKey: kCIInputContrastKey)
            controls.setValue(1.03, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        return out
    }
    
    private func applyKodakPortra400(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6700, y: 3), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        return out
    }
    
    private func applyCinemaTealOrange(_ input: CIImage) -> CIImage {
        var out = input
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.12, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }
    
    private func applySunsetGlow(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6900, y: 5), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        return out
    }
    
    private func applyMonochromeNoir(_ input: CIImage) -> CIImage {
        if let mono = CIFilter(name: "CIPhotoEffectNoir") {
            mono.setValue(input, forKey: kCIInputImageKey)
            return mono.outputImage ?? input
        }
        return input
    }
    
    private func applyVintageWarm(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6800, y: 2), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        return out
    }
    
    private func applyStreetClassic(_ input: CIImage) -> CIImage {
        var out = input
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.04, forKey: kCIInputContrastKey)
            controls.setValue(1.02, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        return out
    }
}
