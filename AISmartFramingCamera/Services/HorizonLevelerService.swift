import Foundation
import Combine
import CoreMotion
import QuartzCore
import simd

/// Động cơ Thước Cân Bằng Chân Trời & Cân Phẳng 2 Trục chuẩn Apple Camera (60 Hz, độ chính xác < 0.55°).
///
/// Tái sử dụng duy nhất `DeviceMotionService.shared` (1 `CMMotionManager` toàn app theo khuyến nghị Apple CoreMotion),
/// lọc trọng lực thích ứng theo vận tốc xoay cổ tay (nhạy tức thì khi xoay, cực đầm khi giữ tĩnh),
/// tự ẩn mượt khi nghiêng quá ±22° giống Camera gốc iPhone và hỗ trợ cân phẳng 2 trục Overhead.
public final class HorizonLevelerService: ObservableObject {
    public static let shared = HorizonLevelerService()

    public struct Evaluation: Equatable, Sendable {
        public let rollDegrees: Double
        public let nearestCardinalDegrees: Double
        public let cardinalDeviationDegrees: Double
        public let isOverhead: Bool
        public let overheadOffsetX: Double
        public let overheadOffsetY: Double
        public let isLevel: Bool
        public let isVisible: Bool
    }

    @Published public private(set) var rollDegrees: Double = 0.0
    /// Độ lệch góc so với phương ngang/dọc gần nhất (0°, ±90°, 180°), nằm trong [-45°, +45°].
    @Published public private(set) var cardinalDeviationDegrees: Double = 0.0
    /// Mốc trục chính gần nhất (0°, +90°, -90°, 180°).
    @Published public private(set) var nearestCardinalDegrees: Double = 0.0
    /// `true` khi máy hướng thẳng xuống mặt bàn (flat-lay) hoặc thẳng lên trời.
    @Published public private(set) var isOverheadMode: Bool = false
    /// Độ lệch 2 trục chuẩn hóa [-1, +1] khi ở chế độ cân phẳng Overhead.
    @Published public private(set) var overheadOffsetX: Double = 0.0
    @Published public private(set) var overheadOffsetY: Double = 0.0
    /// `true` khi máy đã cân bằng chuẩn trong ngưỡng hẹp chuẩn Apple Camera.
    @Published public private(set) var isLevel: Bool = false
    /// `true` khi góc nghiêng nằm trong vùng cân bằng hữu ích (±20° chân trời hoặc ±24° chụp phẳng); tự ẩn khi nghiêng mạnh.
    @Published public private(set) var isVisible: Bool = false
    @Published public private(set) var isReceivingMotion: Bool = false

    public var isHapticsEnabled: Bool = true
    public var onLevelStateUpdated: ((Double, Bool) -> Void)?

    private let stateLock = NSLock()
    private var subscriptionID: UUID?
    private var rollOffsetDegrees: Double = 0.0
    private var smoothedGravity: SIMD3<Double> = SIMD3<Double>(0, -1, 0)
    private var hasSeededGravity: Bool = false
    private var internalIsOverhead: Bool = false
    private var internalIsLevel: Bool = false
    private var internalIsVisible: Bool = false
    private var internalCardinalDegrees: Double = 0.0
    private var lastPublishTime: CFTimeInterval = 0
    private var lastPublishedEval: Evaluation? = nil
    private var lastHapticTime: CFTimeInterval = -.infinity
    private var hasTriggeredHapticForCurrentLevel: Bool = false

