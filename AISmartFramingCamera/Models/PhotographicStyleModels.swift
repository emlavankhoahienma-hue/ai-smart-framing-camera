import Foundation
import SwiftUI
import simd

/// Trục đang được kéo trên Photographic Styles Control Pad để làm nổi đúng thông số trên Top HUD.
public enum PhotographicStyleActiveAxis: Equatable, Sendable {
    case none
    case pad2D
    case palette
    case texture
}

/// Chế độ Kết cấu vi mô (Photographic Styles 3 — chạy trực tiếp 60 FPS Single-Pass Metal trên Live Preview & Ảnh xuất).
public enum PhotographicTextureMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case standard = "standard"
    case softSkin = "soft_skin"
    case glow = "glow"
    case film = "film"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Chuẩn"
        case .softSkin: return "Mịn da"
        case .glow: return "Rạng rỡ"
        case .film: return "Film"
        }
    }

    public var shaderCode: Float {
        switch self {
        case .standard: return 0.0
        case .softSkin: return 1.0
        case .glow: return 2.0
        case .film: return 3.0
        }
    }

    public var defaultIntensity: Float {
        switch self {
        case .standard: return 0.0
        case .softSkin: return 0.45
        case .glow: return 0.45
        case .film: return 0.55
        }
    }

    public var sliderTitle: String {
        switch self {
        case .standard: return "TEXTURE"
        case .softSkin: return "SOFT SKIN"
        case .glow: return "GLOW"
        case .film: return "FILMIC"
        }
    }
}

/// Trạng thái vuốt chia đôi màn hình thời gian thực (Live GPU Split-Screen Wipe) giống Camera iOS 18/26/27.
public struct PhotographicStyleSplitTransition: Equatable, Sendable {
    public var isActive: Bool
    public var leftStyle: PhotographicStyleState
    public var rightStyle: PhotographicStyleState
    /// Tọa độ chuẩn hóa [0.0 ... 1.0] của ranh chia dọc (0 = sát mép trái, 1 = sát mép phải).
    public var splitPosition: Float
    /// Phong cách đang chiếm phần hiển thị ưu thế để đồng bộ Top HUD, tên style & Bottom Pad.
    public var dominantStyle: PhotographicStyleState
    /// Phong cách đích đang vuốt tới & tỷ lệ hòa trộn [0.0 ... 1.0] để chuyển màu nền Pad mượt theo tay.
    public var incomingPreset: PhotographicStylePreset
    public var morphProgress: Float

    public static let inactive = PhotographicStyleSplitTransition(
        isActive: false,
        leftStyle: .standard,
        rightStyle: .standard,
        splitPosition: 1.0,
        dominantStyle: .standard,
        incomingPreset: .standard,
        morphProgress: 0.0
    )

    public init(
        isActive: Bool,
        leftStyle: PhotographicStyleState,
        rightStyle: PhotographicStyleState,
        splitPosition: Float,
        dominantStyle: PhotographicStyleState,
        incomingPreset: PhotographicStylePreset,
        morphProgress: Float
    ) {
        self.isActive = isActive
        self.leftStyle = leftStyle
        self.rightStyle = rightStyle
        self.splitPosition = max(0.0, min(1.0, splitPosition))
        self.dominantStyle = dominantStyle
        self.incomingPreset = incomingPreset
        self.morphProgress = max(0.0, min(1.0, morphProgress))
    }
}

/// Phân nhóm bản chất quang học của 16 Photographic Styles (6 Undertones bên trái Standard · 9 Moods bên phải Standard).
public enum PhotographicStyleGroup: String, Sendable {
    case standard
    case undertone
    case mood

    public var badgeTitle: String {
        switch self {
        case .standard: return "STANDARD"
        case .undertone: return "UNDERTONE"
        case .mood: return "MOOD"
        }
    }
}

/// Tham số quang học cố định cho từng preset (truyền trực tiếp vào Single-Pass Metal Shader).
public struct PhotographicStylePresetRecipe: Sendable {
    public let presetKind: Float          // 0 = standard, 1 = undertone (skin-weighted), 2 = mood (split-tone), 3 = dramatic (dynamic palette shift)
    public let baseContrast: Float        // Tương phản đường cong nền (-0.30 ... +0.42)
    public let baseShadowLift: Float      // Nâng/hạ vùng tối nền (-0.25 ... +0.28)
    public let baseHighlightRoll: Float   // Độ nén highlight nền (0.0 ... 0.45)
    public let baseVibrance: Float        // Độ tươi thích ứng nền (-0.35 ... +0.50)
    public let baseSaturation: Float      // Hệ số bão hòa nền (0.0 ... 1.45)
    public let isMonochrome: Float        // 0.0 = màu, 1.0 = đen trắng phim bạc
    public let undertoneStrength: Float   // Cường độ lớp bảo vệ sắc da (0.0 ... 1.2)
    public let splitStrength: Float       // Cường độ Split Toning shadow/highlight (0.0 ... 1.2)
    public let matrixRow0: SIMD4<Float>   // Hàng R ma trận màu 3x3 (linear space)
    public let matrixRow1: SIMD4<Float>   // Hàng G ma trận màu 3x3 (linear space)
    public let matrixRow2: SIMD4<Float>   // Hàng B ma trận màu 3x3 (linear space)
    public let skinShiftLab: SIMD4<Float> // Dịch chuyển (dL, da, db, skinToneProtect) trong OkLab
    public let shadowTint: SIMD4<Float>   // Ám sắc vùng tối (r, g, b, warmRedPop) trong linear space
    public let highlightTint: SIMD4<Float>// Ám sắc vùng sáng (r, g, b, skyProtect) trong linear space
    public let semanticBoost: SIMD4<Float>// (skinLightBoost, foliageGreenPop, skyBlueShift, blueShadowCut)
}

