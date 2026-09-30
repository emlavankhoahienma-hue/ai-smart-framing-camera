import Foundation
import Metal
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import CoreGraphics

/// Bo xu ly mau quang hoc va gia lap chat phim chuyen nghiep.
/// Tich hop kien truc module hoa cho 62 tone mau gia lap may anh co dien, may quay bang tu va phong thu.
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

    // MARK: - Memory Management & Cache Eviction (Giai phong GPU & RAM khi doi preset)
    public func clearCache() {
        context.clearCaches()
        if #available(iOS 16.0, *) {
            context.reclaimResources()
        }
    }

    // MARK: - Manual Film Presets (62 Tones Chuyen Nghiep)
    public func applyPreset(to image: CGImage, preset: FilmPreset, intensity: Float = 1.0) -> CGImage? {
        guard preset != .aiFullAuto && preset != .standard else { return image }
        guard intensity > 0.001 else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset, intensity: intensity) else { return image }
        return context.createCGImage(
            filteredCI,
            from: filteredCI.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    public func applyPreset(to inputImage: CIImage, preset: FilmPreset, intensity: Float = 1.0) -> CIImage? {
        guard preset != .standard && preset != .aiFullAuto else { return inputImage }
        guard intensity > 0.001 else { return inputImage }

        let fullSimulated: CIImage?
        switch preset {
        case .standard, .aiFullAuto:
            fullSimulated = inputImage

        // 1. Trending
        case .fujiX:
            fullSimulated = FujiFilmSimulations.apply(inputImage, preset: preset)
        case .cam1998:
            fullSimulated = VintageCamSimulations.apply(inputImage, preset: preset)
        case .nokia3310:
            fullSimulated = VintagePhoneSimulations.apply(inputImage, preset: preset)
        case .luxury8800:
            fullSimulated = VintagePhoneSimulations.apply(inputImage, preset: preset)
        case .kambo:
            fullSimulated = VintageCamSimulations.apply(inputImage, preset: preset)
        case .cpm35:
            fullSimulated = VintageCamSimulations.apply(inputImage, preset: preset)

        // 2. Vintage Phone
        case .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            fullSimulated = VintagePhoneSimulations.apply(inputImage, preset: preset)

        // 3. Fuji
        case .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW:
            fullSimulated = FujiFilmSimulations.apply(inputImage, preset: preset)

        // 4. Vintage Cam
        case .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street:
            fullSimulated = VintageCamSimulations.apply(inputImage, preset: preset)

        // 5. CCD
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash:
            fullSimulated = CCDDigicamSimulations.apply(inputImage, preset: preset)

        // 6. Kodak
        case .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D:
            fullSimulated = KodakFilmSimulations.apply(inputImage, preset: preset)

        // 7. Ricoh
        case .grPositive, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc:
            fullSimulated = RicohGRSimulations.apply(inputImage, preset: preset)

        // 8. Canon
        case .powershotG, .ixusY2K, .eos5DClassic, .sureShot35, .canonF1, .powershotPro1:
            fullSimulated = CanonCCDSimulations.apply(inputImage, preset: preset)

        // 9. DV
        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i:
            fullSimulated = AnalogDVSimulations.apply(inputImage, preset: preset)

        // 10. Instant
        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra:
            fullSimulated = InstantPolaroidSimulations.apply(inputImage, preset: preset)

        // 11. Studio & Cinema Presets
        case .studioNatural:
            fullSimulated = CinemaAndStudioSimulations.apply(inputImage, preset: preset)

        // Legacy Compatibility Presets
        case .cinemaTealOrange, .sunsetGlow, .leicaMonochrom, .monochromeNoir, .nordicCold, .neonCyberpunk:
            fullSimulated = CinemaAndStudioSimulations.apply(inputImage, preset: preset)
        case .tokyoAiry:
            fullSimulated = FujiFilmSimulations.apply(inputImage, preset: preset)
        case .hkCinema90s:
            fullSimulated = AnalogDVSimulations.apply(inputImage, preset: preset)
        case .vintageWarm:
            fullSimulated = VintageCamSimulations.apply(inputImage, preset: preset)
        case .streetClassic:
            fullSimulated = RicohGRSimulations.apply(inputImage, preset: preset)
        }

        guard let output = fullSimulated else { return inputImage }
        if intensity < 0.999 {
            return FilmSimulationCore.applyIntensityBlend(original: inputImage, filtered: output, intensity: intensity)
        }
        return output
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
        return context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    // MARK: - Combined Preset & AI Tone Mapping Pipeline
    public func applyPresetAndAIParameters(to image: CGImage, preset: FilmPreset, params: AIColorParameters?, intensity: Float = 1.0) -> CGImage? {
        // Build one lazy graph and render once, avoiding two full 48 MP RGBA
        // intermediates and an unnecessary 8-bit colour round trip.
        var output = CIImage(cgImage: image)
        if preset != .standard && preset != .aiFullAuto {
            output = applyPreset(to: output, preset: preset, intensity: intensity) ?? output
        }
        if let params {
            output = applyAIColorParameters(to: output, params: params) ?? output
        }
        return context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    // MARK: - AI Full Color Mode
    public func applyAIColorParameters(to image: CGImage, params: AIColorParameters) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let result = applyAIColorParameters(to: ciImage, params: params) else { return image }
        return context.createCGImage(
            result,
            from: result.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    public func applyAIColorParameters(to inputImage: CIImage, params: AIColorParameters) -> CIImage? {
        var output = inputImage

        let exposureBias = max(-1.2, min(1.2, params.exposureBias))
        if abs(exposureBias) > 0.02 {
            output = FilmSimulationCore.applyExposure(output, ev: Float(exposureBias))
        }

        let warmth = max(-0.35, min(0.35, params.warmthShift))
        let tint = max(-0.25, min(0.25, params.tintShift))
        if abs(warmth) > 0.01 || abs(tint) > 0.01 {
            let neutralTemp: CGFloat = 6500
            let targetTemp = neutralTemp + warmth * 1600.0
            output = FilmSimulationCore.applyTempTint(
                output,
                neutralTemp: neutralTemp,
                targetTemp: targetTemp,
                targetTint: tint * 8.0
            )
        }

        let contrast = max(0.85, min(1.25, params.contrastCurve))
        let saturation = max(0.80, min(1.28, params.saturationLevel))
        if abs(contrast - 1.0) > 0.02 || abs(saturation - 1.0) > 0.02 {
            output = FilmSimulationCore.applyColorControls(
                output,
                contrast: Float(contrast),
                saturation: Float(saturation)
            )
        }

        let highlight = max(-0.30, min(0.30, params.highlightRecovery))
        let shadow = max(-0.25, min(0.35, params.shadowLift))
        if abs(highlight) > 0.02 || abs(shadow) > 0.02 {
            let p0 = CGPoint(x: 0.0, y: max(0.0, shadow * 0.15))
            let p1 = CGPoint(x: 0.25, y: 0.25 + shadow * 0.10)
            let p2 = CGPoint(x: 0.50, y: 0.50)
            let p3 = CGPoint(x: 0.75, y: 0.75 - highlight * 0.10)
            let p4 = CGPoint(x: 1.0, y: min(1.0, 1.0 - highlight * 0.15))
            output = FilmSimulationCore.applyToneCurve(output, p0: p0, p1: p1, p2: p2, p3: p3, p4: p4)
        }

        let vibrance = max(-0.15, min(0.25, params.vibranceBoost))
        if abs(vibrance) > 0.02 {
            output = FilmSimulationCore.applyVibrance(output, amount: Float(vibrance))
        }

        return output
    }
}
