import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Composition Rule Types
public enum CompositionRule: String, CaseIterable, Identifiable, Sendable {
    case ruleOfThirds = "Rule of Thirds"
    case goldenRatio = "Golden Ratio"
    case goldenSpiral = "Golden Spiral"
    case centerSymmetry = "Center Pro"
    case dynamicAI = "AI Auto-Select"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .ruleOfThirds: return "grid"
        case .goldenRatio: return "circle.grid.3x3"
        case .goldenSpiral: return "camera.macro"
        case .centerSymmetry: return "scope"
        case .dynamicAI: return "wand.and.stars"
        }
    }

    public var displayNameVietnamese: String {
        switch self {
        case .ruleOfThirds: return "Quy tắc 1/3"
        case .goldenRatio: return "Tỷ lệ vàng (1.618)"
        case .goldenSpiral: return "Xoắn ốc Fibonacci"
        case .centerSymmetry: return "Tâm đối xứng"
        case .dynamicAI: return "AI Tự động tối ưu"
        }
    }

    public var descriptionVietnamese: String {
        switch self {
        case .ruleOfThirds: return "Đặt chủ thể tại 4 điểm giao thoa kinh điển"
        case .goldenRatio: return "Bố cục tỷ lệ vàng 1:1.618 chuẩn thị giác"
        case .goldenSpiral: return "Đường xoắn ốc dẫn dắt ánh nhìn vào tâm điểm"
        case .centerSymmetry: return "Căn chủ thể chính xác tại tâm đối xứng"
        case .dynamicAI: return "Tự động đề xuất bố cục theo ngữ cảnh"
        }
    }
}

// MARK: - Camera Capture Mode
public enum CameraCaptureMode: String, CaseIterable, Identifiable {
    case photo = "ẢNH"
    case video = "VIDEO"
    case proVideo = "VIDEO PRO"

    public var id: String { rawValue }

    public var isVideo: Bool {
        return self == .video || self == .proVideo
    }
}

// MARK: - Pro Video Parameter Tabs
public enum ProVideoParameterTab: String, CaseIterable, Identifiable {
    case iso = "ISO"
    case shutter = "SHUTTER"
    case aperture = "KHẨU/EV"
    case wb = "WB"
    case focus = "FOCUS"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .iso: return "gauge.medium"
        case .shutter: return "timer"
        case .aperture: return "camera.aperture"
        case .wb: return "sun.max.fill"
        case .focus: return "scope"
        }
    }
}

// MARK: - Video Format Options & Codecs
public enum VideoFormatOption: String, CaseIterable, Identifiable {
    case hd60 = "1080P 60FPS"
    case hd30 = "1080P 30FPS"
    case uhd60 = "4K 60FPS"
    case uhd30 = "4K 30FPS"

    public var id: String { rawValue }

    public var width: Int32 {
        switch self {
        case .hd60, .hd30: return 1920
        case .uhd60, .uhd30: return 3840
        }
    }

    public var height: Int32 {
        switch self {
        case .hd60, .hd30: return 1080
        case .uhd60, .uhd30: return 2160
        }
    }

    public var fps: Double {
        switch self {
        case .hd60, .uhd60: return 60.0
        case .hd30, .uhd30: return 30.0
        }
    }
}

public enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case h264 = "H.264"

    public var id: String { rawValue }
}

// MARK: - AI Framing Session State Machine
/// Đây là trạng thái tổng thể của phiên AI — thay thế bool đơn giản
public enum AISessionState: Equatable {
    case idle                          // Camera đang hoạt động bình thường, chưa khởi động AI
    case analyzing                     // AI đang phân tích bối cảnh (sau khi nhấn nút AI)
    case targetPlaced(locked: Bool)    // AI đã đặt vòng tròn vàng — người dùng di chuyển camera
    case alignmentPerfect              // Tâm trắng trùng vòng vàng — đang countdown chụp
    case capturing                     // Đang thực hiện chụp ảnh
    case done                          // Đã chụp xong — hiển thị kết quả

    public var displayMessage: String {
        switch self {
        case .idle:
            return "Nhấn nút AI để bắt đầu phân tích"
        case .analyzing:
            return "AI đang phân tích cảnh vật..."
        case .targetPlaced(let locked):
            return locked ? "Mục tiêu đã khóa — Di chuyển tâm trắng vào vòng vàng" : "Di chuyển máy để căn chỉnh bố cục"
        case .alignmentPerfect:
            return "✓ Khớp hoàn hảo! Chuẩn bị chụp..."
        case .capturing:
            return "Đang chụp ảnh..."
        case .done:
            return "Hoàn tất!"
        }
    }

