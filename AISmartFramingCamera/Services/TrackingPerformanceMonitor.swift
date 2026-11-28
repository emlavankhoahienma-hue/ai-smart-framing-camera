import Foundation
import Combine

/// Snapshot published at 4Hz ONLY when the Tracking Performance Debug HUD is explicitly enabled.
public struct TrackingPerfSnapshot: Sendable, Equatable {
    public let cameraFPS: Double
    public let overlayFPS: Double
    public let droppedFrames: UInt64
    public let frameToVisionP50Ms: Double
    public let frameToVisionP95Ms: Double
    public let visionTrackP50Ms: Double
    public let visionTrackP95Ms: Double
    public let trackToUIP50Ms: Double
    public let trackToUIP95Ms: Double
    public let mainThreadMaxBlockMs: Double
    public let memoryPhysMB: Double
    public let memoryAvailMB: Int
    public let thermalState: String
    public let displayZoom: Double

    public static let empty = TrackingPerfSnapshot(
        cameraFPS: 0,
        overlayFPS: 0,
        droppedFrames: 0,
        frameToVisionP50Ms: 0,
        frameToVisionP95Ms: 0,
        visionTrackP50Ms: 0,
        visionTrackP95Ms: 0,
        trackToUIP50Ms: 0,
        trackToUIP95Ms: 0,
        mainThreadMaxBlockMs: 0,
        memoryPhysMB: 0,
        memoryAvailMB: -1,
        thermalState: "nom",
        displayZoom: 1.0
    )
}

/// Dedicated ObservableObject for the Debug HUD so 4Hz telemetry updates NEVER trigger
/// SwiftUI body re-evaluation on `CameraMainView`.
@MainActor
public final class TrackingPerfHUDState: ObservableObject {
    @Published public var snapshot: TrackingPerfSnapshot = .empty
    public init() {}
}

/// Zero-overhead-when-OFF real-time pipeline latency & FPS profiler for on-device verification.
/// - Default `isEnabled = false`: every `record*` call returns immediately on a single lock-free check.
/// - When enabled in Debug Settings: maintains fixed-size ring buffers (120 entries, zero heap growth)
///   for per-stage latencies (p50/p95), camera/overlay FPS, dropped frames, thermal state, and memory.
public final class TrackingPerformanceMonitor: @unchecked Sendable {
    public static let shared = TrackingPerformanceMonitor()

    private struct RingBuffer {
        private var storage: [Double]
        private var writeIndex: Int = 0
        private var count: Int = 0
        private let capacity: Int

        init(capacity: Int = 120) {
            self.capacity = max(8, capacity)
            self.storage = Array(repeating: 0, count: self.capacity)
        }

        mutating func append(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity { count += 1 }
        }

        mutating func reset() {
            writeIndex = 0
            count = 0
        }

        func percentiles() -> (p50: Double, p95: Double) {
            guard count > 0 else { return (0, 0) }
            let slice = Array(storage[0..<count]).sorted()
            let i50 = min(slice.count - 1, max(0, Int(Double(slice.count - 1) * 0.50)))
            let i95 = min(slice.count - 1, max(0, Int(Double(slice.count - 1) * 0.95)))
            return (slice[i50], slice[i95])
        }
    }

    private let stateLock = NSLock()
    private var enabledFlag: Bool = false

    private var frameToVisionRing = RingBuffer(capacity: 120)
    private var visionTrackRing = RingBuffer(capacity: 120)
    private var trackToUIRing = RingBuffer(capacity: 120)
    private var mainBlockMaxMs: Double = 0
    private var lastOverlayTickTime: TimeInterval = 0

    private var cameraFrameCountWindow: Int = 0
    private var overlayUpdateCountWindow: Int = 0
    private var windowStartTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastCameraFPS: Double = 0
    private var lastOverlayFPS: Double = 0
    private var droppedFrameCount: UInt64 = 0
    private var latestDisplayZoom: Double = 1.0
    private var lastPublishTime: TimeInterval = 0

    public var onSnapshotUpdated: ((TrackingPerfSnapshot) -> Void)?

    public init() {}

    public var isEnabled: Bool {
        stateLock.withLock { enabledFlag }
    }

