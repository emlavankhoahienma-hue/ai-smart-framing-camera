import Foundation
import CoreGraphics
import QuartzCore

/// Bộ theo dõi và làm mịn hộp nhận diện theo thời gian thực (Real-time Temporal Box Tracker).
/// - Giữ nguyên danh tính thực thể (Persistent UUID) giữa các khung hình liên tiếp.
/// - Áp dụng bộ lọc thích nghi hàm mũ (Adaptive Exponential Moving Average - EMA) triệt tiêu rung giật (anti-jitter).
/// - Cơ chế trôi quán tính (Temporal Coasting) duy trì hộp khi mạng nơ-ron bỏ lỡ 1-2 khung hình, chống chớp tắt.
public final class LiveEntityTracker: @unchecked Sendable {
    public static let shared = LiveEntityTracker()

    private struct TrackedState {
        let id: UUID
        var category: NeuralSubjectCategory
        var label: String
        var confidence: Float
        var smoothedRect: CGRect
        var velocity: CGVector
        var missedCount: Int
        var trackedCount: Int
        var lastSeenTimestamp: TimeInterval
    }

    private let lock = NSLock()
    private var activeTracks: [TrackedState] = []
    private var lastUpdateTimestamp: TimeInterval = 0

    public init() {}

    /// Xóa toàn bộ lịch sử theo dõi (khi chuyển chế độ hoặc reset camera).
    public func reset() {
        lock.withLock {
            activeTracks.removeAll()
            lastUpdateTimestamp = 0
        }
    }

