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
public enum DetectedSceneType: String, CaseIterable, Sendable {
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
public enum AIColorGrade: String, Sendable {
    case softwarm = "Soft Warm"
    case coolnatural = "Cool Natural"
    case golden = "Golden Hour"
    case tealOrange = "Teal & Orange"
    case moody = "Dark Moody"
    case vibrant = "Vibrant"
    case classic = "Classic BW"
    case cinematic = "Cinematic Film"
}

public struct AIColorParameters: Sendable {
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

    // Backward-compatible semantic aliases
    public var saturationLevel: CGFloat { saturationBoost }
    public var highlightRecovery: CGFloat { highlightRoll }
    public var vibranceBoost: CGFloat { saturationBoost - 1.0 }

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

// MARK: - Film Preset Categories (11 Nhóm theo Storyboard & Máy ảnh Retro)
public enum FilmPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case trending = "Trending"
    case vintagePhone = "Vintage phone"
    case fuji = "Fuji"
    case vintageCam = "Vintage cam"
    case ccd = "CCD"
    case kodak = "Kodak"
    case ricoh = "Ricoh"
    case canon = "Canon"
    case dv = "DV"
    case instant = "Instant"
    case original = "Original"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var defaultIconSF: String {
        switch self {
        case .trending: return "flame.fill"
        case .vintagePhone: return "phone.fill"
        case .fuji: return "camera.fill"
        case .vintageCam: return "camera.metering.matrix"
        case .ccd: return "camera.aperture"
        case .kodak: return "film.fill"
        case .ricoh: return "viewfinder"
        case .canon: return "camera.viewfinder"
        case .dv: return "video.fill"
        case .instant: return "photo.fill"
        case .original: return "sparkles"
        }
    }

    public var presets: [FilmPreset] {
        FilmPreset.selectablePresets.filter { $0.category == self }
    }
}

// MARK: - Film Simulation Presets (62 Tone Màu Đỉnh Cao)
public enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    // 1. Trending (6 tones)
    case fujiX = "FUJI X"
    case cam1998 = "1998"
    case nokia3310 = "NOKIA"
    case luxury8800 = "8800"
    case kambo = "Kambo"
    case cpm35 = "CPM35"

    // 2. Vintage phone (6 tones)
    case nokiaSymbian = "Nokia Symbian"
    case motorolaV3 = "Motorola V3"
    case iphone3GS = "iPhone 3GS"
    case blackberryQ10 = "Blackberry Q10"
    case keitai88 = "Keitai 88"
    case sonyK800i = "Sony K800"

    // 3. Fuji (6 tones)
    case classicChrome = "Classic Chrome"
    case fujiPro400H = "Fuji Pro 400H"
    case velvia50 = "Fuji Velvia 50"
    case classicNeg = "Classic Neg"
    case astia100F = "Astia 100F"
    case acrosBW = "Neopan Acros"

    // 4. Vintage cam (6 tones)
    case lomoLCA = "LOMO LC-A"
    case medium120LG = "120LG"
    case fxn35 = "FXN 35"
    case toyK = "Toy K"
    case cinestill800T = "CineStill 800T"
    case cam1998Street = "1998 Street"

    // 5. CCD (6 tones)
    case ccd1Cyber = "CCD1"
    case dCcdWarm = "D-CCD"
    case blueSKCool = "BlueSK"
    case mangaCam = "MangaCam"
    case gCcdGold = "G-CCD"
    case instaLiteFlash = "InstaLite"

    // 6. Kodak (6 tones)
    case kodakPortra400 = "Kodak Portra 400"
    case gold200 = "Kodak Gold 200"
    case colorPlus200 = "Kodak ColorPlus"
    case ektar100 = "Kodak Ektar 100"
    case triX400 = "Kodak Tri-X 400"
    case vision3500D = "Kodak 500D"

    // 7. Ricoh (6 tones)
    case grPositive = "GR3 Positive"
    case grHighBW = "GR High-B&W"
    case grFFilm = "GR F"
    case grStreetSnap = "GR Street"
    case caplioR = "Caplio R"
    case thetaDoc = "Theta Doc"

