import Foundation
import SwiftUI
import simd

/// Phân nhóm bản chất quang học của 8 Photographic Styles (giống triết lý Undertones vs Moods trên iOS Camera).
public enum PhotographicStyleGroup: String, Sendable {
    case standard
    case undertone
    case mood

    public var badgeTitle: String {
        switch self {
        case .standard: return "CHUẨN"
        case .undertone: return "SẮC DA"
        case .mood: return "TÂM TRẠNG"
        }
    }
}

/// Tham số quang học cố định cho từng preset (truyền trực tiếp vào Single-Pass Metal Shader).
public struct PhotographicStylePresetRecipe: Sendable {
    public let presetKind: Float          // 0 = standard, 1 = undertone (skin-weighted), 2 = mood (split-tone)
    public let baseContrast: Float        // Tương phản đường cong nền (-0.25 ... +0.35)
    public let baseShadowLift: Float      // Nâng/hạ vùng tối nền (-0.20 ... +0.20)
    public let baseHighlightRoll: Float   // Độ nén highlight nền (0.0 ... 0.35)
    public let baseVibrance: Float        // Độ tươi thích ứng nền (-0.30 ... +0.40)
    public let baseSaturation: Float      // Hệ số bão hòa nền (0.0 ... 1.35)
    public let isMonochrome: Float        // 0.0 = màu, 1.0 = đen trắng phim bạc
    public let undertoneStrength: Float   // Cường độ lớp bảo vệ sắc da (0.0 ... 1.0)
    public let splitStrength: Float       // Cường độ Split Toning shadow/highlight (0.0 ... 1.0)
    public let matrixRow0: SIMD4<Float>   // Hàng R ma trận màu 3x3 (linear space)
    public let matrixRow1: SIMD4<Float>   // Hàng G ma trận màu 3x3 (linear space)
    public let matrixRow2: SIMD4<Float>   // Hàng B ma trận màu 3x3 (linear space)
    public let skinShiftLab: SIMD4<Float> // Dịch chuyển (dL, da, db, 0) trong OkLab có mặt nạ da
    public let shadowTint: SIMD4<Float>   // Ám sắc vùng tối (r, g, b, 0) trong linear space
    public let highlightTint: SIMD4<Float>// Ám sắc vùng sáng (r, g, b, 0) trong linear space
}

