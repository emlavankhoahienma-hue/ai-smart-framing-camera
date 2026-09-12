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

        // 1. Bù sáng phơi sáng thông minh (CIExposureAdjust: -1.0 EV đến +1.0 EV)
        let exposureBias = max(-1.2, min(1.2, params.exposureBias))
        if abs(exposureBias) > 0.02 {
            if let expFilter = CIFilter(name: "CIExposureAdjust") {
                expFilter.setValue(output, forKey: kCIInputImageKey)
                expFilter.setValue(exposureBias, forKey: kCIInputEVKey)
                output = expFilter.outputImage ?? output
            }
        }

        // 2. Cân bằng trắng & Tint (CITemperatureAndTint: ±1600K và cân bằng Green/Magenta)
        let warmth = max(-0.35, min(0.35, params.warmthShift))
        let tint = max(-0.25, min(0.25, params.tintShift))
        if abs(warmth) > 0.01 || abs(tint) > 0.01 {
            if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
                tempFilter.setValue(output, forKey: kCIInputImageKey)
                let neutralTemp: CGFloat = 6500
                let targetTemp = neutralTemp + warmth * 1600.0 // Điều chỉnh nhiệt độ màu rõ ràng, tự nhiên
                tempFilter.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
                tempFilter.setValue(CIVector(x: targetTemp, y: tint * 50.0), forKey: "inputTargetNeutral")
                output = tempFilter.outputImage ?? output
            }
        }

        // 3. Tôn màu da & Vibrance (bảo vệ sắc da người bằng CIVibrance)
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(output, forKey: kCIInputImageKey)
            let vibAmount = (params.saturationBoost - 1.0) * 0.7
            vibrance.setValue(max(-0.4, min(0.5, vibAmount)), forKey: "inputAmount")
            output = vibrance.outputImage ?? output
        }

        // 4. Tone Curve mượt mà (Cứu sáng Highlight + Nâng sáng Shadow Lift chuyên nghiệp)
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(output, forKey: kCIInputImageKey)
            let shadowLift = max(0.0, min(0.20, params.shadowLift))
            let highlightRoll = max(0.75, min(1.0, params.highlightRoll))
            curve.setValue(CIVector(x: 0.0, y: shadowLift), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.25 + shadowLift * 0.45), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.75 * highlightRoll), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: highlightRoll), forKey: "inputPoint4")
            output = curve.outputImage ?? output
        }

        // 5. Tương phản & Độ bão hòa màu sắc (CIColorControls)
        let contrast = max(0.85, min(1.30, params.contrastCurve))
        let saturation = max(0.75, min(1.35, params.saturationBoost))
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(saturation, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }

        // 6. Hiệu ứng tối góc quang học (Vignette)
        let vignette = max(0.0, min(0.35, params.vignetteAmount))
        if vignette > 0.02 {
            if let vigFilter = CIFilter(name: "CIVignette") {
                vigFilter.setValue(output, forKey: kCIInputImageKey)
                vigFilter.setValue(vignette, forKey: kCIInputIntensityKey)
                vigFilter.setValue(2.0, forKey: kCIInputRadiusKey)
                output = vigFilter.outputImage ?? output
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
