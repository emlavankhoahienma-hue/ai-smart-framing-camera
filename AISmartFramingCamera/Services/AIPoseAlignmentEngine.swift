import Foundation
import CoreGraphics
import Vision
import UIKit

// MARK: - Pose Alignment Result
public struct AIPoseAlignmentResult: Sendable {
    public let score: Double // 0.0 ... 1.0
    public let isMatched: Bool
    public let feedbackMessage: String
    public let recognizedJoints: [AIPoseJoint: CGPoint] // Normalized 0...1 (Top-Left)
    public let matchedJointsCount: Int
    public let totalTemplateJointsCount: Int

    public static let empty = AIPoseAlignmentResult(
        score: 0.0,
        isMatched: false,
        feedbackMessage: "Chưa nhận diện được người trong khung hình",
        recognizedJoints: [:],
        matchedJointsCount: 0,
        totalTemplateJointsCount: 0
    )
}

// MARK: - Real-time AI Pose Alignment Engine (Động Cơ So Khớp Khung Xương Bố Cục)
public final class AIPoseAlignmentEngine: @unchecked Sendable {
    public static let shared = AIPoseAlignmentEngine()

    private let lock = NSLock()
    private var isCurrentlyMatched: Bool = false

    // Ngưỡng trễ Hysteresis chống rung nhấp nháy
    private let matchThreshold: Double = 0.76
    private let releaseThreshold: Double = 0.68

    private init() {}

    public func reset() {
        lock.lock()
        isCurrentlyMatched = false
        lock.unlock()
    }

    /// Đánh giá độ khớp giữa quan sát khung xương Vision và khuôn mẫu tư thế
    public func evaluate(
        observation: VNHumanBodyPoseObservation,
        template: AIPoseTemplate
    ) -> AIPoseAlignmentResult {
        // 1. Trích xuất các điểm khớp từ Apple Vision (Chuyển sang toạ độ chuẩn UI Top-Left)
        let liveJoints = extractLiveJoints(from: observation)
        guard !liveJoints.isEmpty else {
            return .empty
        }

        // 2. Tính toán độ tương đồng hướng góc của các chi (Limb Angular Similarity)
        let limbScore = computeLimbAngularSimilarity(live: liveJoints, template: template.keypoints)

        // 3. Tính toán độ tương đồng vị trí tương đối và vùng phân bố (Spatial Placement)
        let spatialScore = computeSpatialAlignment(live: liveJoints, template: template)

        // 4. Tổng hợp điểm số (65% hướng chi + 35% vị trí không gian)
        let rawScore = max(0.0, min(1.0, 0.65 * limbScore + 0.35 * spatialScore))

        // 5. Cập nhật trạng thái Hysteresis
        lock.lock()
        if isCurrentlyMatched {
            if rawScore < releaseThreshold {
                isCurrentlyMatched = false
            }
        } else {
            if rawScore >= matchThreshold {
                isCurrentlyMatched = true
            }
        }
        let matched = isCurrentlyMatched
        lock.unlock()

        // 6. Tạo câu hướng dẫn trực quan theo thời gian thực
        let message: String
        if matched {
            let percent = Int(rawScore * 100)
            message = "\u{2713} Khớp dáng hoàn hảo (\(percent)%)! Bấm chụp ngay"
        } else if rawScore >= 0.68 {
            message = "Gần khớp! Giữ nguyên tư thế..."
        } else if rawScore >= 0.45 {
            message = "Căn chỉnh tay và vai theo đường viền"
        } else {
            message = "Di chuyển vào vùng khung hướng dẫn"
        }

        return AIPoseAlignmentResult(
            score: rawScore,
            isMatched: matched,
            feedbackMessage: message,
            recognizedJoints: liveJoints,
            matchedJointsCount: liveJoints.count,
            totalTemplateJointsCount: template.keypoints.count
        )
    }

    // MARK: - Private Helpers