    // 8. Canon (6 tones)
    case powershotG = "PowerShot G"
    case ixusY2K = "Canon IXUS"
    case eos5DClassic = "Canon EOS 5D"
    case sureShot35 = "Canon SureShot"
    case canonF1 = "Canon F-1"
    case powershotPro1 = "Canon Pro1"

    // 9. DV (6 tones)
    case miniDV43 = "MiniDV 4:3"
    case hi8Analog = "Hi8"
    case dcrDVD = "DCR-DVD"
    case dvx10024p = "DVX100"
    case vhscHome = "VHS-C"
    case hdv1080i = "HDV 1080i"

    // 10. Instant (6 tones)
    case polaroid600 = "POLA 600"
    case sx70TimeZero = "SX-70"
    case instaxMini = "MINI 7"
    case instaxWide = "WIDE 300"
    case instaxSquare = "SQ10"
    case polaroidSpectra = "Spectra"

    // 11. Original (2 tones)
    case standard = "Original Clean"
    case studioNatural = "Studio Natural"

    // Legacy Compatibility Cases
    case cinemaTealOrange = "Teal & Orange"
    case sunsetGlow = "Sunset Glow"
    case tokyoAiry = "Tokyo Clean"
    case hkCinema90s = "HK Cinema 90s"
    case leicaMonochrom = "Leica Monochrom"
    case monochromeNoir = "Noir High Contrast"
    case vintageWarm = "Vintage Warm 70s"
    case streetClassic = "Street Classic"
    case nordicCold = "Nordic Minimal"
    case neonCyberpunk = "Cyberpunk Night"
    case aiFullAuto = "AI Full Auto Color"

    public var id: String { rawValue }

    public var category: FilmPresetCategory {
        switch self {
        case .fujiX, .cam1998, .nokia3310, .luxury8800, .kambo, .cpm35, .cinemaTealOrange, .sunsetGlow:
            return .trending
        case .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            return .vintagePhone
        case .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW, .tokyoAiry:
            return .fuji
        case .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street, .vintageWarm:
            return .vintageCam
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash:
            return .ccd
        case .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D:
            return .kodak
        case .grPositive, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc, .streetClassic:
            return .ricoh
        case .powershotG, .ixusY2K, .eos5DClassic, .sureShot35, .canonF1, .powershotPro1:
            return .canon
        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i, .hkCinema90s:
            return .dv
        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra:
            return .instant
        case .standard, .studioNatural, .leicaMonochrom, .monochromeNoir, .nordicCold, .neonCyberpunk, .aiFullAuto:
            return .original
        }
    }

