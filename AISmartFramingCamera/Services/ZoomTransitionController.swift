import Foundation
import CoreGraphics

// MARK: - Unified Zoom Source, Hardware Mapping & Smooth Logarithmic Controller

/// Origin of a zoom change command. Only `.manual` and `.pinchContinuous` may drop below 1.0x.
public enum ZoomCommandSource: String, Sendable, Equatable {
    case auto = "AUTO"
    case manual = "MANUAL"
    case pinchContinuous = "PINCH"
    case systemRestore = "SYS_RESTORE"
    case lensInit = "INIT"
}

/// Reason a zoom request was accepted, clamped, or rejected by `ZoomTransitionController`.
public enum ZoomCommandOutcome: String, Sendable, Equatable {
    case acceptedImmediate = "ACCEPTED_IMMEDIATE"
    case acceptedSmooth = "ACCEPTED_SMOOTH"
    case acceptedRedirectedSmooth = "ACCEPTED_REDIRECTED"
    case rejectedInvalidInput = "REJECTED_INVALID"
    case rejectedAutoFloorClampedToCurrent = "REJECTED_AUTO_FLOOR"
    case rejectedDeadband = "REJECTED_DEADBAND"
    case rejectedTransitionBusy = "REJECTED_TRANSITION_BUSY"
    case rejectedSettling = "REJECTED_SETTLING"
    case rejectedSwitchoverHysteresis = "REJECTED_SWITCHOVER_HYSTERESIS"
    case rejectedReversalCooldown = "REJECTED_REVERSAL_COOLDOWN"
    case rejectedSameDirectionCooldown = "REJECTED_COOLDOWN"
    case rejectedRateBudgetExceeded = "REJECTED_RATE_BUDGET"
}

/// Snapshot of active camera lens/multiplier geometry used at the SINGLE conversion chokepoint.
public struct ZoomHardwareConfig: Sendable, Equatable {
    /// Multiplier converting display zoom -> raw AVCaptureDevice videoZoomFactor (e.g. 2.0 on Triple/DualWide, 1.0 on Dual Wide+Tele / Single Wide).
    public var displayMultiplier: CGFloat
    public var minDeviceZoom: CGFloat
    public var maxDeviceZoom: CGFloat
    public var hasPhysicalUltraWide: Bool
    public var allowsSimulatedUltraWide: Bool
    public var isDualCameraActive: Bool
    public var isFrontCamera: Bool
    public var isStandaloneTelephoto: Bool
    public var telephotoOpticalDisplayZoom: CGFloat
    public var opticalSwitchoverDisplayZooms: [CGFloat]
    public var maxDisplayZoomCap: CGFloat

    public init(
        displayMultiplier: CGFloat = 1.0,
        minDeviceZoom: CGFloat = 1.0,
        maxDeviceZoom: CGFloat = 10.0,
        hasPhysicalUltraWide: Bool = false,
        allowsSimulatedUltraWide: Bool = false,
        isDualCameraActive: Bool = false,
        isFrontCamera: Bool = false,
        isStandaloneTelephoto: Bool = false,
        telephotoOpticalDisplayZoom: CGFloat = 2.0,
        opticalSwitchoverDisplayZooms: [CGFloat] = [1.0, 2.0],
        maxDisplayZoomCap: CGFloat = 10.0
    ) {
        self.displayMultiplier = (displayMultiplier.isFinite && displayMultiplier > 0) ? displayMultiplier : 1.0
        self.minDeviceZoom = (minDeviceZoom.isFinite && minDeviceZoom > 0) ? minDeviceZoom : 1.0
        self.maxDeviceZoom = (maxDeviceZoom.isFinite && maxDeviceZoom >= self.minDeviceZoom) ? maxDeviceZoom : max(self.minDeviceZoom, 10.0)
        self.hasPhysicalUltraWide = hasPhysicalUltraWide
        self.allowsSimulatedUltraWide = allowsSimulatedUltraWide
        self.isDualCameraActive = isDualCameraActive
        self.isFrontCamera = isFrontCamera
        self.isStandaloneTelephoto = isStandaloneTelephoto
        self.telephotoOpticalDisplayZoom = (telephotoOpticalDisplayZoom.isFinite && telephotoOpticalDisplayZoom > 1.0) ? telephotoOpticalDisplayZoom : 2.0
        self.opticalSwitchoverDisplayZooms = opticalSwitchoverDisplayZooms
        self.maxDisplayZoomCap = (maxDisplayZoomCap.isFinite && maxDisplayZoomCap >= 1.0) ? maxDisplayZoomCap : 10.0
    }

