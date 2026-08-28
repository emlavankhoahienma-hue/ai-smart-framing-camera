import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Composition Rule Types
public enum CompositionRule: String, CaseIterable, Identifiable {
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
}

// MARK: - Camera Capture Mode
public enum CameraCaptureMode: String, CaseIterable, Identifiable {
    case photo = "ẢNH"
    case video = "VIDEO"
    
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

// MARK: - AI Framing Engine Source Indicator
public enum AIEngineSource: Equatable {
    case geminiCloud(model: String)
    case appleNeuralEngine(scene: String)
    
    public var title: String {
        switch self {
        case .geminiCloud(let model):
            return "✨ Cloud AI: \(model)"
        case .appleNeuralEngine(let scene):
            return "⚡ Apple Neural Engine (\(scene))"
        }
    }
    
    public var badgeName: String {
        switch self {
        case .geminiCloud(let model):
            let short = model.replacingOccurrences(of: "gemini-", with: "").uppercased()
            return "CLOUD AI (\(short))"
        case .appleNeuralEngine:
            return "NPU CHIP A-SERIES"
        }
    }
    
    public var iconName: String {
        switch self {
        case .geminiCloud: return "sparkles"
        case .appleNeuralEngine: return "cpu.fill"
        }
    }
    
    public var badgeColor: Color {
        switch self {
        case .geminiCloud: return .cyan
        case .appleNeuralEngine: return .green
        }
    }
}

// MARK: - Scene Classification Types
public enum DetectedSceneType: String, CaseIterable {
    case portrait = "Portrait"
    case landscape = "Landscape"
    case sunset = "Sunset / Golden Hour"
    case architecture = "Architecture"
    case night = "Night Scene"
    case food = "Food / Macro"
    case street = "Street Life"
    case general = "Auto General"
    
    public var iconName: String {
        switch self {
        case .portrait: return "person.crop.rectangle.fill"
        case .landscape: return "mountain.2.fill"
        case .sunset: return "sun.horizon.fill"
        case .architecture: return "building.columns.fill"
        case .night: return "moon.stars.fill"
        case .food: return "fork.knife"
        case .street: return "figure.walk"
        case .general: return "sparkles"
        }
    }
    
    public var recommendedFilter: FilmPreset {
        switch self {
        case .portrait: return .fujiPro400H
        case .landscape: return .kodakPortra400
        case .sunset: return .sunsetGlow
        case .architecture: return .cinemaTealOrange
        case .night: return .monochromeNoir
        case .food: return .vintageWarm
        case .street: return .streetClassic
        case .general: return .fujiPro400H
        }
    }
    
    /// AI Full Color Mode — tham số màu tối ưu hoàn toàn bởi AI
    public var aiFullColorParameters: AIColorParameters {
        switch self {
        case .portrait:
            return AIColorParameters(warmthShift: -0.08, saturationBoost: 1.05, contrastCurve: 1.04, shadowLift: 0.04, highlightRoll: 0.92, filmGrain: 0.15, vignetteAmount: 0.2, colorGrade: .softwarm)
        case .landscape:
            return AIColorParameters(warmthShift: 0.05, saturationBoost: 1.18, contrastCurve: 1.12, shadowLift: 0.02, highlightRoll: 0.96, filmGrain: 0.10, vignetteAmount: 0.25, colorGrade: .coolnatural)
        case .sunset:
            return AIColorParameters(warmthShift: 0.30, saturationBoost: 1.35, contrastCurve: 1.15, shadowLift: 0.06, highlightRoll: 0.88, filmGrain: 0.12, vignetteAmount: 0.35, colorGrade: .golden)
        case .architecture:
            return AIColorParameters(warmthShift: -0.05, saturationBoost: 1.08, contrastCurve: 1.20, shadowLift: 0.00, highlightRoll: 1.00, filmGrain: 0.05, vignetteAmount: 0.15, colorGrade: .tealOrange)
        case .night:
            return AIColorParameters(warmthShift: -0.15, saturationBoost: 0.80, contrastCurve: 1.35, shadowLift: 0.08, highlightRoll: 0.85, filmGrain: 0.35, vignetteAmount: 0.55, colorGrade: .moody)
        case .food:
            return AIColorParameters(warmthShift: 0.12, saturationBoost: 1.22, contrastCurve: 1.08, shadowLift: 0.05, highlightRoll: 0.94, filmGrain: 0.08, vignetteAmount: 0.18, colorGrade: .vibrant)
        case .street:
            return AIColorParameters(warmthShift: -0.03, saturationBoost: 0.95, contrastCurve: 1.18, shadowLift: 0.01, highlightRoll: 0.97, filmGrain: 0.22, vignetteAmount: 0.30, colorGrade: .classic)
        case .general:
            return AIColorParameters(warmthShift: 0.0, saturationBoost: 1.05, contrastCurve: 1.05, shadowLift: 0.02, highlightRoll: 0.98, filmGrain: 0.10, vignetteAmount: 0.10, colorGrade: .softwarm)
        }
    }
    