    public func setEnabled(_ enabled: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.withLock {
            enabledFlag = enabled
            if enabled {
                frameToVisionRing.reset()
                visionTrackRing.reset()
                trackToUIRing.reset()
                mainBlockMaxMs = 0
                lastOverlayTickTime = 0
                cameraFrameCountWindow = 0
                overlayUpdateCountWindow = 0
                windowStartTime = now
                lastCameraFPS = 0
                lastOverlayFPS = 0
                droppedFrameCount = 0
                lastPublishTime = 0
            }
        }
    }

    /// Called on `videoDataQueue` when a camera frame arrives.
    public func recordCameraFrameArrival(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isEnabled else { return }
        var snapshotToEmit: TrackingPerfSnapshot?
        var callback: ((TrackingPerfSnapshot) -> Void)?
        stateLock.withLock {
            guard enabledFlag else { return }
            cameraFrameCountWindow += 1
            let dt = now - windowStartTime
            if dt >= 0.50 {
                lastCameraFPS = Double(cameraFrameCountWindow) / dt
                lastOverlayFPS = Double(overlayUpdateCountWindow) / dt
                cameraFrameCountWindow = 0
                overlayUpdateCountWindow = 0
                windowStartTime = now
            }
            if now - lastPublishTime >= 0.25 {
                lastPublishTime = now
                snapshotToEmit = buildSnapshotUnlocked()
                callback = onSnapshotUpdated
            }
        }
        if let snap = snapshotToEmit, let cb = callback {
            DispatchQueue.main.async { cb(snap) }
        }
    }

    public func recordDroppedFrame() {
        guard isEnabled else { return }
        stateLock.withLock {
            guard enabledFlag else { return }
            droppedFrameCount &+= 1
        }
    }

    /// Stage 1 latency: camera frame capture PTS -> start of Vision/tracking processing (ms).
    public func recordFrameToVisionLatency(ms: Double) {
        guard isEnabled, ms.isFinite, ms >= 0, ms < 5000 else { return }
        stateLock.withLock {
            guard enabledFlag else { return }
            frameToVisionRing.append(ms)
        }
    }

    /// Stage 2 latency: Vision/optical tracking execution time (ms).
    public func recordVisionTrackDuration(ms: Double) {
        guard isEnabled, ms.isFinite, ms >= 0, ms < 5000 else { return }
        stateLock.withLock {
            guard enabledFlag else { return }
            visionTrackRing.append(ms)
        }
    }

    /// Stage 3 latency: optical/spatial delivery -> main-thread overlay update (ms).
    public func recordOverlayUpdate(
        latencyMs: Double? = nil,
        displayZoom: Double? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isEnabled else { return }
        stateLock.withLock {
            guard enabledFlag else { return }
            overlayUpdateCountWindow += 1
            if let lat = latencyMs, lat.isFinite, lat >= 0, lat < 5000 {
                trackToUIRing.append(lat)
            }
            if lastOverlayTickTime > 0 {
                let gapMs = (now - lastOverlayTickTime) * 1000.0
                if gapMs > 36.0 && gapMs < 2000.0 {
                    mainBlockMaxMs = max(mainBlockMaxMs * 0.92, gapMs)
                } else {
                    mainBlockMaxMs *= 0.98
                }
            }
            lastOverlayTickTime = now
            if let z = displayZoom, z.isFinite, z > 0 {
                latestDisplayZoom = z
            }
        }
    }

    public func currentSnapshot() -> TrackingPerfSnapshot {
        stateLock.withLock { buildSnapshotUnlocked() }
    }

    private func buildSnapshotUnlocked() -> TrackingPerfSnapshot {
        let f2v = frameToVisionRing.percentiles()
        let vt = visionTrackRing.percentiles()
        let t2u = trackToUIRing.percentiles()
        let mem = CameraLogger.currentMemorySnapshot()
        return TrackingPerfSnapshot(
            cameraFPS: lastCameraFPS,
            overlayFPS: lastOverlayFPS,
            droppedFrames: droppedFrameCount,
            frameToVisionP50Ms: f2v.p50,
            frameToVisionP95Ms: f2v.p95,
            visionTrackP50Ms: vt.p50,
            visionTrackP95Ms: vt.p95,
            trackToUIP50Ms: t2u.p50,
            trackToUIP95Ms: t2u.p95,
            mainThreadMaxBlockMs: mainBlockMaxMs,
            memoryPhysMB: mem.physMB,
            memoryAvailMB: mem.availMB,
            thermalState: CameraLogger.thermalStateName(),
            displayZoom: latestDisplayZoom
        )
    }
}
