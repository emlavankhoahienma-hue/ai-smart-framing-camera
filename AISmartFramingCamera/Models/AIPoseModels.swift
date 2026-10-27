import Foundation
import CoreGraphics
import SwiftUI

// MARK: - AI Pose Categories (5 Nhóm Tạo Dáng Nghệ Thuật)
public enum AIPoseCategory: String, CaseIterable, Identifiable, Sendable {
    case leftThird = "Trái 1/3"
    case center = "Trung Tâm"
    case rightThird = "Phải 1/3"
    case seated = "Quán Cafe / Ngồi"
    case street = "Đường Phố / Dạo Bước"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .leftThird: return "arrow.left.to.line"
        case .center: return "dot.scope"
        case .rightThird: return "arrow.right.to.line"
        case .seated: return "chair.lounge"
        case .street: return "figure.walk"
        }
    }
}

// MARK: - Standard Human Pose Joint Names (Theo chuẩn 17 keypoints COCO / Apple Vision)
public enum AIPoseJoint: String, CaseIterable, Sendable {
    case nose
    case leftEye, rightEye
    case leftEar, rightEar
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

// MARK: - Bone Connection for Skeleton Wireframe Drawing
public struct AIPoseBone: Sendable {
    public let from: AIPoseJoint
    public let to: AIPoseJoint

    public static let standardConnections: [AIPoseBone] = [
        // Head / Face
        .init(from: .leftEar, to: .leftEye),
        .init(from: .leftEye, to: .nose),
        .init(from: .nose, to: .rightEye),
        .init(from: .rightEye, to: .rightEar),

        // Upper Body
        .init(from: .leftShoulder, to: .rightShoulder),
        .init(from: .leftShoulder, to: .leftElbow),
        .init(from: .leftElbow, to: .leftWrist),
        .init(from: .rightShoulder, to: .rightElbow),
        .init(from: .rightElbow, to: .rightWrist),

        // Torso / Spine
        .init(from: .leftShoulder, to: .leftHip),
        .init(from: .rightShoulder, to: .rightHip),
        .init(from: .leftHip, to: .rightHip),

        // Lower Body
        .init(from: .leftHip, to: .leftKnee),
        .init(from: .leftKnee, to: .leftAnkle),
        .init(from: .rightHip, to: .rightKnee),
        .init(from: .rightKnee, to: .rightAnkle)
    ]
}

// MARK: - Pose Template Definition (Khuôn Tạo Dáng AI)
public struct AIPoseTemplate: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: AIPoseCategory
    public let compositionRule: String
    public let idealZoom: CGFloat
    public let imageResourceName: String?
    public let normalizedBBox: CGRect // Normalized 0...1 (Top-Left origin)
    public let keypoints: [AIPoseJoint: CGPoint] // Normalized 0...1 (Top-Left origin)

    public init(
        id: String,
        title: String,
        category: AIPoseCategory,
        compositionRule: String,
        idealZoom: CGFloat = 1.0,
        imageResourceName: String? = nil,
        normalizedBBox: CGRect = CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7),
        keypoints: [AIPoseJoint: CGPoint]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.compositionRule = compositionRule
        self.idealZoom = idealZoom
        self.imageResourceName = imageResourceName
        self.normalizedBBox = normalizedBBox
        self.keypoints = keypoints
    }
}

// MARK: - Curated 48 Poses Catalog
public enum AIPoseCatalog {
    public static let allTemplates: [AIPoseTemplate] = generateCatalog()

    public static func templates(for category: AIPoseCategory) -> [AIPoseTemplate] {
        return allTemplates.filter { $0.category == category }
    }