    public var accentColor: Color {
        switch self {
        case .idle: return Color.white.opacity(0.5)
        case .analyzing: return Color.yellow
        case .targetPlaced: return Color.orange
        case .alignmentPerfect: return Color.green
        case .capturing, .done: return Color.cyan
        }
    }

    public var isSessionActive: Bool {
        switch self {
        case .idle, .done: return false
        default: return true
        }
    }
}

// MARK: - Tracking Quality State Machine (Hybrid Optical + Gyro State)
public enum TrackingQuality: Equatable {
    case locked        // đang bám tốt bằng optical tracking
    case predicting     // vừa mất optical, đang ngoại suy bằng vận tốc + gyro
    case reacquiring     // mất lâu hơn, đang cố tìm lại / giữ vị trí cuối
    case lost            // mất hẳn, cần người dùng chạm lại để đặt target
}

// MARK: - Tracking Sensitivity Preset
public enum TrackingSensitivityPreset: String, CaseIterable, Identifiable {
    case low = "Thấp (Ổn định, chống giật)"
    case medium = "Vừa (Cân bằng tiêu chuẩn)"
    case high = "Cao (Phản hồi tức thì)"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .low: return "Thấp"
        case .medium: return "Vừa"
        case .high: return "Cao"
        }
    }
}

// MARK: - AI Framing Engine Source Indicator
public enum AIEngineSource: Equatable {
    case geminiCloud(model: String)
    case localTrained114MB(category: String)
    case yoloNeural(label: String)
    case appleNeuralEngine(scene: String)

    public var title: String {
        switch self {
        case .geminiCloud(let model):
            let clean = model.replacingOccurrences(of: "google/", with: "")
                .replacingOccurrences(of: "openai/", with: "")
                .replacingOccurrences(of: "anthropic/", with: "")
                .replacingOccurrences(of: "meta-llama/", with: "")
            return "✨ OpenRouter: \(clean)"
        case .localTrained114MB(let cat):
            return "🧠 AI Local 114MB (\(cat))"
        case .yoloNeural(let label):
            return "⚡ YOLOv11 Neural (\(label))"
        case .appleNeuralEngine(let scene):
            return "⚡ Apple Neural Engine (\(scene))"
        }
    }

    public var badgeName: String {
        switch self {
        case .geminiCloud(let model):
            let clean = model.replacingOccurrences(of: "google/", with: "")
                .replacingOccurrences(of: "openai/", with: "")
                .replacingOccurrences(of: "anthropic/", with: "")
                .replacingOccurrences(of: "meta-llama/", with: "")
                .uppercased()
            return "OPENROUTER (\(clean))"
        case .localTrained114MB:
            return "AI 114MB"
        case .yoloNeural(let label):
            return "YOLO (\(label.uppercased()))"
        case .appleNeuralEngine:
            return "NPU"
        }
    }

    public var iconName: String {
        switch self {
        case .geminiCloud: return "sparkles"
        case .localTrained114MB: return "brain.head.profile"
        case .yoloNeural: return "bolt.shield.fill"
        case .appleNeuralEngine: return "cpu.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .geminiCloud: return .cyan
        case .localTrained114MB: return .yellow
        case .yoloNeural: return .orange
        case .appleNeuralEngine: return .green
        }
    }

    public var isCloud: Bool {
        if case .geminiCloud = self { return true }
        return false
    }
}

// MARK: - Active AI Indicator Type (Phân biệt nháy màu Local đỏ / Cloud vàng)
public enum ActiveAIIndicatorType: Equatable {
    case none
    case local
    case cloud
}

// MARK: - AI Video Cinematography Director Models
public struct CinematicWaypoint: Identifiable, Equatable {
    public let id: Int                   // 1, 2, 3...
    public var point: CGPoint            // Normalized coordinates (0.05...0.95) in UI space
    public var label: String             // e.g. "1. Bắt đầu: Khóa chủ thể"
    public var actionTip: String         // e.g. "Giữ máy ổn định 1.5s"
    public var recommendedDuration: Double // Thời gian lia khuyến nghị (giây)