    public var displayName: String {
        switch self {
        case .fujiX: return "Fuji X100"
        case .cam1998: return "1998 Cam"
        case .nokia3310: return "Nokia 3310"
        case .luxury8800: return "Nokia 8800"
        case .kambo: return "Kambo Snap"
        case .cpm35: return "Canon CPM35"

        case .nokiaSymbian: return "Nokia Classic"
        case .motorolaV3: return "Motorola V3"
        case .iphone3GS: return "iPhone 3GS"
        case .blackberryQ10: return "Blackberry"
        case .keitai88: return "Keitai 88"
        case .sonyK800i: return "Sony K800i"

        case .classicChrome: return "Classic Chrome"
        case .fujiPro400H: return "Fuji Pro 400H"
        case .velvia50: return "Velvia 50"
        case .classicNeg: return "Classic Neg"
        case .astia100F: return "Astia 100F"
        case .acrosBW: return "Neopan Acros"

        case .lomoLCA: return "LOMO LC-A"
        case .medium120LG: return "120 Medium"
        case .fxn35: return "Fujica FXN"
        case .toyK: return "Toy Camera"
        case .cinestill800T: return "CineStill 800T"
        case .cam1998Street: return "90s Street"

        case .ccd1Cyber: return "Sony CCD1"
        case .dCcdWarm: return "D-CCD Warm"
        case .blueSKCool: return "BlueSK Cool"
        case .mangaCam: return "MangaCam"
        case .gCcdGold: return "G-CCD Gold"
        case .instaLiteFlash: return "InstaLite"

        case .kodakPortra400: return "Portra 400"
        case .gold200: return "Kodak Gold"
        case .colorPlus200: return "ColorPlus"
        case .ektar100: return "Ektar 100"
        case .triX400: return "Tri-X 400"
        case .vision3500D: return "Vision3 500D"

        case .grPositive: return "GR3 Positive"
        case .grHighBW: return "GR High B&W"
        case .grFFilm: return "Ricoh GR1"
        case .grStreetSnap: return "GR Street"
        case .caplioR: return "Caplio R"
        case .thetaDoc: return "Ricoh Doc"

        case .powershotG: return "PowerShot G"
        case .ixusY2K: return "Canon IXUS"
        case .eos5DClassic: return "EOS 5D"
        case .sureShot35: return "SureShot 35"
        case .canonF1: return "Canon F-1"
        case .powershotPro1: return "PowerShot Pro"

        case .miniDV43: return "MiniDV 4:3"
        case .hi8Analog: return "Hi8 Analog"
        case .dcrDVD: return "DCR-DVD"
        case .dvx10024p: return "DVX100 24p"
        case .vhscHome: return "VHS-C Home"
        case .hdv1080i: return "HDV 1080i"

        case .polaroid600: return "Polaroid 600"
        case .sx70TimeZero: return "SX-70 Time"
        case .instaxMini: return "Instax Mini"
        case .instaxWide: return "Instax Wide"
        case .instaxSquare: return "Instax Square"
        case .polaroidSpectra: return "Spectra"

        case .standard: return "Tự nhiên"
        case .studioNatural: return "Studio Natural"

        case .cinemaTealOrange: return "Điện ảnh Teal"
        case .sunsetGlow: return "Hoàng hôn Vàng"
        case .tokyoAiry: return "Tokyo Mơ màng"
        case .hkCinema90s: return "Hồng Kông 90s"
        case .leicaMonochrom: return "Leica Đen trắng"
        case .monochromeNoir: return "Noir Tương phản"
        case .vintageWarm: return "Hoài niệm 70s"
        case .streetClassic: return "Đường phố Pro"
        case .nordicCold: return "Bắc Âu Lạnh"
        case .neonCyberpunk: return "Cyberpunk Đêm"
        case .aiFullAuto: return "Tự động AI"
        }
    }

    public var shortTitle: String {
        switch self {
        case .fujiX: return "FUJI X"
        case .cam1998: return "1998"
        case .nokia3310: return "3310"
        case .luxury8800: return "8800"
        case .kambo: return "KAMBO"
        case .cpm35: return "CPM35"

        case .nokiaSymbian: return "NOKIA"
        case .motorolaV3: return "RAZR"
        case .iphone3GS: return "3GS"
        case .blackberryQ10: return "Q10"
        case .keitai88: return "KEITAI"
        case .sonyK800i: return "K800"

        case .classicChrome: return "CHROME"
        case .fujiPro400H: return "PRO400H"
        case .velvia50: return "VELVIA"
        case .classicNeg: return "CLS NEG"
        case .astia100F: return "ASTIA"
        case .acrosBW: return "ACROS"

        case .lomoLCA: return "LOMO"
        case .medium120LG: return "120LG"
        case .fxn35: return "FXN"
        case .toyK: return "TOY K"
        case .cinestill800T: return "CINE800"
        case .cam1998Street: return "90S CAM"

        case .ccd1Cyber: return "CCD1"
        case .dCcdWarm: return "D-CCD"
        case .blueSKCool: return "BLUESK"
        case .mangaCam: return "MANGA"
        case .gCcdGold: return "G-CCD"
        case .instaLiteFlash: return "FLASH"

        case .kodakPortra400: return "PORTRA"
        case .gold200: return "GOLD200"
        case .colorPlus200: return "CLRPLUS"
        case .ektar100: return "EKTAR"
        case .triX400: return "TRI-X"
        case .vision3500D: return "500D"

        case .grPositive: return "GR POS"
        case .grHighBW: return "GR B&W"
        case .grFFilm: return "GR1"
        case .grStreetSnap: return "SNAP"
        case .caplioR: return "CAPLIO"
        case .thetaDoc: return "DOC"

        case .powershotG: return "CANON G"
        case .ixusY2K: return "IXUS"
        case .eos5DClassic: return "EOS 5D"
        case .sureShot35: return "SURE"
        case .canonF1: return "F-1"
        case .powershotPro1: return "PRO1"

        case .miniDV43: return "MINIDV"
        case .hi8Analog: return "HI8"
        case .dcrDVD: return "DCR"
        case .dvx10024p: return "DVX"
        case .vhscHome: return "VHS-C"
        case .hdv1080i: return "HDV"

        case .polaroid600: return "POLA"
        case .sx70TimeZero: return "SX-70"
        case .instaxMini: return "MINI 7"
        case .instaxWide: return "WIDE300"
        case .instaxSquare: return "SQ10"
        case .polaroidSpectra: return "SPECTRA"

        case .standard: return "RAW"
        case .studioNatural: return "STUDIO"

        case .cinemaTealOrange: return "TEAL"
        case .sunsetGlow: return "HOÀNG HÔN"
        case .tokyoAiry: return "TOKYO"
        case .hkCinema90s: return "HK 90S"
        case .leicaMonochrom: return "LEICA"
        case .monochromeNoir: return "NOIR"
        case .vintageWarm: return "70S"
        case .streetClassic: return "STREET"
        case .nordicCold: return "BẮC ÂU"
        case .neonCyberpunk: return "CYBER"
        case .aiFullAuto: return "TỰ ĐỘNG"
        }
    }

