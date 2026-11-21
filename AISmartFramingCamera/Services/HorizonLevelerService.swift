import Foundation
import Combine
import CoreMotion
import QuartzCore
import simd

/// Động cơ Thước Cân Bằng Chân Trời & Cân Phẳng 2 Trục (Virtual Horizon & Flatlay Bubble Level).
///
/// Tái sử dụng duy nhất `DeviceMotionService.shared` (1 `CMMotionManager` toàn app theo khuyến nghị Apple CoreMotion)
/// thay vì tạo thêm `CMMotionManager` cạnh tranh, tự tạm dừng khi app ẩn/ngủ đông và hỗ trợ đầy đủ:
/// - Cân bằng ngang/dọc toàn vòng 360° (Portrait 0°, Landscape ±90°, Upside-down 180°)
/// - Cân phẳng 2 trục chụp từ trên xuống / hướng lên trời (Overhead / Flatlay khi |gz| >= 0.80)
public final class HorizonLevelerService: ObservableObject {
    public static let shared = HorizonLevelerService()

    @Published public private(set) var rollDegrees: Double = 0.0
    /// Độ lệch góc so với phương ngang/dọc gần nhất (0°, ±90°, 180°), luôn nằm trong [-45°, +45°].
    @Published public private(set) var cardinalDeviationDegrees: Double = 0.0
    /// Mốc trục chính gần nhất (0°, +90°, -90°, 180°).
    @Published public private(set) var nearestCardinalDegrees: Double = 0.0
    /// `true` khi máy hướng thẳng xuống mặt bàn (chụp flatlay/đồ ăn) hoặc thẳng lên trời.
    @Published public private(set) var isOverheadMode: Bool = false
    /// Độ lệch 2 trục chuẩn hóa [-1, +1] khi ở chế độ cân phẳng Overhead.
    @Published public private(set) var overheadOffsetX: Double = 0.0
    @Published public private(set) var overheadOffsetY: Double = 0.0
    /// `true` khi máy đã cân bằng chuẩn trong ngưỡng trễ (hysteresis).
    @Published public private(set) var isLevel: Bool = false
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
    private var lastPublishTime: CFTimeInterval = 0
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

    public func start(rollOffsetDegrees: Double) {
        stateLock.lock()
        self.rollOffsetDegrees = rollOffsetDegrees.isFinite ? rollOffsetDegrees : 0.0
        if subscriptionID != nil {
            stateLock.unlock()
            return
        }
        hasSeededGravity = false
        lastPublishTime = 0
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
        stateLock.unlock()

        if let activeID {
            DeviceMotionService.shared.unsubscribe(activeID)
        }
        DispatchQueue.main.async { [weak self] in
            self?.isReceivingMotion = false
        }
    }

