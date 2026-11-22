import Foundation
import SwiftUI
import simd

// MARK: - Vintage Date Stamp (Dấu Thời Gian kiểu máy phim 35mm / Dazz Cam)
public enum VintageDateStampStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case off = "off"
    case classicQuartz = "classic_quartz"     // Kiểu 1: 11 22 '26 chấm quartz đỏ cam cổ điển
    case retroLED = "retro_led"               // Kiểu 2: '26 11 22 LED cam rực sắc nét
    case compactSlanted = "compact_slanted"   // Kiểu 3: 11 22 '26 chữ nghiêng đỏ rực 90s

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Tắt"
        case .classicQuartz: return "Quartz"
        case .retroLED: return "LED 90s"
        case .compactSlanted: return "Compact"
        }
    }

    public var isEnabled: Bool { self != .off }

    /// Chuỗi ngày chuẩn theo từng kiểu dấu thời gian máy phim thực tế.
    public func formattedDate(from date: Date = Date()) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date) % 100
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        switch self {
        case .off:
            return ""
        case .classicQuartz:
            return String(format: "%d %02d '%02d", m, d, y)
        case .retroLED:
            return String(format: "'%02d %02d %02d", y, m, d)
        case .compactSlanted:
            return String(format: "%d %02d '%02d", m, d, y)
        }
    }

    /// Chuỗi mẫu cố định hiển thị trong 4 ô chọn Dấu Thời Gian.
    public var previewSampleText: String {
        switch self {
        case .off: return ""
        case .classicQuartz: return "2 25 '26"
        case .retroLED: return "'26 02 25"
        case .compactSlanted: return "2 25 '26"
        }
    }
}

// MARK: - Adjustable Organic Light Leak Configuration
public struct VintageLightLeakConfig: Equatable, Sendable, Codable {
    /// Cường độ rò sáng phim quang học (0.0 = tắt ... 1.0 = 100%)
    public var intensity: Float = 0.0
    /// Chỉ số hoa văn rò sáng (0 ... 7: 8 mẫu vệt cháy phim cam/đỏ/hổ phách/hồng tím)
    public var patternIndex: Int = 0
    /// Tự động đổi mẫu rò sáng ngẫu nhiên cho mỗi bức ảnh chụp (giống Light Leak Ngẫu Nhiên)
    public var randomizeOnCapture: Bool = true

    public static let off = VintageLightLeakConfig(intensity: 0.0, patternIndex: 0, randomizeOnCapture: true)

    public init(intensity: Float = 0.0, patternIndex: Int = 0, randomizeOnCapture: Bool = true) {
        self.intensity = intensity.isFinite ? max(0.0, min(1.0, intensity)) : 0.0
        self.patternIndex = ((patternIndex % 8) + 8) % 8
        self.randomizeOnCapture = randomizeOnCapture
    }

    public var isIdentity: Bool {
        intensity < 0.005
    }

    public var percentInt: Int {
        Int(round(intensity * 100.0))
    }
}

// MARK: - Unified Single-Pass Metal Optical Recipe for All Vintage & Film Cameras
/// Bộ công thức quang học đầy đủ căn lề 16-byte gửi trực tiếp vào Single-Pass Metal Uber-Shader (~0.4ms/frame).
public struct VintageCameraOpticalRecipe: Equatable, Sendable {
    public var lutName: String?
    public var matrixRow0: SIMD4<Float>
    public var matrixRow1: SIMD4<Float>
    public var matrixRow2: SIMD4<Float>
    public var shadowTint: SIMD4<Float>       // (r, g, b, strength)
    public var highlightTint: SIMD4<Float>    // (r, g, b, strength)
    public var toneParams: SIMD4<Float>       // (contrast, toeLift, shoulderRoll, exposureEV)
    public var colorParams: SIMD4<Float>      // (saturation, vibrance, warmth, tint)
    public var hslShift: SIMD4<Float>         // (redWarmth, greenTealShift, blueCyanShift, skinGlow)
    public var analogParams: SIMD4<Float>     // (grainIntensity, grainSize, vignetteIntensity, fadeAmount)
    public var opticalParams: SIMD4<Float>    // (halationIntensity, diffusionIntensity, chromaBleedPx, specialMode)
    // specialMode: 0 = Color, 1 = Silver Monochrome, 2 = Cyanotype Blue, 3 = Nokia 3310 Olive LCD, 4 = Bleach Bypass

    public static let identity = VintageCameraOpticalRecipe(
        lutName: nil,
        matrixRow0: SIMD4(1, 0, 0, 0),
        matrixRow1: SIMD4(0, 1, 0, 0),
        matrixRow2: SIMD4(0, 0, 1, 0),
        shadowTint: SIMD4(0, 0, 0, 0),
        highlightTint: SIMD4(0, 0, 0, 0),
        toneParams: SIMD4(1.0, 0.0, 0.0, 0.0),
        colorParams: SIMD4(1.0, 0.0, 0.0, 0.0),
        hslShift: SIMD4(0, 0, 0, 0),
        analogParams: SIMD4(0.0, 1.2, 0.0, 0.0),
        opticalParams: SIMD4(0.0, 0.0, 0.0, 0.0)
    )
}