/// Đầy đủ 16 Phong cách Nhiếp ảnh (Photographic Styles 2 & 3 — 6 Sắc thái da bên trái Tiêu chuẩn, 9 Tâm trạng bên phải Tiêu chuẩn).
public enum PhotographicStylePreset: String, CaseIterable, Identifiable, Sendable, Codable {
    // 6 Undertones (trái Standard)
    case coolMood = "cool_mood"         // Hồng lạnh (Cool Rose)
    case neutral = "neutral"            // Trung tính (Neutral)
    case bright = "bright"              // Sáng (Bright — iOS 26 4-band semantic)
    case softRose = "soft_rose"         // Vàng hồng (Rose Gold)
    case gold = "gold"                  // Vàng kim (Gold)
    case warmAmber = "warm_amber"       // Hổ phách (Amber)

    // Center Anchor
    case standard = "standard"          // Tiêu chuẩn (Standard)

    // 9 Moods (phải Standard)
    case vibrant = "vibrant"            // Rực rỡ (Vibrant)
    case naturalMood = "natural_mood"   // Tự nhiên (Natural — Anti-HDR)
    case luminous = "luminous"          // Phát sáng (Luminous)
    case richContrast = "rich_contrast" // Kịch tính (Dramatic)
    case quiet = "quiet"                // Yên tĩnh (Quiet)
    case cozy = "cozy"                  // Ấm cúng (Cozy)
    case ethereal = "ethereal"          // Thanh tao (Ethereal)
    case mutedBW = "muted_bw"           // Đen trắng dịu (Muted B&W)
    case starkBW = "stark_bw"           // Đen trắng gắt (Stark B&W)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .coolMood:     return "Hồng lạnh"
        case .neutral:      return "Trung tính"
        case .bright:       return "Sáng"
        case .softRose:     return "Vàng hồng"
        case .gold:         return "Vàng kim"
        case .warmAmber:    return "Hổ phách"
        case .standard:     return "Tiêu chuẩn"
        case .vibrant:      return "Rực rỡ"
        case .naturalMood:  return "Tự nhiên"
        case .luminous:     return "Phát sáng"
        case .richContrast: return "Kịch tính"
        case .quiet:        return "Yên tĩnh"
        case .cozy:         return "Ấm cúng"
        case .ethereal:     return "Thanh tao"
        case .mutedBW:      return "Đen trắng dịu"
        case .starkBW:      return "Đen trắng gắt"
        }
    }

    public var englishCode: String {
        switch self {
        case .coolMood:     return "COOL ROSE"
        case .neutral:      return "NEUTRAL"
        case .bright:       return "BRIGHT"
        case .softRose:     return "ROSE GOLD"
        case .gold:         return "GOLD"
        case .warmAmber:    return "AMBER"
        case .standard:     return "STANDARD"
        case .vibrant:      return "VIBRANT"
        case .naturalMood:  return "NATURAL"
        case .luminous:     return "LUMINOUS"
        case .richContrast: return "DRAMATIC"
        case .quiet:        return "QUIET"
        case .cozy:         return "COZY"
        case .ethereal:     return "ETHEREAL"
        case .mutedBW:      return "MUTED B&W"
        case .starkBW:      return "STARK B&W"
        }
    }

    public var group: PhotographicStyleGroup {
        switch self {
        case .standard:
            return .standard
        case .coolMood, .neutral, .bright, .softRose, .gold, .warmAmber:
            return .undertone
        case .vibrant, .naturalMood, .luminous, .richContrast, .quiet, .cozy, .ethereal, .mutedBW, .starkBW:
            return .mood
        }
    }

    public var isMonochrome: Bool { self == .starkBW || self == .mutedBW }

    /// Tọa độ Tone mặc định (chuẩn bảng MakerNote 0x0054 iOS 18/26/27).
    public var defaultTone: Float {
        switch self {
        case .standard:     return  0.00
        case .warmAmber:    return  0.20
        case .gold:         return  0.20
        case .softRose:     return -0.20
        case .bright:       return  0.18
        case .neutral:      return  0.40
        case .coolMood:     return  0.35
        case .vibrant:      return -0.30
        case .naturalMood:  return -0.70
        case .luminous:     return  0.35
        case .richContrast: return -0.76
        case .quiet:        return  0.50
        case .cozy:         return -0.75
        case .ethereal:     return  0.68
        case .mutedBW:      return  0.40
        case .starkBW:      return -1.00
        }
    }

    /// Tọa độ Color mặc định (chuẩn bảng MakerNote 0x0054 iOS 18/26/27).
    public var defaultColor: Float {
        switch self {
        case .standard:     return  0.00
        case .warmAmber:    return  0.20
        case .gold:         return  0.10
        case .softRose:     return -0.20
        case .bright:       return  0.00
        case .neutral:      return -0.10
        case .coolMood:     return -0.10
        case .vibrant:      return  0.33
        case .naturalMood:  return -0.15
        case .luminous:     return  0.30
        case .richContrast: return  0.19
        case .quiet:        return  0.45
        case .cozy:         return -0.20
        case .ethereal:     return -0.15
        case .mutedBW:      return  0.00
        case .starkBW:      return  0.00
        }
    }

    /// Cường độ Palette / Intensity mặc định (0.0 ... 1.0).
    public var defaultPalette: Float {
        switch self {
        case .standard:     return 1.00
        case .warmAmber:    return 1.00
        case .gold:         return 0.85
        case .softRose:     return 0.75
        case .bright:       return 1.00
        case .neutral:      return 0.80
        case .coolMood:     return 0.75
        case .vibrant:      return 1.00
        case .naturalMood:  return 1.00
        case .luminous:     return 1.00
        case .richContrast: return 1.00
        case .quiet:        return 1.00
        case .cozy:         return 1.00
        case .ethereal:     return 1.00
        case .mutedBW:      return 0.50
        case .starkBW:      return 0.50
        }
    }

    public var padTintColor: Color {
        switch self {
        case .standard:     return Color(red: 0.42, green: 0.72, blue: 0.94)
        case .warmAmber:    return Color(red: 0.94, green: 0.60, blue: 0.28)
        case .gold:         return Color(red: 0.96, green: 0.74, blue: 0.30)
        case .softRose:     return Color(red: 0.94, green: 0.60, blue: 0.58)
        case .bright:       return Color(red: 0.62, green: 0.84, blue: 0.96)
        case .neutral:      return Color(red: 0.68, green: 0.66, blue: 0.74)
        case .coolMood:     return Color(red: 0.78, green: 0.62, blue: 0.86)
        case .vibrant:      return Color(red: 0.94, green: 0.46, blue: 0.44)
        case .naturalMood:  return Color(red: 0.56, green: 0.68, blue: 0.62)
        case .luminous:     return Color(red: 0.96, green: 0.66, blue: 0.46)
        case .richContrast: return Color(red: 0.38, green: 0.68, blue: 0.88)
        case .quiet:        return Color(red: 0.72, green: 0.76, blue: 0.54)
        case .cozy:         return Color(red: 0.82, green: 0.52, blue: 0.38)
        case .ethereal:     return Color(red: 0.64, green: 0.82, blue: 0.94)
        case .mutedBW:      return Color(red: 0.76, green: 0.76, blue: 0.78)
        case .starkBW:      return Color(red: 0.62, green: 0.63, blue: 0.66)
        }
    }

    public var padTopRightColor: Color {
        switch self {
        case .standard:     return Color(red: 0.36, green: 0.74, blue: 0.98)
        case .warmAmber:    return Color(red: 0.96, green: 0.66, blue: 0.30)
        case .gold:         return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .softRose:     return Color(red: 0.96, green: 0.66, blue: 0.62)
        case .bright:       return Color(red: 0.54, green: 0.86, blue: 0.98)
        case .neutral:      return Color(red: 0.72, green: 0.72, blue: 0.80)
        case .coolMood:     return Color(red: 0.84, green: 0.68, blue: 0.92)
        case .vibrant:      return Color(red: 0.96, green: 0.48, blue: 0.46)
        case .naturalMood:  return Color(red: 0.58, green: 0.72, blue: 0.66)
        case .luminous:     return Color(red: 0.98, green: 0.70, blue: 0.44)
        case .richContrast: return Color(red: 0.34, green: 0.70, blue: 0.92)
        case .quiet:        return Color(red: 0.78, green: 0.80, blue: 0.54)
        case .cozy:         return Color(red: 0.88, green: 0.56, blue: 0.40)
        case .ethereal:     return Color(red: 0.68, green: 0.86, blue: 0.98)
        case .mutedBW:      return Color(red: 0.80, green: 0.80, blue: 0.82)
        case .starkBW:      return Color(red: 0.72, green: 0.73, blue: 0.76)
        }
    }

    public var padBottomRightColor: Color {
        switch self {
        case .standard:     return Color(red: 0.28, green: 0.22, blue: 0.16)
        case .warmAmber:    return Color(red: 0.42, green: 0.22, blue: 0.08)
        case .gold:         return Color(red: 0.42, green: 0.28, blue: 0.08)
        case .softRose:     return Color(red: 0.38, green: 0.20, blue: 0.18)
        case .bright:       return Color(red: 0.18, green: 0.30, blue: 0.28)
        case .neutral:      return Color(red: 0.22, green: 0.22, blue: 0.28)
        case .coolMood:     return Color(red: 0.26, green: 0.18, blue: 0.34)
        case .vibrant:      return Color(red: 0.18, green: 0.30, blue: 0.28)
        case .naturalMood:  return Color(red: 0.16, green: 0.22, blue: 0.18)
        case .luminous:     return Color(red: 0.38, green: 0.22, blue: 0.14)
        case .richContrast: return Color(red: 0.10, green: 0.22, blue: 0.34)
        case .quiet:        return Color(red: 0.28, green: 0.26, blue: 0.14)
        case .cozy:         return Color(red: 0.36, green: 0.18, blue: 0.12)
        case .ethereal:     return Color(red: 0.22, green: 0.30, blue: 0.38)
        case .mutedBW:      return Color(red: 0.22, green: 0.22, blue: 0.24)
        case .starkBW:      return Color(red: 0.10, green: 0.10, blue: 0.12)
        }
    }

    public var paletteGradientColors: [Color] {
        switch self {
        case .standard:
            return [Color(red: 0.34, green: 0.35, blue: 0.38), Color(red: 0.56, green: 0.64, blue: 0.72), Color(red: 0.72, green: 0.84, blue: 0.96)]
        case .warmAmber:
            return [Color(red: 0.38, green: 0.42, blue: 0.48), Color(red: 0.78, green: 0.56, blue: 0.32), Color(red: 0.96, green: 0.62, blue: 0.24)]
        case .gold:
            return [Color(red: 0.40, green: 0.42, blue: 0.46), Color(red: 0.82, green: 0.66, blue: 0.32), Color(red: 0.98, green: 0.78, blue: 0.28)]
        case .softRose:
            return [Color(red: 0.42, green: 0.44, blue: 0.50), Color(red: 0.80, green: 0.60, blue: 0.58), Color(red: 0.96, green: 0.62, blue: 0.60)]
        case .bright:
            return [Color(red: 0.38, green: 0.44, blue: 0.50), Color(red: 0.58, green: 0.78, blue: 0.86), Color(red: 0.86, green: 0.92, blue: 0.98)]
        case .neutral:
            return [Color(red: 0.36, green: 0.36, blue: 0.40), Color(red: 0.60, green: 0.60, blue: 0.66), Color(red: 0.84, green: 0.84, blue: 0.88)]
        case .coolMood:
            return [Color(red: 0.36, green: 0.38, blue: 0.44), Color(red: 0.66, green: 0.58, blue: 0.78), Color(red: 0.86, green: 0.68, blue: 0.92)]
        case .vibrant:
            return [Color(red: 0.46, green: 0.76, blue: 0.94), Color(red: 0.94, green: 0.76, blue: 0.46), Color(red: 0.96, green: 0.44, blue: 0.42)]
        case .naturalMood:
            return [Color(red: 0.28, green: 0.32, blue: 0.30), Color(red: 0.52, green: 0.58, blue: 0.54), Color(red: 0.74, green: 0.78, blue: 0.72)]
        case .luminous:
            return [Color(red: 0.38, green: 0.34, blue: 0.36), Color(red: 0.84, green: 0.54, blue: 0.38), Color(red: 0.98, green: 0.74, blue: 0.46)]
        case .richContrast:
            return [Color(red: 0.84, green: 0.58, blue: 0.42), Color(red: 0.44, green: 0.56, blue: 0.66), Color(red: 0.28, green: 0.62, blue: 0.86)]
        case .quiet:
            return [Color(red: 0.38, green: 0.38, blue: 0.32), Color(red: 0.68, green: 0.66, blue: 0.48), Color(red: 0.84, green: 0.82, blue: 0.60)]
        case .cozy:
            return [Color(red: 0.36, green: 0.28, blue: 0.24), Color(red: 0.68, green: 0.44, blue: 0.32), Color(red: 0.90, green: 0.58, blue: 0.44)]
        case .ethereal:
            return [Color(red: 0.44, green: 0.48, blue: 0.56), Color(red: 0.64, green: 0.76, blue: 0.88), Color(red: 0.84, green: 0.92, blue: 0.98)]
        case .mutedBW:
            return [Color(red: 0.36, green: 0.36, blue: 0.38), Color(red: 0.66, green: 0.66, blue: 0.68), Color(red: 0.90, green: 0.90, blue: 0.92)]
        case .starkBW:
            return [Color(red: 0.16, green: 0.16, blue: 0.18), Color(red: 0.54, green: 0.54, blue: 0.56), Color(red: 0.94, green: 0.94, blue: 0.96)]
        }
    }

    /// Bộ tham số quang học mạnh, phân tách ngữ nghĩa rõ nét (Linear RGB + OkLab Skin/Foliage/Sky/WarmRed masks).
    public var recipe: PhotographicStylePresetRecipe {
        switch self {
        case .standard:
            return PhotographicStylePresetRecipe(
                presetKind: 0, baseContrast: 0.0, baseShadowLift: 0.0, baseHighlightRoll: 0.0,
                baseVibrance: 0.0, baseSaturation: 1.0, isMonochrome: 0.0,
                undertoneStrength: 0.0, splitStrength: 0.0,
                matrixRow0: SIMD4(1, 0, 0, 0), matrixRow1: SIMD4(0, 1, 0, 0), matrixRow2: SIMD4(0, 0, 1, 0),
                skinShiftLab: SIMD4(0, 0, 0, 0.50), shadowTint: SIMD4(0, 0, 0, 0), highlightTint: SIMD4(0, 0, 0, 0),
                semanticBoost: SIMD4(0, 0, 0, 0)
            )

        case .warmAmber:
            // Amber (TanWarm): ấm áp giàu dải đỏ-hổ phách, tôn sắc da ấm tự nhiên, giữ sạch tường trắng & trời xanh
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: 0.05, baseShadowLift: 0.02, baseHighlightRoll: 0.14,
                baseVibrance: 0.10, baseSaturation: 1.03, isMonochrome: 0.0,
                undertoneStrength: 0.95, splitStrength: 0.36,
                matrixRow0: SIMD4(1.044,  0.012, -0.018, 0),
                matrixRow1: SIMD4(0.008,  1.002, -0.008, 0),
                matrixRow2: SIMD4(-0.014, -0.010,  0.942, 0),
                skinShiftLab: SIMD4(0.018, 0.008, 0.024, 0.58),
                shadowTint: SIMD4(0.016, 0.008, -0.010, 0.14),
                highlightTint: SIMD4(0.022, 0.012, -0.014, 0.14),
                semanticBoost: SIMD4(0.016, 0.02, 0.0, 0.06)
            )

        case .gold:
            // Gold (GoldWarm): tăng nhẹ độ sáng và đẩy dải vàng-cam giờ vàng rực rỡ
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: 0.04, baseShadowLift: 0.04, baseHighlightRoll: 0.16,
                baseVibrance: 0.16, baseSaturation: 1.05, isMonochrome: 0.0,
                undertoneStrength: 1.0, splitStrength: 0.42,
                matrixRow0: SIMD4(1.056,  0.024, -0.024, 0),
                matrixRow1: SIMD4(0.012,  1.016, -0.016, 0),
                matrixRow2: SIMD4(-0.018, -0.018,  0.905, 0),
                skinShiftLab: SIMD4(0.026, 0.008, 0.042, 0.55),
                shadowTint: SIMD4(0.018, 0.012, -0.016, 0.20),
                highlightTint: SIMD4(0.036, 0.024, -0.022, 0.16),
                semanticBoost: SIMD4(0.024, 0.06, 0.0, 0.08)
            )

        case .softRose:
            // Rose Gold (BlushWarm): giả lập hoàng hôn nhẹ, tôn sắc hồng phấn mịn da, có chiều sâu nhẹ
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: 0.04, baseShadowLift: 0.01, baseHighlightRoll: 0.18,
                baseVibrance: 0.10, baseSaturation: 1.02, isMonochrome: 0.0,
                undertoneStrength: 1.0, splitStrength: 0.42,
                matrixRow0: SIMD4(1.052, -0.010,  0.016, 0),
                matrixRow1: SIMD4(-0.008,  0.986,  0.006, 0),
                matrixRow2: SIMD4(0.012,  0.006,  0.976, 0),
                skinShiftLab: SIMD4(0.018, 0.028, 0.012, 0.60),
                shadowTint: SIMD4(0.016, -0.006, 0.014, 0.16),
                highlightTint: SIMD4(0.026, 0.008, 0.016, 0.14),
                semanticBoost: SIMD4(0.016, 0.0, 0.0, 0.0)
            )

        case .bright:
            // Bright (BrightPop — iOS 26): 4-band semantic: tăng tương phản + sáng khuôn mặt/da + tươi tán lá xanh + bảo vệ mây trời!
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: 0.12, baseShadowLift: 0.05, baseHighlightRoll: 0.30,
                baseVibrance: 0.18, baseSaturation: 1.06, isMonochrome: 0.0,
                undertoneStrength: 1.15, splitStrength: 0.25,
                matrixRow0: SIMD4(1.018,  0.004, -0.006, 0),
                matrixRow1: SIMD4(-0.002,  1.024, -0.006, 0),
                matrixRow2: SIMD4(-0.004,  0.008,  1.018, 0),
                skinShiftLab: SIMD4(0.048, 0.006, 0.006, 0.65),
                shadowTint: SIMD4(0.004, 0.008, 0.010, 0.08),
                highlightTint: SIMD4(0.006, 0.008, 0.010, 0.42),
                semanticBoost: SIMD4(0.055, 0.32, 0.18, 0.0)
            )

        case .neutral:
            // Neutral: trung hòa vàng gắt đèn nội thất/hoàng hôn, nâng midtone sạch sẽ trong trẻo
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: -0.06, baseShadowLift: 0.05, baseHighlightRoll: 0.22,
                baseVibrance: -0.06, baseSaturation: 0.94, isMonochrome: 0.0,
                undertoneStrength: 0.90, splitStrength: 0.24,
                matrixRow0: SIMD4(0.976,  0.008,  0.012, 0),
                matrixRow1: SIMD4(0.002,  0.998,  0.004, 0),
                matrixRow2: SIMD4(0.006,  0.010,  1.028, 0),
                skinShiftLab: SIMD4(0.014, -0.008, -0.020, 0.55),
                shadowTint: SIMD4(0.002, 0.004, 0.010, -0.10),
                highlightTint: SIMD4(0.002, 0.004, 0.008, 0.18),
                semanticBoost: SIMD4(0.014, 0.0, 0.05, 0.0)
            )

        case .coolMood:
            // Cool Rose (Cool): tôn sắc hồng lạnh trong trẻo, kìm mảng vàng chói, cân bằng bóng tối mát
            return PhotographicStylePresetRecipe(
                presetKind: 1, baseContrast: 0.04, baseShadowLift: 0.03, baseHighlightRoll: 0.18,
                baseVibrance: 0.10, baseSaturation: 1.02, isMonochrome: 0.0,
                undertoneStrength: 1.05, splitStrength: 0.45,
                matrixRow0: SIMD4(1.024, -0.010,  0.018, 0),
                matrixRow1: SIMD4(-0.008,  0.986,  0.012, 0),
                matrixRow2: SIMD4(0.006,  0.012,  1.044, 0),
                skinShiftLab: SIMD4(0.022, 0.022, -0.022, 0.60),
                shadowTint: SIMD4(-0.006, 0.002, 0.026, 0.10),
                highlightTint: SIMD4(0.014, 0.004, 0.022, 0.16),
                semanticBoost: SIMD4(0.020, -0.04, 0.14, 0.0)
            )

        case .vibrant:
            // Vibrant (Colorful — Kodachrome / Velvia): độ rực sống động mạnh, sâu bóng tinh tế
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: 0.14, baseShadowLift: -0.02, baseHighlightRoll: 0.14,
                baseVibrance: 0.44, baseSaturation: 1.18, isMonochrome: 0.0,
                undertoneStrength: 0.55, splitStrength: 0.42,
                matrixRow0: SIMD4(1.068, -0.032, -0.022, 0),
                matrixRow1: SIMD4(-0.022,  1.058, -0.024, 0),
                matrixRow2: SIMD4(-0.020, -0.028,  1.072, 0),
                skinShiftLab: SIMD4(0.010, 0.004, 0.006, 0.55),
                shadowTint: SIMD4(-0.008, 0.006, 0.016, 0.22),
                highlightTint: SIMD4(0.016, 0.010, 0.002, 0.12),
                semanticBoost: SIMD4(0.012, 0.22, 0.18, 0.0)
            )

        case .naturalMood:
            // Natural (NoFilter): triệt tiêu vẻ HDR phẳng của smartphone, bóng đổ sâu điện ảnh nhưng vẫn giữ rõ chi tiết vùng tối
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: 0.14, baseShadowLift: -0.03, baseHighlightRoll: 0.20,
                baseVibrance: -0.04, baseSaturation: 0.97, isMonochrome: 0.0,
                undertoneStrength: 0.50, splitStrength: 0.24,
                matrixRow0: SIMD4(1.012, -0.005, -0.004, 0),
                matrixRow1: SIMD4(-0.004,  1.008, -0.003, 0),
                matrixRow2: SIMD4(-0.004, -0.005,  1.010, 0),
                skinShiftLab: SIMD4(0.012, 0.002, 0.004, 0.62),
                shadowTint: SIMD4(-0.004, -0.002, 0.003, 0.0),
                highlightTint: SIMD4(0.008, 0.006, 0.002, 0.16),
                semanticBoost: SIMD4(0.022, 0.0, 0.0, 0.0)
            )

        case .luminous:
            // Luminous (DreamyHues): rút bớt xanh lam khỏi bóng/midtone, đẩy rực ánh đỏ & chủ thể phát sáng trong cảnh tối
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: 0.08, baseShadowLift: 0.07, baseHighlightRoll: 0.22,
                baseVibrance: 0.22, baseSaturation: 1.08, isMonochrome: 0.0,
                undertoneStrength: 0.70, splitStrength: 0.52,
                matrixRow0: SIMD4(1.064,  0.012, -0.020, 0),
                matrixRow1: SIMD4(0.006,  1.012, -0.014, 0),
                matrixRow2: SIMD4(-0.020, -0.014,  0.924, 0),
                skinShiftLab: SIMD4(0.034, 0.010, 0.016, 0.58),
                shadowTint: SIMD4(0.012, 0.005, -0.022, 0.28),
                highlightTint: SIMD4(0.028, 0.018, -0.008, 0.14),
                semanticBoost: SIMD4(0.036, 0.04, -0.06, 0.28)
            )

        case .richContrast:
            // Dramatic (UrbanCool): tương phản sâu kiểu điện ảnh Bắc Âu, bóng xanh-xám lạnh (chuyển sắc mượt theo Palette!)
            return PhotographicStylePresetRecipe(
                presetKind: 3, baseContrast: 0.20, baseShadowLift: -0.04, baseHighlightRoll: 0.18,
                baseVibrance: 0.08, baseSaturation: 0.98, isMonochrome: 0.0,
                undertoneStrength: 0.45, splitStrength: 0.78,
                matrixRow0: SIMD4(0.974,  0.006,  0.008, 0),
                matrixRow1: SIMD4(-0.005,  1.010,  0.006, 0),
                matrixRow2: SIMD4(-0.012,  0.014,  1.046, 0),
                skinShiftLab: SIMD4(0.016, -0.004, 0.004, 0.62),
                shadowTint: SIMD4(-0.018, 0.006, 0.030, -0.14),
                highlightTint: SIMD4(0.018, 0.012, -0.006, 0.18),
                semanticBoost: SIMD4(0.024, -0.06, 0.14, 0.0)
            )

        case .quiet:
            // Quiet (WarmAuthentic): chất cổ điển sepia dịu nhẹ, ấm bóng tinh tế, trầm xanh lam, tươi nhẹ dải xanh lục
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: -0.04, baseShadowLift: 0.08, baseHighlightRoll: 0.26,
                baseVibrance: 0.02, baseSaturation: 0.84, isMonochrome: 0.0,
                undertoneStrength: 0.65, splitStrength: 0.52,
                matrixRow0: SIMD4(1.028,  0.014, -0.014, 0),
                matrixRow1: SIMD4(0.008,  1.018, -0.010, 0),
                matrixRow2: SIMD4(-0.012,  0.006,  0.934, 0),
                skinShiftLab: SIMD4(0.016, 0.004, 0.016, 0.58),
                shadowTint: SIMD4(0.016, 0.012, -0.010, 0.06),
                highlightTint: SIMD4(0.020, 0.016, -0.012, 0.24),
                semanticBoost: SIMD4(0.014, 0.22, -0.14, 0.12)
            )

        case .cozy:
            // Cozy (Earthy): tông đất trầm ấm sâu lắng có ánh hồng nhẹ ở vùng sáng, cực hợp quán cà phê đèn vàng
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: 0.14, baseShadowLift: -0.02, baseHighlightRoll: 0.22,
                baseVibrance: 0.04, baseSaturation: 0.94, isMonochrome: 0.0,
                undertoneStrength: 0.65, splitStrength: 0.68,
                matrixRow0: SIMD4(1.046,  0.014, -0.016, 0),
                matrixRow1: SIMD4(0.004,  0.992, -0.008, 0),
                matrixRow2: SIMD4(-0.012, -0.008,  0.928, 0),
                skinShiftLab: SIMD4(0.014, 0.010, 0.018, 0.62),
                shadowTint: SIMD4(0.022, 0.009, -0.014, 0.16),
                highlightTint: SIMD4(0.026, 0.010, 0.010, 0.16),
                semanticBoost: SIMD4(0.020, -0.08, -0.04, 0.10)
            )

        case .ethereal:
            // Ethereal (CloudCover): nâng sáng mạnh toàn ảnh, cứu vùng tối sâu, tôn sắc xanh lam dịu mờ sương siêu thực
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: -0.14, baseShadowLift: 0.18, baseHighlightRoll: 0.32,
                baseVibrance: -0.10, baseSaturation: 0.88, isMonochrome: 0.0,
                undertoneStrength: 0.75, splitStrength: 0.62,
                matrixRow0: SIMD4(0.972,  0.008,  0.018, 0),
                matrixRow1: SIMD4(0.002,  1.004,  0.014, 0),
                matrixRow2: SIMD4(0.004,  0.018,  1.052, 0),
                skinShiftLab: SIMD4(0.032, 0.004, -0.010, 0.60),
                shadowTint: SIMD4(0.010, 0.016, 0.032, -0.08),
                highlightTint: SIMD4(0.018, 0.022, 0.030, 0.34),
                semanticBoost: SIMD4(0.030, 0.0, 0.24, 0.0)
            )

        case .mutedBW:
            // Muted B&W (LongGray): đen trắng dịu Leica Monochrom, nâng sáng & giữ chi tiết bóng đổ êm mắt
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: -0.04, baseShadowLift: 0.12, baseHighlightRoll: 0.24,
                baseVibrance: 0.0, baseSaturation: 0.0, isMonochrome: 1.0,
                undertoneStrength: 0.0, splitStrength: 0.45,
                matrixRow0: SIMD4(1, 0, 0, 0), matrixRow1: SIMD4(0, 1, 0, 0), matrixRow2: SIMD4(0, 0, 1, 0),
                skinShiftLab: SIMD4(0.022, 0, 0, 0.55),
                shadowTint: SIMD4(0.012, 0.012, 0.014, 0),
                highlightTint: SIMD4(0.014, 0.012, 0.008, 0.22),
                semanticBoost: SIMD4(0.020, 0, 0, 0)
            )

        case .starkBW:
            // Stark B&W (StarkBW): đen trắng tương phản mạnh Kodak Tri-X 400, bóng sâu có chi tiết & highlight sắc nét
            return PhotographicStylePresetRecipe(
                presetKind: 2, baseContrast: 0.24, baseShadowLift: -0.05, baseHighlightRoll: 0.16,
                baseVibrance: 0.0, baseSaturation: 0.0, isMonochrome: 1.0,
                undertoneStrength: 0.0, splitStrength: 0.60,
                matrixRow0: SIMD4(1, 0, 0, 0), matrixRow1: SIMD4(0, 1, 0, 0), matrixRow2: SIMD4(0, 0, 1, 0),
                skinShiftLab: SIMD4(0.016, 0, 0, 0.55),
                shadowTint: SIMD4(-0.005, -0.003, 0.007, 0),
                highlightTint: SIMD4(0.010, 0.008, 0.002, 0.12),
                semanticBoost: SIMD4(0.018, 0, 0, 0)
            )
        }
    }
}

