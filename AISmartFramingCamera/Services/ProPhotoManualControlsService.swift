import Foundation
import AVFoundation
import Combine

/// Các nhóm thông số điều khiển thủ công trong chế độ Chụp ảnh Pro (chuẩn Apple AVFoundation).
public enum ProPhotoParameterTab: String, CaseIterable, Identifiable, Sendable {
    case ev = "EV"
    case shutter = "SS"
    case iso = "ISO"
    case wb = "WB"
    case focus = "MF"
    case film = "MÀU"
    case hardware = "PRO"

    public var id: String { rawValue }

    public var vietnameseTitle: String {
        switch self {
        case .ev: return "Bù sáng EV"
        case .shutter: return "Tốc độ màn trập"
        case .iso: return "Độ nhạy ISO"
        case .wb: return "Cân bằng trắng"
        case .focus: return "Lấy nét"
        case .film: return "Giả lập phim"
        case .hardware: return "Tùy chọn Pro"
        }
    }

    public var iconName: String {
        switch self {
        case .ev: return "plusminus"
        case .shutter: return "timer"
        case .iso: return "camera.aperture"
        case .wb: return "thermometer.medium"
        case .focus: return "scope"
        case .film: return "camera.filters"
        case .hardware: return "slider.horizontal.3"
        }
    }
}

/// Chương trình phơi sáng hiện hành hiển thị trên thanh telemetry Pro.
public enum ProPhotoExposureProgram: String, Sendable {
    case auto = "AUTO"
    case shutterPriority = "S"
    case isoPriority = "ISO"
    case manual = "M"
    case locked = "AE-L"

    public var descriptionVietnamese: String {
        switch self {
        case .auto: return "Phơi sáng tự động"
        case .shutterPriority: return "Ưu tiên tốc độ (ISO tự động)"
        case .isoPriority: return "Ưu tiên ISO (Tốc độ tự động)"
        case .manual: return "Thủ công hoàn toàn"
        case .locked: return "Đã khóa phơi sáng AE-L"
        }
    }
}

/// Giới hạn vùng lấy nét tự động (Apple AVCaptureDevice.AutoFocusRangeRestriction).
public enum ProPhotoAFRangeMode: Int, CaseIterable, Identifiable, Sendable {
    case full = 0
    case near = 1
    case far = 2

    public var id: Int { rawValue }

    public var shortLabel: String {
        switch self {
        case .full: return "Toàn dải"
        case .near: return "Gần"
        case .far: return "Xa"
        }
    }

    public var avRestriction: AVCaptureDevice.AutoFocusRangeRestriction {
        switch self {
        case .full: return .none
        case .near: return .near
        case .far: return .far
        }
    }

    public static func from(_ restriction: AVCaptureDevice.AutoFocusRangeRestriction) -> ProPhotoAFRangeMode {
        switch restriction {
        case .near: return .near
        case .far: return .far
        default: return .full
        }
    }
}

/// Mốc cân bằng trắng nhanh cho chế độ Chụp ảnh Pro.
public struct ProPhotoWBPreset: Identifiable, Sendable {
    public let kelvin: Float
    public let label: String
    public var id: Float { kelvin }

    public init(kelvin: Float, label: String) {
        self.kelvin = kelvin
        self.label = label
    }
}

/// Bộ điều khiển Chụp ảnh Pro an toàn phần cứng (Apple AVFoundation).
///
/// Mọi thao tác đọc/ghi `AVCaptureDevice` đều đi qua hàng đợi tuần tự
/// `CameraService.shared.scheduleDeviceConfiguration`, luôn kiểm tra cờ hỗ trợ phần cứng
/// và kẹp chặt biên (`minISO...maxISO`, `minExposureDuration...maxExposureDuration`,
/// `1.0...maxWhiteBalanceGain`, `minExposureTargetBias...maxExposureTargetBias`)
/// để tuyệt đối tránh `NSInvalidArgumentException` trên mọi dòng iPhone.
public final class ProPhotoManualControlsService: ObservableObject {
    public static let shared = ProPhotoManualControlsService()

    // MARK: - Trạng thái vòng đời

    @Published public private(set) var isActive: Bool = false

    // MARK: - Phơi sáng (ISO / Shutter / EV / AE-L)

    @Published public var isAutoISO: Bool = true
    @Published public var currentISO: Float = 100
    @Published public private(set) var minISO: Float = 32
    @Published public private(set) var maxISO: Float = 3200
    @Published public private(set) var isCustomExposureSupported: Bool = true

    /// Thời gian phơi sáng theo giây (ví dụ 0.5s = 1/2s, 0.008s = 1/125s).
    @Published public var isAutoShutter: Bool = true
    @Published public var currentShutterSeconds: Double = 1.0 / 125.0
    @Published public private(set) var minShutterSeconds: Double = 1.0 / 4000.0
    @Published public private(set) var maxShutterSeconds: Double = 0.5

    @Published public var currentEVBias: Float = 0.0
    @Published public private(set) var minEVBias: Float = -3.0
    @Published public private(set) var maxEVBias: Float = 3.0

    @Published public var isExposureLocked: Bool = false
    @Published public private(set) var isExposureLockSupported: Bool = true

    // MARK: - Cân bằng trắng (Kelvin & Tint — tự động chọn phần cứng ISP hoặc GPU an toàn cho Virtual Multi-Camera)

    @Published public var isAutoWB: Bool = true
    @Published public var currentKelvin: Float = 5500
    @Published public var currentTint: Float = 0
    @Published public private(set) var isManualWBSupported: Bool = true
    /// `true` trên ống kính vật lý đơn hỗ trợ `isLockingWhiteBalanceWithCustomDeviceGainsSupported`;
    /// `false` trên Virtual Multi-Camera (builtInTripleCamera / DualWide) -> dùng Khóa AWB phần cứng + GPU Kelvin/Tint để không bao giờ văng app.
    @Published public private(set) var isHardwareCustomWBSupported: Bool = false
    @Published public private(set) var isWhiteBalanceLockSupported: Bool = true
    @Published public var isWhiteBalanceLocked: Bool = false
    @Published public private(set) var softwareWhiteBalanceGrade: ProPhotoSoftwareWBGrade = .inactive
    public var onSoftwareWhiteBalanceChanged: ((ProPhotoSoftwareWBGrade) -> Void)?
    public let minKelvin: Float = 2500
    public let maxKelvin: Float = 9500
    public let minTint: Float = -50
    public let maxTint: Float = 50

    // MARK: - Lấy nét (Manual Focus / AF-L / AF Range)

    @Published public var isAutoFocus: Bool = true
    @Published public var currentLensPosition: Float = 0.5
    @Published public private(set) var isManualFocusSupported: Bool = true
    @Published public var isFocusLocked: Bool = false
    @Published public private(set) var isFocusLockSupported: Bool = true
    @Published public var afRangeMode: ProPhotoAFRangeMode = .full
    @Published public private(set) var isAFRangeSupported: Bool = false

    // MARK: - Tùy chọn phần cứng Apple Pro

    @Published public var isLowLightBoostPreferred: Bool = true
    @Published public private(set) var isLowLightBoostSupported: Bool = false
    @Published public private(set) var isHardwareLowLightBoostActive: Bool = false