    public var deviceBadge: String {
        switch category {
        case .trending: return "TREND"
        case .vintagePhone: return "PHONE"
        case .fuji: return "FUJI"
        case .vintageCam: return "CAM"
        case .ccd: return "CCD"
        case .kodak: return "KODAK"
        case .ricoh: return "RICOH"
        case .canon: return "CANON"
        case .dv: return "DV"
        case .instant: return "INSTANT"
        case .original: return "ORIG"
        }
    }

    public var deviceIconSF: String {
        switch self {
        case .fujiX, .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW:
            return "camera.fill"
        case .nokia3310, .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            return "phone.fill"
        case .cam1998, .luxury8800, .kambo, .cpm35, .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street:
            return "camera.metering.matrix"
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash:
            return "camera.aperture"
        case .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D:
            return "film.fill"
        case .grPositive, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc:
            return "viewfinder"
        case .powershotG, .ixusY2K, .eos5DClassic, .sureShot35, .canonF1, .powershotPro1:
            return "camera.viewfinder"
        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i:
            return "video.fill"
        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra:
            return "photo.fill"
        default:
            return "sparkles"
        }
    }

    public var previewColor: Color {
        switch category {
        case .trending: return Color(red: 1.0, green: 0.65, blue: 0.20)
        case .vintagePhone: return Color(red: 0.60, green: 0.70, blue: 0.85)
        case .fuji: return Color(red: 0.35, green: 0.75, blue: 0.55)
        case .vintageCam: return Color(red: 0.85, green: 0.55, blue: 0.35)
        case .ccd: return Color(red: 0.40, green: 0.65, blue: 0.95)
        case .kodak: return Color(red: 0.95, green: 0.75, blue: 0.15)
        case .ricoh: return Color(red: 0.80, green: 0.30, blue: 0.30)
        case .canon: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .dv: return Color(red: 0.45, green: 0.50, blue: 0.60)
        case .instant: return Color(red: 0.40, green: 0.80, blue: 0.85)
        case .original: return Color.white.opacity(0.85)
        }
    }