    public init(id: Int, point: CGPoint, label: String, actionTip: String, recommendedDuration: Double = 2.0) {
        self.id = id
        self.point = point
        self.label = label
        self.actionTip = actionTip
        self.recommendedDuration = recommendedDuration
    }
}

public struct AIVideoDirectorGuidance: Equatable {
    public let shotStyleTitle: String               // e.g. "Lia ngang bắt trọn bối cảnh (Cinematic Pan)"
    public let movementDirectionDescription: String // e.g. "Lia máy chậm từ trái sang phải, chuyển tiếp mượt mà qua các tâm"
    public let suggestedPacingSeconds: Double       // e.g. 5.0s
    public let waypoints: [CinematicWaypoint]        // Các tâm đánh dấu trên màn hình (2 - 4 điểm)
    public let suggestedZoom: CGFloat               // 1.0x - 2.0x
    public let directorTip: String                  // Lời khuyên của đạo diễn
    public let modelUsed: String                    // Model AI OpenRouter đã phân tích

    public init(
        shotStyleTitle: String,
        movementDirectionDescription: String,
        suggestedPacingSeconds: Double,
        waypoints: [CinematicWaypoint],
        suggestedZoom: CGFloat = 1.0,
        directorTip: String,
        modelUsed: String = "OpenRouter AI"
    ) {
        self.shotStyleTitle = shotStyleTitle
        self.movementDirectionDescription = movementDirectionDescription
        self.suggestedPacingSeconds = suggestedPacingSeconds
        self.waypoints = waypoints
        self.suggestedZoom = suggestedZoom
        self.directorTip = directorTip
        self.modelUsed = modelUsed
    }
}


// MARK: - Smart Autofocus Target Type
public enum SmartFocusType: Equatable {
    case face
    case salientObject
    case center
    case aiTarget
}

// MARK: - Scene Classification Types
public enum DetectedSceneType: String, CaseIterable {
    case portrait = "Portrait"
    case pet = "Pet / Animal"
    case landscape = "Landscape"
    case sunset = "Sunset / Golden Hour"
    case architecture = "Architecture"
    case sky = "Sky / Cloud"
    case water = "Water / Sea"
    case foliage = "Foliage / Nature"
    case night = "Night Scene"
    case food = "Food"
    case macro = "Macro / Close-up"
    case street = "Street Life"
    case general = "Auto General"

    public var isSkyOrInfiniteHorizon: Bool {
        return self == .sky || self == .landscape || self == .sunset
    }

    public var isDeformableNature: Bool {
        return self == .foliage || self == .water
    }

    public var iconName: String {
        switch self {
        case .portrait: return "person.crop.rectangle.fill"
        case .pet: return "pawprint.fill"
        case .landscape: return "mountain.2.fill"
        case .sunset: return "sun.horizon.fill"
        case .architecture: return "building.columns.fill"
        case .sky: return "cloud.sun.fill"
        case .water: return "water.waves"
        case .foliage: return "leaf.fill"
        case .night: return "moon.stars.fill"
        case .food: return "fork.knife"
        case .macro: return "camera.macro"
        case .street: return "figure.walk"
        case .general: return "sparkles"
        }
    }

    public var recommendedFilter: FilmPreset {
        switch self {
        case .portrait: return .fujiPro400H
        case .pet: return .kodakPortra400
        case .landscape: return .velvia50
        case .sunset: return .sunsetGlow
        case .architecture: return .classicChrome
        case .sky: return .velvia50
        case .water: return .cinemaTealOrange
        case .foliage: return .tokyoAiry
        case .night: return .cinestill800T
        case .food: return .ektar100
        case .macro: return .fujiPro400H
        case .street: return .streetClassic
        case .general: return .fujiPro400H
        }
    }