    /// Tính toán thuần từ vector trọng lực thiết bị (đã tách ra để kiểm thử toán học trực tiếp).
    public static func evaluateGravity(
        _ gravity: SIMD3<Double>,
        rollOffsetDegrees: Double,
        wasOverhead: Bool,
        wasLevel: Bool
    ) -> (
        rollDegrees: Double,
        nearestCardinalDegrees: Double,
        cardinalDeviationDegrees: Double,
        isOverhead: Bool,
        overheadOffsetX: Double,
        overheadOffsetY: Double,
        isLevel: Bool
    ) {
        let len = simd_length(gravity)
        let g = (len.isFinite && len > 1e-6) ? (gravity / len) : SIMD3<Double>(0, -1, 0)

        // Hysteresis chuyển đổi giữa chế độ cân chân trời và cân phẳng 2 trục (chụp flatlay / hướng trời)
        let absZ = abs(g.z)
        let isOverhead = wasOverhead ? (absZ >= 0.74) : (absZ >= 0.82)

        // Trục dọc/ngang theo chiều trọng lực chiếu lên mặt phẳng màn hình (gx, gy)
        let rawRoll = atan2(g.x, -g.y) * 180.0 / .pi
        let calibratedRoll = wrapAngle180(rawRoll - rollOffsetDegrees)

        // Mốc 0°, +90°, -90°, 180° gần nhất để hoạt động chuẩn cả khi cầm dọc lẫn xoay ngang (Landscape)
        let nearestCardinal = (calibratedRoll / 90.0).rounded() * 90.0
        let deviation = wrapAngle180(calibratedRoll - nearestCardinal)

        // Độ lệch phẳng 2 trục (khi cầm ngang úp xuống hoặc ngửa lên)
        let clampedX = max(-1.0, min(1.0, g.x / 0.35))
        let clampedY = max(-1.0, min(1.0, -g.y / 0.35))
        let tiltFromFlatDegrees = asin(min(1.0, hypot(g.x, g.y))) * 180.0 / .pi

        let isLevel: Bool
        if isOverhead {
            isLevel = tiltFromFlatDegrees <= (wasLevel ? 2.2 : 1.5)
        } else {
            isLevel = abs(deviation) <= (wasLevel ? 1.4 : 0.9)
        }

        return (
            rollDegrees: calibratedRoll,
            nearestCardinalDegrees: wrapAngle180(nearestCardinal),
            cardinalDeviationDegrees: deviation,
            isOverhead: isOverhead,
            overheadOffsetX: clampedX,
            overheadOffsetY: clampedY,
            isLevel: isLevel
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

        // Hệ tọa độ tham chiếu CoreMotion (.xArbitraryZVertical) có +Z hướng lên trời => trọng lực thế giới = (0, 0, -1).
        // `deviceToWorld.inverse` ánh xạ vector trọng lực từ thế giới về hệ tọa độ thiết bị (gx, gy, gz).
        let rawGravity = q.inverse.act(SIMD3<Double>(0.0, 0.0, -1.0))
        guard rawGravity.x.isFinite, rawGravity.y.isFinite, rawGravity.z.isFinite else { return }

        let now = CACurrentMediaTime()

        stateLock.lock()
        guard subscriptionID != nil else {
            stateLock.unlock()
            return
        }

        // Lọc thông thấp EMA nhẹ để thanh thước trượt mượt như Camera gốc iPhone, triệt tiêu rung vi mô
        if !hasSeededGravity {
            smoothedGravity = rawGravity
            hasSeededGravity = true
        } else {
            let alpha = 0.24
            smoothedGravity = smoothedGravity * (1.0 - alpha) + rawGravity * alpha
        }

        // Giới hạn tần suất đẩy lên MainActor ở 30 Hz (~33ms) để UI mượt tuyệt đối mà không tốn CPU
        if now - lastPublishTime < (1.0 / 30.0) {
            stateLock.unlock()
            return
        }
        lastPublishTime = now

        let result = Self.evaluateGravity(
            smoothedGravity,
            rollOffsetDegrees: rollOffsetDegrees,
            wasOverhead: internalIsOverhead,
            wasLevel: internalIsLevel
        )

        let prevLevel = internalIsLevel
        internalIsOverhead = result.isOverhead
        internalIsLevel = result.isLevel

        var shouldFireHaptic = false
        if result.isLevel && !prevLevel && !hasTriggeredHapticForCurrentLevel {
            if now - lastHapticTime >= 1.4 {
                lastHapticTime = now
                shouldFireHaptic = true
            }
            hasTriggeredHapticForCurrentLevel = true
        } else if !result.isLevel {
            hasTriggeredHapticForCurrentLevel = false
        }
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rollDegrees = result.rollDegrees
            self.nearestCardinalDegrees = result.nearestCardinalDegrees
            self.cardinalDeviationDegrees = result.cardinalDeviationDegrees
            self.isOverheadMode = result.isOverhead
            self.overheadOffsetX = result.overheadOffsetX
            self.overheadOffsetY = result.overheadOffsetY
            self.isLevel = result.isLevel
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