    public var localizedName: String {
        switch self {
        case .portrait: return "Chân dung (Portrait)"
        case .landscape: return "Phong cảnh (Landscape)"
        case .sunset: return "Hoàng hôn (Golden Hour)"
        case .architecture: return "Kiến trúc (Architecture)"
        case .night: return "Ban đêm (Night Scene)"
        case .food: return "Ẩm thực / Macro"
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
}

public struct AIColorParameters {
    /// -1.0 (cool) to +1.0 (warm)
    public let warmthShift: CGFloat
    /// 0.5 (muted) to 1.6 (vibrant)
    public let saturationBoost: CGFloat
    /// 0.8 (flat) to 1.5 (punchy)
    public let contrastCurve: CGFloat
    /// 0.0 (deep blacks) to 0.1 (lifted shadows)
    public let shadowLift: CGFloat
    /// 0.85 (soft highlights) to 1.0 (hard highlights)
    public let highlightRoll: CGFloat
    /// 0.0 (no grain) to 0.5 (heavy grain)
    public let filmGrain: CGFloat
    /// 0.0 (no vignette) to 0.7 (heavy vignette)
    public let vignetteAmount: CGFloat
    /// Color grading style
    public let colorGrade: AIColorGrade
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
public enum FilmPreset: String, CaseIterable, Identifiable {
    case standard = "Standard Clean"
    case fujiPro400H = "Fuji Pro 400H"
    case kodakPortra400 = "Kodak Portra 400"
    case cinemaTealOrange = "Teal & Orange"
    case sunsetGlow = "Sunset Glow"
    case monochromeNoir = "Noir High Contrast"
    case vintageWarm = "Vintage Warm 70s"
    case streetClassic = "Street Classic"
    case aiFullAuto = "AI Full Auto Color"
    
    public var id: String { rawValue }
    
    public var shortTitle: String {
        switch self {
        case .standard: return "STD"
        case .fujiPro400H: return "FUJI"
        case .kodakPortra400: return "PORTRA"
        case .cinemaTealOrange: return "CINE"
        case .sunsetGlow: return "SUNSET"
        case .monochromeNoir: return "B&W"
        case .vintageWarm: return "70s"
        case .streetClassic: return "STREET"
        case .aiFullAuto: return "AI✦"
        }
    }
    
    public var description: String {
        switch self {
        case .standard: return "Màu thực tế trung thực, dải sáng tối đa"
        case .fujiPro400H: return "Tone xanh pastel nhẹ, tôn da tươi sáng"
        case .kodakPortra400: return "Sắc ấm vàng dịu, chuyển màu highlight mượt mà"
        case .cinemaTealOrange: return "Tương phản điện ảnh Hollywood ấn tượng"
        case .sunsetGlow: return "Ấm áp rực rỡ, nhấn mạnh sắc hoàng hôn"
        case .monochromeNoir: return "Đen trắng tương phản cao nghệ thuật"
        case .vintageWarm: return "Phong cách retro thập niên 70 hoài niệm"
        case .streetClassic: return "Màu đường phố sắc nét, chiều sâu khối tốt"
        case .aiFullAuto: return "AI toàn quyền: tự động màu sắc, tone, grain, vignette"
        }
    }
    
    public var isAIFullAuto: Bool { self == .aiFullAuto }
}

// MARK: - Captured Photo Item
public struct CapturedPhotoItem: Identifiable {
    public let id: UUID = UUID()
    public let originalImage: CGImage
    public let processedImage: CGImage
    public let sceneType: DetectedSceneType
    public let appliedPreset: FilmPreset
    public let compositionRule: CompositionRule
    public let alignmentScore: Double
    public let timestamp: Date
    public let iso: Float
    public let shutterSpeed: Double
    public let aiColorParameters: AIColorParameters?
    
    public init(
        originalImage: CGImage,
        processedImage: CGImage,
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