    /// AI Full Color Mode — tham số màu tối ưu hoàn toàn bởi AI
    public var aiFullColorParameters: AIColorParameters {
        switch self {
        case .portrait:
            return AIColorParameters(warmthShift: -0.08, saturationBoost: 1.05, contrastCurve: 1.04, shadowLift: 0.04, highlightRoll: 0.92, filmGrain: 0.15, vignetteAmount: 0.2, colorGrade: .softwarm)
        case .pet:
            return AIColorParameters(warmthShift: 0.08, saturationBoost: 1.15, contrastCurve: 1.06, shadowLift: 0.05, highlightRoll: 0.93, filmGrain: 0.10, vignetteAmount: 0.15, colorGrade: .vibrant)
        case .landscape:
            return AIColorParameters(warmthShift: 0.05, saturationBoost: 1.18, contrastCurve: 1.12, shadowLift: 0.02, highlightRoll: 0.96, filmGrain: 0.10, vignetteAmount: 0.25, colorGrade: .coolnatural)
        case .sunset:
            return AIColorParameters(warmthShift: 0.30, saturationBoost: 1.35, contrastCurve: 1.15, shadowLift: 0.06, highlightRoll: 0.88, filmGrain: 0.12, vignetteAmount: 0.35, colorGrade: .golden)
        case .architecture:
            return AIColorParameters(warmthShift: -0.05, saturationBoost: 1.08, contrastCurve: 1.20, shadowLift: 0.00, highlightRoll: 1.00, filmGrain: 0.05, vignetteAmount: 0.15, colorGrade: .tealOrange)
        case .sky:
            return AIColorParameters(warmthShift: -0.10, saturationBoost: 1.25, contrastCurve: 1.10, shadowLift: 0.01, highlightRoll: 0.98, filmGrain: 0.05, vignetteAmount: 0.20, colorGrade: .coolnatural)
        case .water:
            return AIColorParameters(warmthShift: -0.12, saturationBoost: 1.20, contrastCurve: 1.15, shadowLift: 0.02, highlightRoll: 0.95, filmGrain: 0.08, vignetteAmount: 0.22, colorGrade: .coolnatural)
        case .foliage:
            return AIColorParameters(warmthShift: 0.02, saturationBoost: 1.22, contrastCurve: 1.08, shadowLift: 0.04, highlightRoll: 0.94, filmGrain: 0.08, vignetteAmount: 0.18, colorGrade: .vibrant)
        case .night:
            return AIColorParameters(warmthShift: -0.15, saturationBoost: 0.80, contrastCurve: 1.35, shadowLift: 0.08, highlightRoll: 0.85, filmGrain: 0.35, vignetteAmount: 0.55, colorGrade: .moody)
        case .food:
            return AIColorParameters(warmthShift: 0.12, saturationBoost: 1.22, contrastCurve: 1.08, shadowLift: 0.05, highlightRoll: 0.94, filmGrain: 0.08, vignetteAmount: 0.18, colorGrade: .vibrant)
        case .macro:
            return AIColorParameters(warmthShift: 0.04, saturationBoost: 1.20, contrastCurve: 1.10, shadowLift: 0.03, highlightRoll: 0.95, filmGrain: 0.08, vignetteAmount: 0.22, colorGrade: .vibrant)
        case .street:
            return AIColorParameters(warmthShift: -0.03, saturationBoost: 0.95, contrastCurve: 1.18, shadowLift: 0.01, highlightRoll: 0.97, filmGrain: 0.22, vignetteAmount: 0.30, colorGrade: .classic)
        case .general:
            return AIColorParameters(warmthShift: 0.0, saturationBoost: 1.05, contrastCurve: 1.05, shadowLift: 0.02, highlightRoll: 0.98, filmGrain: 0.10, vignetteAmount: 0.10, colorGrade: .softwarm)
        }
    }

    public var localizedName: String {
        switch self {
        case .portrait: return "Chân dung (Portrait)"
        case .pet: return "Thú cưng (Pet)"
        case .landscape: return "Phong cảnh (Landscape)"
        case .sunset: return "Hoàng hôn (Golden Hour)"
        case .architecture: return "Kiến trúc (Architecture)"
        case .sky: return "Bầu trời / Mây (Sky)"
        case .water: return "Mặt nước (Water)"
        case .foliage: return "Cây cối / Lá (Foliage)"
        case .night: return "Ban đêm (Night Scene)"
        case .food: return "Ẩm thực (Food)"
        case .macro: return "Cận cảnh (Macro)"
        case .street: return "Đường phố (Street)"
        case .general: return "Tự nhiên (Natural)"
        }
    }
}

// MARK: - AI Full Color Parameters (Neural Engine driven)
public enum AIColorGrade: String {
    case softwarm = "Soft Warm"
    case coolnatural = "Cool Natural"
    case golden = "Golden Hour"
    case tealOrange = "Teal & Orange"
    case moody = "Dark Moody"
    case vibrant = "Vibrant"
    case classic = "Classic BW"
    case cinematic = "Cinematic Film"
}

