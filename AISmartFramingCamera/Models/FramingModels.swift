import Foundation
import CoreGraphics
import SwiftUI
import UIKit
import ImageIO

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
            return "\u{2713} Khớp hoàn hảo! Chuẩn bị chụp..."
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
    case semanticLocal(label: String)
    case compositionLocal(label: String)
    case yoloNeural(label: String)
    case appleNeuralEngine(scene: String)

    public var title: String {
        switch self {
        case .geminiCloud(let model):
            let clean = model.replacingOccurrences(of: "google/", with: "")
                .replacingOccurrences(of: "openai/", with: "")
                .replacingOccurrences(of: "anthropic/", with: "")
                .replacingOccurrences(of: "meta-llama/", with: "")
            return "OpenRouter: \(clean)"
        case .compositionLocal(let label):
            return "Charm 2025 + SAMP-Net (\(label))"
        case .semanticLocal(let label):
            return "SigLIP + Vision/YOLO (\(label))"
        case .yoloNeural(let label):
            return "YOLO12 Neural (\(label))"
        case .appleNeuralEngine(let scene):
            return "Apple Neural Engine (\(scene))"
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
        case .compositionLocal:
            return "Charm 2025"
        case .semanticLocal:
            return "SigLIP + Vision"
        case .yoloNeural(let label):
            return "YOLO12 (\(label.uppercased()))"
        case .appleNeuralEngine:
            return "NPU"
        }
    }

    public var iconName: String {
        switch self {
        case .geminiCloud: return "sparkles"
        case .compositionLocal, .semanticLocal: return "brain.head.profile"
        case .yoloNeural: return "bolt.shield.fill"
        case .appleNeuralEngine: return "cpu.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .geminiCloud: return .cyan
        case .compositionLocal, .semanticLocal: return .yellow
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
        case .sunset: return .gold200
        case .architecture: return .classicChrome
        case .sky: return .velvia50
        case .water: return .blueSKCool
        case .foliage: return .fujiPro400H
        case .night: return .cinestill800T
        case .food: return .ektar100
        case .macro: return .fujiPro400H
        case .street: return .grStreetSnap
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

// MARK: - Film Simulation Type (Phan loai ban chat ky thuat / quang hoc)
public enum FilmSimulationType: String, CaseIterable, Identifiable, Sendable {
    case filmEmulsion = "Film Emulsion"           // Mo phong thuoc phim hoa hoc (Portra, Velvia, Ektar, Tri-X, Acros, GR Neg)
    case digitalSensor = "Digital Sensor"         // Mo phong cam bien ky thuat so CCD / CMOS (Sony CCD, Canon IXUS, Caplio)
    case tapeAndBroadcast = "Tape & Broadcast"   // Mo phong bang tu va video quang hoc (MiniDV, Hi8, VHS-C, HDV)
    case instantPrint = "Instant Print"           // Mo phong anh lay lien hoa hoc va ky thuat so (Polaroid 600, Instax)
    case deviceDisplay = "Device Display"         // Mo phong man hinh hien thi (Nokia 3310 LCD ma tran)
    case historicAlternative = "Historic Alternative" // Quy trinh lich su dac thu (Cyanotype, Bleach Bypass)
    case creativeProfile = "Creative Profile"     // Cam hung sang tao tu phong cach / than may (LOMO, Toy K, 1998 Cam)

    public var id: String { rawValue }
}

// MARK: - Film Simulation Presets (65 Tone Mau Tuyen Chon & Legacy Presets)
public enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    // 1. Trending (7 tones)
    case fujiX = "FUJI X"
    case cam1998 = "1998"
    case nokia3310 = "NOKIA"
    case luxury8800 = "8800"
    case kambo = "Kambo"
    case cpm35 = "CPM35"
    case bleachBypass = "Bleach Bypass"

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

    // 4. Vintage cam (7 tones)
    case lomoLCA = "LOMO LC-A"
    case medium120LG = "120LG"
    case fxn35 = "FXN 35"
    case toyK = "Toy K"
    case cinestill800T = "CineStill 800T"
    case cam1998Street = "1998 Street"
    case cyanotype = "Cyanotype"

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

    // 7. Ricoh (7 tones)
    case grPositive = "GR3 Positive"
    case grNegative = "GR Negative"
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
        case .fujiX, .cam1998, .nokia3310, .luxury8800, .kambo, .cpm35, .bleachBypass, .cinemaTealOrange, .sunsetGlow:
            return .trending
        case .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i:
            return .vintagePhone
        case .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW, .tokyoAiry:
            return .fuji
        case .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street, .cyanotype, .vintageWarm:
            return .vintageCam
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash:
            return .ccd
        case .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D:
            return .kodak
        case .grPositive, .grNegative, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc, .streetClassic:
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
        case .nokia3310: return "Nokia 3310 LCD"
        case .luxury8800: return "Nokia 8800"
        case .kambo: return "Kambo Snap"
        case .cpm35: return "Canon CPM35"
        case .bleachBypass: return "Bleach Bypass"

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
        case .cyanotype: return "Cyanotype Print"

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
        case .vision3500D: return "Vision3 250D"

        case .grPositive: return "GR3 Positive"
        case .grNegative: return "GR Negative Film"
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

        case .standard: return "Tu nhien"
        case .studioNatural: return "Studio Natural"

        case .cinemaTealOrange: return "Dien anh Teal"
        case .sunsetGlow: return "Hoang hon Vang"
        case .tokyoAiry: return "Tokyo Mo mang"
        case .hkCinema90s: return "Hong Kong 90s"
        case .leicaMonochrom: return "Leica Den trang"
        case .monochromeNoir: return "Noir Tuong phan"
        case .vintageWarm: return "Hoai niem 70s"
        case .streetClassic: return "Duong pho Pro"
        case .nordicCold: return "Bac Au Lanh"
        case .neonCyberpunk: return "Cyberpunk Dem"
        case .aiFullAuto: return "Tu dong AI"
        }
    }

    public var shortTitle: String {
        switch self {
        case .fujiX: return "FUJI X"
        case .cam1998: return "1998"
        case .nokia3310: return "3310 LCD"
        case .luxury8800: return "8800"
        case .kambo: return "KAMBO"
        case .cpm35: return "CPM35"
        case .bleachBypass: return "BLEACH"

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
        case .cyanotype: return "CYANO"

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
        case .vision3500D: return "250D"

        case .grPositive: return "GR POS"
        case .grNegative: return "GR NEG"
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
        case .sunsetGlow: return "HOANG HON"
        case .tokyoAiry: return "TOKYO"
        case .hkCinema90s: return "HK 90S"
        case .leicaMonochrom: return "LEICA"
        case .monochromeNoir: return "NOIR"
        case .vintageWarm: return "70S"
        case .streetClassic: return "STREET"
        case .nordicCold: return "BAC AU"
        case .neonCyberpunk: return "CYBER"
        case .aiFullAuto: return "TU DONG"
        }
    }

    public var deviceBadge: String {
        switch self {
        case .cyanotype: return "PRINT"
        case .grNegative: return "RICOH"
        case .bleachBypass: return "CINE"
        default:
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
    }

    public var deviceIconSF: String {
        switch self {
        case .cyanotype:
            return "sun.max.fill"
        case .grNegative:
            return "viewfinder"
        case .bleachBypass:
            return "film"
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
        switch self {
        case .cyanotype: return Color(red: 0.18, green: 0.45, blue: 0.72)
        case .bleachBypass: return Color(red: 0.70, green: 0.72, blue: 0.74)
        case .grNegative: return Color(red: 0.35, green: 0.55, blue: 0.52)
        default:
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
    }

    public var description: String {
        switch self {
        case .fujiX: return "Phong cach Fujifilm X-Series ton da sang min, shadow dam tham"
        case .cam1998: return "Cam hung may anh dung 1 lan nam 1998, anh do am ap thap nien 90"
        case .nokia3310: return "Mo phong man hinh ma tran LCD don sac xanh reu cua dien thoai Nokia 3310 (nam 2000)"
        case .luxury8800: return "Tong kim loai vang am sang trong, tuong phan dam am"
        case .kambo: return "May anh do choi Nhat Ban, trong treo, anh cam am ap"
        case .cpm35: return "Cam hung Canon SureShot 35mm dam chat du lich doi thuong"
        case .bleachBypass: return "Ky thuat giu bac dien anh, tuong phan gat, khu bao hoa mau 60% kim loai"

        case .nokiaSymbian: return "Chat anh camera phone Carl Zeiss thoi dau smartphone N-Series"
        case .motorolaV3: return "Motorola Razr V3 nap gap huyen thoai Y2K"
        case .iphone3GS: return "Tong mau am diu dang, hat nhe, hoai niem smartphone 2009"
        case .blackberryQ10: return "Tong mau doanh nhan lanh, shadow sau, do net cao"
        case .keitai88: return "Dien thoai gap Nhat Ban, tone mo mang, da trang su"
        case .sonyK800i: return "Cyber-shot K800i chan thuc, hoi am, chi tiet tot"

        case .classicChrome: return "Mau phim phong su tai lieu, do bao hoa diu, shadow dam tham"
        case .fujiPro400H: return "Tone xanh pastel nhe, ton da tuoi sang trong treo"
        case .velvia50: return "Sac mau ruc ro bung no, xanh la va bien sau tham"
        case .classicNeg: return "Fujifilm Superia hoai niem duong pho Nhat Ban"
        case .astia100F: return "Tong chan dung diu nhe, chuyen vung sang toi em ai"
        case .acrosBW: return "Den trang sau tham voi do chuyen xam bac tinh te"

        case .lomoLCA: return "Cam hung Lomography LC-A, toi 4 goc manh, bao hoa ruc ro ngau hung"
        case .medium120LG: return "Cam hung Diana/Holga 120 Medium Format mo mang mo ao"
        case .fxn35: return "Cam hung Fujica 35mm Rangefinder, mau phim thap nien 70 sac net"
        case .toyK: return "Cam hung Toy Camera thau kinh nhua bien ao, am ap diu dang"
        case .cinestill800T: return "Phim dien anh dem CineStill 800T, quang do halation am ap quanh den"
        case .cam1998Street: return "Phong cach may co bo tui thap nien 90 duong pho"
        case .cyanotype: return "Ban in lich su don sac xanh Pho (Prussian Blue 1842), dai tuong phan muot ma"

        case .ccd1Cyber: return "Sony Cyber-shot CCD 2000s, da muot, troi trong"
        case .dCcdWarm: return "Digicam CCD am, chup tiec voi flash truc tiep hoai co"
        case .blueSKCool: return "CCD tone lanh Bac Au, highlight sang ruc ro"
        case .mangaCam: return "Cam bien CCD phong cach Anime Nhat Ban, da sang hong"
        case .gCcdGold: return "Bat sang hoang hon ruc ro, sac cam vang duom"
        case .instaLiteFlash: return "Y2K Party Flash CCD, tuong phan gat thoi thuong"

        case .kodakPortra400: return "Sac am vang diu, chuyen mau highlight va da cuc muot ma"
        case .gold200: return "Kodak Gold 200, sac nang he vang ong a, hat film min"
        case .colorPlus200: return "Kodak ColorPlus, tone phim binh dan hoai co kinh dien"
        case .ektar100: return "Hat sieu min, sac do va xanh duong ruc ro sac sao"
        case .triX400: return "Den trang phong su bao chi, hat phim ro net, cam xuc"
        case .vision3500D: return "Mo phong phim dien anh Kodak Vision3 250D Daylight, dai sang rong, highlight em diu"

        case .grPositive: return "Ricoh GR III Positive Film, tuong phan cao, xanh tham"
        case .grNegative: return "Mau film am ban duong pho Ricoh GR III, bong sau tham, tuong phan kich tinh"
        case .grHighBW: return "Ricoh GR High Contrast Black & White, kich tinh duong pho"
        case .grFFilm: return "Cam hung Ricoh GR1 28mm huyen thoai duong pho sac net"
        case .grStreetSnap: return "Toi uu chup nhanh snapshot duong pho, shadow sau"
        case .caplioR: return "Digicam Ricoh doi dau, chan thuc moc mac"
        case .thetaDoc: return "Tone phim tai lieu doi thuong hoai niem"

        case .powershotG: return "Canon PowerShot G7/G9 CCD cao cap, da hong hao"
        case .ixusY2K: return "Canon IXY/IXUS Digicam bo tui thoi thuong, da sang"
        case .eos5DClassic: return "Canon 5D 'Queen' Fullframe, mau da kinh dien bat hu"
        case .sureShot35: return "Cam hung Canon Autoboy/SureShot ngam chup gia dinh vui tuoi"
        case .canonF1: return "Cam hung may co chuyen nghiep Canon F-1, mau sac chuan muc"
        case .powershotPro1: return "Ong kinh vien do L tren cam bien CCD"

        case .miniDV43: return "Sony MiniDV Handycam, mau bang tu nhung nam 2000"
        case .hi8Analog: return "Video analog gia dinh thap nien 90, moc mac am ap"
        case .dcrDVD: return "Mau dia quang DVD gia dinh ruc ro tuoi sang"
        case .dvx10024p: return "Panasonic DVX100, mau phim doc lap indie 24fps"
        case .vhscHome: return "Video gia dinh thap nien 80-90, am ap gan gui"
        case .hdv1080i: return "Bang tu do net cao truyen hinh thap nien 2000"

        case .polaroid600: return "Polaroid 600 Vintage, tuong phan cao, hat to retro"
        case .sx70TimeZero: return "Polaroid SX-70 mau am nghe thuat, highlight vang bo"
        case .instaxMini: return "Fujifilm Instax Mini tuoi sang, da trang hong, vien mem"
        case .instaxWide: return "Fujifilm Instax Wide kho rong quang hoc analog tu nhien"
        case .instaxSquare: return "Fujifilm Instax SQ lai ky thuat so, sac net, tuong phan cao"
        case .polaroidSpectra: return "Polaroid Spectra khung hinh rong, mau dam tham"

        case .standard: return "Mau thuc te trung thuc, dai sang toi da"
        case .studioNatural: return "Toi uu dai tuong phan tu nhien nhe nhang"

        case .cinemaTealOrange: return "Tuong phan dien anh Hollywood, teal doi lap da am"
        case .sunsetGlow: return "Am ap ruc ro, nhan manh anh sang ven vang ruom"
        case .tokyoAiry: return "Phong cach Nhat Ban mo mang, highlight trong treo"
        case .hkCinema90s: return "Shadow ngoc luc bao, anh den vang am Wong Kar-wai"
        case .leicaMonochrom: return "Den trang thuan khiet Leica, dai xam bac vo cuc"
        case .monochromeNoir: return "Den trang tuong phan cao nghe thuat, bong den sau"
        case .vintageWarm: return "Phong cach retro thap nien 70 hoai niem"
        case .streetClassic: return "Mau duong pho sac net, micro-contrast cao"
        case .nordicCold: return "Tone lanh Bac Au toi gian, khu bao hoa mau nong"
        case .neonCyberpunk: return "Shadow lam tim huyen bi, highlight hong tim neon"
        case .aiFullAuto: return "Tu dong phan tich va ap dung preset toi uu"
        }
    }

    public var simulationType: FilmSimulationType {
        switch self {
        case .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW,
             .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D,
             .cinestill800T, .grNegative:
            return .filmEmulsion

        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash,
             .powershotG, .ixusY2K, .eos5DClassic, .powershotPro1, .caplioR, .sonyK800i,
             .iphone3GS, .motorolaV3, .blackberryQ10, .keitai88, .nokiaSymbian, .luxury8800:
            return .digitalSensor

        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i, .hkCinema90s:
            return .tapeAndBroadcast

        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra:
            return .instantPrint

        case .nokia3310:
            return .deviceDisplay

        case .cyanotype, .bleachBypass:
            return .historicAlternative

        case .fujiX, .cam1998, .kambo, .cpm35, .lomoLCA, .medium120LG, .fxn35, .toyK,
             .cam1998Street, .grPositive, .grHighBW, .grFFilm, .grStreetSnap, .thetaDoc,
             .sureShot35, .canonF1, .cinemaTealOrange, .sunsetGlow, .tokyoAiry,
             .leicaMonochrom, .monochromeNoir, .vintageWarm, .streetClassic, .nordicCold,
             .neonCyberpunk, .standard, .studioNatural, .aiFullAuto:
            return .creativeProfile
        }
    }

    public var idealScenario: String {
        switch self {
        case .fujiX, .classicChrome, .classicNeg: return "Duong pho, cafe, kien truc co, doi song sinh hoat"
        case .fujiPro400H, .astia100F, .kodakPortra400, .eos5DClassic, .powershotG: return "Chan dung ban ngay, ngoai troi, cafe, hoa co, da sang"
        case .cam1998, .vintageWarm, .toyK, .colorPlus200: return "Ky niem, ban be, du lich hoai niem thap nien 90"
        case .nokia3310, .nokiaSymbian, .motorolaV3, .iphone3GS, .keitai88, .sonyK800i: return "Chup snapshot vui nhon Y2K, trang phuc retro, tiec ban be"
        case .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash, .ixusY2K: return "Digicam tiec dem, flash truc tiep, chup guong, thoi trang Y2K"
        case .velvia50, .gold200, .ektar100, .grPositive: return "Phong canh nui non hung vi, may troi, bien xanh ruc ro"
        case .triX400, .acrosBW, .grHighBW, .leicaMonochrom, .monochromeNoir, .cyanotype: return "Den trang nghe thuat, bieu cam khuon mat, bong do kich tinh"
        case .cinestill800T, .neonCyberpunk, .hkCinema90s, .bleachBypass: return "Dem thanh pho, tram xang, bien hieu neon, anh sang den duong"
        case .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i: return "Video retro, khoanh khac gia dinh, du lich vintage"
        case .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra: return "Anh ky niem lay lien, sinh nhat, da ngoai, khoanh khac gan gui"
        case .grNegative, .grStreetSnap: return "Khoanh khac duong pho chieu toi, doc hanh, phan chieu mat nuoc"
        default: return "Moi canh chup can chat luong chan thuc hoac tu dong AI"
        }
    }

    public var isAIFullAuto: Bool { self == .aiFullAuto }

    // MARK: - Live Viewfinder Simulation Properties (Zero-Latency GPU Composition)
    public var isMonochrome: Bool {
        switch self {
        case .acrosBW, .triX400, .leicaMonochrom, .monochromeNoir, .grHighBW, .cyanotype:
            return true
        default:
            return false
        }
    }

    public var liveSaturation: Double {
        if isMonochrome { return 0.0 }
        switch self {
        case .bleachBypass: return 0.40
        case .grNegative: return 0.92
        default:
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
                case .kodakPortra400: return 0.98
                case .gold200: return 1.08
                case .colorPlus200: return 1.07
                case .ektar100: return 1.18
                case .vision3500D: return 1.02
                default: return 0.98
                }
            case .ricoh:
                switch self {
                case .grPositive: return 1.18
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
                return 0.94
            case .instant:
                return 0.92
            case .original:
                return 1.0
            }
        }
    }

    public var liveContrast: Double {
        switch self {
        case .monochromeNoir, .grHighBW: return 1.30
        case .bleachBypass: return 1.28
        case .acrosBW, .triX400, .leicaMonochrom, .cyanotype: return 1.18
        case .grNegative: return 1.18
        case .grPositive, .velvia50: return 1.14
        case .lomoLCA: return 1.08
        case .cam1998, .toyK, .colorPlus200: return 1.08
        case .nokia3310: return 1.10
        case .kodakPortra400: return 1.03
        case .standard: return 1.0
        default: return 1.04
        }
    }

    public var liveBrightness: Double {
        switch self {
        case .keitai88, .fujiPro400H: return 0.015
        case .nokia3310: return 0.02
        case .luxury8800: return -0.01
        case .bleachBypass: return -0.01
        default: return 0.0
        }
    }

    public var liveTintOverlayColor: Color? {
        if isMonochrome && self != .cyanotype { return nil }
        switch self {
        case .cyanotype:
            return Color(red: 0.18, green: 0.45, blue: 0.72)
        case .grNegative:
            return Color(red: 0.20, green: 0.50, blue: 0.55)
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
        case .cyanotype: return 0.14
        case .nokia3310: return 0.08
        case .gold200, .colorPlus200: return 0.06
        case .ccd1Cyber, .blueSKCool: return 0.05
        case .fujiX, .fujiPro400H: return 0.04
        case .grNegative: return 0.04
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
        case .bleachBypass: return 0.28
        case .grNegative: return 0.26
        case .polaroid600, .sx70TimeZero, .cyanotype: return 0.25
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

    /// Danh muc cac preset mau chinh thuc tuyen chon (65 tones phan bo can xung 11 nhom)
    public static let mainCuratedPresets: [FilmPreset] = [
        // 1. Trending (7)
        .fujiX, .cam1998, .nokia3310, .luxury8800, .kambo, .cpm35, .bleachBypass,
        // 2. Vintage phone (6)
        .nokiaSymbian, .motorolaV3, .iphone3GS, .blackberryQ10, .keitai88, .sonyK800i,
        // 3. Fuji (6)
        .classicChrome, .fujiPro400H, .velvia50, .classicNeg, .astia100F, .acrosBW,
        // 4. Vintage cam (7)
        .lomoLCA, .medium120LG, .fxn35, .toyK, .cinestill800T, .cam1998Street, .cyanotype,
        // 5. CCD (6)
        .ccd1Cyber, .dCcdWarm, .blueSKCool, .mangaCam, .gCcdGold, .instaLiteFlash,
        // 6. Kodak (6)
        .kodakPortra400, .gold200, .colorPlus200, .ektar100, .triX400, .vision3500D,
        // 7. Ricoh (7)
        .grPositive, .grNegative, .grHighBW, .grFFilm, .grStreetSnap, .caplioR, .thetaDoc,
        // 8. Canon (6)
        .powershotG, .ixusY2K, .eos5DClassic, .sureShot35, .canonF1, .powershotPro1,
        // 9. DV (6)
        .miniDV43, .hi8Analog, .dcrDVD, .dvx10024p, .vhscHome, .hdv1080i,
        // 10. Instant (6)
        .polaroid600, .sx70TimeZero, .instaxMini, .instaxWide, .instaxSquare, .polaroidSpectra,
        // 11. Original (2)
        .standard, .studioNatural
    ]

    /// Danh muc cac preset legacy dung de tuong thich nguoc du lieu cu va alias AI
    public static let legacyPresets: [FilmPreset] = [
        .cinemaTealOrange, .sunsetGlow, .tokyoAiry, .hkCinema90s,
        .leicaMonochrom, .monochromeNoir, .vintageWarm, .streetClassic,
        .nordicCold, .neonCyberpunk, .aiFullAuto
    ]

    /// Danh sach cac preset co the lua chon thu cong tren giao dien nguoi dung (UI Drawer)
    public static var selectablePresets: [FilmPreset] {
        return mainCuratedPresets
    }

    /// Chuoi catalog mo ta day du gui vao Prompt cho AI voi so dem dong chinh xac
    public static var aiCatalogDescription: String {
        var catalog = "DANH MUC \(selectablePresets.count) BO MAU FILM & MAY ANH RETRO CO SAN (Hay chon chinh xac 1 preset ID phu hop nhat):\n"
        for p in selectablePresets {
            catalog += "- \"\(p.rawValue)\": [\(p.category.rawValue)] \(p.displayName) (\(p.simulationType.rawValue)) - \(p.description). Toi uu cho: \(p.idealScenario)\n"
        }
        return catalog
    }

    /// Khoi phuc an toan preset tu chuoi tra ve cua AI hoac tim kiem voi kien truc 3 tang khong va cham chuoi con
    public static func match(from rawInput: String) -> FilmPreset? {
        let clean = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }

        // Tang 1: Khop chinh xac hoan toan voi rawValue, displayName hoac shortTitle cua tat ca preset (ke ca legacy)
        for p in allCases {
            if clean == p.rawValue.lowercased() || clean == p.displayName.lowercased() || clean == p.shortTitle.lowercased() {
                return p
            }
        }

        // Tang 2: Tu dien alias co chu dich (Tranh tuyet doi va cham giua Nokia Symbian va Nokia 3310, 1998 Street va 1998, v.v.)
        let exactAliases: [String: FilmPreset] = [
            // Nokia 3310 vs Nokia Symbian vs 8800
            "nokia 3310": .nokia3310,
            "3310": .nokia3310,
            "nokia 3310 lcd": .nokia3310,
            "nokia lcd": .nokia3310,
            "3310 lcd": .nokia3310,
            "nokia symbian": .nokiaSymbian,
            "nokia symbian carl zeiss": .nokiaSymbian,
            "nokia n73": .nokiaSymbian,
            "nokia n95": .nokiaSymbian,
            "nokia zeiss": .nokiaSymbian,
            "nokia classic": .nokiaSymbian,
            "nokia 8800": .luxury8800,
            "8800": .luxury8800,
            "luxury 8800": .luxury8800,

            // 1998 Disposable vs 90s Street
            "1998": .cam1998,
            "cam 1998": .cam1998,
            "1998 cam": .cam1998,
            "disposable 1998": .cam1998,
            "1998 street": .cam1998Street,
            "90s street": .cam1998Street,
            "street 1998": .cam1998Street,

            // CCD variations
            "ccd1": .ccd1Cyber,
            "ccd 1": .ccd1Cyber,
            "sony ccd": .ccd1Cyber,
            "sony ccd1": .ccd1Cyber,
            "d-ccd": .dCcdWarm,
            "dccd": .dCcdWarm,
            "d ccd": .dCcdWarm,
            "d-ccd warm": .dCcdWarm,
            "g-ccd": .gCcdGold,
            "gccd": .gCcdGold,
            "g ccd": .gCcdGold,
            "g-ccd gold": .gCcdGold,
            "bluesk": .blueSKCool,
            "blue sk": .blueSKCool,
            "bluesk cool": .blueSKCool,
            "manga": .mangaCam,
            "mangacam": .mangaCam,
            "instalite": .instaLiteFlash,
            "instalite flash": .instaLiteFlash,

            // Kodak
            "kodak 500d": .vision3500D,
            "vision3 500d": .vision3500D,
            "vision3 250d": .vision3500D,
            "vision 250d": .vision3500D,
            "vision3": .vision3500D,
            "kodak 250d": .vision3500D,
            "portra": .kodakPortra400,
            "portra 400": .kodakPortra400,
            "kodak portra": .kodakPortra400,
            "kodak portra 400": .kodakPortra400,
            "colorplus": .colorPlus200,
            "colorplus 200": .colorPlus200,
            "kodak colorplus": .colorPlus200,
            "gold 200": .gold200,
            "kodak gold": .gold200,
            "kodak gold 200": .gold200,
            "ektar": .ektar100,
            "ektar 100": .ektar100,
            "kodak ektar": .ektar100,
            "tri-x": .triX400,
            "tri-x 400": .triX400,
            "trix": .triX400,
            "trix 400": .triX400,

            // Fuji
            "fuji x": .fujiX,
            "fujix": .fujiX,
            "fuji x100": .fujiX,
            "x100": .fujiX,
            "x100v": .fujiX,
            "classic chrome": .classicChrome,
            "pro 400h": .fujiPro400H,
            "fuji pro 400h": .fujiPro400H,
            "pro400h": .fujiPro400H,
            "velvia": .velvia50,
            "velvia 50": .velvia50,
            "fuji velvia": .velvia50,
            "classic neg": .classicNeg,
            "classic negative": .classicNeg,
            "astia": .astia100F,
            "astia 100f": .astia100F,
            "acros": .acrosBW,
            "neopan acros": .acrosBW,

            // Instant & Polaroid
            "instax wide": .instaxWide,
            "instax wide 300": .instaxWide,
            "wide 300": .instaxWide,
            "instax square": .instaxSquare,
            "instax sq10": .instaxSquare,
            "sq10": .instaxSquare,
            "instax mini": .instaxMini,
            "instax mini 7": .instaxMini,
            "mini 7": .instaxMini,
            "pola 600": .polaroid600,
            "polaroid 600": .polaroid600,
            "sx-70": .sx70TimeZero,
            "sx70": .sx70TimeZero,
            "spectra": .polaroidSpectra,

            // Camcorders & DV
            "dcr-dvd": .dcrDVD,
            "dcr dvd": .dcrDVD,
            "hdv 1080i": .hdv1080i,
            "hdv": .hdv1080i,
            "minidv": .miniDV43,
            "minidv 4:3": .miniDV43,
            "hi8": .hi8Analog,
            "hi8 analog": .hi8Analog,
            "dvx100": .dvx10024p,
            "dvx": .dvx10024p,
            "vhs-c": .vhscHome,
            "vhsc": .vhscHome,

            // Ricoh
            "gr positive": .grPositive,
            "gr3 positive": .grPositive,
            "gr negative": .grNegative,
            "gr negative film": .grNegative,
            "gr neg": .grNegative,
            "gr high b&w": .grHighBW,
            "gr b&w": .grHighBW,
            "gr street": .grStreetSnap,
            "gr street snap": .grStreetSnap,
            "gr1": .grFFilm,
            "ricoh gr1": .grFFilm,
            "caplio": .caplioR,
            "caplio r": .caplioR,
            "theta doc": .thetaDoc,

            // Canon
            "powershot g": .powershotG,
            "canon ixus": .ixusY2K,
            "ixus": .ixusY2K,
            "eos 5d": .eos5DClassic,
            "5d": .eos5DClassic,
            "sureshot": .sureShot35,
            "canon f-1": .canonF1,
            "f-1": .canonF1,
            "powershot pro": .powershotPro1,

            // Historic & Creative Additions
            "cyanotype": .cyanotype,
            "cyanotype print": .cyanotype,
            "bleach bypass": .bleachBypass,
            "silver cinema": .bleachBypass,

            // Legacy
            "teal & orange": .cinemaTealOrange,
            "teal orange": .cinemaTealOrange,
            "sunset glow": .sunsetGlow,
            "tokyo clean": .tokyoAiry,
            "tokyo airy": .tokyoAiry,
            "hk cinema": .hkCinema90s,
            "hk cinema 90s": .hkCinema90s,
            "leica monochrom": .leicaMonochrom,
            "noir high contrast": .monochromeNoir,
            "vintage warm 70s": .vintageWarm,
            "street classic": .streetClassic,
            "nordic minimal": .nordicCold,
            "cyberpunk night": .neonCyberpunk,
            "ai full auto color": .aiFullAuto
        ]

        if let direct = exactAliases[clean] {
            return direct
        }

        // Tang 3: Phan tich tu khoa ngu nghia uu tien cac tu khoa dai va dac thu nhat truoc
        let semanticRules: [(keyword: String, preset: FilmPreset)] = [
            ("nokia symbian", .nokiaSymbian),
            ("carl zeiss", .nokiaSymbian),
            ("nokia 8800", .luxury8800),
            ("nokia 3310", .nokia3310),
            ("nokia lcd", .nokia3310),
            ("1998 street", .cam1998Street),
            ("90s street", .cam1998Street),
            ("1998 cam", .cam1998),
            ("disposable 1998", .cam1998),
            ("gr negative", .grNegative),
            ("gr positive", .grPositive),
            ("gr high b&w", .grHighBW),
            ("gr street", .grStreetSnap),
            ("cyanotype", .cyanotype),
            ("bleach bypass", .bleachBypass),
            ("cinestill 800t", .cinestill800T),
            ("cinestill", .cinestill800T),
            ("800t", .cinestill800T),
            ("vision3 250d", .vision3500D),
            ("vision3", .vision3500D),
            ("500d", .vision3500D),
            ("portra 400", .kodakPortra400),
            ("portra", .kodakPortra400),
            ("colorplus 200", .colorPlus200),
            ("colorplus", .colorPlus200),
            ("gold 200", .gold200),
            ("ektar 100", .ektar100),
            ("tri-x 400", .triX400),
            ("tri-x", .triX400),
            ("trix", .triX400),
            ("classic chrome", .classicChrome),
            ("classic neg", .classicNeg),
            ("pro 400h", .fujiPro400H),
            ("velvia 50", .velvia50),
            ("velvia", .velvia50),
            ("astia 100f", .astia100F),
            ("astia", .astia100F),
            ("neopan acros", .acrosBW),
            ("acros", .acrosBW),
            ("instax wide", .instaxWide),
            ("wide 300", .instaxWide),
            ("instax square", .instaxSquare),
            ("sq10", .instaxSquare),
            ("instax mini", .instaxMini),
            ("polaroid 600", .polaroid600),
            ("sx-70", .sx70TimeZero),
            ("powershot g", .powershotG),
            ("canon ixus", .ixusY2K),
            ("eos 5d", .eos5DClassic),
            ("dcr-dvd", .dcrDVD),
            ("hdv 1080i", .hdv1080i),
            ("minidv", .miniDV43),
            ("hi8", .hi8Analog),
            ("vhs-c", .vhscHome),
            ("dvx100", .dvx10024p),
            ("d-ccd", .dCcdWarm),
            ("g-ccd", .gCcdGold),
            ("bluesk", .blueSKCool),
            ("manga", .mangaCam),
            ("instalite", .instaLiteFlash),
            ("fuji x", .fujiX),
            ("x100", .fujiX),
            ("motorola v3", .motorolaV3),
            ("razr", .motorolaV3),
            ("iphone 3gs", .iphone3GS),
            ("blackberry", .blackberryQ10),
            ("sony k800", .sonyK800i),
            ("keitai", .keitai88),
            ("lomo", .lomoLCA),
            ("holga", .medium120LG),
            ("120lg", .medium120LG),
            ("hong kong", .hkCinema90s),
            ("wong kar", .hkCinema90s),
            ("teal & orange", .cinemaTealOrange),
            ("teal orange", .cinemaTealOrange),
            ("sunset", .sunsetGlow),
            ("tokyo", .tokyoAiry),
            ("leica", .leicaMonochrom),
            ("cyberpunk", .neonCyberpunk),
            ("nordic", .nordicCold)
        ]

        for rule in semanticRules {
            if clean.contains(rule.keyword) {
                return rule.preset
            }
        }

        // Fallbacks chung cuoi cung
        if clean.contains("3310") || clean.contains("lcd") { return .nokia3310 }
        if clean.contains("nokia") { return .nokiaSymbian }
        if clean.contains("1998") { return .cam1998 }
        if clean.contains("ccd") { return .ccd1Cyber }
        if clean.contains("kodak") { return .gold200 }
        if clean.contains("fuji") { return .classicChrome }
        if clean.contains("ricoh") { return .grPositive }
        if clean.contains("canon") { return .powershotG }
        if clean.contains("dv") || clean.contains("vhs") { return .miniDV43 }
        if clean.contains("polaroid") || clean.contains("instant") { return .polaroid600 }
        if clean.contains("standard") || clean.contains("tu nhien") { return .standard }

        return nil
    }
}


// MARK: - Captured Photo Item
public struct CapturedPhotoItem: Identifiable, @unchecked Sendable {
    public let id: UUID = UUID()
    public let originalImage: CGImage
    public let processedImage: CGImage
    /// Original camera file. DNG for RAW; JPEG/HEIF for processed captures.
    public let rawPhotoData: Data?
    /// The original JPEG captured alongside a DNG for Photos display.
    public let processedCompanionData: Data?
    public let saveFormat: PhotoSaveFormat
    public let preservesOriginalFile: Bool
    public let rawLocalFileURL: URL?
    public var resolutionDescription: String {
        let pixels = Double(originalImage.width) * Double(originalImage.height)
        return String(format: "%.1f MP · %d × %d", pixels / 1_000_000,
                      originalImage.width, originalImage.height)
    }
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
        processedCompanionData: Data? = nil,
        saveFormat: PhotoSaveFormat = .jpeg,
        preservesOriginalFile: Bool = false,
        rawLocalFileURL: URL? = nil,
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
        self.processedCompanionData = processedCompanionData
        self.saveFormat = saveFormat
        self.preservesOriginalFile = preservesOriginalFile
        self.rawLocalFileURL = rawLocalFileURL
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

// MARK: - Live Detected Entity
public struct LiveDetectedEntity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var rect: CGRect
    public var label: String
    public var confidence: Float
    public var category: NeuralSubjectCategory
    public var lastSeen: TimeInterval

    public init(
        id: UUID = UUID(),
        rect: CGRect,
        label: String,
        confidence: Float,
        category: NeuralSubjectCategory,
        lastSeen: TimeInterval = 0
    ) {
        self.id = id
        self.rect = rect
        self.label = label
        self.confidence = confidence
        self.category = category
        self.lastSeen = lastSeen
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
    public var detectedEntities: [LiveDetectedEntity] = []
    public var detectedHorizonAngle: Double?
    public var detectedHorizonY: CGFloat?
    public var foregroundMaskRects: [CGRect] = []
    public var focalAnchorPoint: CGPoint?
    public var focalSaliencyRatio: Double = 0.5
    public var edgeClutterScore: Double = 0.0

    public init() {}
}

// MARK: - Photo Save Format
public enum PhotoSaveFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heif = "HEIF"
    case dng = "DNG"
    case heic = "HEIC"

    public static var allCases: [PhotoSaveFormat] {
        [.jpeg, .heif, .dng]
    }

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

// MARK: - Windowed Zoom Models
public enum WindowedZoomAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case ratio3_4 = "3:4"
    case ratio1_1 = "1:1"
    case ratio16_9 = "16:9"

    public var id: String { rawValue }

    public var ratioHeightOverWidth: CGFloat {
        switch self {
        case .ratio3_4: return 4.0 / 3.0 // chieu cao / chieu rong cho anh dung doc
        case .ratio1_1: return 1.0
        case .ratio16_9: return 16.0 / 9.0 // chieu cao / chieu rong cho video dung doc (9:16)
        }
    }

    /// Tinh toan ti le kich thuoc khung ngam (fraction tu 0.0 den 1.0 so voi toan canh)
    public func windowFractions(
        focalLength: Double,
        baseOpticalZoom: CGFloat = 1.0,
        containerAspect: CGFloat = 3.0 / 4.0
    ) -> (widthFraction: CGFloat, heightFraction: CGFloat) {
        // Khi tieu cu <= 24.0mm (hoac Full / khong zoom), bung rong 100% toan bo viewfinder khong cat anh
        if focalLength <= 24.0 {
            return (1.0, 1.0)
        }

        let focal = max(24.0, min(135.0, focalLength))
        // Khi zoom quang hoc cam Tele (baseOpticalZoom >= 2.0x), cam thu nhan anh o tieu cu lon hon (vd: 2x = 48mm, 3x = 72mm).
        // Khung ngam se tinh ti le cat tren nen anh Tele chat luong cao thay vi crop nat anh 1x:
        let effectiveBaseZoom = max(1.0, baseOpticalZoom)
        let rawScale = (24.0 * Double(effectiveBaseZoom)) / focal
        let scale = CGFloat(max(0.10, min(1.0, rawScale)))

        let targetAspect: CGFloat
        switch self {
        case .ratio3_4:
            targetAspect = 3.0 / 4.0
        case .ratio1_1:
            targetAspect = 1.0
        case .ratio16_9:
            targetAspect = 9.0 / 16.0
        }

        let safeAspect = containerAspect > 0 ? containerAspect : (3.0 / 4.0)
        if safeAspect >= targetAspect {
            let widthFrac = min(1.0, scale * (targetAspect / safeAspect))
            let heightFrac = min(1.0, scale)
            return (widthFrac, heightFrac)
        } else {
            let widthFrac = min(1.0, scale)
            let heightFrac = min(1.0, scale * (safeAspect / targetAspect))
            return (widthFrac, heightFrac)
        }
    }
}

public struct WindowedFocalLengthPreset: Identifiable, Equatable, Sendable {
    public let focalLength: Double
    public let label: String
    public let sceneRecommendation: String

    public var id: Double { focalLength }

    public static let standardPresets: [WindowedFocalLengthPreset] = [
        WindowedFocalLengthPreset(focalLength: 24.0, label: "Full", sceneRecommendation: "Toan Canh / Khong Zoom"),
        WindowedFocalLengthPreset(focalLength: 28.0, label: "28mm", sceneRecommendation: "Phong Canh / Do Thi"),
        WindowedFocalLengthPreset(focalLength: 35.0, label: "35mm", sceneRecommendation: "Doi Thuong Co Dien"),
        WindowedFocalLengthPreset(focalLength: 50.0, label: "50mm", sceneRecommendation: "Tieu Chuan Mat Nguoi"),
        WindowedFocalLengthPreset(focalLength: 85.0, label: "85mm", sceneRecommendation: "Chan Dung Hoang Kim")
    ]
}

// MARK: - Align Studio Design System & Theme
public struct AlignTheme {
    // 1. Measured chromatic palette extracted directly from AppLogo.png:
    // Top-Left: Iris Violet (120, 99, 242) -> #7863F2
    public static let irisViolet = Color(red: 120.0 / 255.0, green: 99.0 / 255.0, blue: 242.0 / 255.0)
    // Bottom-Left: Electric Cyan (40, 182, 242) -> #28B6F2
    public static let electricCyan = Color(red: 40.0 / 255.0, green: 182.0 / 255.0, blue: 242.0 / 255.0)
    // Bottom-Right: Emerald Mint (9, 167, 134) -> #09A786
    public static let emeraldMint = Color(red: 9.0 / 255.0, green: 167.0 / 255.0, blue: 134.0 / 255.0)
    // Top-Right: Optical Amber Gold (255, 183, 38) -> #FFB726
    public static let amberGold = Color(red: 255.0 / 255.0, green: 183.0 / 255.0, blue: 38.0 / 255.0)

    // 2. Pro Camera Luxury Neutrals (Leica / Apple Pro aesthetic):
    public static let obsidianBlack = Color(red: 0.043, green: 0.047, blue: 0.055)     // #0B0C0E
    public static let carbonSurface = Color(red: 0.075, green: 0.082, blue: 0.098)     // #131519
    public static let graphiteSurface = Color(red: 0.110, green: 0.118, blue: 0.137)   // #1C1E23
    public static let titaniumBorder = Color.white.opacity(0.12)
    public static let platinumWhite = Color(red: 0.97, green: 0.98, blue: 0.98)       // #F8F9FA
    public static let mutedCaption = Color.white.opacity(0.55)

    // 3. Signature Controlled Gradients:
    // Primary Brand Signature: Iris Violet -> Electric Cyan (Subtle, professional)
    public static let signatureGradient = LinearGradient(
        colors: [irisViolet, electricCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Subtle Rim Stroke Gradient: 1.5pt border for AI buttons & cards
    public static let rimGradient = LinearGradient(
        colors: [irisViolet.opacity(0.85), electricCyan.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Full Aperture Spectrum (Reserved for AI active states & hero branding):
    public static let apertureSpectrumGradient = LinearGradient(
        colors: [irisViolet, electricCyan, emeraldMint, amberGold],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Optical Reticle Color: Strictly reserved for target tracking & optical framing
    public static let opticalTargetColor = amberGold
    public static let opticalAlignedColor = Color(red: 0.19, green: 0.82, blue: 0.35) // #30D158 (ISO Green)
}

// MARK: - Persistent App Photo Storage Service
public final class AppPhotoStorageService: @unchecked Sendable {
    public static let shared = AppPhotoStorageService()

    public struct StoredPhotoRecord: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let filename: String
        public let thumbnailFilename: String
        public let timestamp: Date
        public let format: String
        public let width: Int
        public let height: Int
        public let sceneType: String
        public let preset: String
        public let compositionRule: String
        public let alignmentScore: Double
        public let iso: Float
        public let shutterSpeed: Double
        public let isDNG: Bool

        public var resolutionDescription: String {
            let mp = Double(width * height) / 1_000_000.0
            return String(format: "%.1f MP • %d x %d", mp, width, height)
        }
    }

    private let fileManager = FileManager.default
    private let storageLock = NSLock()

    public let capturesDirectory: URL
    public let thumbsDirectory: URL
    public let metadataDirectory: URL

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let captures = docs.appendingPathComponent("AlignStudioCaptures", isDirectory: true)
        let thumbs = captures.appendingPathComponent("Thumbnails", isDirectory: true)
        let meta = captures.appendingPathComponent("Metadata", isDirectory: true)

        self.capturesDirectory = captures
        self.thumbsDirectory = thumbs
        self.metadataDirectory = meta

        for dir in [captures, thumbs, meta] {
            if !fileManager.fileExists(atPath: dir.path) {
                do {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    CameraLogger.error("AppPhotoStorageService: Khong the tao thu muc \(dir.lastPathComponent)", error: error, category: .photoKit)
                }
            }
        }
    }

    /// Save full capture permanently to app sandbox
    @discardableResult
    public func persistCapture(
        id: UUID,
        image: CGImage,
        mainData: Data,
        format: PhotoSaveFormat,
        sceneType: DetectedSceneType,
        preset: FilmPreset,
        compositionRule: CompositionRule,
        score: Double,
        iso: Float = 100,
        shutterSpeed: Double = 1.0 / 125.0
    ) -> StoredPhotoRecord? {
        let ext: String
        switch format {
        case .dng: ext = "dng"
        case .jpeg: ext = "jpg"
        case .heif, .heic: ext = "heic"
        }

        let photoFilename = "AlignStudio_\(id.uuidString).\(ext)"
        let thumbFilename = "thumb_\(id.uuidString).jpg"
        let photoURL = capturesDirectory.appendingPathComponent(photoFilename)
        let thumbURL = thumbsDirectory.appendingPathComponent(thumbFilename)
        let metaURL = metadataDirectory.appendingPathComponent("\(id.uuidString).json")

        storageLock.lock()
        defer { storageLock.unlock() }

        do {
            try mainData.write(to: photoURL, options: .atomic)
        } catch {
            CameraLogger.error("AppPhotoStorageService: Khong the ghi tep anh \(photoFilename)", error: error, category: .photoKit)
            return nil
        }

        if let thumbData = generateThumbnailData(from: image, maxPixelSize: 512) {
            do {
                try thumbData.write(to: thumbURL, options: .atomic)
            } catch {
                CameraLogger.warning("AppPhotoStorageService: Khong the ghi thumbnail \(thumbFilename): \(error.localizedDescription)", category: .photoKit)
            }
        }

        let record = StoredPhotoRecord(
            id: id,
            filename: photoFilename,
            thumbnailFilename: thumbFilename,
            timestamp: Date(),
            format: ext.uppercased(),
            width: image.width,
            height: image.height,
            sceneType: sceneType.rawValue,
            preset: preset.displayName,
            compositionRule: compositionRule.rawValue,
            alignmentScore: score,
            iso: iso,
            shutterSpeed: shutterSpeed,
            isDNG: format == .dng
        )

        do {
            let metaData = try JSONEncoder().encode(record)
            try metaData.write(to: metaURL, options: .atomic)
        } catch {
            CameraLogger.warning("AppPhotoStorageService: Khong the ghi metadata: \(error.localizedDescription)", category: .photoKit)
        }

        return record
    }

    /// Fetch all saved records sorted by newest first
    public func fetchAllRecords() -> [StoredPhotoRecord] {
        guard let metaFiles = try? fileManager.contentsOfDirectory(at: metadataDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            return []
        }

        var records: [StoredPhotoRecord] = []
        for file in metaFiles where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let rec = try? JSONDecoder().decode(StoredPhotoRecord.self, from: data) {
                let imgURL = capturesDirectory.appendingPathComponent(rec.filename)
                if fileManager.fileExists(atPath: imgURL.path) {
                    records.append(rec)
                }
            }
        }

        // Also scan legacy RAW directory
        let legacyRAW = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("RAW", isDirectory: true)
        if let legacyURL = legacyRAW, let legacyFiles = try? fileManager.contentsOfDirectory(at: legacyURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            for rawFile in legacyFiles where rawFile.pathExtension.lowercased() == "dng" {
                if !records.contains(where: { $0.filename == rawFile.lastPathComponent }) {
                    let id = UUID()
                    let rec = StoredPhotoRecord(
                        id: id,
                        filename: rawFile.lastPathComponent,
                        thumbnailFilename: "",
                        timestamp: (try? rawFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date(),
                        format: "DNG",
                        width: 4032,
                        height: 3024,
                        sceneType: "RAW",
                        preset: "Standard",
                        compositionRule: "Rule of Thirds",
                        alignmentScore: 1.0,
                        iso: 100,
                        shutterSpeed: 1.0 / 125.0,
                        isDNG: true
                    )
                    records.append(rec)
                }
            }
        }

        records.sort { $0.timestamp > $1.timestamp }
        return records
    }

    public func latestRecord() -> StoredPhotoRecord? {
        return fetchAllRecords().first
    }

    public func photoURL(for record: StoredPhotoRecord) -> URL {
        let standard = capturesDirectory.appendingPathComponent(record.filename)
        if fileManager.fileExists(atPath: standard.path) {
            return standard
        }
        let legacy = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("RAW").appendingPathComponent(record.filename)
        if let l = legacy, fileManager.fileExists(atPath: l.path) {
            return l
        }
        return standard
    }

    public func thumbnailURL(for record: StoredPhotoRecord) -> URL? {
        guard !record.thumbnailFilename.isEmpty else { return nil }
        let url = thumbsDirectory.appendingPathComponent(record.thumbnailFilename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func loadThumbnailImage(for record: StoredPhotoRecord) -> CGImage? {
        if let thumbURL = thumbnailURL(for: record),
           let data = try? Data(contentsOf: thumbURL),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let fullURL = photoURL(for: record)
        guard let source = CGImageSourceCreateWithURL(fullURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public func loadFullImage(for record: StoredPhotoRecord) -> CGImage? {
        let fullURL = photoURL(for: record)
        guard let source = CGImageSourceCreateWithURL(fullURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public func deleteRecord(_ record: StoredPhotoRecord) {
        storageLock.lock()
        defer { storageLock.unlock() }
        let imgURL = photoURL(for: record)
        if fileManager.fileExists(atPath: imgURL.path) {
            do {
                try fileManager.removeItem(at: imgURL)
            } catch {
                CameraLogger.error("AppPhotoStorageService: Khong the xoa anh \(imgURL.lastPathComponent)", error: error, category: .photoKit)
            }
        }
        if let thumb = thumbnailURL(for: record), fileManager.fileExists(atPath: thumb.path) {
            do {
                try fileManager.removeItem(at: thumb)
            } catch {
                CameraLogger.warning("AppPhotoStorageService: Khong the xoa thumbnail \(thumb.lastPathComponent): \(error.localizedDescription)", category: .photoKit)
            }
        }
        let metaURL = metadataDirectory.appendingPathComponent("\(record.id.uuidString).json")
        if fileManager.fileExists(atPath: metaURL.path) {
            do {
                try fileManager.removeItem(at: metaURL)
            } catch {
                CameraLogger.warning("AppPhotoStorageService: Khong the xoa metadata: \(error.localizedDescription)", category: .photoKit)
            }
        }
    }

    private func generateThumbnailData(from cgImage: CGImage, maxPixelSize: Int) -> Data? {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / CGFloat(cgImage.width), CGFloat(maxPixelSize) / CGFloat(cgImage.height), 1.0)
        let targetWidth = max(1, Int(round(CGFloat(cgImage.width) * scale)))
        let targetHeight = max(1, Int(round(CGFloat(cgImage.height) * scale)))
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaledCG = context.makeImage() else { return nil }
        return UIImage(cgImage: scaledCG).jpegData(compressionQuality: 0.80)
    }
}