    private init() {}

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return subscriptionID != nil
    }

    public func updateRollOffset(_ degrees: Double) {
        stateLock.lock()
        rollOffsetDegrees = degrees.isFinite ? degrees : 0.0
        stateLock.unlock()
    }

    public func start(rollOffsetDegrees: Double = 0.0) {
        stateLock.lock()
        self.rollOffsetDegrees = rollOffsetDegrees.isFinite ? rollOffsetDegrees : 0.0
        if subscriptionID != nil {
            stateLock.unlock()
            return
        }
        hasSeededGravity = false
        lastPublishTime = 0
        lastPublishedEval = nil
        stateLock.unlock()

        let id = DeviceMotionService.shared.subscribe { [weak self] sample in
            self?.processMotionSample(sample)
        }

        stateLock.lock()
        if subscriptionID == nil {
            subscriptionID = id
            stateLock.unlock()
        } else {
            stateLock.unlock()
            DeviceMotionService.shared.unsubscribe(id)
        }
    }

    public func stop() {
        stateLock.lock()
        let activeID = subscriptionID
        subscriptionID = nil
        hasSeededGravity = false
        lastPublishedEval = nil
        stateLock.unlock()

        if let activeID {
            DeviceMotionService.shared.unsubscribe(activeID)
        }
        DispatchQueue.main.async { [weak self] in
            self?.isReceivingMotion = false
            self?.isVisible = false
        }
    }

    /// Tính toán thuần từ vector trọng lực thiết bị (độ chính xác chuẩn Apple Camera, không phụ thuộc UI).
    public static func evaluateGravity(
        _ gravity: SIMD3<Double>,
        rollOffsetDegrees: Double,
        wasOverhead: Bool,
        wasLevel: Bool,
        wasVisible: Bool = true,
        previousCardinalDegrees: Double = 0.0
    ) -> Evaluation {
        let len = simd_length(gravity)
        let g = (len.isFinite && len > 1e-6) ? (gravity / len) : SIMD3<Double>(0, -1, 0)

        // Hysteresis chuyển đổi giữa cân chân trời (upright/landscape) và cân phẳng 2 trục (flat-lay / overhead).
        // Dùng ngưỡng 0.85 (~58° pitch) để tránh vùng phóng đại nhiễu atan2 khi chúc máy xuống nhẹ 35–50°.
        let absZ = abs(g.z)
        let isOverhead = wasOverhead ? (absZ >= 0.78) : (absZ >= 0.85)

        // Góc roll quang học thực tế trên mặt phẳng cảm biến: atan2(gx, -gy).
        let rawRoll = atan2(g.x, -g.y) * 180.0 / .pi
        let calibratedRoll = wrapAngle180(rawRoll - rollOffsetDegrees)

        // Chọn mốc trục chính (0°, +90°, -90°, 180°) có hysteresis ±3° quanh biên ±45° để không giật trục.
        let prevDelta = abs(wrapAngle180(calibratedRoll - previousCardinalDegrees))
        let nearestCardinal: Double
        if prevDelta <= 48.0 {
            nearestCardinal = wrapAngle180(previousCardinalDegrees)
        } else {
            nearestCardinal = wrapAngle180((calibratedRoll / 90.0).rounded() * 90.0)
        }
        let deviation = wrapAngle180(calibratedRoll - nearestCardinal)

        // Cân phẳng 2 trục (Overhead / Flat-lay): phạm vi hiển thị mượt ±22° (sin 22° ≈ 0.375)
        let clampedX = max(-1.0, min(1.0, g.x / 0.375))
        let clampedY = max(-1.0, min(1.0, -g.y / 0.375))
        let tiltFromFlatDegrees = asin(min(1.0, hypot(g.x, g.y))) * 180.0 / .pi

        // Ngưỡng cân bằng chính xác cao giống Apple Camera:
        // - Chân trời: vào <= 0.55°, thoát > 0.90° (không bị lệch mắt thường)
        // - Chụp phẳng: vào <= 0.85°, thoát > 1.30°
        let isLevel: Bool
        let isVisible: Bool
        if isOverhead {
            isLevel = tiltFromFlatDegrees <= (wasLevel ? 1.30 : 0.85)
            isVisible = tiltFromFlatDegrees <= (wasVisible ? 26.0 : 22.0)
        } else {
            isLevel = abs(deviation) <= (wasLevel ? 0.90 : 0.55)
            isVisible = abs(deviation) <= (wasVisible ? 22.0 : 19.0)
        }

        return Evaluation(
            rollDegrees: calibratedRoll,
            nearestCardinalDegrees: nearestCardinal,
            cardinalDeviationDegrees: deviation,
            isOverhead: isOverhead,
            overheadOffsetX: clampedX,
            overheadOffsetY: clampedY,
            isLevel: isLevel,
            isVisible: isVisible
        )
    }

    public static func wrapAngle180(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0.0 }
        var a = degrees.truncatingRemainder(dividingBy: 360.0)
        if a > 180.0 { a -= 360.0 }
        if a <= -180.0 { a += 360.0 }
        return a
    }

    private func processMotionSample(_ sample: TrackingMotionSample) {
        let q = sample.deviceToWorld
        let qVec = q.vector
        guard qVec.x.isFinite, qVec.y.isFinite, qVec.z.isFinite, qVec.w.isFinite,
              simd_length(qVec) > 1e-9 else { return }

        // Hệ tọa độ tham chiếu CoreMotion (.xArbitraryZVertical): +Z hướng lên trời => trọng lực thế giới = (0, 0, -1).
        // `deviceToWorld.inverse` ánh xạ từ thế giới về hệ tọa độ thiết bị (gx, gy, gz).
        let rawGravity = q.inverse.act(SIMD3<Double>(0.0, 0.0, -1.0))
        guard rawGravity.x.isFinite, rawGravity.y.isFinite, rawGravity.z.isFinite else { return }

        let now = CACurrentMediaTime()

        stateLock.lock()
        guard subscriptionID != nil else {
            stateLock.unlock()
            return
        }

        // Lọc thích ứng vận tốc: xoay tay nhanh phản hồi tức thì (alpha cao), giữ tĩnh triệt rung vi mô (alpha thấp)
        if !hasSeededGravity {
            smoothedGravity = rawGravity
            hasSeededGravity = true
        } else {
            let delta = simd_length(rawGravity - smoothedGravity)
            let alpha = min(0.52, max(0.14, 0.14 + delta * 2.8))
            smoothedGravity = simd_normalize(smoothedGravity * (1.0 - alpha) + rawGravity * alpha)
        }

        // 60 Hz mượt như Camera gốc iPhone (có deadband tránh phát thừa khi máy đứng yên)
        if now - lastPublishTime < (1.0 / 60.0) {
            stateLock.unlock()
            return
        }

        let result = Self.evaluateGravity(
            smoothedGravity,
            rollOffsetDegrees: rollOffsetDegrees,
            wasOverhead: internalIsOverhead,
            wasLevel: internalIsLevel,
            wasVisible: internalIsVisible,
            previousCardinalDegrees: internalCardinalDegrees
        )

        let prevLevel = internalIsLevel
        internalIsOverhead = result.isOverhead
        internalIsLevel = result.isLevel
        internalIsVisible = result.isVisible
        internalCardinalDegrees = result.nearestCardinalDegrees

        var shouldFireHaptic = false
        if result.isLevel && result.isVisible && !prevLevel && !hasTriggeredHapticForCurrentLevel {
            if now - lastHapticTime >= 0.85 {
                lastHapticTime = now
                shouldFireHaptic = true
            }
            hasTriggeredHapticForCurrentLevel = true
        } else if !result.isLevel {
            hasTriggeredHapticForCurrentLevel = false
        }

        let needsUIUpdate: Bool
        if let prev = lastPublishedEval {
            needsUIUpdate = prev.isLevel != result.isLevel
                || prev.isVisible != result.isVisible
                || prev.isOverhead != result.isOverhead
                || prev.nearestCardinalDegrees != result.nearestCardinalDegrees
                || abs(prev.cardinalDeviationDegrees - result.cardinalDeviationDegrees) >= 0.06
                || abs(prev.overheadOffsetX - result.overheadOffsetX) >= 0.005
                || abs(prev.overheadOffsetY - result.overheadOffsetY) >= 0.005
        } else {
            needsUIUpdate = true
        }

        if needsUIUpdate {
            lastPublishTime = now
            lastPublishedEval = result
        }
        stateLock.unlock()

        guard needsUIUpdate || shouldFireHaptic else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rollDegrees = result.rollDegrees
            self.nearestCardinalDegrees = result.nearestCardinalDegrees
            self.cardinalDeviationDegrees = result.cardinalDeviationDegrees
            self.isOverheadMode = result.isOverhead
            self.overheadOffsetX = result.overheadOffsetX
            self.overheadOffsetY = result.overheadOffsetY
            self.isLevel = result.isLevel
            self.isVisible = result.isVisible
            if !self.isReceivingMotion {
                self.isReceivingMotion = true
            }
            if shouldFireHaptic && self.isHapticsEnabled {
                HapticFeedbackService.shared.triggerSelectionChange()
            }
            self.onLevelStateUpdated?(result.rollDegrees, result.isLevel)
        }
    }
}