    /// Minimum display zoom allowed for explicit manual user interaction (buttons/pinch).
    public var manualMinDisplayZoom: CGFloat {
        if isDualCameraActive || isFrontCamera {
            return 1.0
        }
        if hasPhysicalUltraWide {
            return max(0.5, minDeviceZoom / max(1.0, displayMultiplier))
        }
        if allowsSimulatedUltraWide {
            return 0.5
        }
        return 1.0
    }

    /// Hard minimum display zoom for automatic zoom decisions (NEVER auto-drops to 0.5x Ultra-Wide).
    public var autoMinDisplayZoom: CGFloat {
        return 1.0
    }

    /// Maximum reachable display zoom under current hardware configuration.
    public var maxDisplayZoom: CGFloat {
        if isDualCameraActive {
            return min(maxDisplayZoomCap, max(1.0, maxDeviceZoom))
        }
        if isStandaloneTelephoto {
            return min(maxDisplayZoomCap, max(telephotoOpticalDisplayZoom, maxDeviceZoom * telephotoOpticalDisplayZoom))
        }
        let byDevice = maxDeviceZoom / max(1.0, displayMultiplier)
        return min(maxDisplayZoomCap, max(1.0, byDevice))
    }
}

/// SINGLE authoritative display <-> hardware device zoom unit converter.
public enum DisplayDeviceZoomMapper {
    public static func deviceZoom(forDisplayZoom displayZoom: CGFloat, config: ZoomHardwareConfig) -> CGFloat {
        let safeDisplay = (displayZoom.isFinite && displayZoom > 0) ? displayZoom : 1.0
        if config.isDualCameraActive {
            return max(1.0, min(safeDisplay, config.maxDeviceZoom))
        }
        if config.isStandaloneTelephoto {
            let optical = max(1.0, config.telephotoOpticalDisplayZoom)
            return max(config.minDeviceZoom, min(safeDisplay / optical, config.maxDeviceZoom))
        }
        if !config.hasPhysicalUltraWide && safeDisplay < 1.0 {
            return config.minDeviceZoom
        }
        let mult = (config.displayMultiplier.isFinite && config.displayMultiplier > 0) ? config.displayMultiplier : 1.0
        let raw = safeDisplay * mult
        guard raw.isFinite else { return max(config.minDeviceZoom, min(mult, config.maxDeviceZoom)) }
        return max(config.minDeviceZoom, min(raw, config.maxDeviceZoom))
    }

    public static func displayZoom(
        forDeviceZoom deviceZoom: CGFloat,
        config: ZoomHardwareConfig,
        simulatedUltraWideFactor: CGFloat? = nil
    ) -> CGFloat {
        guard deviceZoom.isFinite, deviceZoom > 0 else { return 1.0 }
        if config.isDualCameraActive {
            return max(1.0, min(deviceZoom, config.maxDeviceZoom))
        }
        if config.isStandaloneTelephoto {
            return deviceZoom * max(1.0, config.telephotoOpticalDisplayZoom)
        }
        if !config.hasPhysicalUltraWide, let sim = simulatedUltraWideFactor, sim.isFinite, sim > 0.1, sim < 0.99 {
            return sim
        }
        let mult = (config.displayMultiplier.isFinite && config.displayMultiplier > 0) ? config.displayMultiplier : 1.0
        return deviceZoom / mult
    }

    /// Simulated Ultra-Wide (< 1.0x via warp shader) is strictly manual-only and only on devices without hardware Ultra-Wide.
    public static func usesSimulatedUltraWide(
        displayZoom: CGFloat,
        source: ZoomCommandSource,
        config: ZoomHardwareConfig
    ) -> Bool {
        guard source == .manual || source == .pinchContinuous else { return false }
        guard !config.hasPhysicalUltraWide, !config.isFrontCamera, !config.isDualCameraActive, config.allowsSimulatedUltraWide else {
            return false
        }
        return displayZoom.isFinite && displayZoom < 0.99
    }
}

/// Logarithmic (power-of-2) ease-in-out curve for native-Camera-like perceptual smoothness.
public struct ZoomAnimationProfile: Sendable, Equatable {
    /// Default base duration (seconds) for a 1-octave zoom change (e.g. 1.0x -> 2.0x).
    /// Tunable in Debug mode via slider inside [0.40s, 1.50s].
    public static let defaultOneOctaveDuration: TimeInterval = 0.85
    public static let minConfigurableDuration: TimeInterval = 0.40
    public static let maxConfigurableDuration: TimeInterval = 1.50

    public var baseOneOctaveDuration: TimeInterval

