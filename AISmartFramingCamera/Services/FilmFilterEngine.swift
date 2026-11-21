import Foundation
import Metal
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import CoreGraphics
import Vision

/// Bộ tham số tinh chỉnh công thức giả lập phim theo thời gian thực (CoreImage GPU hợp nhất 1 pass).
public struct FilmSimulationTuning: Equatable, Sendable, Codable {
    /// Tương phản (-0.35 ... +0.35, 0 = giữ nguyên)
    public var contrast: Float = 0.0
    /// Bão hòa màu (-0.50 ... +0.50, 0 = giữ nguyên)
    public var saturation: Float = 0.0
    /// Độ ấm/lạnh màu (-0.50 ... +0.50, 0 = giữ nguyên)
    public var warmth: Float = 0.0
    /// Điều tiết vùng sáng Highlights (-0.40 ... +0.40, 0 = giữ nguyên)
    public var highlights: Float = 0.0
    /// Điều tiết vùng tối Shadows (-0.40 ... +0.40, 0 = giữ nguyên)
    public var shadows: Float = 0.0
    /// Mức hạt phim hữu cơ bổ sung (0.0 ... 1.0)
    public var grain: Float = 0.0
    /// Viền tối quang học góc ảnh (0.0 ... 1.0)
    public var vignette: Float = 0.0

    public static let neutral = FilmSimulationTuning()

    public init(
        contrast: Float = 0.0,
        saturation: Float = 0.0,
        warmth: Float = 0.0,
        highlights: Float = 0.0,
        shadows: Float = 0.0,
        grain: Float = 0.0,
        vignette: Float = 0.0
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.highlights = highlights
        self.shadows = shadows
        self.grain = grain
        self.vignette = vignette
    }

    public var isIdentity: Bool {
        abs(contrast) < 0.005
            && abs(saturation) < 0.005
            && abs(warmth) < 0.005
            && abs(highlights) < 0.005
            && abs(shadows) < 0.005
            && grain < 0.005
            && vignette < 0.005
    }
}

/// Tham số cân bằng trắng GPU an toàn cho ống kính đa tiêu cự ảo (builtInTripleCamera / DualWide)
/// khi Apple AVFoundation không hỗ trợ `isLockingWhiteBalanceWithCustomDeviceGainsSupported`.
public struct ProPhotoSoftwareWBGrade: Equatable, Sendable {
    public var isActive: Bool
    /// Nhiệt độ màu Kelvin (2500K lạnh ... 5500K trung tính ... 9500K ấm)
    public var kelvin: Float
    /// Sắc độ Tint (-50 xanh lá ... 0 ... +50 hồng tím)
    public var tint: Float

    public static let inactive = ProPhotoSoftwareWBGrade(isActive: false, kelvin: 5500, tint: 0)

    public init(isActive: Bool, kelvin: Float, tint: Float) {
        self.isActive = isActive
        self.kelvin = kelvin.isFinite ? max(2500, min(9500, kelvin)) : 5500
        self.tint = tint.isFinite ? max(-50, min(50, tint)) : 0
    }

    public var isIdentity: Bool {
        !isActive || (abs(kelvin - 5500) < 25 && abs(tint) < 1.0)
    }
}

/// Kết quả xếp hạng công thức màu phim bằng Apple Vision Aesthetics (iOS 18+).
public struct FilmFilterRankingResult: Sendable {
    public let preset: FilmPreset
    public let aestheticDelta: Double
    public let evaluatedCount: Int
}

/// Bo xu ly mau quang hoc va gia lap chat phim chuyen nghiep.
/// Tich hop kien truc module hoa cho 62 tone mau gia lap may anh co dien, may quay bang tu va phong thu.
public final class FilmFilterEngine: @unchecked Sendable {
    public static let shared = FilmFilterEngine()

    private let context: CIContext
    private let stateLock = NSLock()
    private var _activeFilmTuning: FilmSimulationTuning = .neutral
    private var _activeSoftwareWhiteBalance: ProPhotoSoftwareWBGrade = .inactive