/// 8 phong cách nhiếp ảnh quang học chuẩn cho Photographic Styles Control Pad.
public enum PhotographicStylePreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case standard = "standard"
    case warmAmber = "warm_amber"
    case softRose = "soft_rose"
    case neutral = "neutral"
    case richContrast = "rich_contrast"
    case vibrant = "vibrant"
    case coolMood = "cool_mood"
    case starkBW = "stark_bw"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Tiêu chuẩn"
        case .warmAmber: return "Ấm áp"
        case .softRose: return "Hồng phấn"
        case .neutral: return "Trung tính"
        case .richContrast: return "Tương phản"
        case .vibrant: return "Sống động"
        case .coolMood: return "Lạnh sâu"
        case .starkBW: return "Đơn sắc"
        }
    }

    public var group: PhotographicStyleGroup {
        switch self {
        case .standard:
            return .standard
        case .warmAmber, .softRose, .neutral:
            return .undertone
        case .richContrast, .vibrant, .coolMood, .starkBW:
            return .mood
        }
    }

    public var isMonochrome: Bool { self == .starkBW }

    public var defaultTone: Float { 0.0 }
    public var defaultColor: Float { 0.0 }
    public var defaultPalette: Float { 1.0 }

    /// Sắc độ nhẹ (không chói neon) cho góc phải nền Control Pad & track thanh Bảng màu.
    public var padTintColor: Color {
        switch self {
        case .standard:     return Color(red: 0.46, green: 0.72, blue: 0.90) // Xanh trời dịu như Camera iOS
        case .warmAmber:    return Color(red: 0.88, green: 0.67, blue: 0.40) // Hổ phách ấm mịn
        case .softRose:     return Color(red: 0.88, green: 0.60, blue: 0.64) // Hồng phấn dịu
        case .neutral:      return Color(red: 0.74, green: 0.73, blue: 0.70) // Xám ấm trung tính
        case .richContrast: return Color(red: 0.62, green: 0.68, blue: 0.76) // Than ánh thép
        case .vibrant:      return Color(red: 0.42, green: 0.76, blue: 0.86) // Xanh trong rực nhẹ
        case .coolMood:     return Color(red: 0.44, green: 0.62, blue: 0.84) // Xanh trầm điện ảnh
        case .starkBW:      return Color(red: 0.72, green: 0.72, blue: 0.74) // Bạc đơn sắc
        }
    }

    /// Bộ tham số quang học đã hiệu chuẩn trong không gian Linear RGB & OkLab.
    public var recipe: PhotographicStylePresetRecipe {
        switch self {
        case .standard:
            return PhotographicStylePresetRecipe(
                presetKind: 0,
                baseContrast: 0.0,
                baseShadowLift: 0.0,
                baseHighlightRoll: 0.0,
                baseVibrance: 0.0,
                baseSaturation: 1.0,
                isMonochrome: 0.0,
                undertoneStrength: 0.0,
                splitStrength: 0.0,
                matrixRow0: SIMD4(1, 0, 0, 0),
                matrixRow1: SIMD4(0, 1, 0, 0),
                matrixRow2: SIMD4(0, 0, 1, 0),
                skinShiftLab: SIMD4(0, 0, 0, 0),
                shadowTint: SIMD4(0, 0, 0, 0),
                highlightTint: SIMD4(0, 0, 0, 0)
            )

        case .warmAmber:
            return PhotographicStylePresetRecipe(
                presetKind: 1,
                baseContrast: 0.04,
                baseShadowLift: 0.02,
                baseHighlightRoll: 0.08,
                baseVibrance: 0.08,
                baseSaturation: 1.02,
                isMonochrome: 0.0,
                undertoneStrength: 1.0,
                splitStrength: 0.30,
                matrixRow0: SIMD4(1.030,  0.008, -0.014, 0),
                matrixRow1: SIMD4(0.005,  1.002, -0.006, 0),
                matrixRow2: SIMD4(-0.010, -0.006,  0.962, 0),
                skinShiftLab: SIMD4(0.012, 0.007, 0.022, 0),
                shadowTint: SIMD4(0.012, 0.006, -0.008, 0),
                highlightTint: SIMD4(0.018, 0.010, -0.014, 0)
            )

        case .softRose:
            return PhotographicStylePresetRecipe(
                presetKind: 1,
                baseContrast: -0.04,
                baseShadowLift: 0.045,
                baseHighlightRoll: 0.14,
                baseVibrance: 0.06,
                baseSaturation: 0.99,
                isMonochrome: 0.0,
                undertoneStrength: 1.0,
                splitStrength: 0.28,
                matrixRow0: SIMD4(1.026, -0.004,  0.008, 0),
                matrixRow1: SIMD4(-0.004, 0.994,  0.002, 0),
                matrixRow2: SIMD4(0.006,  0.002,  0.992, 0),
                skinShiftLab: SIMD4(0.018, 0.018, 0.006, 0),
                shadowTint: SIMD4(0.008, -0.003, 0.006, 0),
                highlightTint: SIMD4(0.014, 0.004, 0.008, 0)
            )

        case .neutral:
            return PhotographicStylePresetRecipe(
                presetKind: 1,
                baseContrast: -0.07,
                baseShadowLift: 0.03,
                baseHighlightRoll: 0.18,
                baseVibrance: -0.05,
                baseSaturation: 0.95,
                isMonochrome: 0.0,
                undertoneStrength: 0.65,
                splitStrength: 0.15,
                matrixRow0: SIMD4(0.996,  0.004,  0.000, 0),
                matrixRow1: SIMD4(0.002,  0.998,  0.000, 0),
                matrixRow2: SIMD4(0.002,  0.002,  0.996, 0),
                skinShiftLab: SIMD4(0.006, -0.005, -0.004, 0),
                shadowTint: SIMD4(0.003, 0.003, 0.004, 0),
                highlightTint: SIMD4(0.002, 0.002, 0.000, 0)
            )

        case .richContrast:
            return PhotographicStylePresetRecipe(
                presetKind: 2,
                baseContrast: 0.26,
                baseShadowLift: -0.10,
                baseHighlightRoll: 0.12,
                baseVibrance: 0.08,
                baseSaturation: 1.04,
                isMonochrome: 0.0,
                undertoneStrength: 0.35,
                splitStrength: 0.55,
                matrixRow0: SIMD4(1.032, -0.014, -0.006, 0),
                matrixRow1: SIMD4(-0.008, 1.016, -0.006, 0),
                matrixRow2: SIMD4(-0.008, -0.012, 1.022, 0),
                skinShiftLab: SIMD4(0.000, 0.004, 0.006, 0),
                shadowTint: SIMD4(-0.008, -0.002, 0.014, 0),
                highlightTint: SIMD4(0.014, 0.008, -0.006, 0)
            )

        case .vibrant:
            return PhotographicStylePresetRecipe(
                presetKind: 2,
                baseContrast: 0.08,
                baseShadowLift: 0.025,
                baseHighlightRoll: 0.10,
                baseVibrance: 0.34,
                baseSaturation: 1.12,
                isMonochrome: 0.0,
                undertoneStrength: 0.45,
                splitStrength: 0.35,
                matrixRow0: SIMD4(1.042, -0.020, -0.012, 0),
                matrixRow1: SIMD4(-0.014, 1.034, -0.014, 0),
                matrixRow2: SIMD4(-0.012, -0.018, 1.044, 0),
                skinShiftLab: SIMD4(0.008, 0.002, 0.004, 0),
                shadowTint: SIMD4(-0.004, 0.004, 0.010, 0),
                highlightTint: SIMD4(0.010, 0.008, 0.002, 0)
            )

        case .coolMood:
            return PhotographicStylePresetRecipe(
                presetKind: 2,
                baseContrast: 0.14,
                baseShadowLift: -0.055,
                baseHighlightRoll: 0.14,
                baseVibrance: -0.06,
                baseSaturation: 0.92,
                isMonochrome: 0.0,
                undertoneStrength: 0.40,
                splitStrength: 0.72,
                matrixRow0: SIMD4(0.958,  0.004,  0.014, 0),
                matrixRow1: SIMD4(-0.004, 1.002,  0.012, 0),
                matrixRow2: SIMD4(-0.010, 0.014,  1.042, 0),
                skinShiftLab: SIMD4(0.002, -0.004, -0.008, 0),
                shadowTint: SIMD4(-0.014, 0.004, 0.024, 0),
                highlightTint: SIMD4(0.008, 0.006, 0.004, 0)
            )

        case .starkBW:
            return PhotographicStylePresetRecipe(
                presetKind: 2,
                baseContrast: 0.28,
                baseShadowLift: -0.09,
                baseHighlightRoll: 0.14,
                baseVibrance: 0.0,
                baseSaturation: 0.0,
                isMonochrome: 1.0,
                undertoneStrength: 0.0,
                splitStrength: 0.60,
                matrixRow0: SIMD4(1, 0, 0, 0),
                matrixRow1: SIMD4(0, 1, 0, 0),
                matrixRow2: SIMD4(0, 0, 1, 0),
                skinShiftLab: SIMD4(0, 0, 0, 0),
                shadowTint: SIMD4(-0.004, 0.000, 0.008, 0),
                highlightTint: SIMD4(0.006, 0.004, 0.000, 0)
            )
        }
    }
}