    public init(baseOneOctaveDuration: TimeInterval = ZoomAnimationProfile.defaultOneOctaveDuration) {
        let clamped = baseOneOctaveDuration.isFinite
            ? max(Self.minConfigurableDuration, min(Self.maxConfigurableDuration, baseOneOctaveDuration))
            : Self.defaultOneOctaveDuration
        self.baseOneOctaveDuration = clamped
    }

    /// Computes duration proportional to logarithmic (octave) distance:
    /// - Small changes (1.0x -> 1.2x, 0.26 oct): ~0.39s (snappy without snapping)
    /// - 1-octave change (1.0x -> 2.0x): 0.85s
    /// - Large change (1.0x -> 3.0x, 1.58 oct): ~1.11s (silky inside 0.6-1.2s)
    public func duration(from startDisplayZoom: CGFloat, to targetDisplayZoom: CGFloat) -> TimeInterval {
        let z0 = max(0.25, Double(startDisplayZoom.isFinite ? startDisplayZoom : 1.0))
        let z1 = max(0.25, Double(targetDisplayZoom.isFinite ? targetDisplayZoom : 1.0))
        let octaves = abs(log2(z1 / z0))
        if octaves < 1e-4 { return 0.0 }
        let speedScale = baseOneOctaveDuration / Self.defaultOneOctaveDuration
        let minDur = 0.34 * speedScale
        let maxDur = 1.20 * speedScale
        let raw = baseOneOctaveDuration * pow(max(0.05, octaves), 0.58)
        return max(minDur, min(maxDur, raw))
    }

    /// Symmetric cubic ease-in-out `3u^2 - 2u^3`: zero velocity at start & end, peak slope 1.5.
    public static func easeInOut(_ progress: Double) -> Double {
        let u = max(0.0, min(1.0, progress))
        return u * u * (3.0 - 2.0 * u)
    }

    /// Perceptually uniform logarithmic (power-of-2) interpolation between display zooms.
    public func interpolatedDisplayZoom(from startZoom: CGFloat, to targetZoom: CGFloat, progress: Double) -> CGFloat {
        let z0 = max(0.25, Double(startZoom.isFinite ? startZoom : 1.0))
        let z1 = max(0.25, Double(targetZoom.isFinite ? targetZoom : 1.0))
        let eased = Self.easeInOut(progress)
        let logZ = log2(z0) + (log2(z1) - log2(z0)) * eased
        return CGFloat(exp2(logZ))
    }

    /// Peak instantaneous rate in octaves/second for this transition (used by invariant tests).
    public func peakOctavesPerSecond(from startZoom: CGFloat, to targetZoom: CGFloat) -> Double {
        let dur = duration(from: startZoom, to: targetZoom)
        guard dur > 1e-5 else { return 0 }
        let z0 = max(0.25, Double(startZoom))
        let z1 = max(0.25, Double(targetZoom))
        let octaves = abs(log2(z1 / z0))
        return 1.5 * octaves / dur
    }
}

/// Audit record written at the SINGLE zoom-write chokepoint.
public struct ZoomAuditEntry: Sendable, Equatable {
    public let seq: UInt64
    public let uptime: TimeInterval
    public let oldDisplayZoom: CGFloat
    public let newDisplayZoom: CGFloat
    public let oldDeviceZoom: CGFloat
    public let newDeviceZoom: CGFloat
    public let displayMultiplier: CGFloat
    public let source: ZoomCommandSource
    public let reason: String
    public let note: String

    public var formattedLine: String {
        String(
            format: "#%llu t=%.3f [%@] disp=%.2fx->%.2fx dev=%.2f->%.2f (x%.1f) reason=%@%@",
            seq, uptime, source.rawValue,
            Double(oldDisplayZoom), Double(newDisplayZoom),
            Double(oldDeviceZoom), Double(newDeviceZoom),
            Double(displayMultiplier),
            reason,
            note.isEmpty ? "" : " (\(note))"
        )
    }
}

/// Result returned by `ZoomTransitionController.requestZoom(...)`.
public struct ZoomCommandDecision: Sendable, Equatable {
    public let outcome: ZoomCommandOutcome
    public let targetDisplayZoom: CGFloat
    public let targetDeviceZoom: CGFloat
    public let usesSimulatedUltraWide: Bool
    public let duration: TimeInterval
    public let wasClampedAtAutoFloor: Bool

    public var isAccepted: Bool {
        switch outcome {
        case .acceptedImmediate, .acceptedSmooth, .acceptedRedirectedSmooth:
            return true
        default:
            return false
        }
    }
}