public struct AIColorParameters {
    /// -1.0 (cool) to +1.0 (warm)
    public let warmthShift: CGFloat
    /// 0.5 (muted) to 1.6 (vibrant)
    public let saturationBoost: CGFloat
    /// 0.8 (flat) to 1.5 (punchy)
    public let contrastCurve: CGFloat
    /// 0.0 (deep blacks) to 0.25 (lifted shadows)
    public let shadowLift: CGFloat
    /// 0.75 (soft highlights) to 1.0 (hard highlights)
    public let highlightRoll: CGFloat
    /// 0.0 (no grain) to 0.5 (heavy grain)
    public let filmGrain: CGFloat
    /// 0.0 (no vignette) to 0.7 (heavy vignette)
    public let vignetteAmount: CGFloat
    /// Color grading style
    public let colorGrade: AIColorGrade
    /// -1.0 to +1.0 EV exposure compensation
    public var exposureBias: CGFloat = 0.0
    /// -0.3 (green) to +0.3 (magenta)
    public var tintShift: CGFloat = 0.0

    public init(
        warmthShift: CGFloat,
        saturationBoost: CGFloat,
        contrastCurve: CGFloat,
        shadowLift: CGFloat,
        highlightRoll: CGFloat,
        filmGrain: CGFloat,
        vignetteAmount: CGFloat,
        colorGrade: AIColorGrade,
        exposureBias: CGFloat = 0.0,
        tintShift: CGFloat = 0.0
    ) {
        self.warmthShift = warmthShift
        self.saturationBoost = saturationBoost
        self.contrastCurve = contrastCurve
        self.shadowLift = shadowLift
        self.highlightRoll = highlightRoll
        self.filmGrain = filmGrain
        self.vignetteAmount = vignetteAmount
        self.colorGrade = colorGrade
        self.exposureBias = exposureBias
        self.tintShift = tintShift
    }
}

// MARK: - Legacy FramingAlignmentState (kept for compatibility)
public enum FramingAlignmentState: Equatable {
    case analyzing
    case guiding(distance: CGFloat, angle: CGFloat)
    case aligned(score: Double)
    case locked

    public var statusDescription: String {
        switch self {
        case .analyzing: return "Đang phân tích bối cảnh AI..."
        case .guiding: return "Di chuyển máy để căn chỉnh bố cục"
        case .aligned: return "Bố cục hoàn hảo! Giữ chắc tay"
        case .locked: return "Khung hình khóa mục tiêu"
        }
    }

    public var statusColor: Color {
        switch self {
        case .analyzing: return Color.yellow
        case .guiding: return Color.orange
        case .aligned, .locked: return Color.green
        }
    }
}