// MARK: - Camera Hardware Icon Mapping, Dazz-Style Labels & Calibrated Optical Recipes
extension FilmPreset {
    /// Tên tệp PNG minh họa thân máy ảnh thu nhỏ trong `Resources/CameraIcons/` (nền trong suốt 160x160).
    public var cameraIconAssetName: String {
        switch self {
        // 1. Classic 35mm Compact & Everyday Film
        case .cpm35, .cam1998Street, .vintageWarm, .streetClassic:
            return "cam_classic35"
        // 2. Silver Rangefinder (Fuji X / FXN / Classic Neg)
        case .fujiX, .classicNeg, .fxn35, .tokyoAiry:
            return "cam_rangefinder_silver"
        // 3. Disposable Retro Green (1998 / Toy K / FunS)
        case .cam1998, .toyK, .sureShot35:
            return "cam_disposable_green"
        // 4. Orange Bellows Folding / Creative Film (LOMO / CineStill / Cyanotype / Sunset)
        case .lomoLCA, .cinestill800T, .cyanotype, .sunsetGlow:
            return "cam_folding_orange"
        // 5. Matte Black Pro Rangefinder (Classic Chrome / Leica / Noir / Studio / Original)
        case .classicChrome, .leicaMonochrom, .monochromeNoir, .studioNatural, .standard, .proColorGrade, .aiFullAuto, .nordicCold:
            return "cam_rangefinder_black"
        // 6. Champagne Titanium Compact (Fuji Pro 400H / Astia / Velvia / Gold / ColorPlus)
        case .fujiPro400H, .astia100F, .velvia50, .colorPlus200:
            return "cam_titanium_compact"
        // 7. Stealth Ricoh GR Street Compact
        case .grPositive, .grNegative, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc:
            return "cam_ricoh_gr"
        // 8. Classic Chrome SLR with Brass Dial (Kodak Portra / Gold / Ektar / Tri-X / Canon F-1)
        case .kodakPortra400, .gold200, .ektar100, .triX400, .canonF1:
            return "cam_slr_chrome"
        // 9. Boxy 120 Medium Format (120LG / Acros)
        case .medium120LG, .acrosBW:
            return "cam_medium120"
        // 10. Retro VHS / Hi8 Camcorder
        case .vhscHome, .hi8Analog, .hkCinema90s:
            return "cam_vhs"
        // 11. Super 8mm Yellow Cine Camcorder (Kambo / Neon / Cinema Teal)
        case .kambo, .cinemaTealOrange, .neonCyberpunk:
            return "cam_8mm"
        // 12. Metallic Silver MiniDV Handycam
        case .miniDV43, .dcrDVD, .hdv1080i:
            return "cam_minidv"
        // 13. Y2K Brushed Silver CCD Compact
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .ixusY2K, .instaLiteFlash:
            return "cam_ccd_silver"
        // 14. Matte Black Enthusiast Digital (PowerShot G / Pro1 / EOS 5D / G-CCD)
        case .powershotG, .powershotPro1, .eos5DClassic, .gCcdGold:
            return "cam_powershot_black"
        // 15. Vintage 16mm Cinema Camera (Kodak 500D / DVX100 / Bleach Bypass)
        case .vision3500D, .dvx10024p, .bleachBypass:
            return "cam_16mm_cine"
        // 16. Mint-Cream Instax Camera
        case .instaxMini, .instaxWide, .instaxSquare:
            return "cam_instax_mint"
        // 17. Classic Polaroid Rainbow Instant Camera
        case .polaroid600, .sx70TimeZero, .polaroidSpectra:
            return "cam_polaroid_rainbow"
        // 18. Classic 2000s Retro Camera Phone
        case .nokia3310, .luxury8800, .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            return "cam_retro_phone"
        }
    }

    /// Nhãn màu ngắn đặc trưng kiểu máy ảnh cổ điển hiển thị dưới thân máy (vd: D Classic, FXN R, CPM35, 8mm...).
    public var cameraDisplayTag: String {
        switch self {
        case .cpm35: return "CPM35"
        case .fujiX: return "FXN R"
        case .cam1998: return "D FunS"
        case .kambo: return "8mm"
        case .cinestill800T: return "800T"
        case .classicChrome: return "OFM R"
        case .classicNeg: return "Classic N"
        case .fujiPro400H: return "Pro 400H"
        case .velvia50: return "Velvia"
        case .astia100F: return "CT2F"
        case .acrosBW: return "Acros"
        case .lomoLCA: return "PAF R"
        case .medium120LG: return "S67"
        case .fxn35: return "D Classic"
        case .toyK: return "D Half"
        case .cam1998Street: return "135 SR"
        case .kodakPortra400: return "Portra"
        case .gold200: return "Gold 200"
        case .colorPlus200: return "Color+"
        case .ektar100: return "Ektar"
        case .triX400: return "Tri-X"
        case .vision3500D: return "16mm"
        case .grPositive: return "GR DR"
        case .grNegative: return "GR Neg"
        case .grHighBW: return "GR B&W"
        case .grFFilm: return "GR F"
        case .ccd1Cyber: return "CCD R"
        case .dCcdWarm: return "D-CCD"
        case .gCcdGold: return "G-CCD"
        case .blueSKCool: return "BlueSK"
        case .powershotG: return "G-Pro"
        case .ixusY2K: return "IXUS"
        case .vhscHome: return "VHS"
        case .miniDV43: return "MiniDV"
        case .dcrDVD: return "DCR"
        case .hi8Analog: return "Hi8"
        case .dvx10024p: return "Kino"
        case .instaxMini: return "Inst C"
        case .instaxSquare: return "Inst SQ"
        case .instaxWide: return "Inst W"
        case .polaroid600: return "Pola 600"
        case .sx70TimeZero: return "SX-70"
        default: return shortTitle
        }
    }

    /// Bộ công thức quang học đơn luồng Metal đã hiệu chuẩn riêng cho từng dòng máy ảnh / phim.
    public var metalOpticalRecipe: VintageCameraOpticalRecipe {
        switch self {
        case .standard, .proColorGrade, .aiFullAuto:
            return .identity

        // MARK: - 1. Dazz Signature & Classic 35mm Film Cameras
        case .cpm35:
            // Compact 35mm ấm mịn, vùng tối nâu ấm nhẹ, hạt mịn hữu cơ
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.04, 0.02, -0.02, 0),
                matrixRow1: SIMD4(0.01, 1.00, -0.01, 0),
                matrixRow2: SIMD4(-0.02, 0.01, 0.93, 0),
                shadowTint: SIMD4(0.024, 0.014, 0.002, 0.55),
                highlightTint: SIMD4(0.026, 0.016, -0.014, 0.45),
                toneParams: SIMD4(1.09, 0.028, 0.16, 0.02),
                colorParams: SIMD4(1.03, 0.08, 0.14, 0.02),
                hslShift: SIMD4(0.05, -0.06, -0.04, 0.14),
                analogParams: SIMD4(0.24, 1.25, 0.24, 0.14),
                opticalParams: SIMD4(0.08, 0.04, 0.0, 0)
            )