/// Trạng thái Photographic Style 2D + Kết cấu Styles 3 thời gian thực (Tone, Color, Palette, Texture, Grain).
public struct PhotographicStyleState: Equatable, Sendable, Codable {
    public var preset: PhotographicStylePreset
    /// Trục Y của Control Pad: -1.0 (tối sâu) ... 0.0 ... +1.0 (sáng thoáng)
    public var tone: Float
    /// Trục X của Control Pad: -1.0 (nhạt/trầm) ... 0.0 ... +1.0 (rực rỡ)
    public var color: Float
    /// Thanh cường độ hòa trộn tuyến tính: 0.0 (tắt) ... 1.0 (100%)
    public var palette: Float
    /// Kết cấu vi mô Styles 3 (Standard / Soft Skin / Glow / Film) chạy live 60 FPS GPU
    public var textureMode: PhotographicTextureMode
    /// Cường độ kết cấu (0.0 ... 1.0)
    public var textureIntensity: Float
    /// Bật/tắt hạt phim độc lập
    public var grainEnabled: Bool
    /// Mức hạt phim (0.0 ... 1.0)
    public var grainAmount: Float
    /// Kích thước hạt phim vật lý (0.7 ... 1.8)
    public var grainSize: Float

    public static let standard = PhotographicStyleState(
        preset: .standard, tone: 0.0, color: 0.0, palette: 1.0,
        textureMode: .standard, textureIntensity: 0.0,
        grainEnabled: false, grainAmount: 0.36, grainSize: 1.20
    )