// MARK: - Film Simulation Presets
public enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard Clean"
    case fujiPro400H = "Fuji Pro 400H"
    case kodakPortra400 = "Kodak Portra 400"
    case classicChrome = "Classic Chrome"
    case cinemaTealOrange = "Teal & Orange"
    case velvia50 = "Fuji Velvia 50"
    case sunsetGlow = "Sunset Glow"
    case tokyoAiry = "Tokyo Clean"
    case hkCinema90s = "HK Cinema 90s"
    case cinestill800T = "CineStill 800T"
    case leicaMonochrom = "Leica Monochrom"
    case monochromeNoir = "Noir High Contrast"
    case triX400 = "Kodak Tri-X 400"
    case vintageWarm = "Vintage Warm 70s"
    case streetClassic = "Street Classic"
    case nordicCold = "Nordic Minimal"
    case ektar100 = "Kodak Ektar 100"
    case neonCyberpunk = "Cyberpunk Night"
    case aiFullAuto = "AI Full Auto Color"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Tự nhiên"
        case .fujiPro400H: return "Fuji Pastel"
        case .kodakPortra400: return "Portra Ấm"
        case .classicChrome: return "Classic Chrome"
        case .cinemaTealOrange: return "Điện ảnh Teal"
        case .velvia50: return "Velvia Rực rỡ"
        case .sunsetGlow: return "Hoàng hôn Vàng"
        case .tokyoAiry: return "Tokyo Mơ màng"
        case .hkCinema90s: return "Hồng Kông 90s"
        case .cinestill800T: return "CineStill Đêm"
        case .leicaMonochrom: return "Leica Đen trắng"
        case .monochromeNoir: return "Noir Tương phản"
        case .triX400: return "Tri-X Phóng sự"
        case .vintageWarm: return "Hoài niệm 70s"
        case .streetClassic: return "Đường phố Pro"
        case .nordicCold: return "Bắc Âu Lạnh"
        case .ektar100: return "Ektar Sắc nét"
        case .neonCyberpunk: return "Cyberpunk Đêm"
        case .aiFullAuto: return "Tự động AI"
        }
    }

    public var shortTitle: String {
        switch self {
        case .standard: return "TỰ NHIÊN"
        case .fujiPro400H: return "PASTEL"
        case .kodakPortra400: return "PORTRA"
        case .classicChrome: return "CHROME"
        case .cinemaTealOrange: return "TEAL"
        case .velvia50: return "VELVIA"
        case .sunsetGlow: return "HOÀNG HÔN"
        case .tokyoAiry: return "TOKYO"
        case .hkCinema90s: return "HK 90S"
        case .cinestill800T: return "CINESTILL"
        case .leicaMonochrom: return "LEICA BW"
        case .monochromeNoir: return "NOIR"
        case .triX400: return "TRI-X"
        case .vintageWarm: return "HOÀI NIỆM"
        case .streetClassic: return "ĐƯỜNG PHỐ"
        case .nordicCold: return "BẮC ÂU"
        case .ektar100: return "EKTAR"
        case .neonCyberpunk: return "CYBER"
        case .aiFullAuto: return "TỰ ĐỘNG"
        }
    }

    public var description: String {
        switch self {
        case .standard: return "Màu thực tế trung thực, dải sáng tối đa"
        case .fujiPro400H: return "Tone xanh pastel nhẹ, tôn da tươi sáng trong trẻo"
        case .kodakPortra400: return "Sắc ấm vàng dịu, chuyển màu highlight và tone da mượt mà"
        case .classicChrome: return "Màu phim phóng sự tài liệu, độ bão hòa dịu, shadow đằm thắm"
        case .cinemaTealOrange: return "Tương phản điện ảnh Hollywood, shadow xanh teal đối lập da ấm"
        case .velvia50: return "Sắc màu rực rỡ bùng nổ, xanh lá và biển sâu thẳm, tương phản cao"
        case .sunsetGlow: return "Ấm áp rực rỡ, nhấn mạnh ánh sáng ven vàng ruộm khi hoàng hôn"
        case .tokyoAiry: return "Phong cách Nhật Bản mơ màng, highlight trong trẻo, da mịn màng"
        case .hkCinema90s: return "Shadow xanh ngọc lục bảo (Wong Kar-wai), ánh đèn vàng ấm hoài niệm"
        case .cinestill800T: return "Phim điện ảnh đêm, tone lạnh dịu với quầng ấm quanh ánh đèn"
        case .leicaMonochrom: return "Đen trắng thuần khiết Leica, dải chuyển xám bạc vô cực tinh tế"
        case .monochromeNoir: return "Đen trắng tương phản cao nghệ thuật, bóng đen sâu kịch tính"
        case .triX400: return "Đen trắng phóng sự báo chí, hạt phim rõ nét, giàu cảm xúc đời thường"
        case .vintageWarm: return "Phong cách retro thập niên 70 hoài niệm, fade nhẹ vùng đen"
        case .streetClassic: return "Màu đường phố sắc nét, micro-contrast cao, chiều sâu khối đanh thép"
        case .nordicCold: return "Tone lạnh Bắc Âu tối giản, khử bão hòa màu nóng, thanh khiết"
        case .ektar100: return "Hạt siêu mịn, sắc đỏ và xanh dương rực rỡ sắc sảo, độ nét cao"
        case .neonCyberpunk: return "Shadow lam tím huyền bí, highlight hồng tím neon viễn tưởng"
        case .aiFullAuto: return "Tự động phân tích và áp dụng preset tối ưu nhất theo thời gian thực"
        }
    }

    public var idealScenario: String {
        switch self {
        case .standard: return "Mọi cảnh chụp cần độ chân thực tuyệt đối của cảm biến"
        case .fujiPro400H: return "Chân dung ban ngày, ngoài trời, cafe, hoa cỏ, trang phục sáng màu"
        case .kodakPortra400: return "Chân dung nắng chiều, khoảnh khắc gia đình, ấm cúng hoài niệm"
        case .classicChrome: return "Ảnh tài liệu, phố cổ, kiến trúc cổ điển, đời sống sinh hoạt"
        case .cinemaTealOrange: return "Du lịch, biển đảo, bầu trời xanh, đô thị hiện đại kịch tính"
        case .velvia50: return "Phong cảnh núi non hùng vĩ, mây trời, biển xanh ngắt, thiên nhiên hoa lá"
        case .sunsetGlow: return "Hoàng hôn, bình minh, chiều tà, ngược sáng ven tóc (rim light)"
        case .tokyoAiry: return "Nàng thơ học đường, thời trang nhẹ nhàng, hoa anh đào, không gian tĩnh lặng"
        case .hkCinema90s: return "Quán ăn đêm, phố hoa đèn màu, ngõ hẻm retro, chân dung tâm trạng"
        case .cinestill800T: return "Đêm thành phố, trạm xăng, biển hiệu neon, ánh sáng đèn đường vàng"
        case .leicaMonochrom: return "Chân dung nghệ thuật có chiều sâu, ảnh đặc tả cảm xúc, chi tiết kiến trúc"
        case .monochromeNoir: return "Hình khối kiến trúc tương phản gắt, bóng đổ ấn tượng, tối giản"
        case .triX400: return "Phóng sự đời thường, chuyển động đường phố, khoảnh khắc ngẫu nhiên"
        case .vintageWarm: return "Đồ vật cổ xưa, kỷ niệm, không gian gỗ ấm cúng, ảnh kỷ yếu retro"
        case .streetClassic: return "Nhiếp ảnh đường phố snap, con người lao động, nhịp sống đô thị sôi động"
        case .nordicCold: return "Ngày âm u nhiều mây, mùa đông tuyết, sương mù, nội thất tối giản"
        case .ektar100: return "Thời trang cao cấp, xe cộ, kiến trúc hiện đại sắc sảo, đồ ăn hấp dẫn"
        case .neonCyberpunk: return "Đêm mưa ướt phản chiếu ánh đèn, cyberpunk, bar pub ngập ánh sáng neon"
        case .aiFullAuto: return "Tự động nhận diện bối cảnh và kích hoạt preset tốt nhất"
        }
    }

    public var isAIFullAuto: Bool { self == .aiFullAuto }

    /// Danh sách các preset có thể lựa chọn thủ công (loại trừ .aiFullAuto)
    public static var selectablePresets: [FilmPreset] {
        return allCases.filter { !$0.isAIFullAuto }
    }

    /// Chuỗi catalog mô tả đầy đủ để gửi vào Prompt cho AI
    public static var aiCatalogDescription: String {
        var catalog = "DANH MỤC 18 BỘ MÀU FILM CÓ SẴN (Hãy chọn chính xác 1 preset ID phù hợp nhất):\n"
        for p in selectablePresets {
            catalog += "- \"\(p.rawValue)\": \(p.displayName) — \(p.description). Tối ưu cho: \(p.idealScenario)\n"
        }
        return catalog
    }

    /// Khôi phục an toàn preset từ chuỗi trả về của AI
    public static func match(from rawInput: String) -> FilmPreset? {
        let clean = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in selectablePresets {
            if clean == p.rawValue.lowercased() || clean.contains(p.rawValue.lowercased()) {
                return p
            }
            if clean == p.displayName.lowercased() || clean.contains(p.displayName.lowercased()) {
                return p
            }
            if clean == p.shortTitle.lowercased() {
                return p
            }
        }
        // Match theo từ khóa ngữ nghĩa
        if clean.contains("fuji") && clean.contains("pastel") { return .fujiPro400H }
        if clean.contains("portra") || clean.contains("am ap") || clean.contains("ấm") { return .kodakPortra400 }
        if clean.contains("chrome") || clean.contains("tai lieu") || clean.contains("tài liệu") { return .classicChrome }
        if clean.contains("velvia") || clean.contains("ruc ro") || clean.contains("rực rỡ") { return .velvia50 }
        if clean.contains("teal") || clean.contains("dien anh") || clean.contains("điện ảnh") { return .cinemaTealOrange }
        if clean.contains("sunset") || clean.contains("hoang hon") || clean.contains("hoàng hôn") { return .sunsetGlow }
        if clean.contains("tokyo") || clean.contains("airy") || clean.contains("mo mang") || clean.contains("mơ màng") { return .tokyoAiry }
        if clean.contains("hk") || clean.contains("hong kong") || clean.contains("wong kar") || clean.contains("vuong gia ve") { return .hkCinema90s }
        if clean.contains("cinestill") || clean.contains("800t") || clean.contains("tungsten") { return .cinestill800T }
        if clean.contains("leica") || clean.contains("monochrom") { return .leicaMonochrom }
        if clean.contains("noir") || clean.contains("tuong phan") || clean.contains("tương phản") { return .monochromeNoir }
        if clean.contains("trix") || clean.contains("tri-x") || clean.contains("phong su") || clean.contains("phóng sự") { return .triX400 }
        if clean.contains("vintage") || clean.contains("70s") || clean.contains("hoai niem") || clean.contains("hoài niệm") { return .vintageWarm }
        if clean.contains("street") || clean.contains("duong pho") || clean.contains("đường phố") { return .streetClassic }
        if clean.contains("nordic") || clean.contains("bac au") || clean.contains("bắc âu") || clean.contains("lanh") { return .nordicCold }
        if clean.contains("ektar") || clean.contains("sac net") || clean.contains("sắc nét") { return .ektar100 }
        if clean.contains("cyber") || clean.contains("neon") || clean.contains("tuong lai") || clean.contains("tương lai") { return .neonCyberpunk }
        if clean.contains("standard") || clean.contains("tu nhien") || clean.contains("tự nhiên") { return .standard }
        return nil
    }
}

