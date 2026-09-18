import CoreGraphics
import Foundation

/// Shared aspect-fill geometry for the preview layer and every visual overlay.
/// Normalized coordinates use a top-left origin, matching the app's UI model.
struct CameraPreviewGeometry: Sendable {
    let sourceAspectRatio: CGFloat

    init(sourceAspectRatio: CGFloat) {
        if sourceAspectRatio.isFinite, sourceAspectRatio > 0 {
            self.sourceAspectRatio = sourceAspectRatio
        } else {
            self.sourceAspectRatio = 3.0 / 4.0
        }
    }

    init(captureMode: CameraCaptureMode) {
        self.init(sourceAspectRatio: captureMode.isVideo ? 9.0 / 16.0 : 3.0 / 4.0)
    }

    func fittedSize(in container: CGSize) -> CGSize {
        guard container.width.isFinite,
              container.height.isFinite,
              container.width > 0,
              container.height > 0 else {
            return .zero
        }

        let containerAspect = container.width / container.height
        if containerAspect > sourceAspectRatio {
            return CGSize(width: container.height * sourceAspectRatio, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / sourceAspectRatio)
    }

    func screenPoint(fromNormalized point: CGPoint, in size: CGSize) -> CGPoint? {
        guard let normalized = Self.sanitizedNormalizedPoint(point),
              let transform = aspectFillTransform(in: size) else {
            return nil
        }
        return CGPoint(
            x: transform.origin.x + normalized.x * transform.displaySize.width,
            y: transform.origin.y + normalized.y * transform.displaySize.height
        )
    }

    func normalizedPoint(fromScreen point: CGPoint, in size: CGSize) -> CGPoint? {
        guard point.x.isFinite,
              point.y.isFinite,
              let transform = aspectFillTransform(in: size) else {
            return nil
        }
        let normalized = CGPoint(
            x: (point.x - transform.origin.x) / transform.displaySize.width,
            y: (point.y - transform.origin.y) / transform.displaySize.height
        )
        return Self.sanitizedNormalizedPoint(normalized)
    }

    func screenRect(fromNormalized rect: CGRect, in size: CGSize) -> CGRect? {
        guard let normalizedRect = Self.sanitizedNormalizedRect(rect),
              let topLeft = screenPoint(fromNormalized: normalizedRect.origin, in: size),
              let bottomRight = screenPoint(
                fromNormalized: CGPoint(x: normalizedRect.maxX, y: normalizedRect.maxY),
                in: size
              ) else {
            return nil
        }
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    func normalizedRect(fromScreen rect: CGRect, in size: CGSize) -> CGRect? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              let topLeft = normalizedPoint(fromScreen: rect.origin, in: size),
              let bottomRight = normalizedPoint(
                fromScreen: CGPoint(x: rect.maxX, y: rect.maxY),
                in: size
              ) else {
            return nil
        }
        return Self.sanitizedNormalizedRect(
            CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )
        )
    }

    static func sanitizedNormalizedPoint(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    static func sanitizedNormalizedRect(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite else {
            return nil
        }
        let bounded = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounded.isNull, bounded.width >= 0.002, bounded.height >= 0.002 else {
            return nil
        }
        return bounded
    }

    private func aspectFillTransform(in size: CGSize) -> (displaySize: CGSize, origin: CGPoint)? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        let containerAspect = size.width / size.height
        let displaySize: CGSize
        if containerAspect > sourceAspectRatio {
            displaySize = CGSize(width: size.width, height: size.width / sourceAspectRatio)
        } else {
            displaySize = CGSize(width: size.height * sourceAspectRatio, height: size.height)
        }
        return (
            displaySize,
            CGPoint(x: (size.width - displaySize.width) / 2, y: (size.height - displaySize.height) / 2)
        )
    }
}

public struct TrackedTargetObservation: Sendable {
    public let center: CGPoint
    public let boundingBox: CGRect
    public let confidence: Float
    public let isPredicted: Bool

    init?(center: CGPoint, boundingBox: CGRect, confidence: Float, isPredicted: Bool = false) {
        guard let safeCenter = CameraPreviewGeometry.sanitizedNormalizedPoint(center),
              let safeBox = CameraPreviewGeometry.sanitizedNormalizedRect(boundingBox),
              confidence.isFinite else {
            return nil
        }
        self.center = safeCenter
        self.boundingBox = safeBox
        self.confidence = min(max(confidence, 0), 1)
        self.isPredicted = isPredicted
    }
}

enum CameraCoordinateMapper {
    static func uiToDevice(_ point: CGPoint) -> CGPoint {
        let safe = finitePoint(point)
        return CGPoint(
            x: min(max(safe.y, 0.01), 0.99),
            y: min(max(1 - safe.x, 0.01), 0.99)
        )
    }

    static func deviceToUI(_ point: CGPoint) -> CGPoint {
        let safe = finitePoint(point)
        return CGPoint(
            x: min(max(1 - safe.y, 0.01), 0.99),
            y: min(max(safe.x, 0.01), 0.99)
        )
    }

    private static func finitePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x.isFinite ? point.x : 0.5,
            y: point.y.isFinite ? point.y : 0.5
        )
    }
}