    private static func generateCatalog() -> [AIPoseTemplate] {
        var list: [AIPoseTemplate] = []

        // MARK: 1. Group Left-Third (12 Poses)
        let leftThirdPoses: [(String, String, String, CGFloat, [AIPoseJoint: CGPoint])] = [
            ("left_01", "Nghiêng đầu vuốt tóc", "Quy tắc 1/3 trái, mắt mở rộng sang phải", 1.0, [
                .nose: CGPoint(x: 0.33, y: 0.22),
                .leftEye: CGPoint(x: 0.31, y: 0.20), .rightEye: CGPoint(x: 0.35, y: 0.20),
                .leftEar: CGPoint(x: 0.28, y: 0.21), .rightEar: CGPoint(x: 0.37, y: 0.21),
                .leftShoulder: CGPoint(x: 0.27, y: 0.28), .rightShoulder: CGPoint(x: 0.39, y: 0.28),
                .leftElbow: CGPoint(x: 0.23, y: 0.24), .leftWrist: CGPoint(x: 0.27, y: 0.18),
                .rightElbow: CGPoint(x: 0.41, y: 0.38), .rightWrist: CGPoint(x: 0.38, y: 0.46),
                .leftHip: CGPoint(x: 0.29, y: 0.50), .rightHip: CGPoint(x: 0.37, y: 0.50),
                .leftKnee: CGPoint(x: 0.28, y: 0.68), .rightKnee: CGPoint(x: 0.36, y: 0.70),
                .leftAnkle: CGPoint(x: 0.27, y: 0.88), .rightAnkle: CGPoint(x: 0.35, y: 0.90)
            ]),
            ("left_02", "Đứng nghiêng người mẫu", "Đường nét chữ S nhẹ, vai thả lỏng", 1.0, [
                .nose: CGPoint(x: 0.34, y: 0.20),
                .leftEye: CGPoint(x: 0.32, y: 0.19), .rightEye: CGPoint(x: 0.36, y: 0.19),
                .leftShoulder: CGPoint(x: 0.28, y: 0.27), .rightShoulder: CGPoint(x: 0.40, y: 0.27),
                .leftElbow: CGPoint(x: 0.26, y: 0.38), .leftWrist: CGPoint(x: 0.28, y: 0.48),
                .rightElbow: CGPoint(x: 0.42, y: 0.37), .rightWrist: CGPoint(x: 0.38, y: 0.47),
                .leftHip: CGPoint(x: 0.30, y: 0.51), .rightHip: CGPoint(x: 0.38, y: 0.51),
                .leftKnee: CGPoint(x: 0.31, y: 0.70), .rightKnee: CGPoint(x: 0.39, y: 0.71),
                .leftAnkle: CGPoint(x: 0.31, y: 0.90), .rightAnkle: CGPoint(x: 0.39, y: 0.91)
            ]),
            ("left_03", "Chân dung cận cảnh che mắt", "Điểm nhấn thị giác, tiêu cự 2.0x", 2.0, [
                .nose: CGPoint(x: 0.35, y: 0.40),
                .leftEye: CGPoint(x: 0.31, y: 0.36), .rightEye: CGPoint(x: 0.39, y: 0.36),
                .leftShoulder: CGPoint(x: 0.22, y: 0.58), .rightShoulder: CGPoint(x: 0.48, y: 0.58),
                .leftElbow: CGPoint(x: 0.18, y: 0.70), .leftWrist: CGPoint(x: 0.30, y: 0.42),
                .rightElbow: CGPoint(x: 0.52, y: 0.72), .rightWrist: CGPoint(x: 0.45, y: 0.85)
            ]),
            ("left_04", "Quay lưng ngoái nhìn", "Tạo chiều sâu không gian bí ẩn", 1.0, [
                .nose: CGPoint(x: 0.36, y: 0.22),
                .leftEye: CGPoint(x: 0.34, y: 0.21), .rightEye: CGPoint(x: 0.38, y: 0.21),
                .leftShoulder: CGPoint(x: 0.30, y: 0.29), .rightShoulder: CGPoint(x: 0.42, y: 0.28),
                .leftElbow: CGPoint(x: 0.28, y: 0.40), .leftWrist: CGPoint(x: 0.32, y: 0.50),
                .rightElbow: CGPoint(x: 0.44, y: 0.39), .rightWrist: CGPoint(x: 0.40, y: 0.49),
                .leftHip: CGPoint(x: 0.31, y: 0.52), .rightHip: CGPoint(x: 0.39, y: 0.52),
                .leftKnee: CGPoint(x: 0.30, y: 0.71), .rightKnee: CGPoint(x: 0.38, y: 0.70),
                .leftAnkle: CGPoint(x: 0.29, y: 0.90), .rightAnkle: CGPoint(x: 0.37, y: 0.89)
            ]),
            ("left_05", "Tựa tường đón nắng", "Tận dụng bóng đổ kiến trúc", 1.0, [
                .nose: CGPoint(x: 0.33, y: 0.23),
                .leftShoulder: CGPoint(x: 0.26, y: 0.30), .rightShoulder: CGPoint(x: 0.38, y: 0.30),
                .leftElbow: CGPoint(x: 0.22, y: 0.41), .leftWrist: CGPoint(x: 0.26, y: 0.51),
                .rightElbow: CGPoint(x: 0.40, y: 0.40), .rightWrist: CGPoint(x: 0.35, y: 0.50),
                .leftHip: CGPoint(x: 0.28, y: 0.53), .rightHip: CGPoint(x: 0.36, y: 0.53),
                .leftKnee: CGPoint(x: 0.27, y: 0.72), .rightKnee: CGPoint(x: 0.35, y: 0.71),
                .leftAnkle: CGPoint(x: 0.26, y: 0.91), .rightAnkle: CGPoint(x: 0.34, y: 0.90)
            ]),
            ("left_06", "Tay chống hông tự tin", "Cân bằng đối trọng góc 1/3", 1.0, [
                .nose: CGPoint(x: 0.35, y: 0.21),
                .leftShoulder: CGPoint(x: 0.28, y: 0.28), .rightShoulder: CGPoint(x: 0.42, y: 0.28),
                .leftElbow: CGPoint(x: 0.20, y: 0.37), .leftWrist: CGPoint(x: 0.26, y: 0.48),
                .rightElbow: CGPoint(x: 0.45, y: 0.38), .rightWrist: CGPoint(x: 0.41, y: 0.48),
                .leftHip: CGPoint(x: 0.29, y: 0.50), .rightHip: CGPoint(x: 0.39, y: 0.50),
                .leftKnee: CGPoint(x: 0.28, y: 0.70), .rightKnee: CGPoint(x: 0.41, y: 0.70),
                .leftAnkle: CGPoint(x: 0.27, y: 0.89), .rightAnkle: CGPoint(x: 0.43, y: 0.89)
            ]),
            ("left_07", "Cúi đầu chỉnh trang phục", "Bắt khoảnh khắc candid chân thật", 1.0, [
                .nose: CGPoint(x: 0.33, y: 0.27),
                .leftShoulder: CGPoint(x: 0.26, y: 0.32), .rightShoulder: CGPoint(x: 0.40, y: 0.32),
                .leftElbow: CGPoint(x: 0.24, y: 0.43), .leftWrist: CGPoint(x: 0.31, y: 0.48),
                .rightElbow: CGPoint(x: 0.41, y: 0.43), .rightWrist: CGPoint(x: 0.35, y: 0.48),
                .leftHip: CGPoint(x: 0.29, y: 0.54), .rightHip: CGPoint(x: 0.37, y: 0.54),
                .leftKnee: CGPoint(x: 0.29, y: 0.72), .rightKnee: CGPoint(x: 0.37, y: 0.72),
                .leftAnkle: CGPoint(x: 0.29, y: 0.90), .rightAnkle: CGPoint(x: 0.37, y: 0.90)
            ]),
            ("left_08", "Cầm ly nước dạo phố", "Phong cách lifestyle đường phố", 1.0, [
                .nose: CGPoint(x: 0.34, y: 0.21),
                .leftShoulder: CGPoint(x: 0.27, y: 0.28), .rightShoulder: CGPoint(x: 0.41, y: 0.28),
                .leftElbow: CGPoint(x: 0.24, y: 0.38), .leftWrist: CGPoint(x: 0.27, y: 0.48),
                .rightElbow: CGPoint(x: 0.44, y: 0.36), .rightWrist: CGPoint(x: 0.39, y: 0.34),
                .leftHip: CGPoint(x: 0.29, y: 0.51), .rightHip: CGPoint(x: 0.38, y: 0.51),
                .leftKnee: CGPoint(x: 0.28, y: 0.70), .rightKnee: CGPoint(x: 0.39, y: 0.69),
                .leftAnkle: CGPoint(x: 0.27, y: 0.89), .rightAnkle: CGPoint(x: 0.40, y: 0.88)
            ]),
            ("left_09", "Khoanh tay tựa lan can", "Thư thái, tôn dáng áo khoác dài", 1.0, [
                .nose: CGPoint(x: 0.33, y: 0.22),
                .leftShoulder: CGPoint(x: 0.26, y: 0.29), .rightShoulder: CGPoint(x: 0.40, y: 0.29),
                .leftElbow: CGPoint(x: 0.24, y: 0.40), .leftWrist: CGPoint(x: 0.35, y: 0.43),
                .rightElbow: CGPoint(x: 0.41, y: 0.41), .rightWrist: CGPoint(x: 0.30, y: 0.44),
                .leftHip: CGPoint(x: 0.28, y: 0.52), .rightHip: CGPoint(x: 0.37, y: 0.52),
                .leftKnee: CGPoint(x: 0.27, y: 0.71), .rightKnee: CGPoint(x: 0.36, y: 0.71),
                .leftAnkle: CGPoint(x: 0.26, y: 0.90), .rightAnkle: CGPoint(x: 0.35, y: 0.90)
            ]),
            ("left_10", "Dáng đứng đón gió", "Hai tay mở nhẹ, mặt ngước góc 15 độ", 1.0, [
                .nose: CGPoint(x: 0.35, y: 0.19),
                .leftShoulder: CGPoint(x: 0.28, y: 0.27), .rightShoulder: CGPoint(x: 0.42, y: 0.27),
                .leftElbow: CGPoint(x: 0.22, y: 0.37), .leftWrist: CGPoint(x: 0.18, y: 0.46),
                .rightElbow: CGPoint(x: 0.47, y: 0.37), .rightWrist: CGPoint(x: 0.51, y: 0.46),
                .leftHip: CGPoint(x: 0.30, y: 0.50), .rightHip: CGPoint(x: 0.39, y: 0.50),
                .leftKnee: CGPoint(x: 0.29, y: 0.69), .rightKnee: CGPoint(x: 0.40, y: 0.69),
                .leftAnkle: CGPoint(x: 0.28, y: 0.89), .rightAnkle: CGPoint(x: 0.41, y: 0.89)
            ]),
            ("left_11", "Ngồi bậc thềm góc trái", "Chân duỗi tạo đường dẫn thị giác", 1.0, [
                .nose: CGPoint(x: 0.32, y: 0.32),
                .leftShoulder: CGPoint(x: 0.26, y: 0.40), .rightShoulder: CGPoint(x: 0.39, y: 0.40),
                .leftElbow: CGPoint(x: 0.23, y: 0.52), .leftWrist: CGPoint(x: 0.28, y: 0.62),
                .rightElbow: CGPoint(x: 0.42, y: 0.51), .rightWrist: CGPoint(x: 0.36, y: 0.61),
                .leftHip: CGPoint(x: 0.27, y: 0.62), .rightHip: CGPoint(x: 0.37, y: 0.62),
                .leftKnee: CGPoint(x: 0.33, y: 0.74), .rightKnee: CGPoint(x: 0.44, y: 0.75),
                .leftAnkle: CGPoint(x: 0.38, y: 0.90), .rightAnkle: CGPoint(x: 0.52, y: 0.88)
            ]),
            ("left_12", "Chân dung nửa người", "Tỉ lệ vàng bán thân góc 1/3", 1.5, [
                .nose: CGPoint(x: 0.34, y: 0.30),
                .leftEye: CGPoint(x: 0.31, y: 0.28), .rightEye: CGPoint(x: 0.37, y: 0.28),
                .leftShoulder: CGPoint(x: 0.24, y: 0.43), .rightShoulder: CGPoint(x: 0.46, y: 0.43),
                .leftElbow: CGPoint(x: 0.20, y: 0.62), .leftWrist: CGPoint(x: 0.26, y: 0.78),
                .rightElbow: CGPoint(x: 0.49, y: 0.62), .rightWrist: CGPoint(x: 0.43, y: 0.77),
                .leftHip: CGPoint(x: 0.27, y: 0.82), .rightHip: CGPoint(x: 0.42, y: 0.82)
            ])
        ]

        for p in leftThirdPoses {
            list.append(AIPoseTemplate(
                id: p.0, title: p.1, category: .leftThird,
                compositionRule: p.2, idealZoom: p.3,
                imageResourceName: "PoseGuides/left/\(p.0.replacingOccurrences(of: "left_", with: "")).png",
                keypoints: p.4
            ))
        }

        // MARK: 2. Group Center (12 Poses)
        let centerPoses: [(String, String, String, CGFloat, [AIPoseJoint: CGPoint])] = [
            ("mid_01", "Chính diện thời trang Y2K", "Bố cục trung tâm đối xứng hoàn hảo", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.20),
                .leftEye: CGPoint(x: 0.47, y: 0.19), .rightEye: CGPoint(x: 0.53, y: 0.19),
                .leftShoulder: CGPoint(x: 0.42, y: 0.27), .rightShoulder: CGPoint(x: 0.58, y: 0.27),
                .leftElbow: CGPoint(x: 0.36, y: 0.37), .leftWrist: CGPoint(x: 0.41, y: 0.46),
                .rightElbow: CGPoint(x: 0.64, y: 0.37), .rightWrist: CGPoint(x: 0.59, y: 0.46),
                .leftHip: CGPoint(x: 0.44, y: 0.50), .rightHip: CGPoint(x: 0.56, y: 0.50),
                .leftKnee: CGPoint(x: 0.44, y: 0.69), .rightKnee: CGPoint(x: 0.56, y: 0.69),
                .leftAnkle: CGPoint(x: 0.43, y: 0.89), .rightAnkle: CGPoint(x: 0.57, y: 0.89)
            ]),
            ("mid_02", "Chạm gọng kính râm", "Ánh mắt trung tâm thu hút người nhìn", 1.5, [
                .nose: CGPoint(x: 0.50, y: 0.30),
                .leftEye: CGPoint(x: 0.46, y: 0.28), .rightEye: CGPoint(x: 0.54, y: 0.28),
                .leftShoulder: CGPoint(x: 0.38, y: 0.43), .rightShoulder: CGPoint(x: 0.62, y: 0.43),
                .leftElbow: CGPoint(x: 0.33, y: 0.58), .leftWrist: CGPoint(x: 0.43, y: 0.33),
                .rightElbow: CGPoint(x: 0.66, y: 0.60), .rightWrist: CGPoint(x: 0.61, y: 0.75),
                .leftHip: CGPoint(x: 0.42, y: 0.80), .rightHip: CGPoint(x: 0.58, y: 0.80)
            ]),
            ("mid_03", "Cầm hoa che mắt", "Nàng thơ cổ điển, điểm nhấn màu sắc", 1.5, [
                .nose: CGPoint(x: 0.50, y: 0.32),
                .leftEye: CGPoint(x: 0.46, y: 0.30), .rightEye: CGPoint(x: 0.54, y: 0.30),
                .leftShoulder: CGPoint(x: 0.38, y: 0.45), .rightShoulder: CGPoint(x: 0.62, y: 0.45),
                .leftElbow: CGPoint(x: 0.42, y: 0.62), .leftWrist: CGPoint(x: 0.47, y: 0.35),
                .rightElbow: CGPoint(x: 0.58, y: 0.62), .rightWrist: CGPoint(x: 0.53, y: 0.35)
            ]),
            ("mid_04", "Ánh mắt ngang đường 1/3", "Tỷ lệ vàng ánh mắt chuẩn nhiếp ảnh", 2.0, [
                .nose: CGPoint(x: 0.50, y: 0.36),
                .leftEye: CGPoint(x: 0.44, y: 0.33), .rightEye: CGPoint(x: 0.56, y: 0.33),
                .leftShoulder: CGPoint(x: 0.32, y: 0.56), .rightShoulder: CGPoint(x: 0.68, y: 0.56)
            ]),
            ("mid_05", "Nghiêng đầu nụ cười tỏa nắng", "Thân thẳng, đầu nghiêng tạo nét duyên", 1.5, [
                .nose: CGPoint(x: 0.52, y: 0.30),
                .leftEye: CGPoint(x: 0.48, y: 0.28), .rightEye: CGPoint(x: 0.55, y: 0.29),
                .leftShoulder: CGPoint(x: 0.39, y: 0.43), .rightShoulder: CGPoint(x: 0.61, y: 0.43),
                .leftElbow: CGPoint(x: 0.35, y: 0.60), .leftWrist: CGPoint(x: 0.38, y: 0.75),
                .rightElbow: CGPoint(x: 0.65, y: 0.60), .rightWrist: CGPoint(x: 0.62, y: 0.75)
            ]),
            ("mid_06", "Đút tay túi áo khoác", "Dáng đứng tự nhiên, ngực mở rộng", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.21),
                .leftShoulder: CGPoint(x: 0.42, y: 0.28), .rightShoulder: CGPoint(x: 0.58, y: 0.28),
                .leftElbow: CGPoint(x: 0.38, y: 0.39), .leftWrist: CGPoint(x: 0.44, y: 0.48),
                .rightElbow: CGPoint(x: 0.62, y: 0.39), .rightWrist: CGPoint(x: 0.56, y: 0.48),
                .leftHip: CGPoint(x: 0.44, y: 0.50), .rightHip: CGPoint(x: 0.56, y: 0.50),
                .leftKnee: CGPoint(x: 0.43, y: 0.69), .rightKnee: CGPoint(x: 0.57, y: 0.69),
                .leftAnkle: CGPoint(x: 0.43, y: 0.89), .rightAnkle: CGPoint(x: 0.57, y: 0.89)
            ]),
            ("mid_07", "Ôm túi xách trước ngực", "Thân thiện, trẻ trung, tự nhiên", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.22),
                .leftShoulder: CGPoint(x: 0.42, y: 0.29), .rightShoulder: CGPoint(x: 0.58, y: 0.29),
                .leftElbow: CGPoint(x: 0.39, y: 0.40), .leftWrist: CGPoint(x: 0.46, y: 0.45),
                .rightElbow: CGPoint(x: 0.61, y: 0.40), .rightWrist: CGPoint(x: 0.54, y: 0.45),
                .leftHip: CGPoint(x: 0.44, y: 0.51), .rightHip: CGPoint(x: 0.56, y: 0.51),
                .leftKnee: CGPoint(x: 0.44, y: 0.70), .rightKnee: CGPoint(x: 0.56, y: 0.70),
                .leftAnkle: CGPoint(x: 0.44, y: 0.90), .rightAnkle: CGPoint(x: 0.56, y: 0.90)
            ]),
            ("mid_08", "Chụp từ trên xuống góc cao", "Mặt ngước lên đón sáng trọn vẹn", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.28),
                .leftShoulder: CGPoint(x: 0.38, y: 0.42), .rightShoulder: CGPoint(x: 0.62, y: 0.42),
                .leftElbow: CGPoint(x: 0.32, y: 0.58), .leftWrist: CGPoint(x: 0.40, y: 0.70),
                .rightElbow: CGPoint(x: 0.68, y: 0.58), .rightWrist: CGPoint(x: 0.60, y: 0.70),
                .leftHip: CGPoint(x: 0.42, y: 0.68), .rightHip: CGPoint(x: 0.58, y: 0.68),
                .leftKnee: CGPoint(x: 0.40, y: 0.82), .rightKnee: CGPoint(x: 0.60, y: 0.82)
            ]),
            ("mid_09", "Khoanh tay phong thái tự tin", "Phong thái đĩnh đạc, bố cục vững vàng", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.21),
                .leftShoulder: CGPoint(x: 0.41, y: 0.28), .rightShoulder: CGPoint(x: 0.59, y: 0.28),
                .leftElbow: CGPoint(x: 0.38, y: 0.40), .leftWrist: CGPoint(x: 0.52, y: 0.42),
                .rightElbow: CGPoint(x: 0.62, y: 0.40), .rightWrist: CGPoint(x: 0.48, y: 0.42),
                .leftHip: CGPoint(x: 0.44, y: 0.51), .rightHip: CGPoint(x: 0.56, y: 0.51),
                .leftKnee: CGPoint(x: 0.44, y: 0.70), .rightKnee: CGPoint(x: 0.56, y: 0.70),
                .leftAnkle: CGPoint(x: 0.44, y: 0.89), .rightAnkle: CGPoint(x: 0.56, y: 0.89)
            ]),
            ("mid_10", "Dáng bật nhảy năng động", "Khoảnh khắc bay bổng, tràn đầy năng lượng", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.16),
                .leftShoulder: CGPoint(x: 0.43, y: 0.24), .rightShoulder: CGPoint(x: 0.57, y: 0.24),
                .leftElbow: CGPoint(x: 0.35, y: 0.20), .leftWrist: CGPoint(x: 0.30, y: 0.12),
                .rightElbow: CGPoint(x: 0.65, y: 0.20), .rightWrist: CGPoint(x: 0.70, y: 0.12),
                .leftHip: CGPoint(x: 0.45, y: 0.45), .rightHip: CGPoint(x: 0.55, y: 0.45),
                .leftKnee: CGPoint(x: 0.40, y: 0.58), .rightKnee: CGPoint(x: 0.60, y: 0.58),
                .leftAnkle: CGPoint(x: 0.36, y: 0.70), .rightAnkle: CGPoint(x: 0.64, y: 0.70)
            ]),
            ("mid_11", "Chân dung cận cảnh bắt sáng", "Tập trung ánh nhìn và bờ môi", 2.0, [
                .nose: CGPoint(x: 0.50, y: 0.40),
                .leftEye: CGPoint(x: 0.44, y: 0.35), .rightEye: CGPoint(x: 0.56, y: 0.35),
                .leftShoulder: CGPoint(x: 0.30, y: 0.62), .rightShoulder: CGPoint(x: 0.70, y: 0.62)
            ]),
            ("mid_12", "Đứng trụ một chân", "Dồn trọng tâm chân sau, chân trước cong", 1.0, [
                .nose: CGPoint(x: 0.49, y: 0.20),
                .leftShoulder: CGPoint(x: 0.41, y: 0.27), .rightShoulder: CGPoint(x: 0.57, y: 0.27),
                .leftElbow: CGPoint(x: 0.38, y: 0.38), .leftWrist: CGPoint(x: 0.41, y: 0.48),
                .rightElbow: CGPoint(x: 0.61, y: 0.38), .rightWrist: CGPoint(x: 0.58, y: 0.48),
                .leftHip: CGPoint(x: 0.43, y: 0.50), .rightHip: CGPoint(x: 0.55, y: 0.50),
                .leftKnee: CGPoint(x: 0.44, y: 0.70), .rightKnee: CGPoint(x: 0.53, y: 0.68),
                .leftAnkle: CGPoint(x: 0.44, y: 0.89), .rightAnkle: CGPoint(x: 0.51, y: 0.86)
            ])
        ]

        for p in centerPoses {
            list.append(AIPoseTemplate(
                id: p.0, title: p.1, category: .center,
                compositionRule: p.2, idealZoom: p.3,
                imageResourceName: "PoseGuides/mid/\(p.0.replacingOccurrences(of: "mid_", with: "")).png",
                keypoints: p.4
            ))
        }

        // MARK: 3. Group Right-Third (12 Poses)
        let rightThirdPoses: [(String, String, String, CGFloat, [AIPoseJoint: CGPoint])] = [
            ("right_01", "Che tay che nắng", "Quy tắc 1/3 phải, khuỷu tay nâng cao", 1.0, [
                .nose: CGPoint(x: 0.66, y: 0.21),
                .leftEye: CGPoint(x: 0.64, y: 0.20), .rightEye: CGPoint(x: 0.68, y: 0.20),
                .leftShoulder: CGPoint(x: 0.59, y: 0.28), .rightShoulder: CGPoint(x: 0.73, y: 0.28),
                .leftElbow: CGPoint(x: 0.56, y: 0.38), .leftWrist: CGPoint(x: 0.60, y: 0.48),
                .rightElbow: CGPoint(x: 0.77, y: 0.23), .rightWrist: CGPoint(x: 0.70, y: 0.17),
                .leftHip: CGPoint(x: 0.62, y: 0.50), .rightHip: CGPoint(x: 0.70, y: 0.50),
                .leftKnee: CGPoint(x: 0.63, y: 0.69), .rightKnee: CGPoint(x: 0.71, y: 0.70),
                .leftAnkle: CGPoint(x: 0.63, y: 0.89), .rightAnkle: CGPoint(x: 0.72, y: 0.90)
            ]),
            ("right_02", "Đón ánh bình minh", "Mặt quay sang trái đón sáng", 1.0, [
                .nose: CGPoint(x: 0.65, y: 0.22),
                .leftShoulder: CGPoint(x: 0.58, y: 0.29), .rightShoulder: CGPoint(x: 0.72, y: 0.29),
                .leftElbow: CGPoint(x: 0.55, y: 0.39), .leftWrist: CGPoint(x: 0.59, y: 0.49),
                .rightElbow: CGPoint(x: 0.75, y: 0.39), .rightWrist: CGPoint(x: 0.71, y: 0.49),
                .leftHip: CGPoint(x: 0.61, y: 0.51), .rightHip: CGPoint(x: 0.69, y: 0.51),
                .leftKnee: CGPoint(x: 0.62, y: 0.70), .rightKnee: CGPoint(x: 0.70, y: 0.70),
                .leftAnkle: CGPoint(x: 0.62, y: 0.90), .rightAnkle: CGPoint(x: 0.70, y: 0.90)
            ]),
            ("right_03", "Bước dài sang trái", "Đường dẫn chuyển động vào khung cảnh", 1.0, [
                .nose: CGPoint(x: 0.67, y: 0.20),
                .leftShoulder: CGPoint(x: 0.60, y: 0.27), .rightShoulder: CGPoint(x: 0.74, y: 0.27),
                .leftElbow: CGPoint(x: 0.55, y: 0.37), .leftWrist: CGPoint(x: 0.52, y: 0.46),
                .rightElbow: CGPoint(x: 0.77, y: 0.37), .rightWrist: CGPoint(x: 0.79, y: 0.46),
                .leftHip: CGPoint(x: 0.63, y: 0.49), .rightHip: CGPoint(x: 0.71, y: 0.49),
                .leftKnee: CGPoint(x: 0.56, y: 0.68), .rightKnee: CGPoint(x: 0.75, y: 0.69),
                .leftAnkle: CGPoint(x: 0.50, y: 0.88), .rightAnkle: CGPoint(x: 0.78, y: 0.89)
            ]),
            ("right_04", "Chống cằm suy tư", "Khuỷu tay tựa điểm tựa, mắt nhìn xa", 1.5, [
                .nose: CGPoint(x: 0.66, y: 0.30),
                .leftShoulder: CGPoint(x: 0.56, y: 0.42), .rightShoulder: CGPoint(x: 0.76, y: 0.42),
                .leftElbow: CGPoint(x: 0.52, y: 0.58), .leftWrist: CGPoint(x: 0.58, y: 0.70),
                .rightElbow: CGPoint(x: 0.78, y: 0.55), .rightWrist: CGPoint(x: 0.68, y: 0.38)
            ]),
            ("right_05", "Giơ tay chào năng lượng", "Tạo sự kết nối với người xem", 1.0, [
                .nose: CGPoint(x: 0.66, y: 0.21),
                .leftShoulder: CGPoint(x: 0.58, y: 0.28), .rightShoulder: CGPoint(x: 0.73, y: 0.28),
                .leftElbow: CGPoint(x: 0.55, y: 0.38), .leftWrist: CGPoint(x: 0.59, y: 0.48),
                .rightElbow: CGPoint(x: 0.78, y: 0.22), .rightWrist: CGPoint(x: 0.82, y: 0.12),
                .leftHip: CGPoint(x: 0.61, y: 0.50), .rightHip: CGPoint(x: 0.70, y: 0.50),
                .leftKnee: CGPoint(x: 0.61, y: 0.69), .rightKnee: CGPoint(x: 0.70, y: 0.69),
                .leftAnkle: CGPoint(x: 0.61, y: 0.89), .rightAnkle: CGPoint(x: 0.70, y: 0.89)
            ]),
            ("right_06", "Ngoái đầu cười qua vai", "Bắt khoảnh khắc xoay người duyên dáng", 1.0, [
                .nose: CGPoint(x: 0.64, y: 0.21),
                .leftShoulder: CGPoint(x: 0.58, y: 0.28), .rightShoulder: CGPoint(x: 0.71, y: 0.28),
                .leftElbow: CGPoint(x: 0.56, y: 0.39), .leftWrist: CGPoint(x: 0.60, y: 0.49),
                .rightElbow: CGPoint(x: 0.73, y: 0.39), .rightWrist: CGPoint(x: 0.69, y: 0.49),
                .leftHip: CGPoint(x: 0.61, y: 0.51), .rightHip: CGPoint(x: 0.69, y: 0.51),
                .leftKnee: CGPoint(x: 0.61, y: 0.70), .rightKnee: CGPoint(x: 0.69, y: 0.70),
                .leftAnkle: CGPoint(x: 0.61, y: 0.89), .rightAnkle: CGPoint(x: 0.69, y: 0.89)
            ]),
            ("right_07", "Che má e ấp", "Phong cách chân dung Nhật Bản nhẹ nhàng", 1.5, [
                .nose: CGPoint(x: 0.66, y: 0.31),
                .leftShoulder: CGPoint(x: 0.57, y: 0.43), .rightShoulder: CGPoint(x: 0.75, y: 0.43),
                .leftElbow: CGPoint(x: 0.54, y: 0.58), .leftWrist: CGPoint(x: 0.58, y: 0.72),
                .rightElbow: CGPoint(x: 0.78, y: 0.55), .rightWrist: CGPoint(x: 0.70, y: 0.35)
            ]),
            ("right_08", "Ngồi ghế vắt chéo chân", "Thanh lịch góc 1/3 phải", 1.0, [
                .nose: CGPoint(x: 0.67, y: 0.26),
                .leftShoulder: CGPoint(x: 0.60, y: 0.34), .rightShoulder: CGPoint(x: 0.74, y: 0.34),
                .leftElbow: CGPoint(x: 0.58, y: 0.46), .leftWrist: CGPoint(x: 0.64, y: 0.54),
                .rightElbow: CGPoint(x: 0.76, y: 0.46), .rightWrist: CGPoint(x: 0.70, y: 0.54),
                .leftHip: CGPoint(x: 0.62, y: 0.56), .rightHip: CGPoint(x: 0.72, y: 0.56),
                .leftKnee: CGPoint(x: 0.60, y: 0.72), .rightKnee: CGPoint(x: 0.66, y: 0.68),
                .leftAnkle: CGPoint(x: 0.62, y: 0.88), .rightAnkle: CGPoint(x: 0.68, y: 0.85)
            ]),
            ("right_09", "Tay vuốt nhẹ ve áo", "Tỉ mỉ từng chi tiết thời trang", 1.0, [
                .nose: CGPoint(x: 0.66, y: 0.22),
                .leftShoulder: CGPoint(x: 0.59, y: 0.29), .rightShoulder: CGPoint(x: 0.73, y: 0.29),
                .leftElbow: CGPoint(x: 0.57, y: 0.40), .leftWrist: CGPoint(x: 0.64, y: 0.46),
                .rightElbow: CGPoint(x: 0.75, y: 0.40), .rightWrist: CGPoint(x: 0.68, y: 0.46),
                .leftHip: CGPoint(x: 0.61, y: 0.51), .rightHip: CGPoint(x: 0.70, y: 0.51),
                .leftKnee: CGPoint(x: 0.61, y: 0.70), .rightKnee: CGPoint(x: 0.70, y: 0.70),
                .leftAnkle: CGPoint(x: 0.61, y: 0.90), .rightAnkle: CGPoint(x: 0.70, y: 0.90)
            ]),
            ("right_10", "Đứng dáng chữ S quyến rũ", "Tôn đường cong cơ thể", 1.0, [
                .nose: CGPoint(x: 0.66, y: 0.20),
                .leftShoulder: CGPoint(x: 0.59, y: 0.27), .rightShoulder: CGPoint(x: 0.73, y: 0.27),
                .leftElbow: CGPoint(x: 0.54, y: 0.37), .leftWrist: CGPoint(x: 0.58, y: 0.47),
                .rightElbow: CGPoint(x: 0.77, y: 0.36), .rightWrist: CGPoint(x: 0.72, y: 0.46),
                .leftHip: CGPoint(x: 0.64, y: 0.50), .rightHip: CGPoint(x: 0.73, y: 0.49),
                .leftKnee: CGPoint(x: 0.63, y: 0.70), .rightKnee: CGPoint(x: 0.71, y: 0.70),
                .leftAnkle: CGPoint(x: 0.64, y: 0.89), .rightAnkle: CGPoint(x: 0.70, y: 0.89)
            ]),
            ("right_11", "Cúi người nhìn ống kính", "Tạo cảm giác thân thiện gần gũi", 1.2, [
                .nose: CGPoint(x: 0.65, y: 0.28),
                .leftShoulder: CGPoint(x: 0.57, y: 0.36), .rightShoulder: CGPoint(x: 0.73, y: 0.36),
                .leftElbow: CGPoint(x: 0.54, y: 0.50), .leftWrist: CGPoint(x: 0.58, y: 0.62),
                .rightElbow: CGPoint(x: 0.75, y: 0.50), .rightWrist: CGPoint(x: 0.71, y: 0.62),
                .leftHip: CGPoint(x: 0.60, y: 0.60), .rightHip: CGPoint(x: 0.70, y: 0.60)
            ]),
            ("right_12", "Tay chạm túi quần mắt nhìn nghiêng", "Tự nhiên, phong thái thời trang", 1.0, [
                .nose: CGPoint(x: 0.66, y: 0.21),
                .leftShoulder: CGPoint(x: 0.59, y: 0.28), .rightShoulder: CGPoint(x: 0.73, y: 0.28),
                .leftElbow: CGPoint(x: 0.56, y: 0.38), .leftWrist: CGPoint(x: 0.60, y: 0.48),
                .rightElbow: CGPoint(x: 0.76, y: 0.38), .rightWrist: CGPoint(x: 0.72, y: 0.48),
                .leftHip: CGPoint(x: 0.61, y: 0.51), .rightHip: CGPoint(x: 0.70, y: 0.51),
                .leftKnee: CGPoint(x: 0.62, y: 0.70), .rightKnee: CGPoint(x: 0.71, y: 0.70),
                .leftAnkle: CGPoint(x: 0.62, y: 0.89), .rightAnkle: CGPoint(x: 0.72, y: 0.89)
            ])
        ]

        for p in rightThirdPoses {
            list.append(AIPoseTemplate(
                id: p.0, title: p.1, category: .rightThird,
                compositionRule: p.2, idealZoom: p.3,
                imageResourceName: "PoseGuides/right/\(p.0.replacingOccurrences(of: "right_", with: "")).png",
                keypoints: p.4
            ))
        }

        // MARK: 4. Group Seated / Cafe (6 Poses)
        let seatedPoses: [(String, String, String, CGFloat, [AIPoseJoint: CGPoint])] = [
            ("seated_01", "Bắt chéo chân nâng tách cafe", "Bố cục tam giác cân bằng tại quán cafe", 1.2, [
                .nose: CGPoint(x: 0.48, y: 0.28),
                .leftShoulder: CGPoint(x: 0.40, y: 0.36), .rightShoulder: CGPoint(x: 0.58, y: 0.36),
                .leftElbow: CGPoint(x: 0.36, y: 0.48), .leftWrist: CGPoint(x: 0.46, y: 0.42),
                .rightElbow: CGPoint(x: 0.62, y: 0.49), .rightWrist: CGPoint(x: 0.55, y: 0.58),
                .leftHip: CGPoint(x: 0.42, y: 0.58), .rightHip: CGPoint(x: 0.56, y: 0.58),
                .leftKnee: CGPoint(x: 0.40, y: 0.72), .rightKnee: CGPoint(x: 0.48, y: 0.68),
                .leftAnkle: CGPoint(x: 0.42, y: 0.88), .rightAnkle: CGPoint(x: 0.50, y: 0.85)
            ]),
            ("seated_02", "Chống cằm bên ô cửa sổ", "Tận dụng ánh sáng tự nhiên cạnh cửa sổ", 1.5, [
                .nose: CGPoint(x: 0.45, y: 0.32),
                .leftShoulder: CGPoint(x: 0.38, y: 0.42), .rightShoulder: CGPoint(x: 0.58, y: 0.42),
                .leftElbow: CGPoint(x: 0.35, y: 0.55), .leftWrist: CGPoint(x: 0.42, y: 0.40),
                .rightElbow: CGPoint(x: 0.60, y: 0.56), .rightWrist: CGPoint(x: 0.52, y: 0.65)
            ]),
            ("seated_03", "Ngồi bệt tựa tường duỗi chân", "Tạo đường chéo kéo dài đôi chân", 1.0, [
                .nose: CGPoint(x: 0.40, y: 0.30),
                .leftShoulder: CGPoint(x: 0.34, y: 0.38), .rightShoulder: CGPoint(x: 0.50, y: 0.38),
                .leftElbow: CGPoint(x: 0.30, y: 0.50), .leftWrist: CGPoint(x: 0.36, y: 0.58),
                .rightElbow: CGPoint(x: 0.54, y: 0.50), .rightWrist: CGPoint(x: 0.48, y: 0.58),
                .leftHip: CGPoint(x: 0.36, y: 0.62), .rightHip: CGPoint(x: 0.48, y: 0.62),
                .leftKnee: CGPoint(x: 0.46, y: 0.72), .rightKnee: CGPoint(x: 0.58, y: 0.70),
                .leftAnkle: CGPoint(x: 0.56, y: 0.86), .rightAnkle: CGPoint(x: 0.68, y: 0.84)
            ]),
            ("seated_04", "Ngồi ghế bar một chân chạm đất", "Thon gọn vóc dáng, hiện đại", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.24),
                .leftShoulder: CGPoint(x: 0.42, y: 0.32), .rightShoulder: CGPoint(x: 0.58, y: 0.32),
                .leftElbow: CGPoint(x: 0.39, y: 0.44), .leftWrist: CGPoint(x: 0.45, y: 0.52),
                .rightElbow: CGPoint(x: 0.61, y: 0.44), .rightWrist: CGPoint(x: 0.55, y: 0.52),
                .leftHip: CGPoint(x: 0.44, y: 0.54), .rightHip: CGPoint(x: 0.56, y: 0.54),
                .leftKnee: CGPoint(x: 0.42, y: 0.70), .rightKnee: CGPoint(x: 0.58, y: 0.68),
                .leftAnkle: CGPoint(x: 0.42, y: 0.90), .rightAnkle: CGPoint(x: 0.58, y: 0.82)
            ]),
            ("seated_05", "Đọc sách lật trang tạp chí", "Khoảnh khắc chăm chú đầy tri thức", 1.2, [
                .nose: CGPoint(x: 0.49, y: 0.32),
                .leftShoulder: CGPoint(x: 0.40, y: 0.40), .rightShoulder: CGPoint(x: 0.58, y: 0.40),
                .leftElbow: CGPoint(x: 0.36, y: 0.54), .leftWrist: CGPoint(x: 0.44, y: 0.60),
                .rightElbow: CGPoint(x: 0.62, y: 0.54), .rightWrist: CGPoint(x: 0.54, y: 0.60),
                .leftHip: CGPoint(x: 0.42, y: 0.62), .rightHip: CGPoint(x: 0.56, y: 0.62)
            ]),
            ("seated_06", "Co gối trên sofa thư giãn", "Ấm cúng, gần gũi, dịu êm", 1.0, [
                .nose: CGPoint(x: 0.48, y: 0.28),
                .leftShoulder: CGPoint(x: 0.40, y: 0.37), .rightShoulder: CGPoint(x: 0.57, y: 0.37),
                .leftElbow: CGPoint(x: 0.36, y: 0.50), .leftWrist: CGPoint(x: 0.45, y: 0.52),
                .rightElbow: CGPoint(x: 0.61, y: 0.50), .rightWrist: CGPoint(x: 0.52, y: 0.52),
                .leftHip: CGPoint(x: 0.42, y: 0.60), .rightHip: CGPoint(x: 0.56, y: 0.60),
                .leftKnee: CGPoint(x: 0.44, y: 0.50), .rightKnee: CGPoint(x: 0.54, y: 0.50),
                .leftAnkle: CGPoint(x: 0.44, y: 0.72), .rightAnkle: CGPoint(x: 0.54, y: 0.72)
            ])
        ]

        for p in seatedPoses {
            list.append(AIPoseTemplate(
                id: p.0, title: p.1, category: .seated,
                compositionRule: p.2, idealZoom: p.3,
                keypoints: p.4
            ))
        }

        // MARK: 5. Group Street (6 Poses)
        let streetPoses: [(String, String, String, CGFloat, [AIPoseJoint: CGPoint])] = [
            ("street_01", "Sải bước qua đường áo bay", "Khoảnh khắc chuyển động điện ảnh", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.20),
                .leftShoulder: CGPoint(x: 0.43, y: 0.28), .rightShoulder: CGPoint(x: 0.57, y: 0.28),
                .leftElbow: CGPoint(x: 0.38, y: 0.38), .leftWrist: CGPoint(x: 0.35, y: 0.48),
                .rightElbow: CGPoint(x: 0.62, y: 0.38), .rightWrist: CGPoint(x: 0.66, y: 0.47),
                .leftHip: CGPoint(x: 0.45, y: 0.50), .rightHip: CGPoint(x: 0.55, y: 0.50),
                .leftKnee: CGPoint(x: 0.40, y: 0.69), .rightKnee: CGPoint(x: 0.62, y: 0.68),
                .leftAnkle: CGPoint(x: 0.35, y: 0.88), .rightAnkle: CGPoint(x: 0.68, y: 0.86)
            ]),
            ("street_02", "Chờ đèn đỏ ngoái nhìn lại", "Khoảnh khắc bất chợt phong cách paparazzi", 1.0, [
                .nose: CGPoint(x: 0.52, y: 0.21),
                .leftShoulder: CGPoint(x: 0.45, y: 0.28), .rightShoulder: CGPoint(x: 0.59, y: 0.28),
                .leftElbow: CGPoint(x: 0.41, y: 0.39), .leftWrist: CGPoint(x: 0.46, y: 0.48),
                .rightElbow: CGPoint(x: 0.62, y: 0.39), .rightWrist: CGPoint(x: 0.58, y: 0.48),
                .leftHip: CGPoint(x: 0.46, y: 0.51), .rightHip: CGPoint(x: 0.56, y: 0.51),
                .leftKnee: CGPoint(x: 0.46, y: 0.70), .rightKnee: CGPoint(x: 0.56, y: 0.70),
                .leftAnkle: CGPoint(x: 0.46, y: 0.89), .rightAnkle: CGPoint(x: 0.56, y: 0.89)
            ]),
            ("street_03", "Cầm ô đi dưới mưa", "Tâm trạng hoài niệm, lãng mạn", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.23),
                .leftShoulder: CGPoint(x: 0.42, y: 0.30), .rightShoulder: CGPoint(x: 0.58, y: 0.30),
                .leftElbow: CGPoint(x: 0.39, y: 0.41), .leftWrist: CGPoint(x: 0.43, y: 0.50),
                .rightElbow: CGPoint(x: 0.62, y: 0.33), .rightWrist: CGPoint(x: 0.58, y: 0.22),
                .leftHip: CGPoint(x: 0.44, y: 0.52), .rightHip: CGPoint(x: 0.56, y: 0.52),
                .leftKnee: CGPoint(x: 0.44, y: 0.71), .rightKnee: CGPoint(x: 0.56, y: 0.71),
                .leftAnkle: CGPoint(x: 0.44, y: 0.90), .rightAnkle: CGPoint(x: 0.56, y: 0.90)
            ]),
            ("street_04", "Đứng trước cửa tiệm cafe retro", "Hòa mình vào không gian kiến trúc cổ điển", 1.0, [
                .nose: CGPoint(x: 0.48, y: 0.22),
                .leftShoulder: CGPoint(x: 0.41, y: 0.29), .rightShoulder: CGPoint(x: 0.56, y: 0.29),
                .leftElbow: CGPoint(x: 0.38, y: 0.40), .leftWrist: CGPoint(x: 0.43, y: 0.49),
                .rightElbow: CGPoint(x: 0.59, y: 0.40), .rightWrist: CGPoint(x: 0.54, y: 0.49),
                .leftHip: CGPoint(x: 0.43, y: 0.51), .rightHip: CGPoint(x: 0.54, y: 0.51),
                .leftKnee: CGPoint(x: 0.43, y: 0.70), .rightKnee: CGPoint(x: 0.54, y: 0.70),
                .leftAnkle: CGPoint(x: 0.43, y: 0.89), .rightAnkle: CGPoint(x: 0.54, y: 0.89)
            ]),
            ("street_05", "Đút tay túi quần rảo bước", "Nhanh nhẹn, hiện đại, năng động", 1.0, [
                .nose: CGPoint(x: 0.50, y: 0.20),
                .leftShoulder: CGPoint(x: 0.42, y: 0.27), .rightShoulder: CGPoint(x: 0.58, y: 0.27),
                .leftElbow: CGPoint(x: 0.38, y: 0.38), .leftWrist: CGPoint(x: 0.43, y: 0.47),
                .rightElbow: CGPoint(x: 0.62, y: 0.38), .rightWrist: CGPoint(x: 0.57, y: 0.47),
                .leftHip: CGPoint(x: 0.44, y: 0.50), .rightHip: CGPoint(x: 0.56, y: 0.50),
                .leftKnee: CGPoint(x: 0.42, y: 0.69), .rightKnee: CGPoint(x: 0.59, y: 0.68),
                .leftAnkle: CGPoint(x: 0.40, y: 0.88), .rightAnkle: CGPoint(x: 0.63, y: 0.87)
            ]),
            ("street_06", "Tựa cột đèn đường góc phố", "Điểm tựa hình học tạo góc chụp điện ảnh", 1.0, [
                .nose: CGPoint(x: 0.47, y: 0.21),
                .leftShoulder: CGPoint(x: 0.40, y: 0.28), .rightShoulder: CGPoint(x: 0.55, y: 0.28),
                .leftElbow: CGPoint(x: 0.36, y: 0.39), .leftWrist: CGPoint(x: 0.40, y: 0.49),
                .rightElbow: CGPoint(x: 0.58, y: 0.38), .rightWrist: CGPoint(x: 0.52, y: 0.48),
                .leftHip: CGPoint(x: 0.42, y: 0.50), .rightHip: CGPoint(x: 0.53, y: 0.50),
                .leftKnee: CGPoint(x: 0.43, y: 0.70), .rightKnee: CGPoint(x: 0.50, y: 0.68),
                .leftAnkle: CGPoint(x: 0.43, y: 0.89), .rightAnkle: CGPoint(x: 0.48, y: 0.85)
            ])
        ]

        for p in streetPoses {
            list.append(AIPoseTemplate(
                id: p.0, title: p.1, category: .street,
                compositionRule: p.2, idealZoom: p.3,
                keypoints: p.4
            ))
        }

        return list
    }
}