// MARK: - Captured Photo Item
public struct CapturedPhotoItem: Identifiable {
    public let id: UUID = UUID()
    public let originalImage: CGImage
    public let processedImage: CGImage
    public let rawPhotoData: Data?
    public let livePhotoMovieURL: URL?
    public let sceneType: DetectedSceneType
    public let appliedPreset: FilmPreset
    public let compositionRule: CompositionRule
    public let alignmentScore: Double
    public let timestamp: Date
    public let iso: Float
    public let shutterSpeed: Double
    public let aiColorParameters: AIColorParameters?

    public var isLivePhoto: Bool {
        return livePhotoMovieURL != nil
    }

    public init(
        originalImage: CGImage,
        processedImage: CGImage,
        rawPhotoData: Data? = nil,
        livePhotoMovieURL: URL? = nil,
        sceneType: DetectedSceneType,
        appliedPreset: FilmPreset,
        compositionRule: CompositionRule,
        alignmentScore: Double,
        timestamp: Date = Date(),
        iso: Float = 100,
        shutterSpeed: Double = 0.016,
        aiColorParameters: AIColorParameters? = nil
    ) {
        self.originalImage = originalImage
        self.processedImage = processedImage
        self.rawPhotoData = rawPhotoData
        self.livePhotoMovieURL = livePhotoMovieURL
        self.sceneType = sceneType
        self.appliedPreset = appliedPreset
        self.compositionRule = compositionRule
        self.alignmentScore = alignmentScore
        self.timestamp = timestamp
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.aiColorParameters = aiColorParameters
    }
}