    public var activeFilmTuning: FilmSimulationTuning {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _activeFilmTuning
        }
        set {
            stateLock.lock()
            _activeFilmTuning = newValue
            stateLock.unlock()
        }
    }

    public var activeSoftwareWhiteBalance: ProPhotoSoftwareWBGrade {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _activeSoftwareWhiteBalance
        }
        set {
            stateLock.lock()
            _activeSoftwareWhiteBalance = newValue
            stateLock.unlock()
        }
    }

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
    }

    // MARK: - GPU White Balance & Film Recipe Fine-Tuning (Single-Pass Lazy CI Graph)

    public func applySoftwareWhiteBalance(to inputImage: CIImage, wb: ProPhotoSoftwareWBGrade) -> CIImage {
        guard !wb.isIdentity else { return inputImage }
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return inputImage }
        // Theo chuẩn Apple CoreImage: cố định targetNeutral ở 5500K trung tính, thay đổi inputNeutral:
        // Kelvin > 5500K làm ảnh ấm vàng, Kelvin < 5500K làm ảnh mát xanh; Tint (-) xanh lá, (+) hồng tím.
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: CGFloat(wb.kelvin), y: CGFloat(wb.tint)), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 5500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? inputImage
    }

    public func applyFilmTuning(
        to inputImage: CIImage,
        tuning: FilmSimulationTuning,
        isRealtimePreview: Bool = false
    ) -> CIImage {
        guard !tuning.isIdentity else { return inputImage }
        let prevRealtime = FilmSimulationCore.isRealtimePreview
        FilmSimulationCore.isRealtimePreview = isRealtimePreview
        defer { FilmSimulationCore.isRealtimePreview = prevRealtime }

        var output = inputImage

        // 1. Độ ấm/lạnh bổ sung cho giả lập phim
        if abs(tuning.warmth) >= 0.005 {
            let shiftedTemp = CGFloat(6500.0 + Double(tuning.warmth) * 2400.0)
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(output, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: shiftedTemp, y: 0), forKey: "inputNeutral")
                filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                output = filter.outputImage ?? output
            }
        }

        // 2. Tương phản & Bão hòa màu
        if abs(tuning.contrast) >= 0.005 || abs(tuning.saturation) >= 0.005 {
            let contrastVal = max(0.60, min(1.45, 1.0 + tuning.contrast))
            let satVal = max(0.0, min(1.65, 1.0 + tuning.saturation))
            output = FilmSimulationCore.applyColorControls(output, contrast: contrastVal, saturation: satVal)
        }

        // 3. Đường cong Vùng sáng (Highlights) & Vùng tối (Shadows)
        if abs(tuning.highlights) >= 0.005 || abs(tuning.shadows) >= 0.005 {
            let sh = CGFloat(max(-0.40, min(0.40, tuning.shadows)))
            let hi = CGFloat(max(-0.40, min(0.40, tuning.highlights)))
            let p0 = CGPoint(x: 0.0, y: max(0.0, sh * 0.14))
            let p1 = CGPoint(x: 0.25, y: max(0.05, min(0.45, 0.25 + sh * 0.20)))
            let p2 = CGPoint(x: 0.50, y: 0.50)
            let p3 = CGPoint(x: 0.75, y: max(0.55, min(0.95, 0.75 + hi * 0.20)))
            let p4 = CGPoint(x: 1.0, y: min(1.0, max(0.86, 1.0 + hi * 0.12)))
            output = FilmSimulationCore.applyToneCurve(output, p0: p0, p1: p1, p2: p2, p3: p3, p4: p4)
        }

        // 4. Viền tối quang học (Vignette)
        if tuning.vignette >= 0.005 {
            output = FilmSimulationCore.applyVignette(
                output,
                intensity: min(1.6, tuning.vignette * 1.45),
                radius: 1.55
            )
        }

        // 5. Hạt phim hữu cơ (bỏ qua bước blur nặng khi chạy preview 60 FPS)
        if tuning.grain >= 0.005 {
            output = FilmSimulationCore.applyOrganicGrain(
                output,
                intensity: min(1.0, tuning.grain * 0.85),
                grainSize: 1.25
            )
        }

        return output
    }

    // MARK: - Manual Film Presets (62 Tones Chuyen Nghiep)
    public func applyPreset(to image: CGImage, preset: FilmPreset, intensity: Float = 1.0) -> CGImage? {
        let wb = activeSoftwareWhiteBalance
        let tuning = activeFilmTuning
        let hasPreset = preset != .aiFullAuto && preset != .standard && preset != .proColorGrade && intensity > 0.001
        guard hasPreset || !wb.isIdentity || !tuning.isIdentity else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset, intensity: intensity) else { return image }
        return context.createCGImage(
            filteredCI,
            from: filteredCI.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    public func applyPreset(
        to inputImage: CIImage,
        preset: FilmPreset,
        intensity: Float = 1.0,
        isRealtimePreview: Bool = false,
        applyUserGrade: Bool = true
    ) -> CIImage? {
        let wb = applyUserGrade ? activeSoftwareWhiteBalance : .inactive
        let tuning = applyUserGrade ? activeFilmTuning : .neutral
        let hasPreset = preset != .standard && preset != .aiFullAuto && preset != .proColorGrade && intensity > 0.001
        guard hasPreset || !wb.isIdentity || !tuning.isIdentity else { return inputImage }

        let prevRealtime = FilmSimulationCore.isRealtimePreview
        FilmSimulationCore.isRealtimePreview = isRealtimePreview
        defer { FilmSimulationCore.isRealtimePreview = prevRealtime }

        let wbAdjustedInput = applySoftwareWhiteBalance(to: inputImage, wb: wb)
        let workingOutput: CIImage

        if !hasPreset {
            workingOutput = wbAdjustedInput
        } else {
            let fullSimulated: CIImage?
            switch preset {
            case .standard, .aiFullAuto, .proColorGrade:
                fullSimulated = wbAdjustedInput

            // 1. Trending
            case .fujiX:
                fullSimulated = FujiFilmSimulations.apply(wbAdjustedInput, preset: preset)
            case .cam1998:
                fullSimulated = VintageCamSimulations.apply(wbAdjustedInput, preset: preset)
            case .nokia3310:
                fullSimulated = VintagePhoneSimulations.apply(wbAdjustedInput, preset: preset)
            case .luxury8800:
                fullSimulated = VintagePhoneSimulations.apply(wbAdjustedInput, preset: preset)
            case .kambo:
                fullSimulated = VintageCamSimulations.apply(wbAdjustedInput, preset: preset)
            case .cpm35:
                fullSimulated = VintageCamSimulations.apply(wbAdjustedInput, preset: preset)

            // 2. Vintage Phone
            case .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
                fullSimulated = VintagePhoneSimulations.apply(wbAdjustedInput, preset: preset)

            // 3. Fuji
            case .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW:
                fullSimulated = FujiFilmSimulations.apply(wbAdjustedInput, preset: preset)

            // 4. Vintage Cam
            case .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street:
                fullSimulated = VintageCamSimulations.apply(wbAdjustedInput, preset: preset)

            // 5. CCD
            case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash:
                fullSimulated = CCDDigicamSimulations.apply(wbAdjustedInput, preset: preset)

            // 6. Kodak
            case .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D:
                fullSimulated = KodakFilmSimulations.apply(wbAdjustedInput, preset: preset)

            // 7. Ricoh
            case .grPositive, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc:
                fullSimulated = RicohGRSimulations.apply(wbAdjustedInput, preset: preset)

            // 8. Canon
            case .powershotG, .ixusY2K, .eos5DClassic, .sureShot35, .canonF1, .powershotPro1:
                fullSimulated = CanonCCDSimulations.apply(wbAdjustedInput, preset: preset)

            // 9. DV
            case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i:
                fullSimulated = AnalogDVSimulations.apply(wbAdjustedInput, preset: preset)

            // 10. Instant
            case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra:
                fullSimulated = InstantPolaroidSimulations.apply(wbAdjustedInput, preset: preset)

            // 11. Studio & Cinema Presets
            case .studioNatural:
                fullSimulated = CinemaAndStudioSimulations.apply(wbAdjustedInput, preset: preset)

            // 12. Historic & Creative Additions
            case .cyanotype, .grNegative, .bleachBypass:
                fullSimulated = HistoricAndCreativeSimulations.apply(wbAdjustedInput, preset: preset)

            // Legacy Compatibility Presets
            case .cinemaTealOrange, .sunsetGlow, .leicaMonochrom, .monochromeNoir, .nordicCold, .neonCyberpunk:
                fullSimulated = CinemaAndStudioSimulations.apply(wbAdjustedInput, preset: preset)
            case .tokyoAiry:
                fullSimulated = FujiFilmSimulations.apply(wbAdjustedInput, preset: preset)
            case .hkCinema90s:
                fullSimulated = AnalogDVSimulations.apply(wbAdjustedInput, preset: preset)
            case .vintageWarm:
                fullSimulated = VintageCamSimulations.apply(wbAdjustedInput, preset: preset)
            case .streetClassic:
                fullSimulated = RicohGRSimulations.apply(wbAdjustedInput, preset: preset)
            }

            if let output = fullSimulated {
                if intensity < 0.999 {
                    workingOutput = FilmSimulationCore.applyIntensityBlend(original: wbAdjustedInput, filtered: output, intensity: intensity)
                } else {
                    workingOutput = output
                }
            } else {
                workingOutput = wbAdjustedInput
            }
        }

        return applyFilmTuning(to: workingOutput, tuning: tuning, isRealtimePreview: isRealtimePreview)
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
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    // MARK: - Combined Preset & AI Tone Mapping Pipeline
    public func applyPresetAndAIParameters(to image: CGImage, preset: FilmPreset, params: AIColorParameters?, intensity: Float = 1.0) -> CGImage? {
        // Build one lazy graph and render once, avoiding two full 48 MP RGBA
        // intermediates and an unnecessary 8-bit colour round trip.
        var output = CIImage(cgImage: image)
        if (preset != .standard && preset != .aiFullAuto) || !activeSoftwareWhiteBalance.isIdentity || !activeFilmTuning.isIdentity {
            output = applyPreset(to: output, preset: preset, intensity: intensity) ?? output
        }
        if let params {
            output = applyAIColorParameters(to: output, params: params) ?? output
        }
        return context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
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
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
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

    // MARK: - iOS 18+ Apple Vision Aesthetic Film Filter Ranking (0 MB extra RAM, graceful iOS 17 fallback)

    /// Chấm điểm thẩm mỹ trực tiếp tối đa 3 công thức màu ứng viên so với ảnh gốc bằng
    /// `VNCalculateImageAestheticsScoresRequest` trên thumbnail <= 288px. Trả về `nil` trên iOS 17
    /// hoặc khi máy nóng / Low Power Mode để tự động rơi về `scene.recommendedFilter`.
    public func rankBestFilmPreset(for previewImage: CGImage, scene: DetectedSceneType) -> FilmFilterRankingResult? {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal == .nominal || thermal == .fair,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return nil
        }
        guard #available(iOS 18.0, *) else { return nil }

        let candidates = Array(scene.candidateFilmPresets.prefix(3))
        guard !candidates.isEmpty else { return nil }

        let rawCI = CIImage(cgImage: previewImage)
        let maxDim = max(rawCI.extent.width, rawCI.extent.height)
        guard maxDim > 16 else { return nil }
        let scale = min(1.0, 288.0 / maxDim)
        let smallCI = scale < 0.99
            ? rawCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : rawCI
        let colorSpace = previewImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        func evaluateAesthetic(_ ci: CIImage) -> (score: Double, isUtility: Bool)? {
            autoreleasepool {
                guard let cg = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: colorSpace) else {
                    return nil
                }
                let request = VNCalculateImageAestheticsScoresRequest()
                let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                    guard let obs = request.results?.first, obs.overallScore.isFinite else { return nil }
                    return (Double(obs.overallScore), obs.isUtility)
                } catch {
                    return nil
                }
            }
        }

        defer { context.clearCaches() }

        guard let baseEval = evaluateAesthetic(smallCI) else { return nil }
        var evaluatedCount = 1
        var bestPreset: FilmPreset?
        var bestScore = baseEval.score

        for preset in candidates {
            guard !Task.isCancelled else { return nil }
            let renderedCI: CIImage = autoreleasepool {
                applyPreset(
                    to: smallCI,
                    preset: preset,
                    intensity: 1.0,
                    isRealtimePreview: true,
                    applyUserGrade: false
                ) ?? smallCI
            }
            guard let candEval = evaluateAesthetic(renderedCI) else { continue }
            evaluatedCount += 1
            // Không chọn preset nếu nó khiến Vision đánh dấu ảnh bị tụt thành utility
            if candEval.isUtility && !baseEval.isUtility { continue }
            if candEval.score > bestScore {
                bestScore = candEval.score
                bestPreset = preset
            }
        }

        guard let winner = bestPreset else { return nil }
        let delta = bestScore - baseEval.score
        guard delta >= 0.015 else { return nil }
        return FilmFilterRankingResult(preset: winner, aestheticDelta: delta, evaluatedCount: evaluatedCount)
    }
}