    public var description: String {
        switch self {
        case .fujiX: return "Phong cách Fujifilm X100V tôn da trắng sáng, shadow đằm thắm"
        case .cam1998: return "Máy ảnh dùng 1 lần năm 1998, ánh đỏ hoài niệm thập niên 90"
        case .nokia3310: return "Chất lo-fi điện thoại phím bấm những năm 2000"
        case .luxury8800: return "Tông kim loại vàng ấm sang trọng, tương phản đầm ấm"
        case .kambo: return "Máy ảnh đồ chơi Nhật Bản, trong trẻo, ánh cam ấm áp"
        case .cpm35: return "Canon SureShot 35mm đậm chất du lịch đời thường"

        case .nokiaSymbian: return "Tông điện thoại cổ điển, hơi ngả vàng/xanh lục dịu"
        case .motorolaV3: return "Motorola Razr V3 nắp gập huyền thoại Y2K"
        case .iphone3GS: return "Tông màu ấm dịu dàng, hạt nhẹ, hoài niệm smartphone 2009"
        case .blackberryQ10: return "Tông màu doanh nhân lạnh, shadow sâu, độ nét cao"
        case .keitai88: return "Điện thoại gập Nhật Bản, tone mơ màng, da trắng sứ"
        case .sonyK800i: return "Cyber-shot K800i chân thực, hơi ấm, chi tiết tốt"

        case .classicChrome: return "Màu phim phóng sự tài liệu, độ bão hòa dịu, shadow đằm thắm"
        case .fujiPro400H: return "Tone xanh pastel nhẹ, tôn da tươi sáng trong trẻo"
        case .velvia50: return "Sắc màu rực rỡ bùng nổ, xanh lá và biển sâu thẳm"
        case .classicNeg: return "Fujifilm Superia hoài niệm đường phố Nhật Bản"
        case .astia100F: return "Tông chân dung dịu nhẹ, chuyển vùng sáng tối êm ái"
        case .acrosBW: return "Đen trắng sâu thẳm với độ chuyển xám bạc tinh tế"

        case .lomoLCA: return "Lomography LC-A, tối 4 góc mạnh, bão hòa rực rỡ ngẫu hứng"
        case .medium120LG: return "Diana/Holga 120 Medium Format mơ màng mờ ảo"
        case .fxn35: return "Fujica 35mm Rangefinder, màu phim thập niên 70 sắc nét"
        case .toyK: return "Toy Camera ống kính nhựa biến ảo, ấm áp dịu dàng"
        case .cinestill800T: return "Phim điện ảnh đêm, tone lạnh với quầng ấm quanh đèn"
        case .cam1998Street: return "Màu máy cơ bỏ túi thập niên 90 đường phố"

        case .ccd1Cyber: return "Sony Cyber-shot CCD 2000s, da mượt, trời trong"
        case .dCcdWarm: return "Digicam CCD ấm, chụp tiệc với flash trực tiếp hoài cổ"
        case .blueSKCool: return "CCD tone lạnh Bắc Âu, highlight sáng rực rỡ"
        case .mangaCam: return "Cảm biến CCD phong cách Anime Nhật Bản, da sáng hồng"
        case .gCcdGold: return "Bắt sáng hoàng hôn rực rỡ, sắc cam vàng đượm"
        case .instaLiteFlash: return "Y2K Party Flash CCD, tương phản gắt thời thượng"

        case .kodakPortra400: return "Sắc ấm vàng dịu, chuyển màu highlight và da cực mượt mà"
        case .gold200: return "Kodak Gold 200, sắc nắng hè vàng óng ả, hạt film mịn"
        case .colorPlus200: return "Kodak ColorPlus, tone phim bình dân hoài cổ kinh điển"
        case .ektar100: return "Hạt siêu mịn, sắc đỏ và xanh dương rực rỡ sắc sảo"
        case .triX400: return "Đen trắng phóng sự báo chí, hạt phim rõ nét, cảm xúc"
        case .vision3500D: return "Phim nhựa điện ảnh Hollywood 35mm dải động rộng"

        case .grPositive: return "Ricoh GR III Positive Film, tương phản cao, xanh thẳm"
        case .grHighBW: return "Ricoh GR High Contrast Black & White, kịch tính đường phố"
        case .grFFilm: return "Ricoh GR1 28mm huyền thoại đường phố sắc nét"
        case .grStreetSnap: return "Tối ưu chụp nhanh snapshot đường phố, shadow sâu"
        case .caplioR: return "Digicam Ricoh đời đầu, chân thực mộc mạc"
        case .thetaDoc: return "Tone phim tài liệu đời thường hoài niệm"

        case .powershotG: return "Canon PowerShot G7/G9 CCD cao cấp, da hồng hào"
        case .ixusY2K: return "Canon IXY/IXUS Digicam bỏ túi thời thượng, da sáng"
        case .eos5DClassic: return "Canon 5D 'Queen' Fullframe, màu da kinh điển bất hủ"
        case .sureShot35: return "Canon Autoboy/SureShot ngắm chụp gia đình vui tươi"
        case .canonF1: return "Máy cơ chuyên nghiệp truyền thống, màu sắc chuẩn mực"
        case .powershotPro1: return "Ống kính viền đỏ L trên cảm biến CCD"

        case .miniDV43: return "Sony MiniDV Handycam, màu băng từ những năm 2000"
        case .hi8Analog: return "Video analog gia đình thập niên 90, mộc mạc ấm áp"
        case .dcrDVD: return "Màu đĩa quang DVD gia đình rực rỡ tươi sáng"
        case .dvx10024p: return "Panasonic DVX100, màu phim độc lập indie 24fps"
        case .vhscHome: return "Video gia đình thập niên 80-90, ấm áp gần gũi"
        case .hdv1080i: return "Băng từ độ nét cao truyền hình thập niên 2000"

        case .polaroid600: return "Polaroid 600 Vintage, tương phản cao, hạt to retro"
        case .sx70TimeZero: return "Polaroid SX-70 màu ấm nghệ thuật, highlight vàng bơ"
        case .instaxMini: return "Fujifilm Instax Mini tươi sáng, da trắng hồng, viền mềm"
        case .instaxWide: return "Fujifilm Instax Wide góc rộng trong trẻo tự nhiên"
        case .instaxSquare: return "Fujifilm Instax SQ vuông vức hiện đại, màu cân bằng"
        case .polaroidSpectra: return "Polaroid Spectra khung hình rộng, màu đằm thắm"

        case .standard: return "Màu thực tế trung thực, dải sáng tối đa"
        case .studioNatural: return "Tối ưu dải tương phản tự nhiên nhẹ nhàng"

        case .cinemaTealOrange: return "Tương phản điện ảnh Hollywood, teal đối lập da ấm"
        case .sunsetGlow: return "Ấm áp rực rỡ, nhấn mạnh ánh sáng ven vàng ruộm"
        case .tokyoAiry: return "Phong cách Nhật Bản mơ màng, highlight trong trẻo"
        case .hkCinema90s: return "Shadow ngọc lục bảo, ánh đèn vàng ấm Wong Kar-wai"
        case .leicaMonochrom: return "Đen trắng thuần khiết Leica, dải xám bạc vô cực"
        case .monochromeNoir: return "Đen trắng tương phản cao nghệ thuật, bóng đen sâu"
        case .vintageWarm: return "Phong cách retro thập niên 70 hoài niệm"
        case .streetClassic: return "Màu đường phố sắc nét, micro-contrast cao"
        case .nordicCold: return "Tone lạnh Bắc Âu tối giản, khử bão hòa màu nóng"
        case .neonCyberpunk: return "Shadow lam tím huyền bí, highlight hồng tím neon"
        case .aiFullAuto: return "Tự động phân tích và áp dụng preset tối ưu"
        }
    }

