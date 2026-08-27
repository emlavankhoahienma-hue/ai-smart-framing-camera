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

// MARK: - Alignment State
public enum FramingAlignmentState: Equatable {
    case analyzing
    case guiding(distance: CGFloat, angle: CGFloat)
    case aligned(score: Double)
    case locked
    
    public var statusDescription: String {
        switch self {
        case .analyzing:
            return "Đang phân tích bối cảnh AI..."
        case .guiding:
            return "Di chuyển máy để căn chỉnh bố cục"
        case .aligned:
            return "Bố cục hoàn hảo! Giữ chắc tay"
        case .locked:
            return "Khung hình khóa mục tiêu"
        }
    }
    
    public var statusColor: Color {
        switch self {
        case .analyzing:
            return Color.yellow
        case .guiding:
            return Color.orange
        case .aligned, .locked:
            return Color.green
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
        }
    }
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
    
    public init(
        originalImage: CGImage,
        processedImage: CGImage,
        sceneType: DetectedSceneType,
        appliedPreset: FilmPreset,
        compositionRule: CompositionRule,
        alignmentScore: Double,
        timestamp: Date = Date(),
        iso: Float = 100,
        shutterSpeed: Double = 0.016
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
    
    public init() {}
}