    @Published public var isGeometricDistortionCorrectionEnabled: Bool = true
    @Published public private(set) var isGeometricDistortionCorrectionSupported: Bool = false

    @Published public var torchLevel: Float = 0.0
    @Published public private(set) var isTorchSupported: Bool = false

    // MARK: - Thông số đo trực tiếp từ cảm biến & ISP (100% dữ liệu thực)

    @Published public private(set) var measuredLiveISO: Float = 100
    @Published public private(set) var measuredLiveShutterSeconds: Double = 1.0 / 125.0
    @Published public private(set) var measuredLiveKelvin: Float = 5500
    @Published public private(set) var measuredLiveTint: Float = 0
    @Published public private(set) var measuredLiveLensPosition: Float = 0.5
    /// Độ lệch đo sáng thực tế từ Apple ISP (`camera.exposureTargetOffset`, đơn vị EV stop).
    /// Giá trị dương = dư sáng (+EV), âm = thiếu sáng (-EV), 0.0 = đúng sáng chuẩn.
    @Published public private(set) var measuredExposureTargetOffset: Float = 0.0
    @Published public private(set) var hardwareLensAperture: Float = 1.8
    @Published public private(set) var equivalentFocalLengthMM: Int = 24
    @Published public private(set) var activeLensDisplayName: String = "Chính"
    @Published public private(set) var maxPhotoMegapixels: Int = 12
    @Published public private(set) var isAdjustingExposure: Bool = false
    @Published public private(set) var isAdjustingFocus: Bool = false
    @Published public private(set) var isAdjustingWhiteBalance: Bool = false

    // MARK: - Hàng đợi gom lệnh & Timer đọc cảm biến

    private var pendingExposureWorkItem: DispatchWorkItem?
    private var pendingEVWorkItem: DispatchWorkItem?
    private var pendingWBWorkItem: DispatchWorkItem?
    private var pendingFocusWorkItem: DispatchWorkItem?
    private var pendingHardwareWorkItem: DispatchWorkItem?

    private var telemetryTimer: Timer?
    private var isPollingPaused: Bool = false
    private var lastDisplayZoom: CGFloat = 1.0
    private var lastUserExposureWriteAt: TimeInterval = 0
    private var lastUserFocusWriteAt: TimeInterval = 0
    private var lastUserWBWriteAt: TimeInterval = 0

    /// Mốc ISO nhiếp ảnh chuẩn (lọc tự động theo `minISO...maxISO` của ống kính hiện tại).
    public static let standardISOStops: [Float] = [
        25, 32, 50, 64, 100, 160, 200, 320, 400, 640, 800, 1250, 1600, 2500, 3200, 4000, 6400
    ]

    /// Mốc tốc độ màn trập nhiếp ảnh chuẩn (giây, lọc tự động theo `minShutterSeconds...maxShutterSeconds`).
    public static let standardShutterStopsSeconds: [Double] = [
        1.0, 0.5, 0.25, 1.0 / 8.0, 1.0 / 15.0, 1.0 / 30.0, 1.0 / 60.0,
        1.0 / 125.0, 1.0 / 250.0, 1.0 / 500.0, 1.0 / 1000.0, 1.0 / 2000.0, 1.0 / 4000.0
    ]

    public static let standardWBPresets: [ProPhotoWBPreset] = [
        ProPhotoWBPreset(kelvin: 2800, label: "2800K"),
        ProPhotoWBPreset(kelvin: 3800, label: "3800K"),
        ProPhotoWBPreset(kelvin: 5500, label: "5500K"),
        ProPhotoWBPreset(kelvin: 6500, label: "6500K"),
        ProPhotoWBPreset(kelvin: 7500, label: "7500K")
    ]

    private init() {}

    // MARK: - Thuộc tính suy diễn cho UI

    public var exposureProgram: ProPhotoExposureProgram {
        if isExposureLocked && isAutoISO && isAutoShutter {
            return .locked
        }
        switch (isAutoISO, isAutoShutter) {
        case (true, true): return .auto
        case (true, false): return .shutterPriority
        case (false, true): return .isoPriority
        case (false, false): return .manual
        }
    }

    public var hasAnyManualOverride: Bool {
        !isAutoISO
            || !isAutoShutter
            || abs(currentEVBias) >= 0.05
            || !isAutoWB
            || isWhiteBalanceLocked
            || !isAutoFocus
            || isExposureLocked
            || isFocusLocked
            || afRangeMode != .full
            || torchLevel >= 0.05
    }

    public var supportedISOStops: [Float] {
        let filtered = Self.standardISOStops.filter { $0 >= minISO - 1 && $0 <= maxISO + 1 }
        if filtered.isEmpty {
            return [minISO, maxISO]
        }
        return filtered
    }

    public var supportedShutterStops: [Double] {
        let filtered = Self.standardShutterStopsSeconds.filter {
            $0 >= minShutterSeconds * 0.96 && $0 <= maxShutterSeconds * 1.04
        }
        if filtered.isEmpty {
            return [maxShutterSeconds, minShutterSeconds]
        }
        return filtered
    }

    // MARK: - Định dạng thông số chuẩn nhiếp ảnh

    public static func formatShutter(_ seconds: Double, includeUnit: Bool = false) -> String {
        guard seconds.isFinite, seconds > 0 else { return includeUnit ? "1/125s" : "1/125" }
        if seconds >= 0.92 {
            return String(format: "%.1fs", seconds)
        }
        if seconds >= 0.38 {
            let denom = max(2, Int(round(1.0 / seconds)))
            return includeUnit ? "1/\(denom)s" : "1/\(denom)"
        }
        let denom = max(2, Int(round(1.0 / seconds)))
        return includeUnit ? "1/\(denom)s" : "1/\(denom)"
    }

    public static func formatEV(_ ev: Float) -> String {
        let safe = ev.isFinite ? ev : 0
        if abs(safe) < 0.05 { return "0.0" }
        return String(format: "%+.1f", safe)
    }

    public static func formatKelvinShort(_ kelvin: Float) -> String {
        let safe = kelvin.isFinite ? kelvin : 5500
        return String(format: "%.1fK", safe / 1000.0)
    }

    // MARK: - Kích hoạt / Hủy kích hoạt chế độ Pro Photo

    public func activate(displayZoom: CGFloat = 1.0) {
        lastDisplayZoom = displayZoom
        isActive = true
        isPollingPaused = false
        syncHardwareCapabilities(displayZoom: displayZoom)
        startTelemetryTimer()
    }

    public func setPollingPaused(_ paused: Bool) {
        isPollingPaused = paused
        if paused {
            stopTelemetryTimer()
            if torchLevel >= 0.05 {
                setTorchLevel(0.0)
            }
        } else if isActive {
            syncHardwareCapabilities(displayZoom: lastDisplayZoom)
            startTelemetryTimer()
        }
    }

    public func deactivateAndResetToAuto() {
        isActive = false
        stopTelemetryTimer()
        resetToFullAuto()
    }