/// Per-frame output returned by `ZoomTransitionController.step(at:)`.
public struct ZoomStepOutput: Sendable, Equatable {
    public let isAnimating: Bool
    public let didFinishThisStep: Bool
    public let displayZoom: CGFloat
    public let deviceZoom: CGFloat
    public let progress: Double
    public let source: ZoomCommandSource
}

/// Pure, deterministic SINGLE owner of zoom state, auto-zoom guardrails, lens switchover hysteresis,
/// transition freeze/settle windows, logarithmic ease-in-out ramp math, and audit logging.
/// Zero UIKit/AVFoundation dependency so it can be unit-tested exhaustively on macOS CI.
public final class ZoomTransitionController: @unchecked Sendable {
    public struct Policy: Sendable, Equatable {
        /// Auto-zoom floor: NEVER drops below 1.0x (Ultra-Wide 0.5x is manual-only).
        public var autoMinDisplayZoom: CGFloat
        /// Minimum delta in display zoom for an auto-zoom command to execute.
        public var autoDeadband: CGFloat
        /// Cooldown blocking opposite-direction auto-zoom reversals (e.g. zoom-in then zoom-out).
        public var reversalCooldownSeconds: TimeInterval
        /// Minimum spacing between same-direction auto-zoom commands.
        public var sameDirectionCooldownSeconds: TimeInterval
        /// Post-transition settle window where new auto-zoom decisions & stale detections are frozen.
        public var settleWindowSeconds: TimeInterval
        /// Rolling 60-second cap on automatic zoom transitions.
        public var maxAutoChangesPerMinute: Int
        /// Downward hysteresis margin below an optical switchover point (e.g. 2.0x -> must fall below 1.78x).
        public var switchoverDownHysteresis: CGFloat
        /// Upward tolerance when stepping onto an optical switchover point.
        public var switchoverUpTolerance: CGFloat
        /// Maximum instantaneous zoom rate allowed in octaves/second for smooth transitions.
        public var maxAllowedPeakOctavesPerSecond: Double

        public init(
            autoMinDisplayZoom: CGFloat = 1.0,
            autoDeadband: CGFloat = 0.12,
            reversalCooldownSeconds: TimeInterval = 2.5,
            sameDirectionCooldownSeconds: TimeInterval = 0.8,
            settleWindowSeconds: TimeInterval = 0.28,
            maxAutoChangesPerMinute: Int = 10,
            switchoverDownHysteresis: CGFloat = 0.22,
            switchoverUpTolerance: CGFloat = 0.02,
            maxAllowedPeakOctavesPerSecond: Double = 3.2
        ) {
            self.autoMinDisplayZoom = max(1.0, autoMinDisplayZoom)
            self.autoDeadband = max(0.05, autoDeadband)
            self.reversalCooldownSeconds = max(0.0, reversalCooldownSeconds)
            self.sameDirectionCooldownSeconds = max(0.0, sameDirectionCooldownSeconds)
            self.settleWindowSeconds = max(0.0, settleWindowSeconds)
            self.maxAutoChangesPerMinute = max(1, maxAutoChangesPerMinute)
            self.switchoverDownHysteresis = max(0.05, switchoverDownHysteresis)
            self.switchoverUpTolerance = max(0.0, switchoverUpTolerance)
            self.maxAllowedPeakOctavesPerSecond = max(1.0, maxAllowedPeakOctavesPerSecond)
        }
    }

    public private(set) var config: ZoomHardwareConfig
    public var policy: Policy
    public var animationProfile: ZoomAnimationProfile

    // Authoritative current state (unified display zoom units)
    public private(set) var currentDisplayZoom: CGFloat
    public private(set) var targetDisplayZoom: CGFloat
    public private(set) var activeSource: ZoomCommandSource = .lensInit
    public private(set) var isTransitioning: Bool = false
    public private(set) var isReconfiguring: Bool = false
    public private(set) var isSimulatedUltraWideActive: Bool = false
    public private(set) var simulatedUltraWideFactor: CGFloat = 1.0

    // Active ramp curve parameters
    private var rampStartZoom: CGFloat = 1.0
    private var rampEndZoom: CGFloat = 1.0
    private var rampStartTime: TimeInterval = 0
    private var rampDuration: TimeInterval = 0
    private var rampReason: String = ""

    // Cooldown, settle, reversal, and rate-budget tracking
    public private(set) var lastTransitionCompletedAt: TimeInterval = -1e9
    public private(set) var settleUntil: TimeInterval = -1e9
    private var lastAutoCommandAt: TimeInterval = -1e9
    private var lastAutoDirection: Int = 0 // +1 zoom-in, -1 zoom-out, 0 none
    private var autoChangeTimestamps: [TimeInterval] = []
    private var preservedDisplayZoomDuringReconfig: CGFloat = 1.0

