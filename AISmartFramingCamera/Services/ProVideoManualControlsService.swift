import Foundation
import AVFoundation
import Combine

/// UI-facing state for professional camera controls.
///
/// All `AVCaptureDevice` reads and writes cross the serialized boundary provided by
/// `CameraService.scheduleDeviceConfiguration`. Published state is only committed on the
/// main queue, while slider bursts are coalesced before touching hardware.
public final class ProVideoManualControlsService: ObservableObject {
    public static let shared = ProVideoManualControlsService()

    // MARK: - Exposure

    @Published public var isAutoISO = true
    @Published public var currentISO: Float = 100
    @Published public var minISO: Float = 32
    @Published public var maxISO: Float = 3200

    /// Reciprocal seconds: 60 represents 1/60 s.
    @Published public var isAutoShutter = true
    @Published public var currentShutterSpeed: Double = 60
    @Published public var minShutterSpeed: Double = 24
    @Published public var maxShutterSpeed: Double = 8000

    @Published public var isAutoEV = true
    @Published public var currentEVBias: Float = 0
    @Published public var minEVBias: Float = -2
    @Published public var maxEVBias: Float = 2
    @Published public var hardwareLensAperture: Float = 1.8

    // MARK: - White balance

    @Published public var isAutoWB = true
    @Published public var currentKelvin: Float = 5600
    @Published public var currentTint: Float = 0

    // MARK: - Lens focus

    @Published public var isAutoFocus = true
    @Published public var currentLensPosition: Float = 0.5
    @Published public var isManualFocusSupported = false

    // MARK: - Live sensor readouts

    @Published public var measuredLiveISO: Float = 100
    @Published public var measuredLiveShutterSpeed: Double = 60
    @Published public var measuredLiveKelvin: Float = 5600
    @Published public var measuredLiveTint: Float = 0
    @Published public var measuredLiveLensPosition: Float = 0.5

    private var pendingExposureWorkItem: DispatchWorkItem?
    private var pendingWBWorkItem: DispatchWorkItem?
    private var pendingFocusWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Hardware capabilities