    public init(
        preset: PhotographicStylePreset = .standard,
        tone: Float = 0.0,
        color: Float = 0.0,
        palette: Float = 1.0,
        textureMode: PhotographicTextureMode = .standard,
        textureIntensity: Float = 0.0,
        grainEnabled: Bool = false,
        grainAmount: Float = 0.36,
        grainSize: Float = 1.20
    ) {
        self.preset = preset
        self.tone = tone.isFinite ? max(-1.0, min(1.0, tone)) : 0.0
        self.color = color.isFinite ? max(-1.0, min(1.0, color)) : 0.0
        self.palette = palette.isFinite ? max(0.0, min(1.0, palette)) : 1.0
        self.textureMode = textureMode
        self.textureIntensity = textureIntensity.isFinite ? max(0.0, min(1.0, textureIntensity)) : 0.0
        self.grainEnabled = grainEnabled
        self.grainAmount = grainAmount.isFinite ? max(0.0, min(1.0, grainAmount)) : 0.36
        self.grainSize = grainSize.isFinite ? max(0.7, min(1.8, grainSize)) : 1.20
    }

    public static func defaultState(for preset: PhotographicStylePreset) -> PhotographicStyleState {
        PhotographicStyleState(
            preset: preset,
            tone: preset.defaultTone,
            color: preset.defaultColor,
            palette: preset.defaultPalette,
            textureMode: .standard,
            textureIntensity: 0.0,
            grainEnabled: false,
            grainAmount: 0.36,
            grainSize: 1.20
        )
    }

