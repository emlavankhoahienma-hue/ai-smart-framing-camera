import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import CoreGraphics

/// Bộ xử lý màu chuẩn Studio Natural (Leica / Hasselblad True-to-Life Color Science)
/// Tối ưu dải màu da tự nhiên, micro-contrast dịu mắt, hỗ trợ 62 tone máy ảnh retro & phim điện ảnh
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

    // MARK: - Manual Film Presets (62 Tones Chuyên Nghiệp)
    public func applyPreset(to image: CGImage, preset: FilmPreset) -> CGImage? {
        guard preset != .aiFullAuto && preset != .standard else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset) else { return image }
        return context.createCGImage(filteredCI, from: filteredCI.extent)
    }

    public func applyPreset(to inputImage: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .standard, .aiFullAuto: return inputImage
        case .studioNatural: return applyStudioNatural(inputImage)

        // 1. Trending
        case .fujiX: return applyFujiX(inputImage)
        case .cam1998: return apply1998Cam(inputImage)
        case .nokia3310: return applyNokia3310(inputImage)
        case .luxury8800: return applyLuxury8800(inputImage)
        case .kambo: return applyKambo(inputImage)
        case .cpm35: return applyCPM35(inputImage)

        // 2. Vintage Phone
        case .nokiaSymbian: return applyNokiaSymbian(inputImage)
        case .motorolaV3: return applyMotorolaV3(inputImage)
        case .iphone3GS: return applyIPhone3GS(inputImage)
        case .blackberryQ10: return applyBlackberryQ10(inputImage)
        case .keitai88: return applyKeitai88(inputImage)
        case .sonyK800i: return applySonyK800i(inputImage)

        // 3. Fuji
        case .classicChrome: return applyClassicChrome(inputImage)
        case .fujiPro400H: return applyFujiPro400H(inputImage)
        case .velvia50: return applyVelvia50(inputImage)
        case .classicNeg: return applyClassicNeg(inputImage)
        case .astia100F: return applyAstia100F(inputImage)
        case .acrosBW: return applyAcrosBW(inputImage)

        // 4. Vintage Cam
        case .lomoLCA: return applyLomoLCA(inputImage)
        case .medium120LG: return applyMedium120LG(inputImage)
        case .fxn35: return applyFXN35(inputImage)
        case .toyK: return applyToyK(inputImage)
        case .cinestill800T: return applyCineStill800T(inputImage)
        case .cam1998Street: return applyCam1998Street(inputImage)

        // 5. CCD
        case .ccd1Cyber: return applyCCD1Cyber(inputImage)
        case .dCcdWarm: return applyDCCDWarm(inputImage)
        case .blueSKCool: return applyBlueSKCool(inputImage)
        case .mangaCam: return applyMangaCam(inputImage)
        case .gCcdGold: return applyGCCDGold(inputImage)
        case .instaLiteFlash: return applyInstaLiteFlash(inputImage)

        // 6. Kodak
        case .kodakPortra400: return applyKodakPortra400(inputImage)
        case .gold200: return applyGold200(inputImage)
        case .colorPlus200: return applyColorPlus200(inputImage)
        case .ektar100: return applyEktar100(inputImage)
        case .triX400: return applyTriX400(inputImage)
        case .vision3500D: return applyVision3500D(inputImage)

        // 7. Ricoh
        case .grPositive: return applyGRPositive(inputImage)
        case .grHighBW: return applyGRHighBW(inputImage)
        case .grFFilm: return applyGRFFilm(inputImage)
        case .grStreetSnap: return applyGRStreetSnap(inputImage)
        case .caplioR: return applyCaplioR(inputImage)
        case .thetaDoc: return applyThetaDoc(inputImage)

        // 8. Canon
        case .powershotG: return applyPowershotG(inputImage)
        case .ixusY2K: return applyIXUSY2K(inputImage)
        case .eos5DClassic: return applyEOS5DClassic(inputImage)
        case .sureShot35: return applySureShot35(inputImage)
        case .canonF1: return applyCanonF1(inputImage)
        case .powershotPro1: return applyPowershotPro1(inputImage)

        // 9. DV
        case .miniDV43: return applyMiniDV43(inputImage)
        case .hi8Analog: return applyHi8Analog(inputImage)
        case .dcrDVD: return applyDCRDVD(inputImage)
        case .dvx10024p: return applyDVX10024p(inputImage)
        case .vhscHome: return applyVHSCHome(inputImage)
        case .hdv1080i: return applyHDV1080i(inputImage)

        // 10. Instant
        case .polaroid600: return applyPolaroid600(inputImage)
        case .sx70TimeZero: return applySX70TimeZero(inputImage)
        case .instaxMini: return applyInstaxMini(inputImage)
        case .instaxWide: return applyInstaxWide(inputImage)
        case .instaxSquare: return applyInstaxSquare(inputImage)
        case .polaroidSpectra: return applyPolaroidSpectra(inputImage)

        // Legacy Compatibility Presets
        case .cinemaTealOrange: return applyCinemaTealOrange(inputImage)
        case .sunsetGlow: return applySunsetGlow(inputImage)
        case .tokyoAiry: return applyTokyoAiry(inputImage)
        case .hkCinema90s: return applyHKCinema90s(inputImage)
        case .leicaMonochrom: return applyLeicaMonochrom(inputImage)
        case .monochromeNoir: return applyMonochromeNoir(inputImage)
        case .vintageWarm: return applyVintageWarm(inputImage)
        case .streetClassic: return applyStreetClassic(inputImage)
        case .nordicCold: return applyNordicCold(inputImage)
        case .neonCyberpunk: return applyNeonCyberpunk(inputImage)
        }
    }

    // MARK: - Subtle AI Sharpness
    public func applySubtleAISharpness(to image: CGImage, intensity: Float = 0.50) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CISharpenLuminance") else {
            return image
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(intensity, forKey: kCIInputSharpnessKey)
        guard let output = filter.outputImage else { return image }
        return context.createCGImage(output, from: output.extent)
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

    // MARK: - AI Full Color Mode
    public func applyAIColorParameters(to image: CGImage, params: AIColorParameters) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let result = applyAIColorParameters(to: ciImage, params: params) else { return image }
        return context.createCGImage(result, from: result.extent)
    }

    public func applyAIColorParameters(to inputImage: CIImage, params: AIColorParameters) -> CIImage? {
        var output = inputImage

        let exposureBias = max(-1.2, min(1.2, params.exposureBias))
        if abs(exposureBias) > 0.02 {
            output = adjustExposure(output, ev: Float(exposureBias))
        }

        let warmth = max(-0.35, min(0.35, params.warmthShift))
        let tint = max(-0.25, min(0.25, params.tintShift))
        if abs(warmth) > 0.01 || abs(tint) > 0.01 {
            let neutralTemp: CGFloat = 6500
            let targetTemp = neutralTemp + warmth * 1600.0
            output = adjustTempTint(output, neutralTemp: neutralTemp, targetTemp: targetTemp, targetTint: tint * 8.0)
        }

        let contrast = max(0.85, min(1.25, params.contrastCurve))
        let saturation = max(0.80, min(1.28, params.saturationLevel))
        if abs(contrast - 1.0) > 0.02 || abs(saturation - 1.0) > 0.02 {
            output = adjustColor(output, contrast: Float(contrast), saturation: Float(saturation))
        }

        let highlight = max(-0.30, min(0.30, params.highlightRecovery))
        let shadow = max(-0.25, min(0.35, params.shadowLift))
        if abs(highlight) > 0.02 || abs(shadow) > 0.02 {
            let p0 = CGPoint(x: 0.0, y: max(0.0, shadow * 0.15))
            let p1 = CGPoint(x: 0.25, y: 0.25 + shadow * 0.10)
            let p2 = CGPoint(x: 0.50, y: 0.50)
            let p3 = CGPoint(x: 0.75, y: 0.75 - highlight * 0.10)
            let p4 = CGPoint(x: 1.0, y: min(1.0, 1.0 - highlight * 0.15))
            output = adjustToneCurve(output, p0: p0, p1: p1, p2: p2, p3: p3, p4: p4)
        }

        let vibrance = max(-0.15, min(0.25, params.vibranceBoost))
        if abs(vibrance) > 0.02 {
            output = adjustVibrance(output, amount: Float(vibrance))
        }

        return output
    }

    // MARK: - CoreImage Primitive Utilities (Zero-Allocation, GPU Accelerated)
    private func adjustColor(_ input: CIImage, contrast: Float = 1.0, saturation: Float = 1.0, brightness: Float = 0.0) -> CIImage {
        guard let f = CIFilter(name: "CIColorControls") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(contrast, forKey: kCIInputContrastKey)
        f.setValue(saturation, forKey: kCIInputSaturationKey)
        f.setValue(brightness, forKey: kCIInputBrightnessKey)
        return f.outputImage ?? input
    }

    private func adjustTempTint(_ input: CIImage, neutralTemp: CGFloat = 6500, targetTemp: CGFloat, targetTint: CGFloat = 0) -> CIImage {
        guard let f = CIFilter(name: "CITemperatureAndTint") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
        f.setValue(CIVector(x: targetTemp, y: targetTint), forKey: "inputTargetNeutral")
        return f.outputImage ?? input
    }

    private func adjustVibrance(_ input: CIImage, amount: Float) -> CIImage {
        guard let f = CIFilter(name: "CIVibrance") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(amount, forKey: "inputAmount")
        return f.outputImage ?? input
    }

    private func adjustToneCurve(_ input: CIImage, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint) -> CIImage {
        guard let f = CIFilter(name: "CIToneCurve") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: p0.x, y: p0.y), forKey: "inputPoint0")
        f.setValue(CIVector(x: p1.x, y: p1.y), forKey: "inputPoint1")
        f.setValue(CIVector(x: p2.x, y: p2.y), forKey: "inputPoint2")
        f.setValue(CIVector(x: p3.x, y: p3.y), forKey: "inputPoint3")
        f.setValue(CIVector(x: p4.x, y: p4.y), forKey: "inputPoint4")
        return f.outputImage ?? input
    }

    private func adjustVignette(_ input: CIImage, intensity: Float = 0.30, radius: Float = 1.80) -> CIImage {
        guard let f = CIFilter(name: "CIVignette") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(intensity, forKey: kCIInputIntensityKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        return f.outputImage ?? input
    }

    private func adjustExposure(_ input: CIImage, ev: Float) -> CIImage {
        guard let f = CIFilter(name: "CIExposureAdjust") else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(ev, forKey: kCIInputEVKey)
        return f.outputImage ?? input
    }

    private func applyPhotoEffectNamed(_ input: CIImage, name: String) -> CIImage {
        guard let f = CIFilter(name: name) else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        return f.outputImage ?? input
    }

    // MARK: - 1. Trending Presets
    private func applyFujiX(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6350, targetTint: -2.0)
        out = adjustColor(out, contrast: 1.14, saturation: 0.94)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.04), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.5), p3: CGPoint(x: 0.75, y: 0.78), p4: CGPoint(x: 1.0, y: 0.98))
        return adjustVignette(out, intensity: 0.25, radius: 2.0)
    }

    private func apply1998Cam(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7050, targetTint: 4.5)
        out = adjustColor(out, contrast: 1.08, saturation: 1.15, brightness: 0.02)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.05), p1: CGPoint(x: 0.25, y: 0.26), p2: CGPoint(x: 0.5, y: 0.51), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.96))
        return adjustVignette(out, intensity: 0.35, radius: 1.8)
    }

    private func applyNokia3310(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6200, targetTint: -6.0)
        out = adjustColor(out, contrast: 1.06, saturation: 0.84, brightness: 0.02)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.08), p1: CGPoint(x: 0.25, y: 0.30), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.72), p4: CGPoint(x: 1.0, y: 0.92))
    }

    private func applyLuxury8800(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6850, targetTint: 2.0)
        out = adjustColor(out, contrast: 1.15, saturation: 1.08)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.23), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.78), p4: CGPoint(x: 1.0, y: 0.99))
        return adjustVignette(out, intensity: 0.22, radius: 2.2)
    }

    private func applyKambo(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.12)
        out = adjustTempTint(out, targetTemp: 6700, targetTint: 1.5)
        out = adjustColor(out, contrast: 1.05, saturation: 1.18)
        return adjustVibrance(out, amount: 0.15)
    }

    private func applyCPM35(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6600, targetTint: -1.0)
        out = adjustColor(out, contrast: 1.12, saturation: 1.14)
        return adjustVibrance(out, amount: 0.10)
    }

    // MARK: - 2. Vintage Phone Presets
    private func applyNokiaSymbian(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6300, targetTint: -3.5)
        return adjustColor(out, contrast: 1.04, saturation: 0.88, brightness: 0.01)
    }

    private func applyMotorolaV3(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6350, targetTint: 0.5)
        return adjustColor(out, contrast: 1.16, saturation: 0.96, brightness: 0.01)
    }

    private func applyIPhone3GS(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6900, targetTint: 3.0)
        out = adjustColor(out, contrast: 1.05, saturation: 1.08, brightness: 0.02)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.04), p1: CGPoint(x: 0.25, y: 0.27), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.74), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyBlackberryQ10(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6150, targetTint: -1.5)
        out = adjustColor(out, contrast: 1.18, saturation: 0.92)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.77), p4: CGPoint(x: 1.0, y: 1.0))
    }

    private func applyKeitai88(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.15)
        out = adjustTempTint(out, targetTemp: 6400, targetTint: -4.0)
        out = adjustColor(out, contrast: 0.98, saturation: 1.06)
        return adjustVibrance(out, amount: 0.14)
    }

    private func applySonyK800i(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6600, targetTint: 1.0)
        out = adjustColor(out, contrast: 1.10, saturation: 1.12)
        return adjustVibrance(out, amount: 0.08)
    }

    // MARK: - 3. Fuji Presets
    private func applyClassicChrome(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6420, targetTint: -1.5)
        out = adjustColor(out, contrast: 1.14, saturation: 0.88)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.77), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyFujiPro400H(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6380, targetTint: -3.0)
        out = adjustColor(out, contrast: 1.02, saturation: 1.03)
        out = adjustVibrance(out, amount: 0.08)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.26), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.75), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyVelvia50(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6350, targetTint: -4.0)
        out = adjustColor(out, contrast: 1.18, saturation: 1.32)
        return adjustVibrance(out, amount: 0.24)
    }

    private func applyClassicNeg(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6380, targetTint: 1.5)
        out = adjustColor(out, contrast: 1.18, saturation: 0.92)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.21), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.78), p4: CGPoint(x: 1.0, y: 0.97))
    }

    private func applyAstia100F(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6520, targetTint: -1.0)
        out = adjustColor(out, contrast: 1.02, saturation: 1.05)
        out = adjustVibrance(out, amount: 0.06)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.26), p2: CGPoint(x: 0.5, y: 0.51), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.99))
    }

    private func applyAcrosBW(_ input: CIImage) -> CIImage {
        let out = adjustColor(input, contrast: 1.22, saturation: 0.0)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.79), p4: CGPoint(x: 1.0, y: 1.0))
    }

    // MARK: - 4. Vintage Cam Presets
    private func applyLomoLCA(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6800, targetTint: 3.0)
        out = adjustColor(out, contrast: 1.25, saturation: 1.28)
        return adjustVignette(out, intensity: 0.65, radius: 1.5)
    }

    private func applyMedium120LG(_ input: CIImage) -> CIImage {
        var out = applyPhotoEffectNamed(input, name: "CIPhotoEffectFade")
        out = adjustTempTint(out, targetTemp: 6750, targetTint: 2.0)
        out = adjustColor(out, contrast: 0.96, saturation: 1.05)
        return adjustVignette(out, intensity: 0.45, radius: 1.7)
    }

    private func applyFXN35(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6650, targetTint: 0.5)
        out = adjustColor(out, contrast: 1.14, saturation: 1.08)
        return adjustVignette(out, intensity: 0.20, radius: 2.0)
    }

    private func applyToyK(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.08)
        out = adjustTempTint(out, targetTemp: 6900, targetTint: 2.5)
        out = adjustColor(out, contrast: 1.06, saturation: 1.15)
        return adjustVignette(out, intensity: 0.40, radius: 1.6)
    }

    private func applyCineStill800T(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6100, targetTint: -4.0)
        out = adjustColor(out, contrast: 1.16, saturation: 1.14)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.78), p4: CGPoint(x: 1.0, y: 0.98))
        return adjustVignette(out, intensity: 0.20, radius: 2.0)
    }

    private func applyCam1998Street(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6950, targetTint: 3.5)
        out = adjustColor(out, contrast: 1.12, saturation: 1.12)
        return adjustVignette(out, intensity: 0.30, radius: 1.9)
    }

    // MARK: - 5. CCD Presets
    private func applyCCD1Cyber(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6250, targetTint: -2.5)
        out = adjustColor(out, contrast: 1.18, saturation: 1.16)
        return adjustVibrance(out, amount: 0.15)
    }

    private func applyDCCDWarm(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7150, targetTint: 3.0)
        out = adjustColor(out, contrast: 1.15, saturation: 1.14)
        return adjustExposure(out, ev: 0.08)
    }

    private func applyBlueSKCool(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 5850, targetTint: -3.0)
        out = adjustColor(out, contrast: 1.18, saturation: 1.06)
        return adjustVibrance(out, amount: 0.12)
    }

    private func applyMangaCam(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.14)
        out = adjustTempTint(out, targetTemp: 6350, targetTint: -4.5)
        out = adjustColor(out, contrast: 1.04, saturation: 1.14)
        return adjustVibrance(out, amount: 0.18)
    }

    private func applyGCCDGold(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7400, targetTint: 5.0)
        out = adjustColor(out, contrast: 1.14, saturation: 1.22)
        return adjustVignette(out, intensity: 0.25, radius: 2.0)
    }

    private func applyInstaLiteFlash(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.15)
        out = adjustTempTint(out, targetTemp: 6450, targetTint: 1.0)
        out = adjustColor(out, contrast: 1.26, saturation: 1.12)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.20), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.82), p4: CGPoint(x: 1.0, y: 1.0))
    }

    // MARK: - 6. Kodak Presets
    private func applyKodakPortra400(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6850, targetTint: 3.5)
        out = adjustColor(out, contrast: 1.04, saturation: 1.06)
        return adjustVibrance(out, amount: 0.12)
    }

    private func applyGold200(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7250, targetTint: 3.8)
        out = adjustColor(out, contrast: 1.10, saturation: 1.20)
        out = adjustVibrance(out, amount: 0.16)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.26), p2: CGPoint(x: 0.5, y: 0.51), p3: CGPoint(x: 0.75, y: 0.77), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyColorPlus200(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7100, targetTint: 2.2)
        out = adjustColor(out, contrast: 1.08, saturation: 1.08)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.04), p1: CGPoint(x: 0.25, y: 0.27), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.75), p4: CGPoint(x: 1.0, y: 0.96))
    }

    private func applyEktar100(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6580, targetTint: -1.0)
        out = adjustColor(out, contrast: 1.16, saturation: 1.25)
        return adjustVibrance(out, amount: 0.18)
    }

    private func applyTriX400(_ input: CIImage) -> CIImage {
        let out = adjustColor(input, contrast: 1.28, saturation: 0.0)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.20), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.80), p4: CGPoint(x: 1.0, y: 1.0))
    }

    private func applyVision3500D(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6720, targetTint: 0.8)
        out = adjustColor(out, contrast: 1.10, saturation: 1.10)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.24), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.97))
        return adjustVignette(out, intensity: 0.20, radius: 2.2)
    }

    // MARK: - 7. Ricoh Presets
    private func applyGRPositive(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6400, targetTint: -1.0)
        out = adjustColor(out, contrast: 1.24, saturation: 1.18)
        out = adjustVibrance(out, amount: 0.16)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.01), p1: CGPoint(x: 0.25, y: 0.20), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.80), p4: CGPoint(x: 1.0, y: 1.0))
    }

    private func applyGRHighBW(_ input: CIImage) -> CIImage {
        let out = adjustColor(input, contrast: 1.50, saturation: 0.0)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.15), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.85), p4: CGPoint(x: 1.0, y: 1.0))
    }

    private func applyGRFFilm(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6550, targetTint: 0.0)
        out = adjustColor(out, contrast: 1.14, saturation: 1.04)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.24), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.99))
    }

    private func applyGRStreetSnap(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6480, targetTint: -0.5)
        out = adjustColor(out, contrast: 1.18, saturation: 1.08)
        return adjustVibrance(out, amount: 0.10)
    }

    private func applyCaplioR(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6500, targetTint: 1.0)
        return adjustColor(out, contrast: 1.10, saturation: 1.02)
    }

    private func applyThetaDoc(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6650, targetTint: 1.5)
        out = adjustColor(out, contrast: 1.05, saturation: 0.95)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.06), p1: CGPoint(x: 0.25, y: 0.28), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.74), p4: CGPoint(x: 1.0, y: 0.95))
    }

    // MARK: - 8. Canon Presets
    private func applyPowershotG(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6620, targetTint: -2.0)
        out = adjustColor(out, contrast: 1.12, saturation: 1.14)
        return adjustVibrance(out, amount: 0.12)
    }

    private func applyIXUSY2K(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.12)
        out = adjustTempTint(out, targetTemp: 6550, targetTint: -1.5)
        out = adjustColor(out, contrast: 1.10, saturation: 1.12)
        return adjustVibrance(out, amount: 0.14)
    }

    private func applyEOS5DClassic(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6680, targetTint: 1.2)
        out = adjustColor(out, contrast: 1.06, saturation: 1.10)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.25), p2: CGPoint(x: 0.5, y: 0.51), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.99))
    }

    private func applySureShot35(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6780, targetTint: 2.0)
        out = adjustColor(out, contrast: 1.10, saturation: 1.16)
        return adjustVignette(out, intensity: 0.25, radius: 2.0)
    }

    private func applyCanonF1(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6500, targetTint: 0.0)
        return adjustColor(out, contrast: 1.14, saturation: 1.05)
    }

    private func applyPowershotPro1(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6600, targetTint: 0.5)
        return adjustColor(out, contrast: 1.16, saturation: 1.18)
    }

    // MARK: - 9. DV Presets
    private func applyMiniDV43(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6300, targetTint: -2.5)
        out = adjustColor(out, contrast: 1.08, saturation: 0.92, brightness: 0.02)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.04), p1: CGPoint(x: 0.25, y: 0.28), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.74), p4: CGPoint(x: 1.0, y: 0.96))
    }

    private func applyHi8Analog(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6850, targetTint: 2.0)
        out = adjustColor(out, contrast: 1.06, saturation: 0.96, brightness: 0.03)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.06), p1: CGPoint(x: 0.25, y: 0.30), p2: CGPoint(x: 0.5, y: 0.51), p3: CGPoint(x: 0.75, y: 0.73), p4: CGPoint(x: 1.0, y: 0.94))
    }

    private func applyDCRDVD(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6550, targetTint: 0.0)
        return adjustColor(out, contrast: 1.14, saturation: 1.12)
    }

    private func applyDVX10024p(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6650, targetTint: 0.5)
        out = adjustColor(out, contrast: 1.16, saturation: 1.04)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.22), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.77), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyVHSCHome(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6950, targetTint: 3.0)
        out = adjustColor(out, contrast: 1.05, saturation: 1.08, brightness: 0.04)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.08), p1: CGPoint(x: 0.25, y: 0.32), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.72), p4: CGPoint(x: 1.0, y: 0.92))
    }

    private func applyHDV1080i(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6450, targetTint: -0.5)
        return adjustColor(out, contrast: 1.12, saturation: 1.02)
    }

    // MARK: - 10. Instant Presets
    private func applyPolaroid600(_ input: CIImage) -> CIImage {
        var out = applyPhotoEffectNamed(input, name: "CIPhotoEffectInstant")
        out = adjustTempTint(out, targetTemp: 6800, targetTint: 2.0)
        out = adjustColor(out, contrast: 1.12, saturation: 1.08)
        return adjustVignette(out, intensity: 0.35, radius: 1.8)
    }

    private func applySX70TimeZero(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7200, targetTint: 4.0)
        out = adjustColor(out, contrast: 1.05, saturation: 1.12)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.05), p1: CGPoint(x: 0.25, y: 0.28), p2: CGPoint(x: 0.5, y: 0.52), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.96))
        return adjustVignette(out, intensity: 0.30, radius: 1.9)
    }

    private func applyInstaxMini(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.12)
        out = adjustTempTint(out, targetTemp: 6420, targetTint: -1.5)
        out = adjustColor(out, contrast: 1.04, saturation: 1.10)
        return adjustVibrance(out, amount: 0.10)
    }

    private func applyInstaxWide(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6520, targetTint: -0.5)
        out = adjustColor(out, contrast: 1.06, saturation: 1.06)
        return adjustVibrance(out, amount: 0.06)
    }

    private func applyInstaxSquare(_ input: CIImage) -> CIImage {
        let out = adjustTempTint(input, targetTemp: 6580, targetTint: 0.5)
        return adjustColor(out, contrast: 1.08, saturation: 1.08)
    }

    private func applyPolaroidSpectra(_ input: CIImage) -> CIImage {
        var out = applyPhotoEffectNamed(input, name: "CIPhotoEffectTransfer")
        out = adjustTempTint(out, targetTemp: 6850, targetTint: 2.5)
        return adjustColor(out, contrast: 1.14, saturation: 1.10)
    }

    // MARK: - 11. Original Presets
    private func applyStudioNatural(_ input: CIImage) -> CIImage {
        let out = adjustColor(input, contrast: 1.03, saturation: 1.02)
        return adjustVibrance(out, amount: 0.06)
    }

    // MARK: - Legacy Compatibility Presets
    private func applyCinemaTealOrange(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6650, targetTint: -3.0)
        out = adjustColor(out, contrast: 1.15, saturation: 1.12)
        return adjustVibrance(out, amount: 0.18)
    }

    private func applySunsetGlow(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7250, targetTint: 6.0)
        out = adjustColor(out, contrast: 1.10, saturation: 1.25)
        return adjustVignette(out, intensity: 0.20, radius: 2.0)
    }

    private func applyTokyoAiry(_ input: CIImage) -> CIImage {
        var out = adjustExposure(input, ev: 0.15)
        out = adjustTempTint(out, targetTemp: 6350, targetTint: -4.0)
        out = adjustColor(out, contrast: 0.98, saturation: 1.06)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.04), p1: CGPoint(x: 0.25, y: 0.28), p2: CGPoint(x: 0.5, y: 0.52), p3: CGPoint(x: 0.75, y: 0.77), p4: CGPoint(x: 1.0, y: 0.98))
        return adjustVibrance(out, amount: 0.12)
    }

    private func applyHKCinema90s(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6850, targetTint: -5.0)
        out = adjustColor(out, contrast: 1.18, saturation: 1.15)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.21), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.79), p4: CGPoint(x: 1.0, y: 0.97))
        return adjustVignette(out, intensity: 0.35, radius: 1.8)
    }

    private func applyLeicaMonochrom(_ input: CIImage) -> CIImage {
        var out = adjustColor(input, contrast: 1.15, saturation: 0.0)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.01), p1: CGPoint(x: 0.25, y: 0.24), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.78), p4: CGPoint(x: 1.0, y: 0.99))
    }

    private func applyMonochromeNoir(_ input: CIImage) -> CIImage {
        let out = adjustColor(input, contrast: 1.35, saturation: 0.0)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.0), p1: CGPoint(x: 0.25, y: 0.18), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.82), p4: CGPoint(x: 1.0, y: 1.0))
    }

    private func applyVintageWarm(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 7300, targetTint: 5.0)
        out = adjustColor(out, contrast: 1.05, saturation: 1.12)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.06), p1: CGPoint(x: 0.25, y: 0.28), p2: CGPoint(x: 0.5, y: 0.50), p3: CGPoint(x: 0.75, y: 0.73), p4: CGPoint(x: 1.0, y: 0.94))
        return adjustVignette(out, intensity: 0.28, radius: 1.9)
    }

    private func applyStreetClassic(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6480, targetTint: -1.0)
        out = adjustColor(out, contrast: 1.16, saturation: 1.06)
        return adjustVibrance(out, amount: 0.10)
    }

    private func applyNordicCold(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 5800, targetTint: -3.0)
        out = adjustColor(out, contrast: 1.14, saturation: 0.85)
        return adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.02), p1: CGPoint(x: 0.25, y: 0.23), p2: CGPoint(x: 0.5, y: 0.49), p3: CGPoint(x: 0.75, y: 0.76), p4: CGPoint(x: 1.0, y: 0.98))
    }

    private func applyNeonCyberpunk(_ input: CIImage) -> CIImage {
        var out = adjustTempTint(input, targetTemp: 6200, targetTint: 8.0)
        out = adjustColor(out, contrast: 1.25, saturation: 1.35)
        out = adjustToneCurve(out, p0: CGPoint(x: 0, y: 0.03), p1: CGPoint(x: 0.25, y: 0.20), p2: CGPoint(x: 0.5, y: 0.48), p3: CGPoint(x: 0.75, y: 0.82), p4: CGPoint(x: 1.0, y: 0.98))
        return adjustVignette(out, intensity: 0.40, radius: 1.6)
    }
}