        case .fxn35:
            // D Classic: 35mm flagship xanh ngọc bóng tối + highlight vàng kem cổ điển
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.02, 0.03, -0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.03, 0.01, 0),
                matrixRow2: SIMD4(-0.03, 0.05, 0.94, 0),
                shadowTint: SIMD4(-0.010, 0.022, 0.018, 0.65),
                highlightTint: SIMD4(0.032, 0.020, -0.016, 0.55),
                toneParams: SIMD4(1.12, 0.022, 0.18, 0.00),
                colorParams: SIMD4(0.98, 0.10, 0.08, -0.05),
                hslShift: SIMD4(0.04, 0.12, -0.08, 0.10),
                analogParams: SIMD4(0.26, 1.30, 0.28, 0.16),
                opticalParams: SIMD4(0.10, 0.06, 0.0, 0)
            )

        case .cam1998:
            // D FunS / 1998 Disposable: sắc xanh lục mát đặc trưng phim dùng 1 lần Fuji Simple Ace
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.98, 0.02, 0.01, 0),
                matrixRow1: SIMD4(-0.02, 1.06, 0.00, 0),
                matrixRow2: SIMD4(-0.02, 0.04, 0.96, 0),
                shadowTint: SIMD4(-0.016, 0.028, 0.014, 0.72),
                highlightTint: SIMD4(0.022, 0.018, -0.010, 0.42),
                toneParams: SIMD4(1.14, 0.035, 0.14, 0.02),
                colorParams: SIMD4(1.06, 0.12, -0.04, -0.10),
                hslShift: SIMD4(0.06, 0.16, -0.06, 0.05),
                analogParams: SIMD4(0.32, 1.45, 0.34, 0.20),
                opticalParams: SIMD4(0.12, 0.05, 0.6, 0)
            )

        case .fujiX:
            // FXN R: Fuji X-T30 + Classic Negative đỏ gạch trầm, xanh lá sâu, bóng tối mát nhẹ
            return VintageCameraOpticalRecipe(
                lutName: "Fuji-XT30",
                matrixRow0: SIMD4(1.05, 0.02, -0.04, 0),
                matrixRow1: SIMD4(-0.02, 1.00, 0.02, 0),
                matrixRow2: SIMD4(-0.03, 0.04, 0.96, 0),
                shadowTint: SIMD4(-0.012, 0.014, 0.016, 0.55),
                highlightTint: SIMD4(0.024, 0.012, -0.012, 0.48),
                toneParams: SIMD4(1.14, 0.015, 0.20, 0.0),
                colorParams: SIMD4(0.96, 0.10, 0.08, -0.02),
                hslShift: SIMD4(0.12, 0.10, -0.10, 0.08),
                analogParams: SIMD4(0.22, 1.25, 0.22, 0.10),
                opticalParams: SIMD4(0.06, 0.0, 0.0, 0)
            )

        case .classicChrome:
            // OFM R / Classic Chrome: 3D LUT + hạ bão hòa nhẹ trời ngọc lam, tương phản biên tập
            return VintageCameraOpticalRecipe(
                lutName: "Beetle.92-FujiClassicChrome",
                matrixRow0: SIMD4(0.96, 0.03, 0.01, 0),
                matrixRow1: SIMD4(-0.01, 0.99, 0.02, 0),
                matrixRow2: SIMD4(-0.03, 0.06, 0.97, 0),
                shadowTint: SIMD4(-0.006, 0.008, 0.012, 0.35),
                highlightTint: SIMD4(0.014, 0.010, -0.008, 0.30),
                toneParams: SIMD4(1.08, 0.012, 0.16, 0.0),
                colorParams: SIMD4(0.92, 0.05, -0.03, -0.03),
                hslShift: SIMD4(-0.04, 0.08, -0.12, 0.04),
                analogParams: SIMD4(0.18, 1.20, 0.18, 0.08),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        case .fujiPro400H:
            // Pro 400H: da sáng pastel trong trẻo, bóng nâng nhẹ mềm mại
            return VintageCameraOpticalRecipe(
                lutName: "Beetle.92-Fuji160C",
                matrixRow0: SIMD4(0.98, 0.02, 0.00, 0),
                matrixRow1: SIMD4(0.00, 1.02, -0.01, 0),
                matrixRow2: SIMD4(0.01, 0.04, 0.96, 0),
                shadowTint: SIMD4(0.008, 0.018, 0.016, 0.45),
                highlightTint: SIMD4(0.018, 0.014, 0.004, 0.40),
                toneParams: SIMD4(1.02, 0.038, 0.18, 0.06),
                colorParams: SIMD4(0.95, 0.08, 0.02, 0.02),
                hslShift: SIMD4(-0.02, 0.12, -0.06, 0.16),
                analogParams: SIMD4(0.16, 1.15, 0.10, 0.14),
                opticalParams: SIMD4(0.0, 0.12, 0.0, 0)
            )

        case .velvia50:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.09, -0.04, -0.04, 0),
                matrixRow1: SIMD4(-0.04, 1.11, -0.06, 0),
                matrixRow2: SIMD4(-0.03, -0.04, 1.07, 0),
                shadowTint: SIMD4(-0.008, 0.002, 0.016, 0.40),
                highlightTint: SIMD4(0.014, 0.006, 0.000, 0.25),
                toneParams: SIMD4(1.18, 0.0, 0.14, 0.0),
                colorParams: SIMD4(1.24, 0.22, 0.02, 0.04),
                hslShift: SIMD4(0.08, 0.14, 0.12, 0.02),
                analogParams: SIMD4(0.10, 1.00, 0.16, 0.0),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        case .classicNeg:
            return VintageCameraOpticalRecipe(
                lutName: "Beetle.92-FujiNostalgicNeg",
                matrixRow0: SIMD4(1.03, 0.02, -0.03, 0),
                matrixRow1: SIMD4(-0.02, 1.01, 0.02, 0),
                matrixRow2: SIMD4(-0.03, 0.04, 0.96, 0),
                shadowTint: SIMD4(-0.014, 0.016, 0.018, 0.55),
                highlightTint: SIMD4(0.020, 0.010, -0.010, 0.45),
                toneParams: SIMD4(1.16, 0.018, 0.18, 0.0),
                colorParams: SIMD4(0.94, 0.08, 0.05, -0.04),
                hslShift: SIMD4(0.10, 0.12, -0.08, 0.06),
                analogParams: SIMD4(0.24, 1.35, 0.22, 0.12),
                opticalParams: SIMD4(0.06, 0.0, 0.0, 0)
            )

        case .astia100F:
            // CT2F / Astia: da chân dung mịn ấm, tương phản trung tính sang trọng
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.03, 0.01, -0.01, 0),
                matrixRow1: SIMD4(0.00, 1.01, 0.00, 0),
                matrixRow2: SIMD4(0.00, 0.02, 0.97, 0),
                shadowTint: SIMD4(0.008, 0.004, 0.012, 0.40),
                highlightTint: SIMD4(0.020, 0.012, 0.004, 0.42),
                toneParams: SIMD4(1.05, 0.024, 0.18, 0.04),
                colorParams: SIMD4(1.04, 0.12, 0.06, 0.05),
                hslShift: SIMD4(0.04, 0.02, -0.04, 0.18),
                analogParams: SIMD4(0.14, 1.10, 0.14, 0.08),
                opticalParams: SIMD4(0.0, 0.08, 0.0, 0)
            )

        case .acrosBW:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.32, 0.56, 0.12, 0),
                matrixRow1: SIMD4(0.32, 0.56, 0.12, 0),
                matrixRow2: SIMD4(0.32, 0.56, 0.12, 0),
                shadowTint: SIMD4(-0.004, 0.000, 0.008, 0.45),
                highlightTint: SIMD4(0.008, 0.006, 0.002, 0.35),
                toneParams: SIMD4(1.22, 0.012, 0.18, 0.0),
                colorParams: SIMD4(0.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.22, 1.15, 0.22, 0.06),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 1)
            )

        // MARK: - 2. Kodak & Cinema Negative
        case .kodakPortra400:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.04, 0.03, -0.02, 0),
                matrixRow1: SIMD4(0.01, 1.00, -0.01, 0),
                matrixRow2: SIMD4(-0.01, 0.02, 0.94, 0),
                shadowTint: SIMD4(0.016, 0.012, 0.004, 0.45),
                highlightTint: SIMD4(0.028, 0.020, -0.006, 0.50),
                toneParams: SIMD4(1.03, 0.042, 0.22, 0.05),
                colorParams: SIMD4(0.98, 0.12, 0.12, 0.04),
                hslShift: SIMD4(0.06, -0.08, -0.06, 0.22),
                analogParams: SIMD4(0.20, 1.25, 0.14, 0.16),
                opticalParams: SIMD4(0.06, 0.06, 0.0, 0)
            )

        case .gold200:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.07, 0.03, -0.04, 0),
                matrixRow1: SIMD4(0.02, 1.01, -0.03, 0),
                matrixRow2: SIMD4(-0.03, 0.00, 0.89, 0),
                shadowTint: SIMD4(0.022, 0.012, -0.008, 0.52),
                highlightTint: SIMD4(0.038, 0.024, -0.022, 0.60),
                toneParams: SIMD4(1.11, 0.020, 0.16, 0.02),
                colorParams: SIMD4(1.10, 0.14, 0.22, 0.02),
                hslShift: SIMD4(0.10, -0.10, -0.06, 0.16),
                analogParams: SIMD4(0.24, 1.30, 0.22, 0.10),
                opticalParams: SIMD4(0.08, 0.04, 0.0, 0)
            )

        case .colorPlus200:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.05, 0.02, -0.03, 0),
                matrixRow1: SIMD4(0.01, 1.02, -0.02, 0),
                matrixRow2: SIMD4(-0.02, 0.02, 0.92, 0),
                shadowTint: SIMD4(0.012, 0.014, -0.004, 0.45),
                highlightTint: SIMD4(0.028, 0.018, -0.014, 0.48),
                toneParams: SIMD4(1.13, 0.024, 0.16, 0.0),
                colorParams: SIMD4(1.06, 0.10, 0.14, -0.02),
                hslShift: SIMD4(0.08, -0.04, -0.04, 0.12),
                analogParams: SIMD4(0.26, 1.35, 0.20, 0.12),
                opticalParams: SIMD4(0.04, 0.0, 0.0, 0)
            )

        case .ektar100:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.08, -0.03, -0.03, 0),
                matrixRow1: SIMD4(-0.02, 1.05, -0.02, 0),
                matrixRow2: SIMD4(-0.03, -0.02, 1.07, 0),
                shadowTint: SIMD4(-0.008, 0.004, 0.014, 0.35),
                highlightTint: SIMD4(0.016, 0.008, -0.004, 0.32),
                toneParams: SIMD4(1.17, 0.006, 0.15, 0.0),
                colorParams: SIMD4(1.20, 0.20, 0.04, 0.02),
                hslShift: SIMD4(0.12, 0.04, 0.08, 0.04),
                analogParams: SIMD4(0.12, 1.05, 0.16, 0.0),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        case .triX400:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.36, 0.52, 0.12, 0),
                matrixRow1: SIMD4(0.36, 0.52, 0.12, 0),
                matrixRow2: SIMD4(0.36, 0.52, 0.12, 0),
                shadowTint: SIMD4(0.004, 0.002, -0.002, 0.30),
                highlightTint: SIMD4(0.010, 0.008, 0.004, 0.35),
                toneParams: SIMD4(1.28, 0.022, 0.14, 0.0),
                colorParams: SIMD4(0.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.42, 1.55, 0.28, 0.12),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 1)
            )

        case .cinestill800T:
            // CineStill 800T Tungsten: bóng xanh lam điện ảnh + Quầng đỏ Remjet Halation mạnh!
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.95, 0.02, 0.02, 0),
                matrixRow1: SIMD4(-0.02, 1.01, 0.03, 0),
                matrixRow2: SIMD4(-0.03, 0.05, 1.08, 0),
                shadowTint: SIMD4(-0.024, 0.012, 0.036, 0.78),
                highlightTint: SIMD4(0.034, 0.014, -0.012, 0.52),
                toneParams: SIMD4(1.15, 0.022, 0.20, 0.0),
                colorParams: SIMD4(1.06, 0.14, -0.22, -0.06),
                hslShift: SIMD4(0.10, 0.14, 0.12, 0.06),
                analogParams: SIMD4(0.28, 1.35, 0.26, 0.10),
                opticalParams: SIMD4(0.56, 0.10, 0.0, 0)
            )

        case .vision3500D:
            // 16mm / Vision3 Cinema: dải sáng rộng, xanh ngọc bóng, màu điện ảnh Hollywood
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.03, 0.01, -0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.01, 0.01, 0),
                matrixRow2: SIMD4(-0.03, 0.04, 0.99, 0),
                shadowTint: SIMD4(-0.014, 0.014, 0.022, 0.62),
                highlightTint: SIMD4(0.026, 0.016, -0.012, 0.52),
                toneParams: SIMD4(1.12, 0.028, 0.24, 0.0),
                colorParams: SIMD4(1.04, 0.12, 0.04, -0.02),
                hslShift: SIMD4(0.08, 0.10, -0.06, 0.12),
                analogParams: SIMD4(0.30, 1.40, 0.24, 0.12),
                opticalParams: SIMD4(0.24, 0.08, 0.0, 0)
            )

        // MARK: - 3. Vintage Cam, Medium Format & LOMO
        case .lomoLCA:
            // PAF R / LOMO LC-A: tương phản mạnh, rực rỡ, tối góc rõ nét đặc trưng
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.09, -0.02, -0.04, 0),
                matrixRow1: SIMD4(-0.02, 1.06, -0.02, 0),
                matrixRow2: SIMD4(-0.04, 0.04, 1.03, 0),
                shadowTint: SIMD4(-0.016, 0.020, 0.026, 0.65),
                highlightTint: SIMD4(0.036, 0.022, -0.018, 0.58),
                toneParams: SIMD4(1.22, 0.012, 0.14, 0.0),
                colorParams: SIMD4(1.18, 0.18, 0.10, -0.04),
                hslShift: SIMD4(0.12, 0.12, 0.06, 0.08),
                analogParams: SIMD4(0.28, 1.35, 0.56, 0.08),
                opticalParams: SIMD4(0.18, 0.06, 0.8, 0)
            )

        case .medium120LG:
            // S67 / Medium Format 120: chuyển sắc mềm mượt, da tự nhiên, dynamic range rộng
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.02, 0.02, -0.01, 0),
                matrixRow1: SIMD4(0.00, 1.01, 0.00, 0),
                matrixRow2: SIMD4(-0.01, 0.03, 0.96, 0),
                shadowTint: SIMD4(0.006, 0.012, 0.014, 0.48),
                highlightTint: SIMD4(0.020, 0.015, -0.004, 0.45),
                toneParams: SIMD4(1.05, 0.032, 0.24, 0.02),
                colorParams: SIMD4(0.98, 0.10, 0.06, 0.0),
                hslShift: SIMD4(0.04, 0.04, -0.06, 0.16),
                analogParams: SIMD4(0.16, 1.05, 0.18, 0.14),
                opticalParams: SIMD4(0.06, 0.08, 0.0, 0)
            )

        case .toyK:
            // D Half / Toy K: hoài cổ đậm chất giấy ảnh cũ, ấm vàng nhẹ + mờ ống kính nhựa
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.06, 0.04, -0.04, 0),
                matrixRow1: SIMD4(0.01, 1.01, -0.02, 0),
                matrixRow2: SIMD4(-0.04, 0.03, 0.88, 0),
                shadowTint: SIMD4(0.024, 0.016, -0.004, 0.60),
                highlightTint: SIMD4(0.038, 0.026, -0.018, 0.56),
                toneParams: SIMD4(1.08, 0.048, 0.18, 0.0),
                colorParams: SIMD4(0.94, 0.06, 0.18, -0.04),
                hslShift: SIMD4(0.08, -0.06, -0.08, 0.10),
                analogParams: SIMD4(0.36, 1.50, 0.48, 0.28),
                opticalParams: SIMD4(0.14, 0.16, 1.0, 0)
            )

        case .cam1998Street:
            // 135 SR: máy cơ 35mm đường phố giàu tương phản, màu trung thực nổi khối
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.04, -0.01, -0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.02, 0.00, 0),
                matrixRow2: SIMD4(-0.02, 0.02, 0.98, 0),
                shadowTint: SIMD4(-0.008, 0.006, 0.014, 0.48),
                highlightTint: SIMD4(0.022, 0.014, -0.010, 0.42),
                toneParams: SIMD4(1.18, 0.016, 0.16, 0.0),
                colorParams: SIMD4(1.04, 0.12, 0.06, 0.0),
                hslShift: SIMD4(0.08, 0.06, -0.04, 0.08),
                analogParams: SIMD4(0.28, 1.30, 0.30, 0.10),
                opticalParams: SIMD4(0.08, 0.0, 0.0, 0)
            )

        // MARK: - 4. Ricoh GR Street Series
        case .grPositive:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.06, -0.02, -0.02, 0),
                matrixRow1: SIMD4(-0.02, 1.04, -0.01, 0),
                matrixRow2: SIMD4(-0.03, 0.01, 1.04, 0),
                shadowTint: SIMD4(-0.012, 0.002, 0.018, 0.55),
                highlightTint: SIMD4(0.018, 0.010, -0.004, 0.42),
                toneParams: SIMD4(1.22, 0.008, 0.16, 0.0),
                colorParams: SIMD4(1.12, 0.16, 0.02, -0.02),
                hslShift: SIMD4(0.08, 0.06, 0.06, 0.04),
                analogParams: SIMD4(0.18, 1.15, 0.32, 0.04),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        case .grNegative:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.98, 0.03, 0.00, 0),
                matrixRow1: SIMD4(0.00, 1.00, 0.01, 0),
                matrixRow2: SIMD4(-0.02, 0.05, 0.96, 0),
                shadowTint: SIMD4(-0.006, 0.014, 0.018, 0.52),
                highlightTint: SIMD4(0.020, 0.016, -0.006, 0.45),
                toneParams: SIMD4(1.06, 0.042, 0.22, 0.0),
                colorParams: SIMD4(0.84, 0.04, -0.02, -0.04),
                hslShift: SIMD4(-0.04, 0.10, -0.10, 0.06),
                analogParams: SIMD4(0.22, 1.25, 0.22, 0.22),
                opticalParams: SIMD4(0.0, 0.04, 0.0, 0)
            )

        case .grHighBW:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.30, 0.60, 0.10, 0),
                matrixRow1: SIMD4(0.30, 0.60, 0.10, 0),
                matrixRow2: SIMD4(0.30, 0.60, 0.10, 0),
                shadowTint: SIMD4(-0.006, -0.004, 0.004, 0.40),
                highlightTint: SIMD4(0.008, 0.008, 0.008, 0.35),
                toneParams: SIMD4(1.42, 0.0, 0.12, -0.04),
                colorParams: SIMD4(0.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.38, 1.45, 0.36, 0.04),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 1)
            )

        case .grFFilm, .grStreetSnap, .caplioR, .thetaDoc:
            let warmShift: Float = (self == .grFFilm) ? 0.10 : ((self == .caplioR) ? -0.06 : 0.02)
            let contrast: Float = (self == .grStreetSnap) ? 1.18 : 1.10
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.02 + warmShift * 0.2, 0.01, -0.02, 0),
                matrixRow1: SIMD4(0.00, 1.01, 0.00, 0),
                matrixRow2: SIMD4(-0.02, 0.02, 0.99 - warmShift * 0.2, 0),
                shadowTint: SIMD4(-0.006, 0.008, 0.014, 0.42),
                highlightTint: SIMD4(0.018, 0.012, -0.008, 0.38),
                toneParams: SIMD4(contrast, 0.018, 0.16, 0.0),
                colorParams: SIMD4(0.98, 0.08, warmShift, -0.02),
                hslShift: SIMD4(0.04, 0.06, -0.04, 0.06),
                analogParams: SIMD4(0.20, 1.20, 0.24, 0.10),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        // MARK: - 5. CCD & Canon Y2K Digicams
        case .ccd1Cyber, .blueSKCool, .ixusY2K:
            // CCD R / BlueSK / IXUS: xanh dương mát trong trẻo Y2K + 3D LUT CCD-ClassicY2K + highlight flash bloom
            let cool: Float = (self == .blueSKCool) ? -0.22 : -0.14
            return VintageCameraOpticalRecipe(
                lutName: (self == .ccd1Cyber) ? "CCD-ClassicY2K" : nil,
                matrixRow0: SIMD4(0.96, 0.00, 0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.01, 0.02, 0),
                matrixRow2: SIMD4(-0.02, 0.03, 1.07, 0),
                shadowTint: SIMD4(-0.016, 0.004, 0.028, 0.58),
                highlightTint: SIMD4(0.006, 0.014, 0.022, 0.45),
                toneParams: SIMD4(1.12, 0.014, 0.12, 0.04),
                colorParams: SIMD4(1.08, 0.14, cool, 0.02),
                hslShift: SIMD4(-0.02, 0.06, 0.14, 0.08),
                analogParams: SIMD4(0.24, 1.00, 0.16, 0.04),
                opticalParams: SIMD4(0.0, 0.16, 0.6, 0)
            )

        case .dCcdWarm, .gCcdGold, .powershotG, .powershotPro1, .eos5DClassic, .sureShot35, .canonF1, .mangaCam, .instaLiteFlash:
            // Warm CCD / Canon PowerShot / 5D Classic: da hồng ấm đặc trưng Canon + 3D LUT CCD-GoldenCCD / Canon-G7XMarkII + bloom flash
            let isFlash = (self == .instaLiteFlash || self == .dCcdWarm)
            let isWarmGold = (self == .gCcdGold || self == .powershotG || self == .eos5DClassic)
            let resolvedLUT: String? = (self == .gCcdGold)
                ? "CCD-GoldenCCD"
                : ((self == .powershotG || self == .powershotPro1) ? "Canon-G7XMarkII" : nil)
            return VintageCameraOpticalRecipe(
                lutName: resolvedLUT,
                matrixRow0: SIMD4(isWarmGold ? 1.05 : 1.02, 0.02, -0.02, 0),
                matrixRow1: SIMD4(0.00, 1.01, -0.01, 0),
                matrixRow2: SIMD4(-0.02, 0.01, isWarmGold ? 0.94 : 0.98, 0),
                shadowTint: SIMD4(0.012, 0.008, 0.002, 0.42),
                highlightTint: SIMD4(0.024, 0.016, -0.006, 0.45),
                toneParams: SIMD4(isFlash ? 1.15 : 1.09, 0.018, 0.16, isFlash ? 0.08 : 0.02),
                colorParams: SIMD4(1.08, 0.14, isWarmGold ? 0.14 : 0.06, 0.04),
                hslShift: SIMD4(0.06, -0.04, -0.02, 0.16),
                analogParams: SIMD4(0.20, 1.05, 0.18, 0.06),
                opticalParams: SIMD4(0.04, isFlash ? 0.20 : 0.08, 0.4, 0)
            )

        // MARK: - 6. Instant Polaroid & Instax
        case .instaxMini, .instaxWide, .instaxSquare:
            // Inst C / SQ / Wide: tông xanh bạc hà - pastel trong nhẹ, nâng bóng cổ điển
            let isSquare = (self == .instaxSquare)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.97, 0.03, 0.01, 0),
                matrixRow1: SIMD4(-0.01, 1.03, 0.02, 0),
                matrixRow2: SIMD4(0.00, 0.05, 0.98, 0),
                shadowTint: SIMD4(-0.010, 0.024, 0.026, 0.62),
                highlightTint: SIMD4(0.018, 0.024, 0.014, 0.50),
                toneParams: SIMD4(isSquare ? 1.14 : 1.04, 0.052, 0.20, 0.06),
                colorParams: SIMD4(0.94, 0.08, -0.04, -0.06),
                hslShift: SIMD4(-0.04, 0.14, -0.06, 0.10),
                analogParams: SIMD4(0.18, 1.15, 0.24, 0.24),
                opticalParams: SIMD4(0.0, 0.14, 0.0, 0)
            )

        case .polaroid600, .sx70TimeZero, .polaroidSpectra:
            // Pola 600 / SX-70: nâng bóng ấm kem, sắc hồng tím nhẹ ở shadow, chất giấy ảnh lấy liền
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.04, 0.03, -0.02, 0),
                matrixRow1: SIMD4(0.01, 1.00, 0.01, 0),
                matrixRow2: SIMD4(0.01, 0.03, 0.92, 0),
                shadowTint: SIMD4(0.026, 0.012, 0.022, 0.65),
                highlightTint: SIMD4(0.032, 0.024, -0.008, 0.55),
                toneParams: SIMD4(1.05, 0.062, 0.22, 0.04),
                colorParams: SIMD4(0.92, 0.06, 0.12, 0.06),
                hslShift: SIMD4(0.06, -0.08, -0.08, 0.14),
                analogParams: SIMD4(0.24, 1.30, 0.34, 0.32),
                opticalParams: SIMD4(0.08, 0.18, 0.7, 0)
            )

        // MARK: - 7. Retro Video, 8mm, VHS, MiniDV & Kino
        case .kambo:
            // Super 8mm: vàng hổ phách rực nắng, hạt lớn điện ảnh gia đình thập niên 70
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.09, 0.04, -0.05, 0),
                matrixRow1: SIMD4(0.02, 1.01, -0.03, 0),
                matrixRow2: SIMD4(-0.04, 0.01, 0.86, 0),
                shadowTint: SIMD4(0.028, 0.016, -0.010, 0.66),
                highlightTint: SIMD4(0.044, 0.028, -0.026, 0.64),
                toneParams: SIMD4(1.16, 0.036, 0.18, 0.0),
                colorParams: SIMD4(1.10, 0.14, 0.24, -0.02),
                hslShift: SIMD4(0.12, -0.10, -0.10, 0.12),
                analogParams: SIMD4(0.42, 1.65, 0.42, 0.22),
                opticalParams: SIMD4(0.28, 0.14, 1.2, 0)
            )

        case .vhscHome, .hi8Analog, .hkCinema90s:
            // VHS / Hi8 / HK 90s: lệch pha sắc độ ngang (chroma bleed), bóng xanh lục/tím băng từ
            let isHK = (self == .hkCinema90s)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(isHK ? 0.98 : 1.03, 0.02, -0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.04, 0.01, 0),
                matrixRow2: SIMD4(-0.02, 0.04, isHK ? 1.02 : 0.94, 0),
                shadowTint: SIMD4(-0.018, 0.024, 0.022, 0.68),
                highlightTint: SIMD4(0.030, 0.020, -0.012, 0.50),
                toneParams: SIMD4(1.12, 0.044, 0.16, 0.0),
                colorParams: SIMD4(0.96, 0.08, isHK ? -0.08 : 0.06, -0.08),
                hslShift: SIMD4(0.08, 0.14, 0.06, 0.06),
                analogParams: SIMD4(0.36, 1.50, 0.32, 0.24),
                opticalParams: SIMD4(isHK ? 0.36 : 0.14, 0.16, 2.4, 0)
            )

        case .miniDV43, .dcrDVD, .dvx10024p, .hdv1080i:
            // DCR / MiniDV / Kino: máy quay kỹ thuật số đầu 2000s sắc nét mát dịu + chroma bleed nhẹ
            let isKino = (self == .dvx10024p)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.97, 0.01, 0.01, 0),
                matrixRow1: SIMD4(-0.01, 1.01, 0.02, 0),
                matrixRow2: SIMD4(-0.02, 0.03, 1.05, 0),
                shadowTint: SIMD4(-0.014, 0.010, 0.022, 0.52),
                highlightTint: SIMD4(0.014, 0.014, 0.008, 0.38),
                toneParams: SIMD4(isKino ? 1.14 : 1.09, 0.020, 0.18, 0.0),
                colorParams: SIMD4(isKino ? 0.94 : 1.02, 0.10, -0.08, -0.04),
                hslShift: SIMD4(0.02, 0.08, 0.08, 0.06),
                analogParams: SIMD4(0.22, 1.15, 0.18, 0.10),
                opticalParams: SIMD4(isKino ? 0.18 : 0.06, 0.08, 1.3, 0)
            )

        // MARK: - 8. Vintage Mobile Phones & Special Optical Modes
        case .nokia3310:
            // Nokia 3310 LCD xanh rêu ma trận lượng tử hóa (specialMode = 3)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.30, 0.59, 0.11, 0),
                matrixRow1: SIMD4(0.30, 0.59, 0.11, 0),
                matrixRow2: SIMD4(0.30, 0.59, 0.11, 0),
                shadowTint: SIMD4(0, 0, 0, 0),
                highlightTint: SIMD4(0, 0, 0, 0),
                toneParams: SIMD4(1.38, 0.0, 0.0, -0.04),
                colorParams: SIMD4(0.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.08, 1.0, 0.18, 0.0),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 3)
            )

        case .luxury8800, .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            let warmP: Float = (self == .iphone3GS || self == .luxury8800) ? 0.14 : -0.08
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.01 + warmP * 0.25, 0.02, -0.02, 0),
                matrixRow1: SIMD4(0.00, 1.01, 0.01, 0),
                matrixRow2: SIMD4(-0.02, 0.03, 0.98 - warmP * 0.25, 0),
                shadowTint: SIMD4(warmP * 0.08, 0.012, -warmP * 0.08 + 0.014, 0.55),
                highlightTint: SIMD4(0.022, 0.016, -0.008, 0.42),
                toneParams: SIMD4(1.12, 0.034, 0.14, 0.02),
                colorParams: SIMD4(0.94, 0.06, warmP, -0.04),
                hslShift: SIMD4(0.04, 0.08, 0.02, 0.08),
                analogParams: SIMD4(0.30, 1.25, 0.26, 0.18),
                opticalParams: SIMD4(0.06, 0.14, 1.2, 0)
            )

        case .cyanotype:
            // In lam cổ điển thế kỷ 19 (specialMode = 2)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.28, 0.58, 0.14, 0),
                matrixRow1: SIMD4(0.28, 0.58, 0.14, 0),
                matrixRow2: SIMD4(0.28, 0.58, 0.14, 0),
                shadowTint: SIMD4(0.02, 0.10, 0.28, 1.0),
                highlightTint: SIMD4(0.90, 0.94, 0.98, 1.0),
                toneParams: SIMD4(1.24, 0.02, 0.14, 0.0),
                colorParams: SIMD4(1.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.24, 1.30, 0.30, 0.08),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 2)
            )

        case .bleachBypass:
            // Phim nhựa bỏ tẩy bạc: giảm bão hòa mạnh, tương phản gắt, sắc thép điện ảnh (specialMode = 4)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.02, -0.01, -0.01, 0),
                matrixRow1: SIMD4(-0.01, 1.01, 0.00, 0),
                matrixRow2: SIMD4(-0.02, 0.02, 1.02, 0),
                shadowTint: SIMD4(-0.012, 0.002, 0.014, 0.55),
                highlightTint: SIMD4(0.014, 0.012, 0.004, 0.42),
                toneParams: SIMD4(1.34, 0.010, 0.16, 0.0),
                colorParams: SIMD4(0.46, 0.0, -0.06, -0.02),
                hslShift: SIMD4(0.04, -0.04, 0.02, -0.04),
                analogParams: SIMD4(0.28, 1.30, 0.28, 0.06),
                opticalParams: SIMD4(0.08, 0.0, 0.0, 4)
            )

        case .leicaMonochrom, .monochromeNoir:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.32, 0.56, 0.12, 0),
                matrixRow1: SIMD4(0.32, 0.56, 0.12, 0),
                matrixRow2: SIMD4(0.32, 0.56, 0.12, 0),
                shadowTint: SIMD4(-0.004, -0.002, 0.004, 0.40),
                highlightTint: SIMD4(0.008, 0.006, 0.002, 0.35),
                toneParams: SIMD4(self == .monochromeNoir ? 1.38 : 1.24, 0.010, 0.16, 0.0),
                colorParams: SIMD4(0.0, 0.0, 0.0, 0.0),
                hslShift: SIMD4(0, 0, 0, 0),
                analogParams: SIMD4(0.26, 1.25, 0.28, 0.06),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 1)
            )

        case .studioNatural:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(1.01, 0.00, 0.00, 0),
                matrixRow1: SIMD4(0.00, 1.00, 0.00, 0),
                matrixRow2: SIMD4(0.00, 0.00, 0.99, 0),
                shadowTint: SIMD4(0, 0, 0, 0),
                highlightTint: SIMD4(0.006, 0.004, 0.000, 0.20),
                toneParams: SIMD4(1.04, 0.006, 0.16, 0.0),
                colorParams: SIMD4(1.02, 0.06, 0.02, 0.0),
                hslShift: SIMD4(0.02, 0.0, 0.0, 0.08),
                analogParams: SIMD4(0.0, 1.0, 0.06, 0.0),
                opticalParams: SIMD4(0.0, 0.0, 0.0, 0)
            )

        case .tokyoAiry:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.97, 0.01, 0.01, 0),
                matrixRow1: SIMD4(0.00, 1.01, 0.01, 0),
                matrixRow2: SIMD4(0.00, 0.03, 1.04, 0),
                shadowTint: SIMD4(-0.008, 0.014, 0.022, 0.50),
                highlightTint: SIMD4(0.010, 0.016, 0.020, 0.45),
                toneParams: SIMD4(1.02, 0.044, 0.20, 0.08),
                colorParams: SIMD4(0.92, 0.08, -0.10, -0.02),
                hslShift: SIMD4(-0.02, 0.12, 0.06, 0.12),
                analogParams: SIMD4(0.12, 1.10, 0.08, 0.14),
                opticalParams: SIMD4(0.0, 0.14, 0.0, 0)
            )

        case .nordicCold:
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(0.94, 0.01, 0.02, 0),
                matrixRow1: SIMD4(-0.01, 1.00, 0.02, 0),
                matrixRow2: SIMD4(-0.02, 0.03, 1.06, 0),
                shadowTint: SIMD4(-0.018, 0.006, 0.028, 0.65),
                highlightTint: SIMD4(0.006, 0.012, 0.018, 0.40),
                toneParams: SIMD4(1.10, 0.024, 0.18, 0.0),
                colorParams: SIMD4(0.86, 0.04, -0.18, -0.02),
                hslShift: SIMD4(-0.04, 0.08, 0.08, 0.0),
                analogParams: SIMD4(0.18, 1.20, 0.22, 0.12),
                opticalParams: SIMD4(0.0, 0.06, 0.0, 0)
            )

        case .cinemaTealOrange, .sunsetGlow, .vintageWarm, .streetClassic, .neonCyberpunk:
            let isWarm = (self == .sunsetGlow || self == .vintageWarm)
            let isNeon = (self == .neonCyberpunk)
            return VintageCameraOpticalRecipe(
                lutName: nil,
                matrixRow0: SIMD4(isWarm ? 1.08 : 1.02, 0.02, -0.03, 0),
                matrixRow1: SIMD4(-0.01, 1.00, 0.01, 0),
                matrixRow2: SIMD4(-0.03, 0.04, isWarm ? 0.90 : 1.06, 0),
                shadowTint: SIMD4(isWarm ? 0.020 : -0.020, 0.010, isWarm ? -0.008 : 0.032, 0.65),
                highlightTint: SIMD4(0.034, 0.018, isNeon ? 0.026 : -0.016, 0.55),
                toneParams: SIMD4(1.16, 0.020, 0.18, 0.0),
                colorParams: SIMD4(isNeon ? 1.22 : 1.08, 0.16, isWarm ? 0.20 : -0.06, isNeon ? 0.14 : -0.02),
                hslShift: SIMD4(0.10, 0.06, 0.08, 0.10),
                analogParams: SIMD4(0.22, 1.25, 0.24, 0.10),
                opticalParams: SIMD4(isNeon ? 0.42 : 0.16, 0.08, isNeon ? 1.2 : 0.0, 0)
            )
        }
    }
}