    /// Cập nhật các quan sát thô từ YOLO/Vision và trả về danh sách thực thể mượt mà với UUID cố định.
    public func update(
        with rawCandidates: [LiveDetectedEntity],
        timestamp: TimeInterval = CACurrentMediaTime()
    ) -> [LiveDetectedEntity] {
        lock.withLock {
            let dt = lastUpdateTimestamp > 0 ? min(0.20, max(0.01, timestamp - lastUpdateTimestamp)) : 0.05
            lastUpdateTimestamp = timestamp

            let remainingCandidates = rawCandidates
            var updatedTracks: [TrackedState] = []
            var matchedCandidateIndices = Set<Int>()

            // 1. Đối sánh (Association) giữa các Track đang theo dõi và các Candidate mới
            for var track in activeTracks {
                var bestCandidateIndex: Int?
                var bestScore: CGFloat = -1.0

                for (index, candidate) in remainingCandidates.enumerated() {
                    guard !matchedCandidateIndices.contains(index) else { continue }
                    guard isCategoryCompatible(track.category, candidate.category) else { continue }

                    let iou = calculateIoU(track.smoothedRect, candidate.rect)
                    let centerDist = calculateCenterDistance(track.smoothedRect, candidate.rect)

                    // Tiêu chí kết đôi: IoU cao hoặc khoảng cách tâm gần
                    let score = iou * 0.70 + max(0, 1.0 - centerDist * 3.5) * 0.30
                    if (iou >= 0.22 || centerDist <= 0.12) && score > bestScore {
                        bestScore = score
                        bestCandidateIndex = index
                    }
                }

                if let matchedIdx = bestCandidateIndex {
                    let candidate = remainingCandidates[matchedIdx]
                    matchedCandidateIndices.insert(matchedIdx)

                    // Tính độ dịch chuyển tâm để điều chỉnh hệ số làm mịn thích nghi alpha
                    let moveDist = calculateCenterDistance(track.smoothedRect, candidate.rect)
                    let alpha: CGFloat
                    if moveDist < 0.012 {
                        // Rung vi mô do nhiễu cảm biến -> Lọc mạnh (Anti-Jitter)
                        alpha = 0.35
                    } else if moveDist <= 0.08 {
                        // Chuyển động người/vật bình thường -> Mượt mà tự nhiên
                        alpha = 0.58
                    } else {
                        // Lia máy nhanh hoặc đổi hướng đột ngột -> Bám nhanh (Zero Lag)
                        alpha = 0.88
                    }

                    let raw = candidate.rect
                    let prev = track.smoothedRect
                    let newSmoothed = CGRect(
                        x: prev.origin.x * (1 - alpha) + raw.origin.x * alpha,
                        y: prev.origin.y * (1 - alpha) + raw.origin.y * alpha,
                        width: prev.size.width * (1 - alpha) + raw.size.width * alpha,
                        height: prev.size.height * (1 - alpha) + raw.size.height * alpha
                    )

                    let vx = CGFloat(newSmoothed.midX - prev.midX) / CGFloat(dt)
                    let vy = CGFloat(newSmoothed.midY - prev.midY) / CGFloat(dt)

                    track.category = candidate.category
                    track.label = candidate.label
                    track.confidence = candidate.confidence * 0.6 + track.confidence * 0.4
                    track.smoothedRect = clampToUnitRect(newSmoothed)
                    track.velocity = CGVector(dx: vx, dy: vy)
                    track.missedCount = 0
                    track.trackedCount += 1
                    track.lastSeenTimestamp = timestamp

                    updatedTracks.append(track)
                } else {
                    // Track bị lỡ trong khung hình này -> Duy trì quán tính (Coasting) tối đa 3 frame (~150ms)
                    if track.missedCount < 3 && track.trackedCount >= 2 {
                        let coastedRect = CGRect(
                            x: track.smoothedRect.origin.x + track.velocity.dx * CGFloat(dt) * 0.5,
                            y: track.smoothedRect.origin.y + track.velocity.dy * CGFloat(dt) * 0.5,
                            width: track.smoothedRect.size.width,
                            height: track.smoothedRect.size.height
                        )
                        track.smoothedRect = clampToUnitRect(coastedRect)
                        track.confidence *= 0.85
                        track.missedCount += 1
                        updatedTracks.append(track)
                    }
                }
            }

            // 2. Thêm các Candidate mới chưa được ghép cặp
            for (index, candidate) in remainingCandidates.enumerated() {
                guard !matchedCandidateIndices.contains(index) else { continue }
                guard candidate.confidence >= 0.35 else { continue }

                let newTrack = TrackedState(
                    id: UUID(),
                    category: candidate.category,
                    label: candidate.label,
                    confidence: candidate.confidence,
                    smoothedRect: clampToUnitRect(candidate.rect),
                    velocity: .zero,
                    missedCount: 0,
                    trackedCount: 1,
                    lastSeenTimestamp: timestamp
                )
                updatedTracks.append(newTrack)
            }

            // 3. Khử trùng lặp lồng nhau giữa các Track (NMS trên danh sách Tracked)
            var finalTracks: [TrackedState] = []
            let sortedByPriority = updatedTracks.sorted {
                if $0.category.priorityWeight != $1.category.priorityWeight {
                    return $0.category.priorityWeight > $1.category.priorityWeight
                }
                return $0.confidence > $1.confidence
            }

            for track in sortedByPriority {
                let duplicate = finalTracks.contains { existing in
                    let inter = existing.smoothedRect.intersection(track.smoothedRect)
                    guard !inter.isNull, !inter.isEmpty else { return false }
                    let interArea = inter.width * inter.height
                    let smallerArea = min(existing.smoothedRect.width * existing.smoothedRect.height,
                                          track.smoothedRect.width * track.smoothedRect.height)
                    guard smallerArea > 0 else { return false }
                    let overlap = interArea / smallerArea
                    return overlap > 0.65 && (existing.category == track.category || existing.category == .face)
                }
                if !duplicate {
                    finalTracks.append(track)
                }
            }

            activeTracks = finalTracks

            // 4. Trả về thực thể trực tiếp với UUID cố định
            return finalTracks.prefix(8).map {
                LiveDetectedEntity(
                    id: $0.id,
                    rect: $0.smoothedRect,
                    label: $0.label,
                    confidence: $0.confidence,
                    category: $0.category,
                    lastSeen: $0.lastSeenTimestamp
                )
            }
        }
    }

    // MARK: - Private Geometric Helpers

    private func isCategoryCompatible(_ a: NeuralSubjectCategory, _ b: NeuralSubjectCategory) -> Bool {
        if a == b { return true }
        if (a == .face && b == .human) || (a == .human && b == .face) { return true }
        return false
    }

    private func calculateIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = (a.width * a.height) + (b.width * b.height) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    private func calculateCenterDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func clampToUnitRect(_ rect: CGRect) -> CGRect {
        let minX = max(0, min(1, rect.minX))
        let minY = max(0, min(1, rect.minY))
        let maxX = max(minX + 0.03, min(1, rect.maxX))
        let maxY = max(minY + 0.03, min(1, rect.maxY))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