    public var idealScenario: String {
        switch self {
        case .fujiX, .classicChrome, .classicNeg: return "Đường phố, cafe, kiến trúc cổ, đời sống sinh hoạt"
        case .fujiPro400H, .astia100F, .kodakPortra400, .eos5DClassic, .powershotG: return "Chân dung ban ngày, ngoài trời, cafe, hoa cỏ, da sáng"
        case .cam1998, .vintageWarm, .toyK, .colorPlus200: return "Kỷ niệm, bạn bè, du lịch hoài niệm thập niên 90"
        case .nokia3310, .nokiaSymbian, .motorolaV3, .iphone3GS, .keitai88, .sonyK800i: return "Chụp snapshot vui nhộn Y2K, trang phục retro, tiệc bạn bè"
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash, .ixusY2K: return "Digicam tiệc đêm, flash trực tiếp, chụp gương, thời trang Y2K"
        case .velvia50, .gold200, .ektar100, .grPositive: return "Phong cảnh núi non hùng vĩ, mây trời, biển xanh rực rỡ"
        case .triX400, .acrosBW, .grHighBW, .leicaMonochrom, .monochromeNoir: return "Đen trắng nghệ thuật, biểu cảm khuôn mặt, bóng đổ kịch tính"
        case .cinestill800T, .neonCyberpunk, .hkCinema90s: return "Đêm thành phố, trạm xăng, biển hiệu neon, ánh sáng đèn đường"
        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i: return "Video retro, khoảnh khắc gia đình, du lịch vintage"
        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra: return "Ảnh kỷ niệm lấy liền, sinh nhật, dã ngoại, khoảnh khắc gần gũi"
        default: return "Mọi cảnh chụp cần chất lượng chân thực hoặc tự động AI"
        }
    }