    public var hasTextureOrGrain: Bool {
        (textureMode != .standard && textureIntensity >= 0.005) || (grainEnabled && grainAmount >= 0.005)
    }

    /// Trả về `true` khi ảnh không thay đổi (bỏ qua hoàn toàn pass Metal/CoreImage, 0% chi phí GPU).
    public var isIdentity: Bool {
        if hasTextureOrGrain { return false }
        if !preset.isMonochrome && palette < 0.005 { return true }
        return preset == .standard && abs(tone) < 0.005 && abs(color) < 0.005
    }

    /// Trả về `true` khi người dùng đã chỉnh lệch khỏi giá trị mặc định của preset đang chọn.
    public var isModifiedFromPresetDefault: Bool {
        abs(tone - preset.defaultTone) >= 0.005
            || abs(color - preset.defaultColor) >= 0.005
            || abs(palette - preset.defaultPalette) >= 0.005
            || textureMode != .standard
            || grainEnabled
    }

    public var tonePercent: Int { Int(round(tone * 100.0)) }
    public var colorPercent: Int { Int(round(color * 100.0)) }
    public var palettePercent: Int { Int(round(palette * 100.0)) }
    public var texturePercent: Int { Int(round(textureIntensity * 100.0)) }

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

    /// Định dạng 2 chữ số sạch chuẩn iOS Camera Top HUD (`00`, `07`, `84`, `-14`, `100`).
    public var toneHUDNumber: String {
        Self.formatTwoDigitSigned(tonePercent)
    }