    // Bounded in-memory audit log (lightweight, zero disk I/O during ramp ticks)
    private var auditSeq: UInt64 = 0
    private var auditRing: [ZoomAuditEntry] = []
    private let maxAuditEntries: Int = 200

    public init(
        config: ZoomHardwareConfig = ZoomHardwareConfig(),
        policy: Policy = Policy(),
        animationProfile: ZoomAnimationProfile = ZoomAnimationProfile(),
        initialDisplayZoom: CGFloat = 1.0
    ) {
        self.config = config
        self.policy = policy
        self.animationProfile = animationProfile
        let safeInit = max(config.manualMinDisplayZoom, min(config.maxDisplayZoom, initialDisplayZoom.isFinite ? initialDisplayZoom : 1.0))
        self.currentDisplayZoom = safeInit
        self.targetDisplayZoom = safeInit
    }

    public var currentDeviceZoom: CGFloat {
        DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: currentDisplayZoom, config: config)
    }

    public var auditEntries: [ZoomAuditEntry] {
        auditRing
    }

    public func clearAuditLog() {
        auditRing.removeAll(keepingCapacity: true)
    }

    public func updateHardwareConfig(_ newConfig: ZoomHardwareConfig) {
        config = newConfig
    }

    /// True if the controller is neither mid-ramp, mid-reconfig, nor in its post-zoom settle window.
    public func isSettled(at now: TimeInterval) -> Bool {
        !isTransitioning && !isReconfiguring && now >= settleUntil
    }

    /// Rejects detections captured before/during a zoom transition or whose frame zoom disagrees with current hardware zoom.
    public func isDetectionFreshForCurrentZoom(
        frameTimestamp: TimeInterval,
        frameDisplayZoom: Double? = nil,
        at now: TimeInterval
    ) -> Bool {
        guard frameTimestamp.isFinite, now.isFinite else { return false }
        if isTransitioning || isReconfiguring || now < settleUntil {
            return false
        }
        if lastTransitionCompletedAt > -1e8 && frameTimestamp < lastTransitionCompletedAt + 0.05 {
            return false
        }
        if let fz = frameDisplayZoom, fz.isFinite, fz > 0 {
            if abs(fz - Double(currentDisplayZoom)) > 0.14 {
                return false
            }
        }
        return true
    }

    /// Evaluates and (if accepted) executes or begins a zoom transition.
    @discardableResult
    public func requestZoom(
        _ requestedDisplayZoom: CGFloat,
        source: ZoomCommandSource,
        smooth: Bool,
        reason: String,
        at now: TimeInterval
    ) -> ZoomCommandDecision {
        guard requestedDisplayZoom.isFinite, requestedDisplayZoom > 0, now.isFinite else {
            return ZoomCommandDecision(
                outcome: .rejectedInvalidInput,
                targetDisplayZoom: currentDisplayZoom,
                targetDeviceZoom: currentDeviceZoom,
                usesSimulatedUltraWide: isSimulatedUltraWideActive,
                duration: 0,
                wasClampedAtAutoFloor: false
            )
        }

        let minBound: CGFloat = (source == .auto)
            ? max(policy.autoMinDisplayZoom, config.autoMinDisplayZoom)
            : config.manualMinDisplayZoom
        let maxBound = max(minBound, config.maxDisplayZoom)

        var clamped = max(minBound, min(maxBound, requestedDisplayZoom))
        let wasClampedAtAutoFloor = (source == .auto) && (requestedDisplayZoom < minBound - 1e-4)

        if source == .auto {
            // 1. Freeze new auto-zoom decisions during active ramp / camera reconfig / post-zoom settle window.
            if isTransitioning || isReconfiguring {
                return ZoomCommandDecision(
                    outcome: .rejectedTransitionBusy,
                    targetDisplayZoom: targetDisplayZoom,
                    targetDeviceZoom: DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: targetDisplayZoom, config: config),
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }
            if now < settleUntil {
                return ZoomCommandDecision(
                    outcome: .rejectedSettling,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }

            // 2. Auto-zoom must NEVER drop below 1.0x. If clamping collapses to current zoom, reject cleanly.
            let delta = clamped - currentDisplayZoom
            if wasClampedAtAutoFloor && abs(delta) < policy.autoDeadband {
                recordAudit(
                    at: now,
                    oldDisplay: currentDisplayZoom,
                    newDisplay: currentDisplayZoom,
                    source: source,
                    reason: reason,
                    note: String(format: "clampedAutoFloor req=%.2fx->%.2fx", Double(requestedDisplayZoom), Double(clamped))
                )
                return ZoomCommandDecision(
                    outcome: .rejectedAutoFloorClampedToCurrent,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: false,
                    duration: 0,
                    wasClampedAtAutoFloor: true
                )
            }

            // 3. Deadband prevents micro-zoom jitter.
            if abs(delta) < policy.autoDeadband {
                return ZoomCommandDecision(
                    outcome: .rejectedDeadband,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }

            // 4. Switchover hysteresis around optical lens boundaries (e.g. 2.0x, 3.0x, 5.0x):
            //    When currently on or above a switchover rung S, stepping down across S requires dropping
            //    clearly below S - switchoverDownHysteresis to prevent lens chattering.
            if delta < 0 {
                for switchover in config.opticalSwitchoverDisplayZooms where switchover > 1.05 {
                    let currentlyAtOrAbove = currentDisplayZoom >= (switchover - policy.switchoverUpTolerance)
                    let crossesDownIntoBand = clamped < switchover && clamped > (switchover - policy.switchoverDownHysteresis)
                    if currentlyAtOrAbove && crossesDownIntoBand {
                        return ZoomCommandDecision(
                            outcome: .rejectedSwitchoverHysteresis,
                            targetDisplayZoom: currentDisplayZoom,
                            targetDeviceZoom: currentDeviceZoom,
                            usesSimulatedUltraWide: isSimulatedUltraWideActive,
                            duration: 0,
                            wasClampedAtAutoFloor: wasClampedAtAutoFloor
                        )
                    }
                }
            }

            // 5. Reversal cooldown & same-direction cooldown
            let direction = delta > 0 ? 1 : -1
            let elapsedSinceAuto = now - lastAutoCommandAt
            if lastAutoDirection != 0 && direction != lastAutoDirection && elapsedSinceAuto < policy.reversalCooldownSeconds {
                return ZoomCommandDecision(
                    outcome: .rejectedReversalCooldown,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }
            if elapsedSinceAuto < policy.sameDirectionCooldownSeconds {
                return ZoomCommandDecision(
                    outcome: .rejectedSameDirectionCooldown,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }

            // 6. Rolling 60-second auto-zoom change budget
            autoChangeTimestamps.removeAll { now - $0 > 60.0 }
            if autoChangeTimestamps.count >= policy.maxAutoChangesPerMinute {
                return ZoomCommandDecision(
                    outcome: .rejectedRateBudgetExceeded,
                    targetDisplayZoom: currentDisplayZoom,
                    targetDeviceZoom: currentDeviceZoom,
                    usesSimulatedUltraWide: isSimulatedUltraWideActive,
                    duration: 0,
                    wasClampedAtAutoFloor: wasClampedAtAutoFloor
                )
            }

            // Snap final auto target strictly >= 1.0x
            clamped = max(minBound, clamped)
            lastAutoCommandAt = now
            lastAutoDirection = direction
            autoChangeTimestamps.append(now)
        } else if source == .manual || source == .pinchContinuous {
            // Explicit user interaction resets auto reversal lock so future AI sessions respond naturally.
            lastAutoDirection = 0
        }

        let simUW = DisplayDeviceZoomMapper.usesSimulatedUltraWide(
            displayZoom: clamped,
            source: source,
            config: config
        )
        let targetDev = DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: clamped, config: config)
        let oldDisp = currentDisplayZoom

        let wasTransitioning = isTransitioning
        if smooth && abs(clamped - currentDisplayZoom) >= 0.015 {
            var dur = animationProfile.duration(from: currentDisplayZoom, to: clamped)
            // Enforce maximum octave speed cap even if debug slider is set fast
            let octaves = abs(log2(Double(max(0.25, clamped)) / Double(max(0.25, currentDisplayZoom))))
            if dur > 0 && (1.5 * octaves / dur) > policy.maxAllowedPeakOctavesPerSecond {
                dur = (1.5 * octaves) / policy.maxAllowedPeakOctavesPerSecond
            }
            isTransitioning = true
            rampStartZoom = currentDisplayZoom
            rampEndZoom = clamped
            rampStartTime = now
            rampDuration = max(0.05, dur)
            rampReason = reason
            targetDisplayZoom = clamped
            activeSource = source
            isSimulatedUltraWideActive = simUW
            simulatedUltraWideFactor = simUW ? clamped : 1.0

            let outcome: ZoomCommandOutcome = wasTransitioning ? .acceptedRedirectedSmooth : .acceptedSmooth
            recordAudit(
                at: now,
                oldDisplay: oldDisp,
                newDisplay: clamped,
                source: source,
                reason: reason,
                note: String(
                    format: "rampStart dur=%.2fs%@",
                    rampDuration,
                    wasClampedAtAutoFloor ? " clampedAutoFloor" : (wasTransitioning ? " redirected" : "")
                )
            )
            return ZoomCommandDecision(
                outcome: outcome,
                targetDisplayZoom: clamped,
                targetDeviceZoom: targetDev,
                usesSimulatedUltraWide: simUW,
                duration: rampDuration,
                wasClampedAtAutoFloor: wasClampedAtAutoFloor
            )
        } else {
            // Immediate write (e.g. continuous pinch frame, lens init, or system restore)
            isTransitioning = false
            currentDisplayZoom = clamped
            targetDisplayZoom = clamped
            activeSource = source
            isSimulatedUltraWideActive = simUW
            simulatedUltraWideFactor = simUW ? clamped : 1.0
            if source != .pinchContinuous {
                lastTransitionCompletedAt = now
                settleUntil = now + (source == .auto ? policy.settleWindowSeconds : 0.12)
            }
            recordAudit(
                at: now,
                oldDisplay: oldDisp,
                newDisplay: clamped,
                source: source,
                reason: reason,
                note: wasClampedAtAutoFloor ? "immediate clampedAutoFloor" : "immediate"
            )
            return ZoomCommandDecision(
                outcome: .acceptedImmediate,
                targetDisplayZoom: clamped,
                targetDeviceZoom: targetDev,
                usesSimulatedUltraWide: simUW,
                duration: 0,
                wasClampedAtAutoFloor: wasClampedAtAutoFloor
            )
        }
    }

    /// Advances the active smooth logarithmic ease-in-out animation to timestamp `now`.
    public func step(at now: TimeInterval) -> ZoomStepOutput {
        guard isTransitioning, now.isFinite else {
            return ZoomStepOutput(
                isAnimating: false,
                didFinishThisStep: false,
                displayZoom: currentDisplayZoom,
                deviceZoom: currentDeviceZoom,
                progress: 1.0,
                source: activeSource
            )
        }
        let elapsed = max(0.0, now - rampStartTime)
        let progress = rampDuration > 1e-5 ? min(1.0, elapsed / rampDuration) : 1.0
        let interpolated = animationProfile.interpolatedDisplayZoom(
            from: rampStartZoom,
            to: rampEndZoom,
            progress: progress
        )
        let simUW = DisplayDeviceZoomMapper.usesSimulatedUltraWide(
            displayZoom: interpolated,
            source: activeSource,
            config: config
        )
        currentDisplayZoom = interpolated
        isSimulatedUltraWideActive = simUW
        simulatedUltraWideFactor = simUW ? interpolated : 1.0

        let finished = progress >= 1.0 - 1e-6
        if finished {
            currentDisplayZoom = rampEndZoom
            targetDisplayZoom = rampEndZoom
            isTransitioning = false
            lastTransitionCompletedAt = now
            settleUntil = now + policy.settleWindowSeconds
            recordAudit(
                at: now,
                oldDisplay: rampStartZoom,
                newDisplay: rampEndZoom,
                source: activeSource,
                reason: rampReason,
                note: String(format: "rampEnd dur=%.2fs", now - rampStartTime)
            )
        }
        return ZoomStepOutput(
            isAnimating: !finished,
            didFinishThisStep: finished,
            displayZoom: currentDisplayZoom,
            deviceZoom: currentDeviceZoom,
            progress: progress,
            source: activeSource
        )
    }

    /// Cancels an active zoom ramp at its current live display zoom (no snap back).
    public func cancelActiveTransition(at now: TimeInterval, reason: String) {
        guard isTransitioning else { return }
        let stoppedAt = currentDisplayZoom
        isTransitioning = false
        targetDisplayZoom = stoppedAt
        lastTransitionCompletedAt = now
        settleUntil = now + 0.12
        recordAudit(
            at: now,
            oldDisplay: rampStartZoom,
            newDisplay: stoppedAt,
            source: activeSource,
            reason: reason,
            note: "rampCancelled"
        )
    }

    /// Marks the start of a camera format / preset / input switch so AVFoundation's transient
    /// `videoZoomFactor = 1.0` reset (= 0.5x on Triple/DualWide) is suppressed and never leaks to UI.
    @discardableResult
    public func beginCameraReconfiguration(reason: String, at now: TimeInterval) -> CGFloat {
        if isTransitioning {
            _ = step(at: now)
            isTransitioning = false
        }
        isReconfiguring = true
        preservedDisplayZoomDuringReconfig = currentDisplayZoom
        return preservedDisplayZoomDuringReconfig
    }

    /// Finishes camera reconfiguration, updates `displayMultiplier` / bounds, and computes the exact
    /// device zoom needed to preserve display zoom (never dropping to 0.5x unless user was manually at 0.5x).
    public func endCameraReconfiguration(
        newConfig: ZoomHardwareConfig,
        overrideDisplayZoom: CGFloat? = nil,
        reason: String,
        at now: TimeInterval
    ) -> (displayZoom: CGFloat, deviceZoom: CGFloat) {
        let oldDisplay = currentDisplayZoom
        let desired = overrideDisplayZoom ?? preservedDisplayZoomDuringReconfig
        config = newConfig
        isReconfiguring = false
        let minAllowed = (activeSource == .manual || activeSource == .pinchContinuous)
            ? newConfig.manualMinDisplayZoom
            : max(1.0, newConfig.manualMinDisplayZoom)
        let restoredDisplay = max(minAllowed, min(newConfig.maxDisplayZoom, desired.isFinite ? desired : 1.0))
        currentDisplayZoom = restoredDisplay
        targetDisplayZoom = restoredDisplay
        let simUW = DisplayDeviceZoomMapper.usesSimulatedUltraWide(
            displayZoom: restoredDisplay,
            source: activeSource,
            config: newConfig
        )
        isSimulatedUltraWideActive = simUW
        simulatedUltraWideFactor = simUW ? restoredDisplay : 1.0
        lastTransitionCompletedAt = now
        settleUntil = now + 0.15
        let restoredDevice = DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: restoredDisplay, config: newConfig)
        recordAudit(
            at: now,
            oldDisplay: oldDisplay,
            newDisplay: restoredDisplay,
            source: .systemRestore,
            reason: reason,
            note: "reconfigRestore"
        )
        return (restoredDisplay, restoredDevice)
    }

    /// Processes an external KVO `videoZoomFactor` observation from AVFoundation.
    /// Returns `nil` when the transient observation must be ignored (mid-reconfig or mid-smooth-ramp).
    public func handleExternalHardwareZoomObservation(
        _ rawDeviceZoom: CGFloat,
        at now: TimeInterval
    ) -> CGFloat? {
        guard rawDeviceZoom.isFinite, rawDeviceZoom > 0 else { return nil }
        if isReconfiguring {
            // Suppress AVFoundation's transient reset to videoZoomFactor=1.0 (0.5x on Triple/DualWide) during activeFormat/sessionPreset swaps.
            return nil
        }
        if isTransitioning {
            // Smooth CADisplayLink ramp owns live display zoom updates; avoid KVO jitter echoes.
            return nil
        }
        let mappedDisplay = DisplayDeviceZoomMapper.displayZoom(
            forDeviceZoom: rawDeviceZoom,
            config: config,
            simulatedUltraWideFactor: isSimulatedUltraWideActive ? simulatedUltraWideFactor : nil
        )
        if abs(mappedDisplay - currentDisplayZoom) > 0.08 {
            recordAudit(
                at: now,
                oldDisplay: currentDisplayZoom,
                newDisplay: mappedDisplay,
                source: .systemRestore,
                reason: "KVO.externalZoomChange",
                note: String(format: "rawDev=%.2f", Double(rawDeviceZoom))
            )
        }
        currentDisplayZoom = mappedDisplay
        targetDisplayZoom = mappedDisplay
        return mappedDisplay
    }

    /// Formats the bounded audit ring buffer for inclusion in `PreviousSessionLogSheetView` / diagnostic export.
    public func formattedAuditSummary(maxLines: Int = 80) -> String {
        guard !auditRing.isEmpty else { return "(Chưa có sự kiện ghi zoom nào trong phiên này)" }
        return auditRing.suffix(max(1, maxLines)).map(\.formattedLine).joined(separator: "\n")
    }

    private func recordAudit(
        at now: TimeInterval,
        oldDisplay: CGFloat,
        newDisplay: CGFloat,
        source: ZoomCommandSource,
        reason: String,
        note: String
    ) {
        auditSeq &+= 1
        let oldDev = DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: oldDisplay, config: config)
        let newDev = DisplayDeviceZoomMapper.deviceZoom(forDisplayZoom: newDisplay, config: config)
        let entry = ZoomAuditEntry(
            seq: auditSeq,
            uptime: now,
            oldDisplayZoom: oldDisplay,
            newDisplayZoom: newDisplay,
            oldDeviceZoom: oldDev,
            newDeviceZoom: newDev,
            displayMultiplier: config.displayMultiplier,
            source: source,
            reason: reason,
            note: note
        )
        auditRing.append(entry)
        if auditRing.count > maxAuditEntries {
            auditRing.removeFirst(auditRing.count - maxAuditEntries)
        }
    }
}