    public var isAIFullAuto: Bool { self == .aiFullAuto }

    // MARK: - Live Viewfinder Simulation Properties (Zero-Latency GPU Composition)
    public var isMonochrome: Bool {
        switch self {
        case .acrosBW, .triX400, .leicaMonochrom, .monochromeNoir, .grHighBW:
            return true
        default:
            return false
        }
    }

    public var liveSaturation: Double {
        if isMonochrome { return 0.0 }
        switch category {
        case .trending:
            switch self {
            case .fujiX: return 0.94
            case .cam1998: return 1.02
            case .nokia3310: return 0.78
            case .luxury8800: return 0.94
            case .kambo: return 1.04
            case .cpm35: return 0.98
            default: return 0.96
            }
        case .vintagePhone:
            switch self {
            case .iphone3GS: return 0.95
            case .motorolaV3: return 0.90
            default: return 0.86
            }
        case .fuji:
            switch self {
            case .velvia50: return 1.08
            case .classicChrome: return 0.82
            case .classicNeg: return 0.90
            case .fujiPro400H: return 0.92
            case .astia100F: return 0.95
            default: return 0.92
            }
        case .vintageCam:
            switch self {
            case .lomoLCA: return 1.06
            case .toyK: return 1.02
            case .cinestill800T: return 0.96
            default: return 0.98
            }
        case .ccd:
            switch self {
            case .mangaCam: return 1.02
            case .gCcdGold: return 1.04
            default: return 0.98
            }
        case .kodak:
            switch self {
            case .kodakPortra400: return 0.94
            case .gold200: return 1.02
            case .colorPlus200: return 0.98
            case .ektar100: return 1.06
            case .vision3500D: return 0.95
            default: return 0.98
            }
        case .ricoh:
            switch self {
            case .grPositive: return 1.06
            case .grFFilm: return 0.96
            case .grStreetSnap: return 0.98
            default: return 0.96
            }
        case .canon:
            switch self {
            case .eos5DClassic: return 0.96
            case .powershotG: return 1.02
            case .ixusY2K: return 1.00
            default: return 0.98
            }
        case .dv:
            return 0.92
        case .instant:
            return 0.88
        case .original:
            return 1.0
        }
    }

    public var liveContrast: Double {
        switch self {
        case .monochromeNoir, .grHighBW: return 1.25
        case .acrosBW, .triX400, .leicaMonochrom: return 1.15
        case .lomoLCA: return 1.08
        case .grPositive, .velvia50: return 1.08
        case .cam1998, .toyK: return 1.04
        case .nokia3310: return 1.05
        case .standard: return 1.0
        default: return 1.03
        }
    }

    public var liveBrightness: Double {
        switch self {
        case .keitai88, .fujiPro400H: return 0.015
        case .nokia3310: return 0.02
        case .luxury8800: return -0.01
        default: return 0.0
        }
    }