    public func handleHardwareLensChanged(displayZoom: CGFloat, isFront: Bool) {
        lastDisplayZoom = displayZoom
        if isFront && torchLevel >= 0.05 {
            torchLevel = 0.0
        }
        guard isActive else { return }
        syncHardwareCapabilities(displayZoom: displayZoom, reapplyActiveOverrides: true)
    }

    /// Nạp dữ liệu mẫu thực tế chỉ cho Simulator UI Snapshot (`-UI_SNAPSHOT_MODE`).
    public func applySnapshotPreviewState() {
        isActive = true
        minISO = 32
        maxISO = 3200
        currentISO = 100
        measuredLiveISO = 100
        isAutoISO = false
        minShutterSeconds = 1.0 / 4000.0
        maxShutterSeconds = 1.0
        currentShutterSeconds = 1.0 / 250.0
        measuredLiveShutterSeconds = 1.0 / 250.0
        isAutoShutter = false
        currentEVBias = 0.0
        measuredExposureTargetOffset = 0.2
        currentKelvin = 5400
        measuredLiveKelvin = 5400
        currentTint = 2
        measuredLiveTint = 2
        isAutoWB = true
        isAutoFocus = true
        currentLensPosition = 0.62
        measuredLiveLensPosition = 0.62
        hardwareLensAperture = 1.78
        equivalentFocalLengthMM = 24
        activeLensDisplayName = "Chính"
        maxPhotoMegapixels = 48
        isCustomExposureSupported = true
        isManualWBSupported = true
        isManualFocusSupported = true
        isAFRangeSupported = true
        isLowLightBoostSupported = true
        isGeometricDistortionCorrectionSupported = true
        isTorchSupported = true
    }

    // MARK: - Đọc biên phần cứng & đồng bộ thông số