/// Trạng thái Photographic Style 2D thời gian thực (Tone, Color, Palette + Preset).
public struct PhotographicStyleState: Equatable, Sendable, Codable {
    public var preset: PhotographicStylePreset
    /// Trục Y của Control Pad: -1.0 (tối sâu) ... 0.0 ... +1.0 (sáng thoáng)
    public var tone: Float
    /// Trục X của Control Pad: -1.0 (nhạt/trầm) ... 0.0 ... +1.0 (rực rỡ)
    public var color: Float
    /// Thanh cường độ hòa trộn tuyến tính: 0.0 (tắt) ... 1.0 (100%)
    public var palette: Float

    public static let standard = PhotographicStyleState(preset: .standard, tone: 0.0, color: 0.0, palette: 1.0)

    public init(
        preset: PhotographicStylePreset = .standard,
        tone: Float = 0.0,
        color: Float = 0.0,
        palette: Float = 1.0
    ) {
        self.preset = preset
        self.tone = tone.isFinite ? max(-1.0, min(1.0, tone)) : 0.0
        self.color = color.isFinite ? max(-1.0, min(1.0, color)) : 0.0
        self.palette = palette.isFinite ? max(0.0, min(1.0, palette)) : 1.0
    }

    public static func defaultState(for preset: PhotographicStylePreset) -> PhotographicStyleState {
        PhotographicStyleState(
            preset: preset,
            tone: preset.defaultTone,
            color: preset.defaultColor,
            palette: preset.defaultPalette
        )
    }

    /// Trả về `true` khi ảnh không thay đổi (bỏ qua hoàn toàn pass Metal/CoreImage, 0% chi phí GPU).
    public var isIdentity: Bool {
        if palette < 0.005 { return true }
        return preset == .standard && abs(tone) < 0.005 && abs(color) < 0.005
    }

    /// Trả về `true` khi người dùng đã chỉnh lệch khỏi giá trị mặc định của preset đang chọn.
    public var isModifiedFromPresetDefault: Bool {
        abs(tone - preset.defaultTone) >= 0.005
            || abs(color - preset.defaultColor) >= 0.005
            || abs(palette - preset.defaultPalette) >= 0.005
    }

    public var tonePercent: Int { Int(round(tone * 100.0)) }
    public var colorPercent: Int { Int(round(color * 100.0)) }
    public var palettePercent: Int { Int(round(palette * 100.0)) }

    public var toneDisplayText: String {
        let v = tonePercent
        return v > 0 ? "+\(v)" : "\(v)"
    }

    public var colorDisplayText: String {
        let v = colorPercent
        return v > 0 ? "+\(v)" : "\(v)"
    }

    public var paletteDisplayText: String {
        "\(palettePercent)%"
    }
}