    public var colorHUDNumber: String {
        Self.formatTwoDigitSigned(colorPercent)
    }

    public var paletteHUDNumber: String {
        "\(palettePercent)"
    }

    private static func formatTwoDigitSigned(_ value: Int) -> String {
        if value < 0 {
            let absVal = abs(value)
            return absVal < 10 ? "-0\(absVal)" : "-\(absVal)"
        }
        return value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Custom Saved Photographic Style Recipes (Giải quyết hạn chế chỉ lưu 1 công thức của Camera gốc)
public struct PhotographicStyleCustomRecipe: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var state: PhotographicStyleState
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        subtitle: String = "",
        state: PhotographicStyleState,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.state = state
        self.isBuiltIn = isBuiltIn
    }

    /// 5 công thức chuẩn nhiếp ảnh thực tế kiểm chứng từ cộng đồng iPhone 16–18 Pro.
    public static let builtInBenchmarks: [PhotographicStyleCustomRecipe] = [
        PhotographicStyleCustomRecipe(
            id: "builtin_portra400",
            name: "Portra 400",
            subtitle: "Vàng kim · Tone +10 · Color -10 · Mịn da",
            state: PhotographicStyleState(preset: .gold, tone: 0.10, color: -0.10, palette: 0.50, textureMode: .softSkin, textureIntensity: 0.18, grainEnabled: false),
            isBuiltIn: true
        ),
        PhotographicStyleCustomRecipe(
            id: "builtin_classic_chrome",
            name: "Classic Chrome",
            subtitle: "Yên tĩnh · Tone -35 · Color -15 · Hạt phim",
            state: PhotographicStyleState(preset: .quiet, tone: -0.35, color: -0.15, palette: 0.70, textureMode: .standard, textureIntensity: 0.0, grainEnabled: true, grainAmount: 0.34, grainSize: 1.20),
            isBuiltIn: true
        ),
        PhotographicStyleCustomRecipe(
            id: "builtin_velvia",
            name: "Fuji Velvia",
            subtitle: "Rực rỡ · Tone -20 · Color +40 · Palette 80",
            state: PhotographicStyleState(preset: .vibrant, tone: -0.20, color: 0.40, palette: 0.80, textureMode: .standard, textureIntensity: 0.0, grainEnabled: false),
            isBuiltIn: true
        ),
        PhotographicStyleCustomRecipe(
            id: "builtin_trix400",
            name: "Kodak Tri-X 400",
            subtitle: "Đen trắng gắt · Tone -30 · Film 50 · Hạt",
            state: PhotographicStyleState(preset: .starkBW, tone: -0.30, color: 0.0, palette: 1.00, textureMode: .film, textureIntensity: 0.50, grainEnabled: true, grainAmount: 0.46, grainSize: 1.35),
            isBuiltIn: true
        ),
        PhotographicStyleCustomRecipe(
            id: "builtin_antihdr",
            name: "Anti-HDR Daily",
            subtitle: "Hổ phách · Tone -50 · Color +15 · Palette 75",
            state: PhotographicStyleState(preset: .warmAmber, tone: -0.50, color: 0.15, palette: 0.75, textureMode: .standard, textureIntensity: 0.0, grainEnabled: false),
            isBuiltIn: true
        )
    ]
}

public enum PhotographicStyleRecipeStore {
    private static let storageKey = "alignai.photographicStyles.customRecipes.v1"

    public static func loadUserRecipes() -> [PhotographicStyleCustomRecipe] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PhotographicStyleCustomRecipe].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func saveUserRecipes(_ recipes: [PhotographicStyleCustomRecipe]) {
        if let data = try? JSONEncoder().encode(recipes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