    public var liveTintOverlayColor: Color? {
        if isMonochrome { return nil }
        switch self {
        case .fujiX, .fujiPro400H, .classicNeg:
            return Color(red: 0.38, green: 0.90, blue: 0.78)
        case .gold200, .colorPlus200, .vintageWarm, .luxury8800:
            return Color(red: 1.0, green: 0.82, blue: 0.40)
        case .ccd1Cyber, .blueSKCool, .dCcdWarm:
            return Color(red: 0.25, green: 0.65, blue: 1.0)
        case .nokia3310, .keitai88:
            return Color(red: 0.50, green: 0.85, blue: 0.35)
        case .cinestill800T:
            return Color(red: 0.20, green: 0.60, blue: 0.90)
        case .polaroid600, .sx70TimeZero, .instaxMini:
            return Color(red: 1.0, green: 0.92, blue: 0.78)
        case .miniDV43, .hi8Analog, .vhscHome:
            return Color(red: 0.95, green: 0.80, blue: 0.48)
        case .standard:
            return nil
        default:
            return nil
        }
    }

    public var liveTintOpacity: Double {
        switch self {
        case .nokia3310: return 0.08
        case .gold200, .colorPlus200: return 0.06
        case .ccd1Cyber, .blueSKCool: return 0.05
        case .fujiX, .fujiPro400H: return 0.04
        case .polaroid600, .sx70TimeZero: return 0.05
        case .miniDV43, .hi8Analog, .vhscHome: return 0.05
        default: return 0.03
        }
    }

    public var liveVignetteIntensity: Double {
        switch self {
        case .lomoLCA: return 0.58
        case .toyK: return 0.45
        case .cam1998, .cpm35: return 0.32
        case .polaroid600, .sx70TimeZero: return 0.26
        case .miniDV43, .hi8Analog: return 0.20
        default: return 0.0
        }
    }

    public var hasScanlines: Bool {
        switch self {
        case .miniDV43, .hi8Analog, .vhscHome, .nokia3310:
            return true
        default:
            return false
        }
    }

    /// Danh sách các preset có thể lựa chọn thủ công (loại trừ .aiFullAuto)
    public static var selectablePresets: [FilmPreset] {
        return allCases.filter { !$0.isAIFullAuto }
    }

    /// Chuỗi catalog mô tả đầy đủ để gửi vào Prompt cho AI
    public static var aiCatalogDescription: String {
        var catalog = "DANH MỤC 62 BỘ MÀU FILM & MÁY ẢNH RETRO CÓ SẴN (Hãy chọn chính xác 1 preset ID phù hợp nhất):\n"
        for p in selectablePresets {
            catalog += "- \"\(p.rawValue)\": [\(p.category.rawValue)] \(p.displayName) — \(p.description). Tối ưu cho: \(p.idealScenario)\n"
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
        if clean.contains("fuji x") || clean.contains("x100") { return .fujiX }
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
        if clean.contains("ccd") { return .ccd1Cyber }
        if clean.contains("nokia") || clean.contains("phone") { return .nokia3310 }
        if clean.contains("kodak") || clean.contains("gold") { return .gold200 }
        if clean.contains("ricoh") || clean.contains("gr") { return .grPositive }
        if clean.contains("canon") || clean.contains("ixus") { return .ixusY2K }
        if clean.contains("dv") || clean.contains("camcorder") || clean.contains("vhs") { return .miniDV43 }
        if clean.contains("pola") || clean.contains("polaroid") || clean.contains("instant") { return .polaroid600 }
        if clean.contains("standard") || clean.contains("tu nhien") || clean.contains("tự nhiên") { return .standard }
        return nil
    }
}


// MARK: - Captured Photo Item
public struct CapturedPhotoItem: Identifiable, @unchecked Sendable {
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
public enum PhotoSaveFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case dng = "DNG"
    case heif = "HEIF"

    public var id: String { rawValue }
}

// MARK: - Realtime Histogram Data
public struct HistogramBarData: Identifiable, Equatable, @unchecked Sendable {
    public let id: Int
    public var height: CGFloat // 0.05 to 1.0
    public var color: Color

    public init(id: Int, height: CGFloat, color: Color) {
        self.id = id
        self.height = height
        self.color = color
    }

    public static func == (lhs: HistogramBarData, rhs: HistogramBarData) -> Bool {
        return lhs.id == rhs.id && abs(lhs.height - rhs.height) < 0.001
    }
}
