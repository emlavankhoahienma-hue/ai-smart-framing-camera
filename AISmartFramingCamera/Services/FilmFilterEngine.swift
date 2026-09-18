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
        case .classicChrome: return applyClassicChrome(inputImage)
        case .cinemaTealOrange: return applyCinemaTealOrange(inputImage)
        case .velvia50: return applyVelvia50(inputImage)
        case .sunsetGlow: return applySunsetGlow(inputImage)
        case .tokyoAiry: return applyTokyoAiry(inputImage)
        case .hkCinema90s: return applyHKCinema90s(inputImage)
        case .cinestill800T: return applyCineStill800T(inputImage)
        case .leicaMonochrom: return applyLeicaMonochrom(inputImage)
        case .monochromeNoir: return applyMonochromeNoir(inputImage)
        case .triX400: return applyTriX400(inputImage)
        case .vintageWarm: return applyVintageWarm(inputImage)
        case .streetClassic: return applyStreetClassic(inputImage)
        case .nordicCold: return applyNordicCold(inputImage)
        case .ektar100: return applyEktar100(inputImage)
        case .neonCyberpunk: return applyNeonCyberpunk(inputImage)
        }
    }

    // MARK: - Combined Preset & AI Tone Mapping Pipeline
    public func applyPresetAndAIParameters(to image: CGImage, preset: FilmPreset, params: AIColorParameters?) -> CGImage? {
        var currentImage = image
        if preset != .standard && preset != .aiFullAuto {
            if let presetFiltered = applyPreset(to: currentImage, preset: preset) {
                currentImage = presetFiltered
            }
        }
        if let p = params {
            if let paramFiltered = applyAIColorParameters(to: currentImage, params: p) {
                currentImage = paramFiltered
            }
        }
        return currentImage
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

    // MARK: - Dedicated Film Presets Implementations (Studio Grade)

    // 1. Fuji Pro 400H: Xanh pastel nhẹ, da trắng hồng trong trẻo
    private func applyFujiPro400H(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6380, y: -3.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.02, forKey: kCIInputContrastKey)
            controls.setValue(1.03, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.08, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.03), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.26), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.75), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.98), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        return out
    }

    // 2. Kodak Portra 400: Sắc ấm vàng dịu, chuyển tone da cực mượt
    private func applyKodakPortra400(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6850, y: 3.5), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.04, forKey: kCIInputContrastKey)
            controls.setValue(1.06, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.12, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }

    // 3. Classic Chrome: Phóng sự tài liệu, độ bão hòa dịu, shadow đằm
    private func applyClassicChrome(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6420, y: -1.5), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.14, forKey: kCIInputContrastKey)
            controls.setValue(0.88, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.22), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.49), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.77), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.98), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        return out
    }

    // 4. Cinema Teal & Orange: Kịch tính điện ảnh Hollywood
    private func applyCinemaTealOrange(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6650, y: -3.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.15, forKey: kCIInputContrastKey)
            controls.setValue(1.12, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.18, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }

    // 5. Fuji Velvia 50: Sắc màu rực rỡ bùng nổ, xanh lá và biển cực sâu
    private func applyVelvia50(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6350, y: -4.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.18, forKey: kCIInputContrastKey)
            controls.setValue(1.32, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.24, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }

    // 6. Sunset Glow: Ấm áp rực rỡ, nhấn mạnh sắc hoàng hôn
    private func applySunsetGlow(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 7250, y: 6.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.10, forKey: kCIInputContrastKey)
            controls.setValue(1.25, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vig = CIFilter(name: "CIVignette") {
            vig.setValue(out, forKey: kCIInputImageKey)
            vig.setValue(0.20, forKey: kCIInputIntensityKey)
            vig.setValue(2.0, forKey: kCIInputRadiusKey)
            out = vig.outputImage ?? out
        }
        return out
    }

    // 7. Tokyo Clean: Pastel mơ màng, highlight trong trẻo, da mịn màng
    private func applyTokyoAiry(_ input: CIImage) -> CIImage {
        var out = input
        if let exp = CIFilter(name: "CIExposureAdjust") {
            exp.setValue(out, forKey: kCIInputImageKey)
            exp.setValue(0.20, forKey: kCIInputEVKey)
            out = exp.outputImage ?? out
        }
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6320, y: -2.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(0.95, forKey: kCIInputContrastKey)
            controls.setValue(0.96, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.07), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.28), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.51), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.74), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.96), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        return out
    }

    // 8. Hong Kong Cinema 90s: Shadow xanh ngọc emerald, highlight vàng ấm (Wong Kar-wai)
    private func applyHKCinema90s(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6250, y: -9.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.18, forKey: kCIInputContrastKey)
            controls.setValue(1.10, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vig = CIFilter(name: "CIVignette") {
            vig.setValue(out, forKey: kCIInputImageKey)
            vig.setValue(0.32, forKey: kCIInputIntensityKey)
            vig.setValue(2.0, forKey: kCIInputRadiusKey)
            out = vig.outputImage ?? out
        }
        return out
    }

    // 9. CineStill 800T: Phim điện ảnh đêm, tone lạnh dịu với quầng sáng ấm
    private func applyCineStill800T(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 5500, y: 2.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.16, forKey: kCIInputContrastKey)
            controls.setValue(1.08, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.01), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.23), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.78), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.99), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        return out
    }

    // 10. Leica Monochrom: Đen trắng thuần khiết, dải xám bạc vô cực tinh tế
    private func applyLeicaMonochrom(_ input: CIImage) -> CIImage {
        var out = input
        if let mono = CIFilter(name: "CIPhotoEffectNoir") {
            mono.setValue(out, forKey: kCIInputImageKey)
            out = mono.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.12, forKey: kCIInputContrastKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.02), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.26), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.52), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.77), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.98), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        return out
    }

    // 11. Noir High Contrast: Đen trắng tương phản cao nghệ thuật
    private func applyMonochromeNoir(_ input: CIImage) -> CIImage {
        var out = input
        if let mono = CIFilter(name: "CIPhotoEffectNoir") {
            mono.setValue(out, forKey: kCIInputImageKey)
            out = mono.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.35, forKey: kCIInputContrastKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vig = CIFilter(name: "CIVignette") {
            vig.setValue(out, forKey: kCIInputImageKey)
            vig.setValue(0.30, forKey: kCIInputIntensityKey)
            vig.setValue(2.0, forKey: kCIInputRadiusKey)
            out = vig.outputImage ?? out
        }
        return out
    }

    // 12. Kodak Tri-X 400: Đen trắng phóng sự báo chí, hạt phim rõ nét
    private func applyTriX400(_ input: CIImage) -> CIImage {
        var out = input
        if let mono = CIFilter(name: "CIPhotoEffectTonal") {
            mono.setValue(out, forKey: kCIInputImageKey)
            out = mono.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.24, forKey: kCIInputContrastKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        return out
    }

    // 13. Vintage Warm 70s: Hoài niệm phim nhựa thập niên 70, fade nhẹ vùng đen
    private func applyVintageWarm(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6900, y: 3.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(out, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.08), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.28), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.74), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.95), forKey: "inputPoint4")
            out = curve.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.02, forKey: kCIInputContrastKey)
            controls.setValue(1.04, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        return out
    }

    // 14. Street Classic: Màu đường phố sắc nét, micro-contrast cao, nổi khối
    private func applyStreetClassic(_ input: CIImage) -> CIImage {
        var out = input
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.12, forKey: kCIInputContrastKey)
            controls.setValue(1.04, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.08, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }

    // 15. Nordic Minimal: Tone lạnh Bắc Âu tối giản, khử màu nóng
    private func applyNordicCold(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 5900, y: -1.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.06, forKey: kCIInputContrastKey)
            controls.setValue(0.82, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        return out
    }

    // 16. Kodak Ektar 100: Hạt siêu mịn, sắc nét rực rỡ, độ nét tuyệt hảo
    private func applyEktar100(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 6600, y: 1.5), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.15, forKey: kCIInputContrastKey)
            controls.setValue(1.22, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(out, forKey: kCIInputImageKey)
            vibrance.setValue(0.15, forKey: "inputAmount")
            out = vibrance.outputImage ?? out
        }
        return out
    }

    // 17. Cyberpunk Night: Shadow lam tím, highlight hồng tím neon
    private func applyNeonCyberpunk(_ input: CIImage) -> CIImage {
        var out = input
        if let temp = CIFilter(name: "CITemperatureAndTint") {
            temp.setValue(out, forKey: kCIInputImageKey)
            temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temp.setValue(CIVector(x: 5800, y: 15.0), forKey: "inputTargetNeutral")
            out = temp.outputImage ?? out
        }
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(out, forKey: kCIInputImageKey)
            controls.setValue(1.24, forKey: kCIInputContrastKey)
            controls.setValue(1.28, forKey: kCIInputSaturationKey)
            out = controls.outputImage ?? out
        }
        if let vig = CIFilter(name: "CIVignette") {
            vig.setValue(out, forKey: kCIInputImageKey)
            vig.setValue(0.28, forKey: kCIInputIntensityKey)
            vig.setValue(2.0, forKey: kCIInputRadiusKey)
            out = vig.outputImage ?? out
        }
        return out
    }

    // MARK: - Subtle AI Sharpness (Bảo toàn 100% màu sắc & chất ảnh qua Apple CISharpenLuminance)
    /// Tăng cường vi tương phản chi tiết cạnh (Micro-Contrast & Edge Sharpness) trên kênh Luma
    /// Sử dụng bộ lọc CISharpenLuminance chuẩn mực của Apple Core Image:
    /// - Không gây lỗi chia 0 / NaN làm đen mép viền (zero black edge artifact) trên nền trời trắng cháy sáng
    /// - Giữ nguyên 100% sắc thái, nhiệt độ màu và hạt phim gốc (chrominance hoàn toàn bất biến)
    public func applySubtleAISharpness(to image: CGImage, intensity: Float = 0.45) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let sharpenedCI = applySubtleAISharpness(to: ciImage, intensity: intensity) else { return image }
        return context.createCGImage(sharpenedCI, from: ciImage.extent)
    }

    public func applySubtleAISharpness(to input: CIImage, intensity: Float = 0.45) -> CIImage? {
        // Sử dụng Apple CISharpenLuminance: tăng vi tương phản cạnh thuần túy trên kênh Luminance, Chroma không bị suy giảm
        guard let sharpenFilter = CIFilter(name: "CISharpenLuminance") else { return input }
        sharpenFilter.setValue(input, forKey: kCIInputImageKey)
        sharpenFilter.setValue(intensity, forKey: kCIInputSharpnessKey)
        sharpenFilter.setValue(1.69, forKey: kCIInputRadiusKey)

        guard let output = sharpenFilter.outputImage else { return input }

        // Kẹp dải màu an toàn [0.0, 1.0] triệt tiêu hoàn toàn hiện tượng out-of-gamut hoặc đen mép
        if let clampFilter = CIFilter(name: "CIColorClamp") {
            clampFilter.setValue(output, forKey: kCIInputImageKey)
            clampFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
            clampFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
            return clampFilter.outputImage?.cropped(to: input.extent) ?? output
        }

        return output
    }
}