    public func syncHardwareCapabilities() {
        CameraService.shared.scheduleDeviceConfiguration { [weak self] camera in
            let format = camera.activeFormat
            let hardwareMinISO = Self.finite(format.minISO, fallback: 32)
            let hardwareMaxISO = Self.finite(format.maxISO, fallback: 3200)
            let minISO = max(25, min(hardwareMinISO, hardwareMaxISO))
            let maxISO = max(minISO, min(6400, hardwareMaxISO))

            let minDuration = CMTimeGetSeconds(format.minExposureDuration)
            let maxDuration = CMTimeGetSeconds(format.maxExposureDuration)
            let maxShutter = minDuration.isFinite && minDuration > 0
                ? min(8000, max(1, (1 / minDuration).rounded()))
                : 8000
            let minShutter = maxDuration.isFinite && maxDuration > 0
                ? max(1, min(maxShutter, (1 / maxDuration).rounded()))
                : 24

            let deviceMinEV = Self.finite(camera.minExposureTargetBias, fallback: -2)
            let deviceMaxEV = Self.finite(camera.maxExposureTargetBias, fallback: 2)
            let minEV = max(-2, min(deviceMinEV, deviceMaxEV))
            let maxEV = max(minEV, min(2, deviceMaxEV))
            let aperture = camera.lensAperture.isFinite && camera.lensAperture > 0 ? camera.lensAperture : 1.8
            let supportsManualFocus = camera.isLockingFocusWithCustomLensPositionSupported
            let lensPosition = Self.clamp(camera.lensPosition, lower: 0, upper: 1, fallback: 0.5)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.minISO = minISO
                self.maxISO = maxISO
                self.minShutterSpeed = minShutter
                self.maxShutterSpeed = maxShutter
                self.minEVBias = minEV
                self.maxEVBias = maxEV
                self.hardwareLensAperture = aperture
                self.isManualFocusSupported = supportsManualFocus
                self.measuredLiveLensPosition = lensPosition
                if self.isAutoFocus {
                    self.currentLensPosition = lensPosition
                }
                CameraLogger.info(
                    "ProVideo hardware: ISO \(Int(minISO))-\(Int(maxISO)) | Shutter 1/\(Int(maxShutter))-1/\(Int(minShutter)) | f/\(String(format: \"%.1f\", aperture)) | MF \(supportsManualFocus)",
                    category: .capture
                )
            }
        }
    }

    public func updateLiveMeasurements(iso: Float, shutterDuration: Double, lensPosition: Float) {
        let safeISO = Self.finite(iso, fallback: measuredLiveISO)
        let speed = shutterDuration.isFinite && shutterDuration > 0
            ? 1 / shutterDuration
            : measuredLiveShutterSpeed
        measuredLiveISO = safeISO
        measuredLiveShutterSpeed = Self.finite(speed, fallback: 60)
        measuredLiveLensPosition = Self.clamp(lensPosition, lower: 0, upper: 1, fallback: measuredLiveLensPosition)
        if isAutoFocus {
            currentLensPosition = measuredLiveLensPosition
        }
    }

    // MARK: - ISO and shutter

    public func setAutoISO(_ isAuto: Bool) {
        isAutoISO = isAuto
        if isAuto && isAutoShutter {
            restoreContinuousAutoExposure()
        } else {
            applyExposureSettings()
        }
    }

    public func setManualISO(_ iso: Float) {
        currentISO = Self.clamp(iso, lower: minISO, upper: maxISO, fallback: currentISO)
        isAutoISO = false
        applyExposureSettings()
    }

    public func setAutoShutter(_ isAuto: Bool) {
        isAutoShutter = isAuto
        if isAuto && isAutoISO {
            restoreContinuousAutoExposure()
        } else {
            applyExposureSettings()
        }
    }

    public func setManualShutterSpeed(_ speed: Double) {
        currentShutterSpeed = Self.clamp(
            speed,
            lower: minShutterSpeed,
            upper: maxShutterSpeed,
            fallback: currentShutterSpeed
        )
        isAutoShutter = false
        applyExposureSettings()
    }

    private func applyExposureSettings() {
        pendingExposureWorkItem?.cancel()
        let autoISO = isAutoISO
        let autoShutter = isAutoShutter
        let requestedISO = currentISO
        let requestedShutter = currentShutterSpeed

        pendingExposureWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.02) { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }

                if autoISO && autoShutter {
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                    }
                    return
                }
                guard camera.isExposureModeSupported(.custom) else { return }

                let targetISO = autoISO
                    ? Self.clamp(camera.iso, lower: camera.activeFormat.minISO, upper: camera.activeFormat.maxISO, fallback: camera.activeFormat.minISO)
                    : Self.clamp(requestedISO, lower: camera.activeFormat.minISO, upper: camera.activeFormat.maxISO, fallback: camera.activeFormat.minISO)

                let targetDuration: CMTime
                if autoShutter {
                    targetDuration = camera.exposureDuration
                } else {
                    let reciprocal = Self.clamp(requestedShutter, lower: 1, upper: 1_000_000, fallback: 60)
                    let requestedDuration = CMTime(seconds: 1 / reciprocal, preferredTimescale: 1_000_000)
                    targetDuration = max(camera.activeFormat.minExposureDuration, min(requestedDuration, camera.activeFormat.maxExposureDuration))
                }
                camera.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
            } catch {
                CameraLogger.error("ProVideo: Lỗi áp dụng custom exposure", error: error, category: .capture)
            }
        }
    }

    private func restoreContinuousAutoExposure() {
        pendingExposureWorkItem?.cancel()
        CameraService.shared.scheduleDeviceConfiguration { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
            } catch {
                CameraLogger.error("ProVideo: Lỗi khôi phục auto exposure", error: error, category: .capture)
            }
        }
    }

    // MARK: - Exposure compensation

    public func setAutoEV(_ isAuto: Bool) {
        isAutoEV = isAuto
        if isAuto {
            setManualEVBias(0)
            isAutoEV = true
        }
    }

    public func setManualEVBias(_ bias: Float) {
        let clamped = Self.clamp(bias, lower: minEVBias, upper: maxEVBias, fallback: currentEVBias)
        currentEVBias = clamped
        isAutoEV = abs(clamped) < 0.001
        CameraService.shared.setExposureBias(clamped)
    }

    // MARK: - White balance

    public func setAutoWB(_ isAuto: Bool) {
        isAutoWB = isAuto
        if isAuto {
            restoreContinuousAutoWhiteBalance()
        } else {
            applyWhiteBalanceSettings()
        }
    }

    public func setManualWhiteBalance(kelvin: Float, tint: Float = 0) {
        currentKelvin = Self.clamp(kelvin, lower: 2500, upper: 9000, fallback: currentKelvin)
        currentTint = Self.clamp(tint, lower: -50, upper: 50, fallback: currentTint)
        isAutoWB = false
        applyWhiteBalanceSettings()
    }

    private func applyWhiteBalanceSettings() {
        pendingWBWorkItem?.cancel()
        guard !isAutoWB else {
            restoreContinuousAutoWhiteBalance()
            return
        }
        let kelvin = currentKelvin
        let tint = currentTint

        pendingWBWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.02) { camera in
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
            var gains = camera.deviceWhiteBalanceGains(for: values)
            let maxGain = max(1, Self.finite(camera.maxWhiteBalanceGain, fallback: 1))
            gains.redGain = Self.clamp(gains.redGain, lower: 1, upper: maxGain, fallback: 1)
            gains.greenGain = Self.clamp(gains.greenGain, lower: 1, upper: maxGain, fallback: 1)
            gains.blueGain = Self.clamp(gains.blueGain, lower: 1, upper: maxGain, fallback: 1)

            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isWhiteBalanceModeSupported(.locked) {
                    camera.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            } catch {
                CameraLogger.error("ProVideo: Lỗi khóa white balance", error: error, category: .capture)
            }
        }
    }

    private func restoreContinuousAutoWhiteBalance() {
        pendingWBWorkItem?.cancel()
        CameraService.shared.scheduleDeviceConfiguration { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } catch {
                CameraLogger.error("ProVideo: Lỗi khôi phục auto white balance", error: error, category: .capture)
            }
        }
    }

    // MARK: - Manual lens focus

    public func setAutoFocus(_ isAuto: Bool) {
        isAutoFocus = isAuto
        pendingFocusWorkItem?.cancel()
        if isAuto {
            CameraService.shared.restoreContinuousAutoFocus()
        } else {
            setManualFocus(currentLensPosition)
        }
    }

    public func setManualFocus(_ lensPosition: Float) {
        guard isManualFocusSupported else { return }
        let clamped = Self.clamp(lensPosition, lower: 0, upper: 1, fallback: currentLensPosition)
        currentLensPosition = clamped
        isAutoFocus = false
        pendingFocusWorkItem?.cancel()

        pendingFocusWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.015) { camera in
            guard camera.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
            } catch {
                CameraLogger.error("ProVideo: Lỗi điều khiển manual focus", error: error, category: .capture)
            }
        }
    }

    // MARK: - Reset

    public func resetToFullAuto() {
        pendingExposureWorkItem?.cancel()
        pendingWBWorkItem?.cancel()
        pendingFocusWorkItem?.cancel()
        isAutoISO = true
        isAutoShutter = true
        isAutoEV = true
        currentEVBias = 0
        isAutoWB = true
        isAutoFocus = true

        restoreContinuousAutoExposure()
        restoreContinuousAutoWhiteBalance()
        CameraService.shared.restoreContinuousAutoFocus()
        CameraService.shared.setExposureBias(0)
        CameraLogger.info("ProVideo: Đã khôi phục exposure, WB và focus về Auto", category: .capture)
    }

    // MARK: - Numeric safety

    private static func finite(_ value: Float, fallback: Float) -> Float {
        value.isFinite ? value : fallback
    }

    private static func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private static func clamp(_ value: Float, lower: Float, upper: Float, fallback: Float) -> Float {
        let safeLower = lower.isFinite ? lower : fallback
        let safeUpper = upper.isFinite ? max(safeLower, upper) : max(safeLower, fallback)
        let safeValue = value.isFinite ? value : fallback
        return max(safeLower, min(safeValue, safeUpper))
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double, fallback: Double) -> Double {
        let safeLower = lower.isFinite ? lower : fallback
        let safeUpper = upper.isFinite ? max(safeLower, upper) : max(safeLower, fallback)
        let safeValue = value.isFinite ? value : fallback
        return max(safeLower, min(safeValue, safeUpper))
    }
}