    private func extractLiveJoints(from observation: VNHumanBodyPoseObservation) -> [AIPoseJoint: CGPoint] {
        var joints: [AIPoseJoint: CGPoint] = [:]

        let mapping: [(VNHumanBodyPoseObservation.JointName, AIPoseJoint)] = [
            (.nose, .nose),
            (.leftEye, .leftEye), (.rightEye, .rightEye),
            (.leftEar, .leftEar), (.rightEar, .rightEar),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.root, .leftHip), // Root mapped to hip centroid
            (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
        ]

        for (vName, pJoint) in mapping {
            if let point = try? observation.recognizedPoint(vName), point.confidence > 0.25 {
                // Vision: origin is bottom-left (0...1). UI: origin is top-left (0...1)
                joints[pJoint] = CGPoint(x: CGFloat(point.x), y: CGFloat(1.0 - point.y))
            }
        }
        return joints
    }

    private func computeLimbAngularSimilarity(
        live: [AIPoseJoint: CGPoint],
        template: [AIPoseJoint: CGPoint]
    ) -> Double {
        var totalCosine: Double = 0.0
        var limbCount: Int = 0

        // Các cặp chi đánh giá góc xoay
        let testLimbs: [(AIPoseJoint, AIPoseJoint)] = [
            (.leftShoulder, .leftElbow),
            (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow),
            (.rightElbow, .rightWrist),
            (.leftShoulder, .rightShoulder),
            (.leftHip, .rightHip),
            (.leftShoulder, .leftHip),
            (.rightShoulder, .rightHip),
            (.leftHip, .leftKnee),
            (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee),
            (.rightKnee, .rightAnkle)
        ]

        for (j1, j2) in testLimbs {
            guard let l1 = live[j1], let l2 = live[j2],
                  let t1 = template[j1], let t2 = template[j2] else {
                continue
            }

            let vLive = CGPoint(x: l2.x - l1.x, y: l2.y - l1.y)
            let vTemplate = CGPoint(x: t2.x - t1.x, y: t2.y - t1.y)

            let lenLive = hypot(vLive.x, vLive.y)
            let lenTemplate = hypot(vTemplate.x, vTemplate.y)

            guard lenLive > 0.005, lenTemplate > 0.005 else { continue }

            let dot = (vLive.x * vTemplate.x + vLive.y * vTemplate.y)
            let cosTheta = dot / (lenLive * lenTemplate)

            // Chuyển đổi cosTheta (-1...1) sang điểm (0...1)
            let normalizedScore = max(0.0, min(1.0, (cosTheta + 1.0) / 2.0))
            totalCosine += Double(normalizedScore)
            limbCount += 1
        }

        guard limbCount > 0 else { return 0.0 }
        return totalCosine / Double(limbCount)
    }

    private func computeSpatialAlignment(
        live: [AIPoseJoint: CGPoint],
        template: AIPoseTemplate
    ) -> Double {
        // 1. Tính trọng tâm của live pose
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var count: CGFloat = 0
        for pt in live.values {
            sumX += pt.x
            sumY += pt.y
            count += 1
        }
        guard count > 0 else { return 0.0 }
        let liveCentroid = CGPoint(x: sumX / count, y: sumY / count)

        // 2. Tính trọng tâm của template pose
        var tSumX: CGFloat = 0
        var tSumY: CGFloat = 0
        var tCount: CGFloat = 0
        for pt in template.keypoints.values {
            tSumX += pt.x
            tSumY += pt.y
            tCount += 1
        }
        guard tCount > 0 else { return 0.0 }
        let templateCentroid = CGPoint(x: tSumX / tCount, y: tSumY / tCount)

        // 3. Khoảng cách Euclidean giữa 2 tâm
        let dist = hypot(liveCentroid.x - templateCentroid.x, liveCentroid.y - templateCentroid.y)
        // Độ phân tán sigma = 0.22
        let score = exp(-Double(dist * dist) / (2.0 * 0.22 * 0.22))
        return max(0.0, min(1.0, score))
    }
}