// MARK: - Subject AI Data Model
public struct SubjectDetectionResult {
    public var faceRectangles: [CGRect] = []
    public var humanBodyPoses: [CGPoint] = []
    public var saliencyPoints: [CGPoint] = []
    public var dominantSubjectRect: CGRect?
    public var primaryEyePosition: CGPoint?
    public var lookingDirection: CGVector = CGVector(dx: 0, dy: 0)
    public var detectedScene: DetectedSceneType = .general
    public var confidence: Float = 0.0
    public var sceneConfidenceMap: [DetectedSceneType: Float] = [:]
    /// Estimated average luminance 0.0-1.0 (for AI exposure correction)
    public var averageLuminance: Float = 0.5
    /// Estimated color temperature (K): 2700 warm ~ 8000 cool
    public var estimatedColorTemp: Float = 5500

    public init() {}
}

// MARK: - Photo Save Format
public enum PhotoSaveFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case dng = "DNG"
    case heif = "HEIF"

    public var id: String { rawValue }
}

// MARK: - Realtime Histogram Data
public struct HistogramBarData: Identifiable {
    public let id: Int
    public var height: CGFloat // 0.05 to 1.0
    public var color: Color

    public init(id: Int, height: CGFloat, color: Color) {
        self.id = id
        self.height = height
        self.color = color
    }
}