enum AutofocusUpdatePolicy {
    static func shouldIssueUpdate(
        point: CGPoint,
        previousPoint: CGPoint,
        now: CFTimeInterval,
        previousUpdateTime: CFTimeInterval,
        isAEAFLocked: Bool,
        isManualFocus: Bool,
        force: Bool
    ) -> Bool {
        guard !isAEAFLocked,
              !isManualFocus,
              point.x.isFinite,
              point.y.isFinite,
              now.isFinite,
              previousUpdateTime.isFinite else {
            return false
        }
        let safe = CGPoint(x: min(max(point.x, 0.01), 0.99), y: min(max(point.y, 0.01), 0.99))
        let distance = hypot(safe.x - previousPoint.x, safe.y - previousPoint.y)
        return (distance > 0.08 || force) && (force || now - previousUpdateTime >= 0.30)
    }
}

/// Stateful, allocation-light box association and adaptive low-pass filter.
/// It rejects isolated jumps and predicts briefly through short occlusions.
struct DetectionRectStabilizer: Sendable {
    private struct Track: Sendable {
        var rect: CGRect
        var velocity: CGPoint = .zero
        var missedFrames = 0
        var age = 1
    }

    private struct PendingObservation: Sendable {
        var rect: CGRect
        var confirmations: Int
    }

    private var tracks: [Track] = []
    private var pendingObservations: [PendingObservation] = []
    private let maximumMissedFrames: Int

    init(maximumMissedFrames: Int = 8) {
        self.maximumMissedFrames = max(0, maximumMissedFrames)
    }

    mutating func reset() {
        tracks.removeAll(keepingCapacity: true)
        pendingObservations.removeAll(keepingCapacity: true)
    }

    mutating func update(with observations: [CGRect]) -> [CGRect] {
        let validObservations = observations.compactMap(CameraPreviewGeometry.sanitizedNormalizedRect)
        if tracks.isEmpty {
            tracks = validObservations.map { Track(rect: $0) }
            pendingObservations.removeAll(keepingCapacity: true)
            return tracks.map(\.rect)
        }
        var unusedIndices = Set(validObservations.indices)
        var updatedTracks: [Track] = []
        updatedTracks.reserveCapacity(max(tracks.count, validObservations.count))

        for var track in tracks {
            let predicted = predictedRect(for: track)
            let match = unusedIndices
                .map { index in (index, associationScore(predicted, validObservations[index])) }
                .filter { $0.1 >= 0.18 }
                .max { $0.1 < $1.1 }

            if let match {
                let observation = validObservations[match.0]
                unusedIndices.remove(match.0)
                update(&track, with: observation, predicted: predicted)
            } else {
                track.rect = predicted
                track.velocity = CGPoint(x: track.velocity.x * 0.72, y: track.velocity.y * 0.72)
                track.missedFrames += 1
                track.age += 1
            }

            if track.missedFrames <= maximumMissedFrames,
               let safeRect = CameraPreviewGeometry.sanitizedNormalizedRect(track.rect) {
                track.rect = safeRect
                updatedTracks.append(track)
            }
        }

        var nextPending: [PendingObservation] = []
        for index in unusedIndices.sorted() {
            let observation = validObservations[index]
            if var candidate = pendingObservations.first(where: { associationScore($0.rect, observation) >= 0.28 }) {
                candidate.rect = observation
                candidate.confirmations += 1
                if candidate.confirmations >= 2 {
                    updatedTracks.append(Track(rect: observation))
                } else {
                    nextPending.append(candidate)
                }
            } else {
                nextPending.append(PendingObservation(rect: observation, confirmations: 1))
            }
        }

        tracks = updatedTracks
        pendingObservations = nextPending
        return tracks.map(\.rect)
    }

    private func predictedRect(for track: Track) -> CGRect {
        let predictionScale = track.missedFrames == 0 ? 1.0 : pow(0.72, CGFloat(track.missedFrames))
        let center = CGPoint(
            x: track.rect.midX + track.velocity.x * predictionScale,
            y: track.rect.midY + track.velocity.y * predictionScale
        )
        return rect(centeredAt: center, size: track.rect.size)
    }

    private func associationScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        let iou = unionArea > 0 ? intersectionArea / unionArea : 0
        let centerDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        let centerScore = max(0, 1 - centerDistance / 0.35)
        let lhsArea = max(lhs.width * lhs.height, 0.000_001)
        let rhsArea = max(rhs.width * rhs.height, 0.000_001)
        let sizeScore = min(lhsArea, rhsArea) / max(lhsArea, rhsArea)
        return iou * 0.62 + centerScore * 0.28 + sizeScore * 0.10
    }

    private func update(_ track: inout Track, with observation: CGRect, predicted: CGRect) {
        let priorCenter = CGPoint(x: track.rect.midX, y: track.rect.midY)
        let observedCenter = CGPoint(x: observation.midX, y: observation.midY)
        let movement = hypot(observedCenter.x - priorCenter.x, observedCenter.y - priorCenter.y)
        let alpha = min(max(0.18 + movement * 2.4, 0.18), 0.72)

        let center = CGPoint(
            x: predicted.midX + (observedCenter.x - predicted.midX) * alpha,
            y: predicted.midY + (observedCenter.y - predicted.midY) * alpha
        )
        let sizeAlpha = min(alpha, 0.42)
        let size = CGSize(
            width: track.rect.width + (observation.width - track.rect.width) * sizeAlpha,
            height: track.rect.height + (observation.height - track.rect.height) * sizeAlpha
        )
        let measuredVelocity = CGPoint(x: center.x - priorCenter.x, y: center.y - priorCenter.y)
        track.velocity = CGPoint(
            x: track.velocity.x * 0.55 + measuredVelocity.x * 0.45,
            y: track.velocity.y * 0.55 + measuredVelocity.y * 0.45
        )
        track.rect = rect(centeredAt: center, size: size)
        track.missedFrames = 0
        track.age += 1
    }

    private func rect(centeredAt center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