    public func syncHardwareCapabilities(displayZoom: CGFloat? = nil, reapplyActiveOverrides: Bool = false) {
        if let zoom = displayZoom, zoom.isFinite, zoom > 0 {
            lastDisplayZoom = zoom
        }
        let zoomSnapshot = lastDisplayZoom

        CameraService.shared.scheduleDeviceConfiguration { [weak self] camera in
            let format = camera.activeFormat
            let hwMinISO = Self.finite(format.minISO, fallback: 32)
            let hwMaxISO = Self.finite(format.maxISO, fallback: 3200)
            let safeMinISO = max(20, min(hwMinISO, hwMaxISO))
            let safeMaxISO = max(safeMinISO, min(12800, hwMaxISO))

            let hwMinDur = CMTimeGetSeconds(format.minExposureDuration)
            let hwMaxDur = CMTimeGetSeconds(format.maxExposureDuration)
            let safeMinDur = (hwMinDur.isFinite && hwMinDur > 0) ? max(1.0 / 16000.0, hwMinDur) : (1.0 / 4000.0)
            // Giới hạn phơi sáng tối đa 1.0s để viewfinder giữ độ mượt và không treo luồng preview.
            let safeMaxDur = (hwMaxDur.isFinite && hwMaxDur > safeMinDur) ? min(1.0, hwMaxDur) : max(safeMinDur, 0.5)

            let hwMinEV = Self.finite(camera.minExposureTargetBias, fallback: -3.0)
            let hwMaxEV = Self.finite(camera.maxExposureTargetBias, fallback: 3.0)
            let safeMinEV = max(-3.0, min(hwMinEV, hwMaxEV))
            let safeMaxEV = max(safeMinEV, min(3.0, hwMaxEV))

            let aperture = (camera.lensAperture.isFinite && camera.lensAperture > 0) ? camera.lensAperture : 1.8
            let supportsCustomExp = camera.isExposureModeSupported(.custom)
            let supportsExpLock = camera.isExposureModeSupported(.locked)
            let supportsCustomWB = Self.supportsSafeHardwareCustomWB(camera)
            let supportsWBLock = camera.isWhiteBalanceModeSupported(.locked)
            let supportsMF = camera.isLockingFocusWithCustomLensPositionSupported
            let supportsFocusLock = camera.isFocusModeSupported(.locked)
            let supportsAFRange = camera.isAutoFocusRangeRestrictionSupported
            let currentAFRange = supportsAFRange ? ProPhotoAFRangeMode.from(camera.autoFocusRangeRestriction) : .full
            let supportsLLB = camera.isLowLightBoostSupported
            let llbPref = supportsLLB ? camera.automaticallyEnablesLowLightBoostWhenAvailable : false
            let llbActive = supportsLLB ? camera.isLowLightBoostEnabled : false
            let supportsLDC = camera.isGeometricDistortionCorrectionSupported
            let ldcEnabled = supportsLDC ? camera.isGeometricDistortionCorrectionEnabled : false
            let supportsTorch = camera.hasTorch && camera.isTorchAvailable && camera.isTorchModeSupported(.on)

            let liveISO = Self.clamp(camera.iso, lower: safeMinISO, upper: safeMaxISO, fallback: 100)
            let liveDurRaw = CMTimeGetSeconds(camera.exposureDuration)
            let liveDur = (liveDurRaw.isFinite && liveDurRaw > 0)
                ? Self.clamp(liveDurRaw, lower: safeMinDur, upper: safeMaxDur, fallback: 1.0 / 125.0)
                : (1.0 / 125.0)
            let liveOffset = Self.clamp(camera.exposureTargetOffset, lower: -6.0, upper: 6.0, fallback: 0.0)
            let liveBias = Self.clamp(camera.exposureTargetBias, lower: safeMinEV, upper: safeMaxEV, fallback: 0.0)
            let liveLens = Self.clamp(camera.lensPosition, lower: 0.0, upper: 1.0, fallback: 0.5)

            let wbTT = supportsCustomWB ? Self.readSafeTemperatureAndTint(from: camera) : nil
            let maxMP = Self.computeMaxMegapixels(for: format)
            let eqFocal = Self.computeEquivalentFocalLengthMM(camera: camera, displayZoom: zoomSnapshot)
            let lensName = Self.lensDisplayName(for: camera, displayZoom: zoomSnapshot)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.minISO = safeMinISO
                self.maxISO = safeMaxISO
                self.minShutterSeconds = safeMinDur
                self.maxShutterSeconds = safeMaxDur
                self.minEVBias = safeMinEV
                self.maxEVBias = safeMaxEV
                self.hardwareLensAperture = aperture
                self.isCustomExposureSupported = supportsCustomExp
                self.isExposureLockSupported = supportsExpLock
                self.isHardwareCustomWBSupported = supportsCustomWB
                self.isWhiteBalanceLockSupported = supportsWBLock
                self.isManualWBSupported = true
                self.isManualFocusSupported = supportsMF
                self.isFocusLockSupported = supportsFocusLock
                self.isAFRangeSupported = supportsAFRange
                self.afRangeMode = currentAFRange
                self.isLowLightBoostSupported = supportsLLB
                self.isLowLightBoostPreferred = llbPref
                self.isHardwareLowLightBoostActive = llbActive
                self.isGeometricDistortionCorrectionSupported = supportsLDC
                self.isGeometricDistortionCorrectionEnabled = ldcEnabled
                self.isTorchSupported = supportsTorch
                if !supportsTorch {
                    self.torchLevel = 0.0
                }
                self.maxPhotoMegapixels = maxMP
                self.equivalentFocalLengthMM = eqFocal
                self.activeLensDisplayName = lensName

                self.measuredLiveISO = liveISO
                self.measuredLiveShutterSeconds = liveDur
                self.measuredExposureTargetOffset = liveOffset
                self.measuredLiveLensPosition = liveLens
                if let wbTT {
                    self.measuredLiveKelvin = wbTT.kelvin
                    self.measuredLiveTint = wbTT.tint
                }

                // Kẹp lại giá trị người dùng đang giữ vào biên mới của ống kính
                self.currentISO = self.isAutoISO
                    ? liveISO
                    : Self.clamp(self.currentISO, lower: safeMinISO, upper: safeMaxISO, fallback: liveISO)
                self.currentShutterSeconds = self.isAutoShutter
                    ? liveDur
                    : Self.clamp(self.currentShutterSeconds, lower: safeMinDur, upper: safeMaxDur, fallback: liveDur)
                self.currentEVBias = Self.clamp(liveBias, lower: safeMinEV, upper: safeMaxEV, fallback: 0.0)
                if self.isAutoFocus || !supportsMF {
                    self.isAutoFocus = true
                    self.currentLensPosition = liveLens
                }
                if self.isAutoWB, let wbTT {
                    self.currentKelvin = wbTT.kelvin
                    self.currentTint = wbTT.tint
                } else if self.isAutoWB && !supportsCustomWB {
                    self.currentKelvin = 5500
                    self.currentTint = 0
                }
                if !supportsCustomExp {
                    self.isAutoISO = true
                    self.isAutoShutter = true
                }

                if reapplyActiveOverrides && self.isActive {
                    self.reapplyOverridesAfterLensChange()
                }
            }
        }
    }

    public func updateLiveMeasurements(
        iso: Float,
        shutterDuration: Double,
        lensPosition: Float,
        displayZoom: CGFloat
    ) {
        lastDisplayZoom = displayZoom
        guard isActive else { return }
        if iso.isFinite, iso > 0 {
            measuredLiveISO = iso
            if isAutoISO {
                currentISO = Self.clamp(iso, lower: minISO, upper: maxISO, fallback: currentISO)
            }
        }
        if shutterDuration.isFinite, shutterDuration > 0 {
            measuredLiveShutterSeconds = shutterDuration
            if isAutoShutter {
                currentShutterSeconds = Self.clamp(
                    shutterDuration,
                    lower: minShutterSeconds,
                    upper: maxShutterSeconds,
                    fallback: currentShutterSeconds
                )
            }
        }
        let clampedLens = Self.clamp(lensPosition, lower: 0, upper: 1, fallback: measuredLiveLensPosition)
        measuredLiveLensPosition = clampedLens
        if isAutoFocus {
            currentLensPosition = clampedLens
        }
    }

    // MARK: - Vòng đọc telemetry 5 Hz (đo sáng EV Meter, Kelvin thực, AF/AE state & ưu tiên S/ISO)

    private func startTelemetryTimer() {
        stopTelemetryTimer()
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.pollLiveHardwareTelemetry()
        }
        RunLoop.main.add(timer, forMode: .common)
        telemetryTimer = timer
    }

    private func stopTelemetryTimer() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    private func pollLiveHardwareTelemetry() {
        guard isActive, !isPollingPaused else { return }
        let zoomSnapshot = lastDisplayZoom
        let now = Date().timeIntervalSince1970
        let wantShutterPriority = !isAutoShutter && isAutoISO && !isExposureLocked
        let wantISOPriority = !isAutoISO && isAutoShutter && !isExposureLocked
        let manualShutterSec = currentShutterSeconds
        let manualISOVal = currentISO
        let canAdjustSemiAuto = (now - lastUserExposureWriteAt) >= 0.28
        let canSyncExposureTruth = (now - lastUserExposureWriteAt) >= 0.55
        let canSyncFocusTruth = (now - lastUserFocusWriteAt) >= 0.55
        let canSyncWBTruth = (now - lastUserWBWriteAt) >= 0.55

        CameraService.shared.scheduleDeviceConfiguration { [weak self] camera in
            let format = camera.activeFormat
            let hwMinISO = max(20, Self.finite(format.minISO, fallback: 32))
            let hwMaxISO = max(hwMinISO, min(12800, Self.finite(format.maxISO, fallback: 3200)))
            let hwMinDurRaw = CMTimeGetSeconds(format.minExposureDuration)
            let hwMaxDurRaw = CMTimeGetSeconds(format.maxExposureDuration)
            let hwMinDur = (hwMinDurRaw.isFinite && hwMinDurRaw > 0) ? max(1.0 / 16000.0, hwMinDurRaw) : (1.0 / 4000.0)
            let hwMaxDur = (hwMaxDurRaw.isFinite && hwMaxDurRaw > hwMinDur) ? min(1.0, hwMaxDurRaw) : max(hwMinDur, 0.5)

            let offset = Self.clamp(camera.exposureTargetOffset, lower: -6.0, upper: 6.0, fallback: 0.0)
            let liveISO = Self.clamp(camera.iso, lower: hwMinISO, upper: hwMaxISO, fallback: 100)
            let liveDurRaw = CMTimeGetSeconds(camera.exposureDuration)
            let liveDur = (liveDurRaw.isFinite && liveDurRaw > 0) ? liveDurRaw : (1.0 / 125.0)
            let liveBias = Self.clamp(camera.exposureTargetBias, lower: -3.0, upper: 3.0, fallback: 0.0)
            let liveLens = Self.clamp(camera.lensPosition, lower: 0, upper: 1, fallback: 0.5)
            let supportsCustomWB = Self.supportsSafeHardwareCustomWB(camera)
            let wbTT = supportsCustomWB ? Self.readSafeTemperatureAndTint(from: camera) : nil

            // Vòng hồi tiếp bán tự động chuẩn thực tế (S = ưu tiên tốc độ tự chỉnh ISO; ISO = ưu tiên ISO tự chỉnh tốc độ)
            if canAdjustSemiAuto && (wantShutterPriority || wantISOPriority) && camera.isExposureModeSupported(.custom) && abs(offset) >= 0.14 {
                let damping = 0.52
                let multiplier = pow(2.0, -Double(offset) * damping)
                do {
                    try camera.lockForConfiguration()
                    defer { camera.unlockForConfiguration() }
                    if wantShutterPriority {
                        let nextISO = Self.clamp(Float(Double(liveISO) * multiplier), lower: hwMinISO, upper: hwMaxISO, fallback: liveISO)
                        let lockedDurSec = Self.clamp(manualShutterSec, lower: hwMinDur, upper: hwMaxDur, fallback: liveDur)
                        let lockedDur = Self.clampedExposureCMTime(seconds: lockedDurSec, format: format)
                        camera.setExposureModeCustom(duration: lockedDur, iso: nextISO, completionHandler: nil)
                    } else if wantISOPriority {
                        let nextDurSec = Self.clamp(liveDur * multiplier, lower: hwMinDur, upper: hwMaxDur, fallback: liveDur)
                        let nextDur = Self.clampedExposureCMTime(seconds: nextDurSec, format: format)
                        let lockedISO = Self.clamp(manualISOVal, lower: hwMinISO, upper: hwMaxISO, fallback: liveISO)
                        camera.setExposureModeCustom(duration: nextDur, iso: lockedISO, completionHandler: nil)
                    }
                } catch {
                    // Bỏ qua nhẹ nếu hệ thống đang bận cấu hình chụp
                }
            }

            let aperture = (camera.lensAperture.isFinite && camera.lensAperture > 0) ? camera.lensAperture : 1.8
            let eqFocal = Self.computeEquivalentFocalLengthMM(camera: camera, displayZoom: zoomSnapshot)
            let lensName = Self.lensDisplayName(for: camera, displayZoom: zoomSnapshot)
            let exposureMode = camera.exposureMode
            let focusMode = camera.focusMode
            let wbMode = camera.whiteBalanceMode
            let adjustingExp = camera.isAdjustingExposure
            let adjustingFocus = camera.isAdjustingFocus
            let adjustingWB = camera.isAdjustingWhiteBalance
            let llbActive = camera.isLowLightBoostSupported ? camera.isLowLightBoostEnabled : false

            DispatchQueue.main.async {
                guard let self = self, self.isActive else { return }
                self.measuredExposureTargetOffset = offset
                self.measuredLiveISO = liveISO
                self.measuredLiveShutterSeconds = liveDur
                self.measuredLiveLensPosition = liveLens
                self.hardwareLensAperture = aperture
                self.equivalentFocalLengthMM = eqFocal
                self.activeLensDisplayName = lensName
                self.isAdjustingExposure = adjustingExp
                self.isAdjustingFocus = adjustingFocus
                self.isAdjustingWhiteBalance = adjustingWB
                self.isHardwareLowLightBoostActive = llbActive

                if let wbTT {
                    self.measuredLiveKelvin = wbTT.kelvin
                    self.measuredLiveTint = wbTT.tint
                    if self.isAutoWB {
                        self.currentKelvin = wbTT.kelvin
                        self.currentTint = wbTT.tint
                    }
                }

                // Đồng bộ trung thực với trạng thái phần cứng (ví dụ khi người dùng chạm lấy nét lên khung ngắm)
                if canSyncExposureTruth {
                    if exposureMode == .continuousAutoExposure {
                        if !self.isAutoISO { self.isAutoISO = true }
                        if !self.isAutoShutter { self.isAutoShutter = true }
                        if self.isExposureLocked { self.isExposureLocked = false }
                        if abs(self.currentEVBias - liveBias) >= 0.08 {
                            self.currentEVBias = liveBias
                        }
                    } else if exposureMode == .locked {
                        if !self.isExposureLocked { self.isExposureLocked = true }
                    }
                }

                if canSyncFocusTruth {
                    if focusMode == .continuousAutoFocus {
                        if !self.isAutoFocus { self.isAutoFocus = true }
                        if self.isFocusLocked { self.isFocusLocked = false }
                    }
                }

                if canSyncWBTruth && self.isHardwareCustomWBSupported && wbMode == .continuousAutoWhiteBalance && !self.isAutoWB {
                    self.isAutoWB = true
                }
                if canSyncWBTruth && wbMode == .continuousAutoWhiteBalance && self.isWhiteBalanceLocked {
                    self.isWhiteBalanceLocked = false
                }
            }
        }
    }

    // MARK: - Điều khiển ISO & Tốc độ màn trập

    public func setAutoISO(_ auto: Bool) {
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        isAutoISO = auto
        isExposureLocked = false
        if auto && isAutoShutter {
            restoreContinuousAutoExposure()
        } else {
            if !auto {
                currentISO = Self.clamp(measuredLiveISO, lower: minISO, upper: maxISO, fallback: currentISO)
            }
            applyCustomExposure()
        }
    }

    public func setManualISO(_ iso: Float) {
        guard isCustomExposureSupported else { return }
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        currentISO = Self.clamp(iso, lower: minISO, upper: maxISO, fallback: currentISO)
        isAutoISO = false
        isExposureLocked = false
        applyCustomExposure()
    }

    public func setAutoShutter(_ auto: Bool) {
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        isAutoShutter = auto
        isExposureLocked = false
        if auto && isAutoISO {
            restoreContinuousAutoExposure()
        } else {
            if !auto {
                currentShutterSeconds = Self.clamp(
                    measuredLiveShutterSeconds,
                    lower: minShutterSeconds,
                    upper: maxShutterSeconds,
                    fallback: currentShutterSeconds
                )
            }
            applyCustomExposure()
        }
    }

    public func setManualShutterSeconds(_ seconds: Double) {
        guard isCustomExposureSupported else { return }
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        currentShutterSeconds = Self.clamp(seconds, lower: minShutterSeconds, upper: maxShutterSeconds, fallback: currentShutterSeconds)
        isAutoShutter = false
        isExposureLocked = false
        applyCustomExposure()
    }

    private func applyCustomExposure() {
        pendingExposureWorkItem?.cancel()
        let autoISO = isAutoISO
        let autoShutter = isAutoShutter
        let reqISO = currentISO
        let reqDur = currentShutterSeconds

        pendingExposureWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.015) { camera in
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

                let format = camera.activeFormat
                let safeMinISO = Self.finite(format.minISO, fallback: 32)
                let safeMaxISO = max(safeMinISO, Self.finite(format.maxISO, fallback: 3200))
                let targetISO = autoISO
                    ? Self.clamp(camera.iso, lower: safeMinISO, upper: safeMaxISO, fallback: safeMinISO)
                    : Self.clamp(reqISO, lower: safeMinISO, upper: safeMaxISO, fallback: safeMinISO)

                let targetDuration: CMTime
                if autoShutter {
                    let currentSec = CMTimeGetSeconds(camera.exposureDuration)
                    targetDuration = Self.clampedExposureCMTime(
                        seconds: (currentSec.isFinite && currentSec > 0) ? currentSec : (1.0 / 125.0),
                        format: format
                    )
                } else {
                    targetDuration = Self.clampedExposureCMTime(seconds: reqDur, format: format)
                }

                camera.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
            } catch {
                CameraLogger.error("ProPhoto: Lỗi thiết lập phơi sáng thủ công", error: error, category: .capture)
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
                CameraLogger.error("ProPhoto: Lỗi khôi phục AE", error: error, category: .capture)
            }
        }
    }

    // MARK: - Bù sáng EV & Khóa AE-L

    public func setManualEVBias(_ bias: Float) {
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        let clamped = Self.clamp(bias, lower: minEVBias, upper: maxEVBias, fallback: 0.0)
        currentEVBias = clamped
        isExposureLocked = false

        // Theo đặc tả Apple AVFoundation, exposureTargetBias chỉ có tác dụng khi AE hoạt động.
        // Nếu người dùng đang ở M (ISO + SS thủ công), tự chuyển về AE để thanh EV phản hồi trực tiếp.
        let needsRestoreAE = !isAutoISO || !isAutoShutter
        if needsRestoreAE {
            isAutoISO = true
            isAutoShutter = true
        }

        pendingEVWorkItem?.cancel()
        pendingEVWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.015) { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if needsRestoreAE && camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                let hwClamped = Self.clamp(
                    clamped,
                    lower: camera.minExposureTargetBias,
                    upper: camera.maxExposureTargetBias,
                    fallback: 0.0
                )
                camera.setExposureTargetBias(hwClamped, completionHandler: nil)
            } catch {
                CameraLogger.error("ProPhoto: Lỗi chỉnh EV Bias", error: error, category: .capture)
            }
        }
    }

    public func toggleExposureLock() {
        guard isExposureLockSupported else { return }
        lastUserExposureWriteAt = Date().timeIntervalSince1970
        let nextLocked = !isExposureLocked
        isExposureLocked = nextLocked

        if !nextLocked {
            if !isAutoISO || !isAutoShutter {
                applyCustomExposure()
            } else {
                restoreContinuousAutoExposure()
            }
            return
        }

        CameraService.shared.scheduleDeviceConfiguration { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isExposureModeSupported(.locked) {
                    camera.exposureMode = .locked
                }
            } catch {
                CameraLogger.error("ProPhoto: Lỗi khóa AE-L", error: error, category: .capture)
            }
        }
    }

    // MARK: - Cân bằng trắng (Kelvin, Tint, Khóa AWB & Gray World Neutral — tuyệt đối chống văng trên Virtual Multi-Camera)

    private func publishSoftwareWB(_ grade: ProPhotoSoftwareWBGrade) {
        softwareWhiteBalanceGrade = grade
        FilmFilterEngine.shared.activeSoftwareWhiteBalance = grade
        onSoftwareWhiteBalanceChanged?(grade)
    }

    public func setAutoWB(_ auto: Bool) {
        lastUserWBWriteAt = Date().timeIntervalSince1970
        isAutoWB = auto
        if auto {
            isWhiteBalanceLocked = false
            currentKelvin = isHardwareCustomWBSupported ? measuredLiveKelvin : 5500
            currentTint = isHardwareCustomWBSupported ? measuredLiveTint : 0
            publishSoftwareWB(.inactive)
            restoreContinuousAutoWhiteBalance()
        } else {
            currentKelvin = Self.clamp(
                isHardwareCustomWBSupported ? measuredLiveKelvin : currentKelvin,
                lower: minKelvin,
                upper: maxKelvin,
                fallback: 5500
            )
            currentTint = Self.clamp(
                isHardwareCustomWBSupported ? measuredLiveTint : currentTint,
                lower: minTint,
                upper: maxTint,
                fallback: 0
            )
            applyWhiteBalance()
        }
    }

    public func setManualWhiteBalance(kelvin: Float, tint: Float? = nil) {
        lastUserWBWriteAt = Date().timeIntervalSince1970
        currentKelvin = Self.clamp(kelvin, lower: minKelvin, upper: maxKelvin, fallback: currentKelvin)
        if let tint {
            currentTint = Self.clamp(tint, lower: minTint, upper: maxTint, fallback: currentTint)
        }
        isAutoWB = false
        applyWhiteBalance()
    }

    public func setManualTint(_ tint: Float) {
        lastUserWBWriteAt = Date().timeIntervalSince1970
        currentTint = Self.clamp(tint, lower: minTint, upper: maxTint, fallback: currentTint)
        isAutoWB = false
        applyWhiteBalance()
    }

    /// Khóa / Mở khóa AWB phần cứng an toàn trên mọi dòng iPhone (kể cả Triple/DualWide Camera).
    public func toggleWhiteBalanceLock() {
        guard isWhiteBalanceLockSupported else { return }
        lastUserWBWriteAt = Date().timeIntervalSince1970
        let nextLocked = !isWhiteBalanceLocked
        isWhiteBalanceLocked = nextLocked
        if !nextLocked && isAutoWB {
            restoreContinuousAutoWhiteBalance()
            return
        }
        if nextLocked {
            CameraService.shared.scheduleDeviceConfiguration { camera in
                guard camera.isWhiteBalanceModeSupported(.locked) else { return }
                do {
                    try camera.lockForConfiguration()
                    defer { camera.unlockForConfiguration() }
                    camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                } catch {
                    CameraLogger.error("ProPhoto: Lỗi khóa AWB-L", error: error, category: .capture)
                }
            }
        }
    }

    /// Cân bằng trắng 1 chạm: dùng Gray World phần cứng nếu ống kính hỗ trợ custom gain,
    /// hoặc khóa AWB trung tính chuẩn Apple (`currentWhiteBalanceGains`) + đặt lệch GPU về 5500K/0 trên Virtual Multi-Camera.
    public func applyGrayWorldNeutralWB() {
        lastUserWBWriteAt = Date().timeIntervalSince1970
        pendingWBWorkItem?.cancel()

        if !isHardwareCustomWBSupported {
            isAutoWB = false
            isWhiteBalanceLocked = true
            currentKelvin = 5500
            currentTint = 0
            publishSoftwareWB(.inactive)
            pendingWBWorkItem = CameraService.shared.scheduleDeviceConfiguration { camera in
                guard camera.isWhiteBalanceModeSupported(.locked) else { return }
                do {
                    try camera.lockForConfiguration()
                    defer { camera.unlockForConfiguration() }
                    camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                } catch {
                    CameraLogger.error("ProPhoto: Lỗi khóa AWB trung tính", error: error, category: .capture)
                }
            }
            return
        }

        isAutoWB = false
        pendingWBWorkItem = CameraService.shared.scheduleDeviceConfiguration { [weak self] camera in
            guard Self.supportsSafeHardwareCustomWB(camera) else {
                if camera.isWhiteBalanceModeSupported(.locked) {
                    try? camera.lockForConfiguration()
                    camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                    camera.unlockForConfiguration()
                }
                DispatchQueue.main.async {
                    self?.isHardwareCustomWBSupported = false
                    self?.isWhiteBalanceLocked = true
                    self?.currentKelvin = 5500
                    self?.currentTint = 0
                    self?.publishSoftwareWB(.inactive)
                }
                return
            }

            let rawGray = camera.grayWorldDeviceWhiteBalanceGains
            let safeGains = Self.clampedWhiteBalanceGains(rawGray, maxGain: camera.maxWhiteBalanceGain)
            guard Self.areGainsStrictlyValid(safeGains, maxGain: camera.maxWhiteBalanceGain) else { return }
            let tt = camera.temperatureAndTintValues(for: safeGains)
            let resolvedK = Self.clamp(tt.temperature, lower: 2500, upper: 9500, fallback: 5500)
            let resolvedT = Self.clamp(tt.tint, lower: -50, upper: 50, fallback: 0)

            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setWhiteBalanceModeLocked(with: safeGains, completionHandler: nil)
                DispatchQueue.main.async {
                    self?.currentKelvin = resolvedK
                    self?.currentTint = resolvedT
                    self?.measuredLiveKelvin = resolvedK
                    self?.measuredLiveTint = resolvedT
                    self?.publishSoftwareWB(.inactive)
                }
            } catch {
                CameraLogger.error("ProPhoto: Lỗi Gray World WB", error: error, category: .capture)
            }
        }
    }

    private func applyWhiteBalance() {
        pendingWBWorkItem?.cancel()
        guard !isAutoWB else {
            publishSoftwareWB(.inactive)
            restoreContinuousAutoWhiteBalance()
            return
        }
        let kelvin = Self.clamp(currentKelvin, lower: minKelvin, upper: maxKelvin, fallback: 5500)
        let tint = Self.clamp(currentTint, lower: minTint, upper: maxTint, fallback: 0)

        // Đường an toàn cho Virtual Multi-Camera (builtInTripleCamera / DualWide):
        // Khóa AWB hiện tại bằng `currentWhiteBalanceGains` (Apple cho phép 100%) + chỉnh Kelvin/Tint theo thời gian thực trên GPU.
        if !isHardwareCustomWBSupported {
            publishSoftwareWB(ProPhotoSoftwareWBGrade(isActive: true, kelvin: kelvin, tint: tint))
            let shouldLockCurrentAWB = !isWhiteBalanceLocked && isWhiteBalanceLockSupported
            if shouldLockCurrentAWB {
                isWhiteBalanceLocked = true
                pendingWBWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.02) { camera in
                    guard camera.isWhiteBalanceModeSupported(.locked), camera.whiteBalanceMode != .locked else { return }
                    do {
                        try camera.lockForConfiguration()
                        defer { camera.unlockForConfiguration() }
                        camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                    } catch {
                        CameraLogger.error("ProPhoto: Lỗi khóa AWB nền cho GPU WB", error: error, category: .capture)
                    }
                }
            }
            return
        }

        // Đường phần cứng ISP (chỉ chạy trên ống kính vật lý đơn có `isLockingWhiteBalanceWithCustomDeviceGainsSupported == true`)
        publishSoftwareWB(.inactive)
        pendingWBWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.015) { [weak self] camera in
            guard Self.supportsSafeHardwareCustomWB(camera) else {
                // Tự động hạ cánh an toàn sang GPU WB nếu ống kính chuyển sang Virtual Multi-Camera
                if camera.isWhiteBalanceModeSupported(.locked), camera.whiteBalanceMode != .locked {
                    try? camera.lockForConfiguration()
                    camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
                    camera.unlockForConfiguration()
                }
                DispatchQueue.main.async {
                    self?.isHardwareCustomWBSupported = false
                    self?.isWhiteBalanceLocked = true
                    self?.publishSoftwareWB(ProPhotoSoftwareWBGrade(isActive: true, kelvin: kelvin, tint: tint))
                }
                return
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
            let rawGains = camera.deviceWhiteBalanceGains(for: values)
            let safeGains = Self.clampedWhiteBalanceGains(rawGains, maxGain: camera.maxWhiteBalanceGain)
            guard Self.areGainsStrictlyValid(safeGains, maxGain: camera.maxWhiteBalanceGain) else { return }

            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setWhiteBalanceModeLocked(with: safeGains, completionHandler: nil)
            } catch {
                CameraLogger.error("ProPhoto: Lỗi khóa cân bằng trắng", error: error, category: .capture)
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
                CameraLogger.error("ProPhoto: Lỗi khôi phục AWB", error: error, category: .capture)
            }
        }
    }

    // MARK: - Lấy nét (MF, AF-L & Vùng lấy nét AF)

    public func setAutoFocus(_ auto: Bool) {
        lastUserFocusWriteAt = Date().timeIntervalSince1970
        isAutoFocus = auto
        isFocusLocked = false
        pendingFocusWorkItem?.cancel()
        if auto {
            CameraService.shared.restoreContinuousAutoFocus()
        } else {
            setManualFocus(measuredLiveLensPosition)
        }
    }

    public func setManualFocus(_ lensPosition: Float) {
        guard isManualFocusSupported else { return }
        lastUserFocusWriteAt = Date().timeIntervalSince1970
        let clamped = Self.clamp(lensPosition, lower: 0.0, upper: 1.0, fallback: currentLensPosition)
        currentLensPosition = clamped
        isAutoFocus = false
        isFocusLocked = false
        pendingFocusWorkItem?.cancel()

        pendingFocusWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.012) { camera in
            guard camera.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
            } catch {
                CameraLogger.error("ProPhoto: Lỗi lấy nét tay MF", error: error, category: .capture)
            }
        }
    }

    public func toggleFocusLock() {
        guard isFocusLockSupported else { return }
        lastUserFocusWriteAt = Date().timeIntervalSince1970
        let nextLocked = !isFocusLocked
        isFocusLocked = nextLocked

        if !nextLocked {
            if !isAutoFocus {
                setManualFocus(currentLensPosition)
            } else {
                CameraService.shared.restoreContinuousAutoFocus()
            }
            return
        }

        CameraService.shared.scheduleDeviceConfiguration { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isFocusModeSupported(.locked) {
                    camera.focusMode = .locked
                }
            } catch {
                CameraLogger.error("ProPhoto: Lỗi khóa AF-L", error: error, category: .capture)
            }
        }
    }

    public func setAFRangeMode(_ mode: ProPhotoAFRangeMode) {
        guard isAFRangeSupported else { return }
        afRangeMode = mode
        if !isAutoFocus {
            setAutoFocus(true)
        }
        let targetRestriction = mode.avRestriction
        CameraService.shared.scheduleDeviceConfiguration { camera in
            guard camera.isAutoFocusRangeRestrictionSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.autoFocusRangeRestriction = targetRestriction
            } catch {
                CameraLogger.error("ProPhoto: Lỗi đặt vùng lấy nét AF", error: error, category: .capture)
            }
        }
    }

    // MARK: - Tùy chọn phần cứng Apple Pro (Low-Light Boost, Chống méo ống kính, Đèn trợ sáng)

    public func setLowLightBoostEnabled(_ enabled: Bool) {
        guard isLowLightBoostSupported else { return }
        isLowLightBoostPreferred = enabled
        CameraService.shared.scheduleDeviceConfiguration { camera in
            guard camera.isLowLightBoostSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.automaticallyEnablesLowLightBoostWhenAvailable = enabled
            } catch {
                CameraLogger.error("ProPhoto: Lỗi cấu hình Low-Light Boost", error: error, category: .capture)
            }
        }
    }

    public func setGeometricDistortionCorrectionEnabled(_ enabled: Bool) {
        guard isGeometricDistortionCorrectionSupported else { return }
        isGeometricDistortionCorrectionEnabled = enabled
        CameraService.shared.scheduleDeviceConfiguration { camera in
            guard camera.isGeometricDistortionCorrectionSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.isGeometricDistortionCorrectionEnabled = enabled
            } catch {
                CameraLogger.error("ProPhoto: Lỗi cấu hình chống méo quang học", error: error, category: .capture)
            }
        }
    }

    public func setTorchLevel(_ level: Float) {
        guard isTorchSupported else {
            torchLevel = 0.0
            return
        }
        let clamped = Self.clamp(level, lower: 0.0, upper: 1.0, fallback: 0.0)
        torchLevel = clamped < 0.05 ? 0.0 : clamped

        pendingHardwareWorkItem?.cancel()
        pendingHardwareWorkItem = CameraService.shared.scheduleDeviceConfiguration(after: 0.015) { camera in
            guard camera.hasTorch else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if clamped < 0.05 {
                    if camera.isTorchModeSupported(.off) {
                        camera.torchMode = .off
                    }
                } else if camera.isTorchAvailable && camera.isTorchModeSupported(.on) {
                    let safeLevel = Self.clamp(clamped, lower: 0.05, upper: 1.0, fallback: 0.25)
                    try camera.setTorchModeOn(level: safeLevel)
                }
            } catch {
                CameraLogger.error("ProPhoto: Lỗi điều chỉnh đèn trợ sáng", error: error, category: .capture)
            }
        }
    }

    public func cycleTorchPreset() {
        let levels: [Float] = [0.0, 0.25, 0.60, 1.0]
        if let idx = levels.firstIndex(where: { abs($0 - torchLevel) < 0.12 }) {
            setTorchLevel(levels[(idx + 1) % levels.count])
        } else {
            setTorchLevel(0.25)
        }
    }

    // MARK: - Khôi phục & Áp dụng lại khi đổi ống kính

    private func reapplyOverridesAfterLensChange() {
        if !isAutoISO || !isAutoShutter {
            applyCustomExposure()
        } else if abs(currentEVBias) >= 0.05 {
            setManualEVBias(currentEVBias)
        }
        if !isAutoWB && isManualWBSupported {
            applyWhiteBalance()
        }
        if !isAutoFocus && isManualFocusSupported {
            setManualFocus(currentLensPosition)
        }
    }

    public func resetToFullAuto() {
        pendingExposureWorkItem?.cancel()
        pendingEVWorkItem?.cancel()
        pendingWBWorkItem?.cancel()
        pendingFocusWorkItem?.cancel()
        pendingHardwareWorkItem?.cancel()

        let now = Date().timeIntervalSince1970
        lastUserExposureWriteAt = now
        lastUserFocusWriteAt = now
        lastUserWBWriteAt = now

        isAutoISO = true
        isAutoShutter = true
        currentEVBias = 0.0
        isExposureLocked = false
        isAutoWB = true
        isWhiteBalanceLocked = false
        currentKelvin = 5500
        currentTint = 0
        publishSoftwareWB(.inactive)
        isAutoFocus = true
        isFocusLocked = false
        afRangeMode = .full
        torchLevel = 0.0

        CameraService.shared.scheduleDeviceConfiguration { camera in
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }

                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.setExposureTargetBias(0.0, completionHandler: nil)

                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isAutoFocusRangeRestrictionSupported {
                    camera.autoFocusRangeRestriction = .none
                }
                if camera.hasTorch && camera.torchMode != .off && camera.isTorchModeSupported(.off) {
                    camera.torchMode = .off
                }
            } catch {
                CameraLogger.error("ProPhoto: Lỗi khôi phục toàn bộ về Auto", error: error, category: .capture)
            }
        }
    }

    // MARK: - Hàm phụ trợ an toàn số học & phần cứng

    private static func clampedExposureCMTime(seconds: Double, format: AVCaptureDevice.Format) -> CMTime {
        let safeSec = seconds.isFinite && seconds > 0 ? seconds : (1.0 / 125.0)
        let req = CMTime(seconds: safeSec, preferredTimescale: 1_000_000)
        let minD = format.minExposureDuration
        let maxD = min(format.maxExposureDuration, CMTime(seconds: 1.0, preferredTimescale: 1_000_000))
        if minD.isValid && maxD.isValid && maxD >= minD {
            return max(minD, min(req, maxD))
        }
        return req
    }

    private static func supportsSafeHardwareCustomWB(_ camera: AVCaptureDevice) -> Bool {
        !camera.isVirtualDevice
            && camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported
            && camera.isWhiteBalanceModeSupported(.locked)
            && camera.maxWhiteBalanceGain.isFinite
            && camera.maxWhiteBalanceGain >= 1.01
    }

    private static func areGainsStrictlyValid(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        maxGain: Float
    ) -> Bool {
        guard maxGain.isFinite, maxGain >= 1.0 else { return false }
        let values = [gains.redGain, gains.greenGain, gains.blueGain]
        return values.allSatisfy { $0.isFinite && $0 >= 1.0 && $0 <= maxGain }
    }

    private static func clampedWhiteBalanceGains(
        _ raw: AVCaptureDevice.WhiteBalanceGains,
        maxGain: Float
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let safeUpper = max(1.001, Self.finite(maxGain, fallback: 1.001) - 0.001)
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: Self.clamp(raw.redGain, lower: 1.001, upper: safeUpper, fallback: 1.001),
            greenGain: Self.clamp(raw.greenGain, lower: 1.001, upper: safeUpper, fallback: 1.001),
            blueGain: Self.clamp(raw.blueGain, lower: 1.001, upper: safeUpper, fallback: 1.001)
        )
    }

    private static func readSafeTemperatureAndTint(from camera: AVCaptureDevice) -> (kelvin: Float, tint: Float)? {
        guard supportsSafeHardwareCustomWB(camera) else { return nil }
        let gains = clampedWhiteBalanceGains(camera.deviceWhiteBalanceGains, maxGain: camera.maxWhiteBalanceGain)
        guard areGainsStrictlyValid(gains, maxGain: camera.maxWhiteBalanceGain) else { return nil }
        let tt = camera.temperatureAndTintValues(for: gains)
        guard tt.temperature.isFinite, tt.tint.isFinite else { return nil }
        return (
            kelvin: clamp(tt.temperature, lower: 2500, upper: 9500, fallback: 5500),
            tint: clamp(tt.tint, lower: -50, upper: 50, fallback: 0)
        )
    }

    private static func computeMaxMegapixels(for format: AVCaptureDevice.Format) -> Int {
        let dims = format.supportedMaxPhotoDimensions
        guard let maxDim = dims.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else {
            return 12
        }
        let mp = Int((Double(maxDim.width) * Double(maxDim.height) / 1_000_000.0).rounded())
        return max(1, mp)
    }

    private static func computeEquivalentFocalLengthMM(camera: AVCaptureDevice, displayZoom: CGFloat) -> Int {
        if camera.position == .front {
            return 23
        }
        let z = displayZoom.isFinite && displayZoom > 0 ? Double(displayZoom) : 1.0
        // Ống kính chính 1x trên iPhone hiện đại tương đương 24mm (Full-Frame 35mm equivalent)
        return max(12, min(240, Int((24.0 * z).rounded())))
    }

    private static func lensDisplayName(for camera: AVCaptureDevice, displayZoom: CGFloat) -> String {
        if camera.position == .front { return "Trước" }
        switch camera.deviceType {
        case .builtInUltraWideCamera: return "Siêu rộng"
        case .builtInTelephotoCamera: return "Tele"
        case .builtInWideAngleCamera: return "Chính"
        default:
            if displayZoom < 0.85 { return "Siêu rộng" }
            if displayZoom >= 2.6 { return "Tele" }
            return "Chính"
        }
    }

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
