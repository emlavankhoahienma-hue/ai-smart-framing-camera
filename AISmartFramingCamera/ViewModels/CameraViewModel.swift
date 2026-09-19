import Foundation
import SwiftUI
import AVFoundation
import CoreImage
import Photos
import QuartzCore
import CoreMotion
import ImageIO
import UniformTypeIdentifiers

private struct CameraFrameProcessingConfiguration: Sendable {
    var isSettingsVisible = false
    var isFocusPeakingEnabled = false
    var focusPeakingColor: FocusPeakingColor = .green
}

/// Owns frame-rate work on AVFoundation's serial sample-buffer queue. UI state is
/// published only after hopping to the main queue, while configuration snapshots
/// and the most recent pixel buffer are protected for cross-queue access.
private final class CameraFrameProcessor: @unchecked Sendable {
    private let stateLock = NSLock()
    private weak var owner: CameraViewModel?
    private var configuration = CameraFrameProcessingConfiguration()
    private var latestPixelBuffer: CVPixelBuffer?
    private var lastHistogramComputeTime: CFTimeInterval = 0
    private var lastFocusPeakingComputeTime: CFTimeInterval = 0

    @MainActor
    func attach(to owner: CameraViewModel) {
        self.owner = owner
    }

    func updateConfiguration(_ configuration: CameraFrameProcessingConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
    }

    func latestPixelBufferSnapshot() -> CVPixelBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestPixelBuffer
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        // CameraService invokes this method on its serial videoDataQueue. Processing
        // in place avoids an extra frame copy and never sends CMSampleBuffer across
        // another concurrency boundary.
        VisionFramingEngine.shared.processVideoSampleBuffer(sampleBuffer, orientation: .up)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        latestPixelBuffer = pixelBuffer
        let snapshot = configuration
        stateLock.unlock()

        guard !snapshot.isSettingsVisible else { return }

        let now = CACurrentMediaTime()
        if now - lastHistogramComputeTime >= 0.05 {
            lastHistogramComputeTime = now
            let bars = RealtimeHistogramEngine.shared.computeHistogram(from: pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.owner?.histogramBars = bars
            }
        }

        guard snapshot.isFocusPeakingEnabled,
              now - lastFocusPeakingComputeTime >= 0.04 else { return }

        lastFocusPeakingComputeTime = now
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        FocusPeakingEngine.shared.processFrame(ciImage: ciImage, color: snapshot.focusPeakingColor) { [weak self] cgImage in
            DispatchQueue.main.async {
                self?.owner?.focusPeakingCGImage = cgImage
            }
        }
    }
}

@MainActor
public final class CameraViewModel: ObservableObject {
    // MARK: - Services
    public let cameraService = CameraService.shared
    public let visionEngine = VisionFramingEngine.shared
    public let calculator = CompositionCalculator.shared
    public let filterEngine = FilmFilterEngine.shared
    public let haptics = HapticFeedbackService.shared
    public let geminiService = GeminiService.shared
    public let motionService = DeviceMotionService.shared
    private nonisolated let frameProcessor = CameraFrameProcessor()

    // MARK: - AI Session State Machine
    private var aiSessionGeneration: Int = 0
    @Published public var aiSessionState: AISessionState = .idle {
        didSet {
            switch aiSessionState {
            case .idle, .done:
                visionEngine.isIdlePreviewMode = true
            default:
                visionEngine.isIdlePreviewMode = false
            }
        }
    }

    // MARK: - Published UI States (Persisted)
    @Published public var isCameraReady: Bool = false
    @Published public var hasCameraPermission: Bool = false

    /// Composition remains an engine concern. The capture UI no longer exposes visual grids or rule pickers.
    @Published public var activeCompositionRule: CompositionRule = .dynamicAI
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H {
        didSet { UserDefaults.standard.set(selectedFilmPreset.rawValue, forKey: "selectedFilmPreset") }
    }
    @Published public var isAIFullColorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAIFullColorEnabled, forKey: "isAIFullColorEnabled") }
    }
    @Published public var aiRecommendedPreset: FilmPreset? = nil
    @Published public var aiPresetMatchReason: String? = nil
    @Published public var isAutoZoomEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoZoomEnabled, forKey: "isAutoZoomEnabled") }
    }

    // Camera Mode & Live Photo
    @Published public var captureMode: CameraCaptureMode = .photo {
        didSet {
            UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode")
            activeCameraPanel = .none
            cameraService.updateCaptureMode(captureMode)
            if oldValue == .proVideo && captureMode != .proVideo {
                proVideoService.resetToFullAuto()
            } else if captureMode == .proVideo {
                proVideoService.syncHardwareCapabilities()
            }
        }
    }
    @Published public var isLivePhotoEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isLivePhotoEnabled, forKey: "isLivePhotoEnabled")
            cameraService.setLivePhotoCaptureEnabled(isLivePhotoEnabled)
        }
    }
    @Published public var selectedPhotoFormat: PhotoSaveFormat = .jpeg {
        didSet { UserDefaults.standard.set(selectedPhotoFormat.rawValue, forKey: "selectedPhotoFormat") }
    }
    @Published public var isStreetTrackingModeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isStreetTrackingModeEnabled, forKey: "isStreetTrackingModeEnabled") }
    }
    @Published public var liveISO: String = "ISO 32"
    @Published public var liveShutterSpeed: String = "1/400 s"
    @Published public var histogramBars: [HistogramBarData] = (0..<32).map {
        let t = Double($0) / 31.0
        let col = t < 0.28 ? Color(red: 0.15, green: 0.45, blue: 0.95) : (t < 0.72 ? Color(red: 0.40, green: 0.90, blue: 0.60) : Color(red: 0.95, green: 0.45, blue: 0.20))
        return HistogramBarData(id: $0, height: 0.10, color: col)
    }
    @Published public var isRecordingVideo: Bool = false
    @Published public var recordedVideoURL: URL? = nil
    @Published public var isShowingVideoPreview: Bool = false

    // Video Duration & Resolution Stats (Mặc định 00:00:00, Đọc từ cài đặt hệ thống Camera iOS)
    @Published public var videoRecordingTimeString: String = "00:00:00"
    @Published public var videoRecordedDurationSeconds: TimeInterval = 0
    @Published public var activeVideoResolutionString: String = "1080P 30FPS"
    @Published public var selectedVideoCodec: VideoCodec = .hevc {
        didSet {
            UserDefaults.standard.set(selectedVideoCodec.rawValue, forKey: "selectedVideoCodec")
            cameraService.selectedVideoCodec = selectedVideoCodec
        }
    }
    @Published public var selectedVideoFormatOption: VideoFormatOption = .hd60 {
        didSet {
            UserDefaults.standard.set(selectedVideoFormatOption.rawValue, forKey: "selectedVideoFormatOption")
            cameraService.setVideoFormatOption(selectedVideoFormatOption)
        }
    }

    private var videoRecordingTimer: Timer? = nil
    private var videoRecordingStartTime: Date? = nil

    // Pro Video Manual Controls Service & State
    public let proVideoService = ProVideoManualControlsService.shared
    @Published public var selectedProTab: ProVideoParameterTab = .iso
    @Published public var activeCameraPanel: CameraOverlayPanel = .none

    // Camera Parameters
    @Published public var currentZoom: CGFloat = 1.0
    @Published public var displayZoom: CGFloat = 1.0
    @Published public var isRevealingZoomTarget: Bool = false
    @Published public var lockOnProgress: CGFloat = 0
    @Published public var liveZoomFactorForReveal: CGFloat = 1.0
    private var pendingTargetZoomForReveal: CGFloat = 1.0
    private var isZoomRampPhase: Bool = false

    // MARK: - Sun Exposure Slider & Horizon Leveler
    @Published public var isShowingSunSlider: Bool = false
    @Published public var activeSunExposureBias: Float = 0.0

    // MARK: - Thước Đo Cân Bằng Chân Trời (Horizon Leveler)
    @Published public var isHorizonLevelerEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isHorizonLevelerEnabled, forKey: "isHorizonLevelerEnabled") }
    }
    @Published public var currentRollDegrees: Double = 0.0
    @Published public var isDeviceLevel: Bool = false
    private let horizonMotionManager = CMMotionManager()
    private var hasTriggeredLevelHaptic: Bool = false

    // MARK: - Focus Peaking (Viền Báo Nét Điện Ảnh)
    @Published public var isFocusPeakingEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isFocusPeakingEnabled, forKey: "isFocusPeakingEnabled")
            if !isFocusPeakingEnabled { focusPeakingCGImage = nil }
            updateFrameProcessingConfiguration()
        }
    }
    @Published public var focusPeakingColor: FocusPeakingColor = .green {
        didSet {
            UserDefaults.standard.set(focusPeakingColor.rawValue, forKey: "focusPeakingColor")
            updateFrameProcessingConfiguration()
        }
    }
    @Published public var focusPeakingCGImage: CGImage? = nil

    public var zoomRevealRect: CGRect {
        guard isRevealingZoomTarget, pendingTargetZoomForReveal > 1.05 else {
            return CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
        }
        let targetSize = 1.0 / pendingTargetZoomForReveal

        // Tiêu điểm của chủ thể / target (thay vì cố định 0.5, 0.5)
        let focalPoint = currentTargetPoint ?? initialTargetPoint ?? CGPoint(x: 0.5, y: 0.5)

        if !isZoomRampPhase {
            // Giai đoạn 1: khung lướt nhẹ từ toàn cảnh (1.0) về vùng crop dự kiến bao quanh chủ thể
            let p = max(0.0, min(1.0, lockOnProgress))
            let size = 1.0 - (1.0 - targetSize) * p
            let minX = max(0.0, min(1.0 - size, focalPoint.x - size / 2.0))
            let minY = max(0.0, min(1.0 - size, focalPoint.y - size / 2.0))
            return CGRect(x: minX, y: minY, width: size, height: size)
        } else {
            // Giai đoạn 2: khi camera phần cứng đang ramp zoom, khung đồng bộ mở rộng ra mép màn hình
            let ratio = min(1.0, liveZoomFactorForReveal / pendingTargetZoomForReveal)
            let minX = max(0.0, min(1.0 - ratio, focalPoint.x - ratio / 2.0))
            let minY = max(0.0, min(1.0 - ratio, focalPoint.y - ratio / 2.0))
            return CGRect(x: minX, y: minY, width: ratio, height: ratio)
        }
    }

    @Published public var exposureBias: Float = 0.0
    @Published public var activeFlashMode: AVCaptureDevice.FlashMode = .auto {
        didSet { UserDefaults.standard.set(activeFlashMode.rawValue, forKey: "activeFlashMode") }
    }
    @Published public var isPinchingZoom: Bool = false

    private var pendingSuggestedZoom: CGFloat = 1.0
    private var hasExecutedAutoZoomForSession: Bool = false

    public func triggerZoomRevealAnimation(targetZoom: CGFloat) {
        guard targetZoom.isFinite, currentZoom.isFinite else { return }
        guard targetZoom > 1.05, abs(targetZoom - currentZoom) > 0.05 else { return }
        pendingTargetZoomForReveal = targetZoom
        liveZoomFactorForReveal = currentZoom
        isZoomRampPhase = false
        lockOnProgress = 0
        isRevealingZoomTarget = true

        withAnimation(.easeOut(duration: 0.35)) {
            lockOnProgress = 1.0
        }

        // Bắt đầu zoom quang/kỹ thuật số mượt mà sau 0.22s với tốc độ điện ảnh 0.85
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self = self else { return }
            self.isZoomRampPhase = true
            // Rate 0.85: Tốc độ zoom điện ảnh tự nhiên, lướt êm ái, không giật cục
            self.cameraService.smoothZoomFactor(to: targetZoom, rate: 0.85)

            let estimatedRampDuration = Double(abs(targetZoom - self.liveZoomFactorForReveal)) / 0.85 + 0.40
            DispatchQueue.main.asyncAfter(deadline: .now() + estimatedRampDuration) { [weak self] in
                guard let self = self else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    self.isRevealingZoomTarget = false
                }
                self.isZoomRampPhase = false
                self.haptics.triggerLight()
            }
        }
    }

    // AI Framing & Composition
    @Published public var framingResult: FramingTargetResult?
    @Published public var alignmentState: FramingAlignmentState = .analyzing
    @Published public var detectedScene: DetectedSceneType = .general
    @Published public var detectedSubjectRects: [CGRect] = []
    @Published public var detectedFaceRects: [CGRect] = []
    @Published public var currentTrackedTargetRect: CGRect? = nil
    private var latestSubjectDetectionResult: SubjectDetectionResult? = nil
    private var faceRectStabilizer = DetectionRectStabilizer(maximumMissedFrames: 5)
    private var subjectRectStabilizer = DetectionRectStabilizer(maximumMissedFrames: 8)
    private var trackedTargetSize = CGSize(width: 0.14, height: 0.14)

    // MARK: - DOKA-STYLE TARGET TRACKING
    /// Initial target position determined ONCE by AI (normalized 0..1)
    @Published public var initialTargetPoint: CGPoint? = nil

    /// Real-time target position on screen (moves with phone gyroscope towards center (0.5, 0.5))
    @Published public var currentTargetPoint: CGPoint? = nil

    /// Distance from current target point to center (0.5, 0.5)
    @Published public var alignmentDistance: CGFloat = 1.0
    @Published public var isPerfectAlignment: Bool = false

    // Gemini State
    @Published public var isGeminiAnalyzing: Bool = false
    @Published public var geminiError: String? = nil
    @Published public var geminiExplanation: String = ""
    @Published public var geminiColorRecipe: GeminiColorRecipe? = nil
    @Published public var useGeminiForAnalysis: Bool = true {
        didSet { UserDefaults.standard.set(useGeminiForAnalysis, forKey: "useGeminiForAnalysis") }
    }
    @Published public var activeModelUsedName: String = ""
    @Published public var geminiLatencyMs: Int = 0
    @Published public var aiSuggestedZoom: CGFloat? = nil

    // MARK: - AI Video Cinematography Director State (Cloud OpenRouter)
    @Published public var isAIVideoDirectorActive: Bool = false
    @Published public var isAIVideoDirectorAnalyzing: Bool = false
    @Published public var activeVideoGuidance: AIVideoDirectorGuidance? = nil
    @Published public var currentActiveWaypointIndex: Int = 0
    @Published public var videoDirectorError: String? = nil
    @Published public var hasCompletedAllWaypoints: Bool = false
    @Published public var waypointElapsedSeconds: Double = 0.0

    // MARK: - Chỉ Báo Nháy Màu AI (Local: Đỏ, Cloud: Vàng)
    public var activeAIIndicatorType: ActiveAIIndicatorType {
        if isAIVideoDirectorActive {
            return .cloud
        }
        guard aiSessionState != .idle else { return .none }
        if let source = activeEngineSource {
            return source.isCloud ? .cloud : .local
        }
        if aiSessionState == .analyzing {
            return (useGeminiForAnalysis && geminiService.hasAPIKey) ? .cloud : .local
        }
        return .none
    }

    // Capture & Review
    @Published public var latestCapturedPhoto: CapturedPhotoItem?
    @Published public var isShowingPhotoDetail: Bool = false
    @Published public var isShowingSettings: Bool = false {
        didSet {
            if isShowingSettings { focusPeakingCGImage = nil }
            updateFrameProcessingConfiguration()
        }
    }
    @Published public var showAlignmentSuccessFlash: Bool = false
    @Published public var isShutterPressing: Bool = false
    @Published public var activeFlashMode2: Bool = false
    @Published public var autoCaptureCountdown: Int = 0
    @Published public var currentAIColorParams: AIColorParameters? = nil

    // MARK: - Quiet Pro Camera User Settings
    @Published public var isAutoCaptureOnAlignEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoCaptureOnAlignEnabled, forKey: "isAutoCaptureOnAlignEnabled") }
    }
    @Published public var showDetectionBoxes: Bool = false {
        didSet { UserDefaults.standard.set(showDetectionBoxes, forKey: "showDetectionBoxes") }
    }
    @Published public var isSaveOriginalPhotoEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isSaveOriginalPhotoEnabled, forKey: "isSaveOriginalPhotoEnabled") }
    }
    @Published public var isKeepScreenAwakeEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isKeepScreenAwakeEnabled, forKey: "isKeepScreenAwakeEnabled")
            UIApplication.shared.isIdleTimerDisabled = isKeepScreenAwakeEnabled
        }
    }
    @Published public var isProximityHapticsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isProximityHapticsEnabled, forKey: "isProximityHapticsEnabled") }
    }
    @Published public var isGuidanceRayEnabled: Bool = UserDefaults.standard.object(forKey: "isGuidanceRayEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isGuidanceRayEnabled, forKey: "isGuidanceRayEnabled") }
    }

    // Engine Source Indicator
    @Published public var activeEngineSource: AIEngineSource? = nil
    @Published public var arTrackingWarning: String? = nil
    @Published public var activeFocusSquarePoint: CGPoint? = nil
    @Published public var isAEAFLocked: Bool = false
    @Published public var aeafLockPoint: CGPoint? = nil
    @Published public var saveErrorMessage: String? = nil

    // MARK: - Advanced Predictive Tracking State Machine
    @Published public var trackingQuality: TrackingQuality = .locked
    @Published public var trackingSensitivity: TrackingSensitivityPreset = .medium {
        didSet {
            UserDefaults.standard.set(trackingSensitivity.rawValue, forKey: "trackingSensitivity")
            applyTrackingSensitivityToEngines()
        }
    }

    public var confidenceAcceptThreshold: Double {
        switch trackingSensitivity {
        case .low: return 0.20
        case .medium: return 0.30
        case .high: return 0.40
        }
    }

    public var trackingEMAAlpha: CGFloat {
        switch trackingSensitivity {
        case .low: return 0.45
        case .medium: return 0.60
        case .high: return 0.75
        }
    }

    public var maxJumpPerFrame: CGFloat {
        switch trackingSensitivity {
        case .low: return 0.18
        case .medium: return 0.15 // Giới hạn bước nhảy tối ưu thực tế, chống giật nảy
        case .high: return 0.12
        }
    }

    private var lastProximityHapticTime: TimeInterval = 0

    // Internal State
    private var autoCaptureTask: Task<Void, Never>? = nil
    private var analysisFrames: [SubjectDetectionResult] = []
    private let analysisFramesNeeded = 5 // Collect 5 quick frames (~0.25s) for rock-solid stabilization
    private var isOneShotCaptured = false
    private var lastFocusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var lastHardwareAFUpdateTime: CFTimeInterval = 0
    private var lastForcedResetTime: TimeInterval = 0
    private var lastSmartFocusExposureTime: TimeInterval = 0
    private var pendingSmartFocusPoint: CGPoint?
    private var pendingSmartFocusStableCount: Int = 0
    private var focusSquareHideTask: Task<Void, Never>? = nil
    private var manualFocusLockUntil: CFTimeInterval = 0
    private let manualFocusCooldown: CFTimeInterval = 4.0

    public init() {
        // Load saved settings
        let defaults = UserDefaults.standard
        if let presetRaw = defaults.string(forKey: "selectedFilmPreset"), let preset = FilmPreset(rawValue: presetRaw) {
            self.selectedFilmPreset = preset
        }
        if let modeRaw = defaults.string(forKey: "captureMode"), let mode = CameraCaptureMode(rawValue: modeRaw) {
            self.captureMode = mode
        }
        if let photoFormatRaw = defaults.string(forKey: "selectedPhotoFormat"), let photoFormat = PhotoSaveFormat(rawValue: photoFormatRaw) {
            self.selectedPhotoFormat = photoFormat
        }
        if defaults.object(forKey: "isGuidanceRayEnabled") != nil {
            self.isGuidanceRayEnabled = defaults.bool(forKey: "isGuidanceRayEnabled")
        }
        if defaults.object(forKey: "isAIFullColorEnabled") != nil {
            self.isAIFullColorEnabled = defaults.bool(forKey: "isAIFullColorEnabled")
        }
        if defaults.object(forKey: "isAutoZoomEnabled") != nil {
            self.isAutoZoomEnabled = defaults.bool(forKey: "isAutoZoomEnabled")
        }
        if defaults.object(forKey: "isLivePhotoEnabled") != nil {
            self.isLivePhotoEnabled = defaults.bool(forKey: "isLivePhotoEnabled")
        }
        if defaults.object(forKey: "useGeminiForAnalysis") != nil {
            self.useGeminiForAnalysis = defaults.bool(forKey: "useGeminiForAnalysis")
        }
        if defaults.object(forKey: "isStreetTrackingModeEnabled") != nil {
            self.isStreetTrackingModeEnabled = defaults.bool(forKey: "isStreetTrackingModeEnabled")
        }
        if defaults.object(forKey: "isHorizonLevelerEnabled") != nil {
            self.isHorizonLevelerEnabled = defaults.bool(forKey: "isHorizonLevelerEnabled")
        }
        if defaults.object(forKey: "isFocusPeakingEnabled") != nil {
            self.isFocusPeakingEnabled = defaults.bool(forKey: "isFocusPeakingEnabled")
        }
        if let colorRaw = defaults.string(forKey: "focusPeakingColor"), let color = FocusPeakingColor(rawValue: colorRaw) {
            self.focusPeakingColor = color
        }
        if let sensitivityRaw = defaults.string(forKey: "trackingSensitivity"), let sensitivity = TrackingSensitivityPreset(rawValue: sensitivityRaw) {
            self.trackingSensitivity = sensitivity
        }
        if let flashRaw = defaults.object(forKey: "activeFlashMode") as? Int,
           let flash = AVCaptureDevice.FlashMode(rawValue: flashRaw) {
            self.activeFlashMode = flash
        }
        if let codecRaw = defaults.string(forKey: "selectedVideoCodec"), let codec = VideoCodec(rawValue: codecRaw) {
            self.selectedVideoCodec = codec
        }
        if let formatRaw = defaults.string(forKey: "selectedVideoFormatOption"), let format = VideoFormatOption(rawValue: formatRaw) {
            self.selectedVideoFormatOption = format
        }
        if defaults.object(forKey: "isAutoCaptureOnAlignEnabled") != nil {
            self.isAutoCaptureOnAlignEnabled = defaults.bool(forKey: "isAutoCaptureOnAlignEnabled")
        }
        if defaults.object(forKey: "showDetectionBoxes") != nil {
            self.showDetectionBoxes = defaults.bool(forKey: "showDetectionBoxes")
        }
        if defaults.object(forKey: "isSaveOriginalPhotoEnabled") != nil {
            self.isSaveOriginalPhotoEnabled = defaults.bool(forKey: "isSaveOriginalPhotoEnabled")
        }
        if defaults.object(forKey: "isKeepScreenAwakeEnabled") != nil {
            self.isKeepScreenAwakeEnabled = defaults.bool(forKey: "isKeepScreenAwakeEnabled")
        }
        if defaults.object(forKey: "isProximityHapticsEnabled") != nil {
            self.isProximityHapticsEnabled = defaults.bool(forKey: "isProximityHapticsEnabled")
        }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = self.isKeepScreenAwakeEnabled
        }
        self.cameraService.selectedVideoCodec = self.selectedVideoCodec
        self.cameraService.selectedVideoFormatOption = self.selectedVideoFormatOption

        // didSet không fire khi gán trong init -> gọi trực tiếp để engine nhận đúng ngưỡng
        applyTrackingSensitivityToEngines()
        frameProcessor.attach(to: self)
        updateFrameProcessingConfiguration()

        setupCallbacks()
        setupMotionCallbacks()
        startHorizonLeveler()
    }

    private func updateFrameProcessingConfiguration() {
        frameProcessor.updateConfiguration(
            CameraFrameProcessingConfiguration(
                isSettingsVisible: isShowingSettings,
                isFocusPeakingEnabled: isFocusPeakingEnabled,
                focusPeakingColor: focusPeakingColor
            )
        )
    }

    // MARK: - Initialization & Permissions
    public func requestPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.hasCameraPermission = true
            self.startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.hasCameraPermission = granted
                    if granted { self?.startCamera() }
                }
            }
        default:
            self.hasCameraPermission = false
        }
    }

    private func startCamera() {
        cameraService.delegate = self
        cameraService.setupSession { [weak self] success in
            guard let self = self, success else { return }
            self.cameraService.updateCaptureMode(self.captureMode)
            self.cameraService.setLivePhotoCaptureEnabled(self.isLivePhotoEnabled)
            self.activeVideoResolutionString = self.cameraService.getActiveVideoResolutionAndFPS()
            self.displayZoom = self.cameraService.defaultDisplayZoom
            self.currentZoom = self.cameraService.currentZoom
            SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
            StreetSpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
            self.cameraService.start()
            self.isCameraReady = true
        }
    }

    private func setupCallbacks() {
        cameraService.onActiveVideoFormatChanged = { [weak self] format in
            DispatchQueue.main.async {
                self?.activeVideoResolutionString = format
            }
        }

        visionEngine.onDetectionCompleted = { [weak self] detection in
            guard let self = self, !self.isShowingSettings else { return }
            self.handleVisionDetection(detection)
        }

        visionEngine.onTargetTracked = { [weak self] point, confidence, pixelBuffer in
            guard let self = self, !self.isShowingSettings else { return }
            self.handleVisualTargetTracked(point: point, confidence: confidence, pixelBuffer: pixelBuffer)
        }

        // Smart Autofocus (Face Priority > Saliency > Center)
        visionEngine.onSmartFocusPointCalculated = { [weak self] point, focusType in
            guard let self = self, !self.isShowingSettings else { return }
            self.handleSmartFocusCalculated(point: point, type: focusType)
        }

        // Subject Area Did Change Observer (Apple Camera App style)
        cameraService.onSubjectAreaDidChange = { [weak self] in
            guard let self = self else { return }
            self.handleSubjectAreaChanged()
        }

        cameraService.onLiveZoomFactorChanged = { [weak self] zoom in
            guard let self = self else { return }
            self.liveZoomFactorForReveal = zoom
            self.currentZoom = zoom
            self.displayZoom = self.cameraService.convertDeviceZoomToDisplayZoom(zoom)
            SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
            StreetSpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
        }

        // Realtime Exposure Stats Listener (ISO & Shutter Speed)
        // Khi đang mở Cài đặt: bỏ qua cập nhật để không ép SwiftUI re-render toàn bộ
        // Form cài đặt mỗi frame (gây lag khi lướt). Đóng cài đặt là tự cập nhật lại.
        cameraService.onLiveCameraStatsUpdated = { [weak self] stats in
            guard let self = self, !self.isShowingSettings else { return }
            let isoInt = Int(round(stats.iso))
            self.liveISO = "ISO \(isoInt)"
            self.liveShutterSpeed = stats.shutterSpeedString
            self.proVideoService.updateLiveMeasurements(
                iso: stats.iso,
                shutterDuration: stats.exposureDurationSeconds,
                lensPosition: stats.lensPosition
            )
        }
    }

    public func togglePhotoFormat() {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut(duration: 0.2)) {
            switch selectedPhotoFormat {
            case .jpeg: selectedPhotoFormat = .heic
            case .heic: selectedPhotoFormat = .dng
            case .dng: selectedPhotoFormat = .jpeg
            case .heif: selectedPhotoFormat = .heic
            }
        }
    }

    public func toggleVideoCodec() {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedVideoCodec = (selectedVideoCodec == .hevc) ? .h264 : .hevc
        }
    }

    public func toggleVideoFormat() {
        guard !isRecordingVideo else { return }
        haptics.triggerSelectionChange()
        let allCases = VideoFormatOption.allCases
        if let idx = allCases.firstIndex(of: selectedVideoFormatOption) {
            let nextIdx = (idx + 1) % allCases.count
            selectedVideoFormatOption = allCases[nextIdx]
        } else {
            selectedVideoFormatOption = .hd60
        }
    }


    private func setupMotionCallbacks() {
        SpatialTrackingEngine.shared.onSpatialTargetUpdated = { [weak self] point, confidence, quality in
            guard let self = self, !self.isStreetTrackingModeEnabled, !self.isShowingSettings else { return }
            self.lastVisualConfidence = confidence
            // Vòng vàng luôn bám vật thể (kể cả trong lúc zoom reveal) để không nhảy sau khi zoom
            self.currentTargetPoint = point
            self.trackingQuality = quality
            self.currentTrackedTargetRect = self.normalizedRect(centeredAt: point, size: self.trackedTargetSize)
            // Chỉ đánh giá alignment & countdown khi đang ở phase targetPlaced
            if case .targetPlaced = self.aiSessionState {
                self.evaluateAlignment(at: point)
            }
        }

        StreetSpatialTrackingEngine.shared.onSpatialTargetUpdated = { [weak self] point, confidence, quality in
            guard let self = self, self.isStreetTrackingModeEnabled, !self.isShowingSettings else { return }
            self.lastVisualConfidence = confidence
            self.currentTargetPoint = point
            self.trackingQuality = quality
            self.currentTrackedTargetRect = self.normalizedRect(centeredAt: point, size: self.trackedTargetSize)
            if case .targetPlaced = self.aiSessionState {
                self.evaluateAlignment(at: point)
            }
        }
    }

    // Nạp thông số chống nhảy đột biến & ngưỡng nhận confidence của ViewModel (theo trackingSensitivity)
    // xuống engine spatial
    private func applyTrackingSensitivityToEngines() {
        SpatialTrackingEngine.shared.maxObservationJump = maxJumpPerFrame
        SpatialTrackingEngine.shared.opticalAcceptThreshold = confidenceAcceptThreshold
        StreetSpatialTrackingEngine.shared.maxObservationJump = maxJumpPerFrame
        StreetSpatialTrackingEngine.shared.opticalAcceptThreshold = confidenceAcceptThreshold
    }

    // MARK: - AI Session Control (One-Shot Trigger)

    /// Bắt đầu phiên AI khi người dùng bấm nút AI — chỉ phân tích ĐÚNG 1 LẦN duy nhất
    public func startAISession() {
        guard aiSessionState == .idle || aiSessionState == .done else { return }
        haptics.triggerSelectionChange()
        self.aiSessionGeneration += 1
        let requestGeneration = self.aiSessionGeneration

        // Reset state
        SpatialTrackingEngine.shared.stopTracking()
        StreetSpatialTrackingEngine.shared.stopTracking()
        visionEngine.stopTrackingObject()
        analysisFrames = []
        faceRectStabilizer.reset()
        subjectRectStabilizer.reset()
        initialTargetPoint = nil
        currentTargetPoint = nil
        currentTrackedTargetRect = nil
        lastVisualConfidence = 0
        trackingQuality = .locked
        isOneShotCaptured = false
        isPerfectAlignment = false
        alignmentDistance = 1.0
        geminiError = nil
        geminiExplanation = ""
        activeModelUsedName = ""
        activeEngineSource = nil
        arTrackingWarning = nil

        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            aiSessionState = .analyzing
        }

        // Yêu cầu Vision Engine chụp 1 frame chất lượng cao gửi cho Gemini
        visionEngine.captureNextFrameForGemini = true

        if useGeminiForAnalysis && geminiService.hasAPIKey {
            // Lắng nghe trực tiếp khi VisionEngine kết xuất xong frame CGImage chất lượng cao
            visionEngine.onFrameCapturedForAI = { [weak self] frame in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.aiSessionGeneration == requestGeneration && self.aiSessionState == .analyzing && !self.isOneShotCaptured {
                        self.isOneShotCaptured = true
                        self.callGeminiAnalysis(frame: frame)
                    }
                }
            }

            // An toàn dự phòng: Nếu sau 3.5s cloud không phản hồi hoặc frame chụp bị nghẽn, tự động chuyển về Local
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self = self else { return }
                if self.aiSessionGeneration == requestGeneration && self.aiSessionState == .analyzing && !self.isOneShotCaptured {
                    self.isOneShotCaptured = true
                    self.consolidateLocalAnalysisAndLockTarget()
                }
            }
        }
    }

    public func cancelAISession() {
        self.aiSessionGeneration += 1
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        visionEngine.stopTrackingObject()
        SpatialTrackingEngine.shared.stopTracking()
        StreetSpatialTrackingEngine.shared.stopTracking()
        haptics.triggerSelectionChange()
        visionEngine.captureNextFrameForGemini = false
        visionEngine.onFrameCapturedForAI = nil
        trackingQuality = .locked

        withAnimation(.easeInOut(duration: 0.3)) {
            aiSessionState = .idle
            initialTargetPoint = nil
            currentTargetPoint = nil
            currentTrackedTargetRect = nil
            lastVisualConfidence = 0
            isOneShotCaptured = false
            isPerfectAlignment = false
            alignmentDistance = 1.0
            detectedSubjectRects = []
            detectedFaceRects = []
            activeEngineSource = nil
            arTrackingWarning = nil
        }
    }

    // MARK: - Vision & Gemini One-Shot Handling

    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        self.latestSubjectDetectionResult = detection
        switch aiSessionState {
        case .idle, .done:
            // Khi ở chế độ idle: chỉ hiển thị face preview nhẹ nhàng, không tính toán target
            self.detectedScene = detection.detectedScene
            self.detectedFaceRects = faceRectStabilizer.update(with: detection.faceRectangles)
            self.detectedSubjectRects = subjectRectStabilizer.update(
                with: detection.dominantSubjectRect.map { [$0] } ?? []
            )
            return

        case .capturing:
            return

        case .targetPlaced, .alignmentPerfect:
            // ĐÃ KHÓA TARGET: Dừng toàn bộ phân tích Vision để không bị nhảy lung tung!
            // Chuyển động target lúc này hoàn toàn do con quay hồi chuyển Gyroscope điều khiển
            return

        case .analyzing:
            // Giai đoạn phân tích 1 lần (One-shot)
            handleAnalyzingPhase(detection)
        }
    }

    private func handleAnalyzingPhase(_ detection: SubjectDetectionResult) {
        guard !isOneShotCaptured else { return }

        self.detectedScene = detection.detectedScene
        self.detectedFaceRects = faceRectStabilizer.update(with: detection.faceRectangles)
        self.detectedSubjectRects = subjectRectStabilizer.update(
            with: detection.dominantSubjectRect.map { [$0] } ?? []
        )

        // 1. Nếu đang bật phân tích Cloud (OpenRouter) và có API Key:
        if useGeminiForAnalysis && geminiService.hasAPIKey {
            // Kiểm tra xem đã có frame chụp cho Gemini chưa
            if let frame = visionEngine.capturedGeminiFrame {
                visionEngine.capturedGeminiFrame = nil
                isOneShotCaptured = true
                callGeminiAnalysis(frame: frame)
            }
            // ƯU TIÊN TUYỆT ĐỐI CHO CLOUD: Không kích hoạt consolidateLocalAnalysisAndLockTarget ở đây!
            return
        }

        // 2. Chế độ cục bộ (On-device Vision / CoreML): Thu thập đủ 5 frames để lọc nhiễu và khóa mục tiêu
        analysisFrames.append(detection)
        if analysisFrames.count >= analysisFramesNeeded {
            isOneShotCaptured = true
            consolidateLocalAnalysisAndLockTarget()
        }
    }

    // MARK: - Gemini Analysis (One-shot)

    private func callGeminiAnalysis(frame: CGImage) {
        guard !isGeminiAnalyzing else { return }
        isGeminiAnalyzing = true
        let requestGeneration = self.aiSessionGeneration

        let subjectRect = detectedSubjectRects.first ?? detectedFaceRects.first
        let faceRects = detectedFaceRects

        geminiService.analyzeForComposition(
            image: frame,
            sceneContext: self.detectedScene,
            subjectRect: subjectRect,
            faceRects: faceRects
        ) { [weak self] result in
            guard let self = self else { return }
            self.isGeminiAnalyzing = false
            guard self.aiSessionGeneration == requestGeneration, self.aiSessionState == .analyzing else {
                CameraLogger.info("Bỏ qua phản hồi Gemini trễ (phiên đã đổi/kết thúc)", category: .ai)
                return
            }
            switch result {
            case .success(let response):
                self.handleGeminiResponse(response)
            case .failure(let error):
                self.geminiError = error.localizedDescription
                // Lỗi API -> Tự động Fallback qua Neural Engine cục bộ (CoreML / Vision) để vẫn dùng được app
                self.consolidateLocalAnalysisAndLockTarget()
            }
        }
    }

    private func handleGeminiResponse(_ response: GeminiFramingResponse) {
        self.geminiColorRecipe = response.colorRecipe
        self.geminiExplanation = response.explanation
        self.detectedScene = response.sceneType
        self.activeCompositionRule = response.compositionRule
        self.activeModelUsedName = response.modelUsed
        self.activeEngineSource = .geminiCloud(model: response.modelUsed)
        self.geminiLatencyMs = response.latencyMs
        self.aiSuggestedZoom = response.suggestedZoom
        self.pendingSuggestedZoom = response.suggestedZoom
        self.hasExecutedAutoZoomForSession = false

        self.aiRecommendedPreset = response.recommendedPreset
        self.aiPresetMatchReason = response.presetExplanation

        if isAIFullColorEnabled {
            currentAIColorParams = response.colorRecipe.asAIColorParameters
        }

        if selectedFilmPreset.isAIFullAuto {
            selectedFilmPreset = response.recommendedPreset
        }

        var targetPoint = CGPoint(x: response.targetX, y: response.targetY)
        let subjectRect = detectedSubjectRects.first ?? detectedFaceRects.first

        // Nếu Gemini trả về tọa độ trung tâm (0.5, 0.5) nhưng ta có chủ thể thực tế rõ ràng phát hiện lệch tâm,
        // ưu tiên gắn target vào chủ thể để người dùng căn trúng chủ thể & zoom đẹp mắt!
        if let sRect = subjectRect, abs(targetPoint.x - 0.5) < 0.05 && abs(targetPoint.y - 0.5) < 0.05 {
            let sCenter = CGPoint(x: sRect.midX, y: sRect.midY)
            if abs(sCenter.x - 0.5) > 0.08 || abs(sCenter.y - 0.5) > 0.08 {
                targetPoint = sCenter
            }
        }

        // Tự động điều chỉnh zoom nếu Gemini trả về 1.0x nhưng chủ thể ở xa/nhỏ
        if let sRect = subjectRect, self.pendingSuggestedZoom <= 1.05 {
            let area = sRect.width * sRect.height
            if area < 0.035 {
                self.pendingSuggestedZoom = 2.5
                self.aiSuggestedZoom = 2.5
            } else if area < 0.09 {
                self.pendingSuggestedZoom = 2.0
                self.aiSuggestedZoom = 2.0
            } else if area < 0.18 {
                self.pendingSuggestedZoom = 1.6
                self.aiSuggestedZoom = 1.6
            }
        }

        pinTargetAndStartMotion(at: targetPoint, subjectRect: subjectRect)
    }

    // MARK: - Local Neural Engine Analysis (One-shot)

    private func consolidateLocalAnalysisAndLockTarget() {
        var dominantScene: DetectedSceneType = .general
        var avgDetection = SubjectDetectionResult()

        if !analysisFrames.isEmpty {
            var sceneCounts: [DetectedSceneType: Int] = [:]
            for f in analysisFrames { sceneCounts[f.detectedScene, default: 0] += 1 }
            dominantScene = sceneCounts.max(by: { $0.value < $1.value })?.key ?? .general

            let validFrames = analysisFrames.filter { $0.dominantSubjectRect != nil }
            if !validFrames.isEmpty {
                let avgX = validFrames.compactMap { $0.dominantSubjectRect?.midX }.reduce(0, +) / CGFloat(validFrames.count)
                let avgY = validFrames.compactMap { $0.dominantSubjectRect?.midY }.reduce(0, +) / CGFloat(validFrames.count)
                let avgW = validFrames.compactMap { $0.dominantSubjectRect?.width }.reduce(0, +) / CGFloat(validFrames.count)
                let avgH = validFrames.compactMap { $0.dominantSubjectRect?.height }.reduce(0, +) / CGFloat(validFrames.count)
                avgDetection.dominantSubjectRect = CGRect(x: avgX - avgW/2, y: avgY - avgH/2, width: avgW, height: avgH)
                avgDetection.detectedScene = dominantScene
                avgDetection.averageLuminance = analysisFrames.map { $0.averageLuminance }.reduce(0, +) / Float(analysisFrames.count)
                avgDetection.estimatedColorTemp = analysisFrames.map { $0.estimatedColorTemp }.reduce(0, +) / Float(analysisFrames.count)
            }
            if let faceFrame = analysisFrames.first(where: { !$0.faceRectangles.isEmpty }) {
                avgDetection.faceRectangles = faceFrame.faceRectangles
            }
            if let eyeFrame = analysisFrames.first(where: { $0.primaryEyePosition != nil }) {
                avgDetection.primaryEyePosition = eyeFrame.primaryEyePosition
            }
            if let gazeFrame = analysisFrames.first(where: { abs($0.lookingDirection.dx) > 0.05 }) {
                avgDetection.lookingDirection = gazeFrame.lookingDirection
            }
        }

        let result = calculator.calculateTarget(from: avgDetection, rule: activeCompositionRule, currentZoom: currentZoom)
        self.framingResult = result
        self.aiSuggestedZoom = result.recommendedZoomFactor
        self.pendingSuggestedZoom = result.recommendedZoomFactor
        self.hasExecutedAutoZoomForSession = false

        // Xác định chính xác nguồn Engine AI đang hoạt động để hiển thị rõ ràng trên HUD
        if NeuralTargetTracker.shared.hasActiveTrainedModel {
            self.activeEngineSource = .localTrained114MB(category: dominantScene.localizedName)
        } else if YOLODetectionEngine.shared.hasYOLOModel {
            self.activeEngineSource = .yoloNeural(label: dominantScene.localizedName)
        } else {
            self.activeEngineSource = .appleNeuralEngine(scene: dominantScene.localizedName)
        }

        let localPreset = dominantScene.recommendedFilter
        self.aiRecommendedPreset = localPreset
        self.aiPresetMatchReason = "\(localPreset.displayName) — Tối ưu cho bối cảnh \(dominantScene.localizedName)"
        if selectedFilmPreset.isAIFullAuto {
            selectedFilmPreset = localPreset
        }

        if isAIFullColorEnabled {
            currentAIColorParams = dominantScene.aiFullColorParameters
            let lumaError: Float = 0.50 - avgDetection.averageLuminance
            setExposure(max(-1.0, min(1.0, lumaError * 1.2)))
        }

        pinTargetAndStartMotion(at: result.targetPoint, subjectRect: avgDetection.dominantSubjectRect)
    }

    // MARK: - State for Hybrid Optical + Spatial Tracking
    @Published public var lastVisualConfidence: Double = 0
    private var initialPhysicalSubjectCenter: CGPoint? = nil
    private var shouldCheckTextureOnNextFrame: Bool = false

    // MARK: - Low Texture Analysis (Bầu trời, Tường phẳng)
    private var isCurrentlyLowTexture: Bool = false

    private func applyTextureVarianceHysteresis(variance: Double) {
        // Hysteresis 2 ngưỡng: Bật Low-Texture khi < 20.0, Tắt khi > 30.0
        if variance < 20.0 {
            isCurrentlyLowTexture = true
        } else if variance > 30.0 {
            isCurrentlyLowTexture = false
        }
        // Nếu nằm giữa 20.0 và 30.0: giữ nguyên trạng thái trước đó
        SpatialTrackingEngine.shared.setLowTextureFlag(isCurrentlyLowTexture)
        StreetSpatialTrackingEngine.shared.setLowTextureFlag(isCurrentlyLowTexture)
        CameraLogger.info("Texture Variance: \(String(format: "%.2f", variance)) -> LowTexture (Ưu tiên Gyro): \(isCurrentlyLowTexture ? "BẬT" : "TẮT")", category: .tracking)
    }

    private func computeTextureVariance(pixelBuffer: CVPixelBuffer, normalizedRect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 1000 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let regionX = max(0, Int(normalizedRect.origin.x * CGFloat(width)))
        let regionY = max(0, Int(normalizedRect.origin.y * CGFloat(height)))
        let regionW = max(20, Int(normalizedRect.width * CGFloat(width)))
        let regionH = max(20, Int(normalizedRect.height * CGFloat(height)))

        var values: [Double] = []
        var y = regionY
        while y < min(regionY + regionH, height) {
            var x = regionX
            while x < min(regionX + regionW, width) {
                let offset = y * bytesPerRow + x * 4
                if offset + 2 < bytesPerRow * height {
                    let b = Double(buffer[offset])
                    let g = Double(buffer[offset + 1])
                    let r = Double(buffer[offset + 2])
                    values.append(0.299 * r + 0.587 * g + 0.114 * b)
                }
                x += 4
            }
            y += 4
        }

        guard values.count > 8 else { return 1000 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    }

    // MARK: - Pin Target & Start Tracking (Hybrid Optical Flow + 60Hz Gyroscope Spatial Fusion)

    public func pinTargetAndStartMotion(at target: CGPoint, subjectRect: CGRect? = nil) {
        // KHÔNG dùng tâm chủ thể để đè lên tọa độ AI nữa.
        // Ảnh gửi cho AI (cloud & local) là FULL ẢNH nên AI trả về tọa độ CHUẨN THEO ẢNH.
        // Target giờ PIN ĐÚNG TẠI TỌA ĐỘ AI TRẢ VỀ (target). subjectRect chỉ được dùng để
        // lấy KÍCH THƯỚC khung bám & điểm lấy nét phần cứng, KHÔNG thay thế tọa độ target.
        guard let pinPoint = CameraPreviewGeometry.sanitizedNormalizedPoint(target) else { return }

        initialTargetPoint = pinPoint
        currentTargetPoint = pinPoint
        lastVisualConfidence = 1.0
        trackingQuality = .locked
        hasExecutedAutoZoomForSession = false

        alignmentDistance = TargetReticleGeometry.alignmentDistance(to: pinPoint)

        // Đồng bộ phân loại cảnh quan cho Dynamic EKF & Deformable Nature Tracking
        visionEngine.currentSceneType = self.detectedScene
        // Thông báo cho Vision engine: anchor low-texture (vật trắng/đơn sắc) -> siết ngưỡng re-ID
        visionEngine.isLowTextureAnchor = isCurrentlyLowTexture
        if isStreetTrackingModeEnabled {
            SpatialTrackingEngine.shared.stopTracking()
            StreetSpatialTrackingEngine.shared.lockAnchor(at: pinPoint, zoom: currentZoom)
        } else {
            StreetSpatialTrackingEngine.shared.stopTracking()
            SpatialTrackingEngine.shared.lockAnchor(at: pinPoint, zoom: currentZoom)
        }

        // 1. Đánh giá độ phẳng Texture & Đăng ký Vân tay Nơ-ron AI trước để xác định kích thước khung bám tối ưu
        let anchorTarget = pinPoint
        if let buffer = frameProcessor.latestPixelBufferSnapshot() {
            let region = CGRect(x: max(0, anchorTarget.x - 0.08), y: max(0, anchorTarget.y - 0.08), width: 0.16, height: 0.16)
            let variance = computeTextureVariance(pixelBuffer: buffer, normalizedRect: region)
            applyTextureVarianceHysteresis(variance: variance)
            NeuralTargetTracker.shared.setAnchorTemplate(from: buffer, at: anchorTarget)
        } else {
            shouldCheckTextureOnNextFrame = true
        }

        // 2. Khởi động Optical Tracking bám CHÍNH XÁC VÀO VẬT THỂ THẬT (Apple Vision VNTrackObjectRequest)
        // Khi vật thể là màu trắng/đơn sắc (isCurrentlyLowTexture): Mở rộng khung bám để bao quát đường viền cạnh tương phản với nền
        let isLow = isCurrentlyLowTexture
        self.initialPhysicalSubjectCenter = pinPoint
        let initialSize: CGSize
        if let sRect = subjectRect.flatMap({ CameraPreviewGeometry.sanitizedNormalizedRect($0) }) {
            // Dùng TỌA ĐỘ AI (target) làm TÂM khung bám; chỉ lấy KÍCH THƯỚC từ subjectRect
            // để box đủ lớn bao trọn chủ thể mà không làm lệch tâm target khỏi tọa độ AI.
            let expandRatio: CGFloat = isLow ? 1.35 : 1.10
            let minBox: CGFloat = isLow ? 0.20 : 0.08
            let clampedW = min(0.60, max(minBox, sRect.width * expandRatio))
            let clampedH = min(0.60, max(minBox, sRect.height * expandRatio))
            initialSize = CGSize(width: clampedW, height: clampedH)
        } else {
            let targetSize: CGFloat = isLow ? 0.22 : 0.14
            initialSize = CGSize(width: targetSize, height: targetSize)
        }
        trackedTargetSize = initialSize
        currentTrackedTargetRect = normalizedRect(centeredAt: pinPoint, size: initialSize)

        visionEngine.startTrackingObject(at: pinPoint, size: initialSize)

        // 3. Tự động đồng bộ đo sáng & lấy nét phần cứng (Hardware ISP AE/AF) vào đúng tâm mục tiêu
        if !isAEAFLocked && (captureMode != .proVideo || proVideoService.isAutoFocus) {
            let focusTarget = subjectRect
                .flatMap { CameraPreviewGeometry.sanitizedNormalizedRect($0) }
                .map { CGPoint(x: $0.midX, y: $0.midY) } ?? pinPoint
            let devPoint = CameraService.convertUIPointToDevicePoint(focusTarget)
            cameraService.setSmartFocusAndExposure(at: devPoint)
        }

        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.haptics.triggerSuccess()
        }
    }

    // MARK: - 1. Optical Visual Object Tracking Handler (Bám chặt 100% vào vật thể/chữ thực tế trên màn hình)

    private func handleVisualTargetTracked(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer) {
        // Tiếp nhận cập nhật cả trong alignmentPerfect (zoom reveal) để vòng vàng bám vật thể
        // xuyên suốt quá trình zoom — tránh nhảy vị trí khi zoom hoàn tất
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect:
            break
        default:
            return
        }
        lastVisualConfidence = confidence
        if shouldCheckTextureOnNextFrame, let target = currentTargetPoint ?? initialTargetPoint {
            shouldCheckTextureOnNextFrame = false
            let region = CGRect(x: max(0, target.x - 0.08), y: max(0, target.y - 0.08), width: 0.16, height: 0.16)
            let variance = computeTextureVariance(pixelBuffer: pixelBuffer, normalizedRect: region)
            applyTextureVarianceHysteresis(variance: variance)
        }

        if isStreetTrackingModeEnabled {
            StreetSpatialTrackingEngine.shared.updateWithOpticalDetection(
                point: point,
                confidence: confidence,
                pixelBuffer: pixelBuffer
            )
        } else {
            SpatialTrackingEngine.shared.updateWithOpticalDetection(
                point: point,
                confidence: confidence,
                pixelBuffer: pixelBuffer
            )
        }
    }

    public func toggleCameraPanel(_ panel: CameraOverlayPanel) {
        activeCameraPanel = activeCameraPanel == panel ? .none : panel
    }

    public func dismissCameraPanels() {
        activeCameraPanel = .none
    }

    private func normalizedRect(centeredAt center: CGPoint, size: CGSize) -> CGRect? {
        CameraPreviewGeometry.sanitizedNormalizedRect(
            CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        )
    }

    private func evaluateAlignment(at point: CGPoint) {
        let dx = point.x - TargetReticleGeometry.opticalCenter.x
        let dy = point.y - TargetReticleGeometry.opticalCenter.y
        let dist = TargetReticleGeometry.alignmentDistance(to: point)
        self.alignmentDistance = dist

        // Haptic rung khi tiến gần tâm — nếu người dùng bật
        if isProximityHapticsEnabled && dist < 0.15 && dist > calculator.alignmentTolerance {
            let now = CACurrentMediaTime()
            if now - lastProximityHapticTime >= 0.1 {
                lastProximityHapticTime = now
                let intensity = 1.0 - (dist / 0.15)
                haptics.triggerProximityPulse(intensity: intensity)
            }
        }

        let isPerfect = dist <= calculator.alignmentTolerance

        // Kích hoạt khi tâm trắng đè khớp lên vùng target vàng!
        if isPerfect && !isPerfectAlignment && (trackingQuality == .locked || trackingQuality == .predicting) {
            isPerfectAlignment = true
            haptics.triggerMagneticSnap()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                aiSessionState = .alignmentPerfect
                showAlignmentSuccessFlash = true
            }

            // KÍCH HOẠT ZOOM REVEAL ĐÚNG KHI TÂM TRẮNG KHỚP VÀO TÂM VÀNG!
            let willZoom = isAutoZoomEnabled && pendingSuggestedZoom > 1.05 && !hasExecutedAutoZoomForSession
            if willZoom {
                hasExecutedAutoZoomForSession = true
                triggerZoomRevealAnimation(targetZoom: pendingSuggestedZoom)
            }

            if isAutoCaptureOnAlignEnabled {
                startAutoCaptureCountdown(isZooming: willZoom)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showAlignmentSuccessFlash = false
            }
        } else if !isPerfect && isPerfectAlignment {
            isPerfectAlignment = false
            autoCaptureTask?.cancel()
            autoCaptureTask = nil
            autoCaptureCountdown = 0
            withAnimation {
                aiSessionState = .targetPlaced(locked: true)
            }
        }

        if !isPerfect {
            let angle = atan2(dy, dx) * 180 / .pi
            let normalizedAngle = angle < 0 ? angle + 360 : angle
            alignmentState = .guiding(distance: dist, angle: normalizedAngle)
        } else {
            alignmentState = .aligned(score: 1.0)
        }
    }

    private func startAutoCaptureCountdown(isZooming: Bool = false) {
        autoCaptureTask?.cancel()

        let initialWait: UInt64 = isZooming ? 1_400_000_000 : 800_000_000

        autoCaptureCountdown = 1 // 1 giây phản hồi nhanh chụp ngay

        autoCaptureTask = Task {
            try? await Task.sleep(nanoseconds: initialWait)
            await MainActor.run { self.autoCaptureCountdown = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                if self.isPerfectAlignment {
                    self.executeCapture()
                } else {
                    self.aiSessionState = .targetPlaced(locked: true)
                    self.autoCaptureCountdown = 0
                }
            }
        }
    }

    private func executeCapture() {
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        // Dừng hẳn engine spatial — trước đây 60Hz gyro vẫn chạy nền sau khi chụp
        SpatialTrackingEngine.shared.stopTracking()
        StreetSpatialTrackingEngine.shared.stopTracking()
        haptics.triggerShutterClick()

        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        cameraService.capturePhoto(isDNG: selectedPhotoFormat == .dng)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
    }

    // MARK: - Actions
    private var lastContinuousZoomTime: CFTimeInterval = 0
    private var lastContinuousAppliedZoom: CGFloat = 1.0

    public func setZoom(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        displayZoom = displayZoomVal
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        currentZoom = deviceZoom
        cameraService.setZoomFactor(deviceZoom)
        SpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
        StreetSpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
    }

    /// Zoom liên tục mượt mà khi người dùng vuốt/pinch bằng hai ngón tay
    /// Tự động throttle AVFoundation calls (25ms) để chống nghẽn hàng đợi camera phần cứng
    public func setZoomContinuous(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        displayZoom = displayZoomVal
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        currentZoom = deviceZoom
        let now = CACurrentMediaTime()
        if now - lastContinuousZoomTime >= 0.025 || abs(deviceZoom - lastContinuousAppliedZoom) > 0.08 {
            lastContinuousZoomTime = now
            lastContinuousAppliedZoom = deviceZoom
            cameraService.setZoomFactor(deviceZoom)
            SpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
            StreetSpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
        }
    }

    /// Chốt zoom cuối cùng khi người dùng nhấc ngón tay kết thúc pinch
    public func finishZoomGesture(_ finalDisplayZoom: CGFloat) {
        guard finalDisplayZoom.isFinite else { return }
        displayZoom = finalDisplayZoom
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(finalDisplayZoom)
        currentZoom = deviceZoom
        lastContinuousAppliedZoom = deviceZoom
        cameraService.setZoomFactor(deviceZoom)
        SpatialTrackingEngine.shared.updateZoomFactor(finalDisplayZoom)
        StreetSpatialTrackingEngine.shared.updateZoomFactor(finalDisplayZoom)
        haptics.triggerSelectionChange()
    }

    public func setZoomFromButton(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        haptics.triggerSelectionChange()
        displayZoom = displayZoomVal
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        currentZoom = deviceZoom
        cameraService.smoothZoomFactor(to: deviceZoom, rate: 1.8)
        SpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
        StreetSpatialTrackingEngine.shared.updateZoomFactor(displayZoomVal)
    }

    public func setExposure(_ bias: Float) {
        guard bias.isFinite else { return }
        let clamped = max(-2, min(2, bias))
        exposureBias = clamped
        cameraService.setExposureBias(clamped)
    }

    public func lockAEAF(at normalizedPoint: CGPoint, devicePoint: CGPoint) {
        haptics.triggerSuccess()
        aeafLockPoint = normalizedPoint
        activeFocusSquarePoint = normalizedPoint
        isAEAFLocked = true
        isShowingSunSlider = true
        cameraService.lockFocusAndExposure(at: devicePoint)
        CameraLogger.info("🔒 ĐÃ KHÓA AE/AF tại (\(String(format: "%.2f", normalizedPoint.x)), \(String(format: "%.2f", normalizedPoint.y)))", category: .capture)
    }

    public func unlockAEAF() {
        guard isAEAFLocked else { return }
        haptics.triggerSelectionChange()
        isAEAFLocked = false
        manualFocusLockUntil = 0
        aeafLockPoint = nil
        isShowingSunSlider = false
        activeSunExposureBias = 0.0
        cameraService.unlockFocusAndExposure()
        withAnimation(.easeOut(duration: 0.25)) {
            self.activeFocusSquarePoint = nil
        }
        CameraLogger.info("🔓 ĐÃ MỞ KHÓA AE/AF", category: .capture)
    }

    public func toggleFlash() {
        haptics.triggerSelectionChange()
        switch activeFlashMode {
        case .auto: activeFlashMode = .on
        case .on: activeFlashMode = .off
        case .off: activeFlashMode = .auto
        @unknown default: activeFlashMode = .auto
        }
        cameraService.flashMode = activeFlashMode
    }

    public func selectPreset(_ preset: FilmPreset) {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut) {
            selectedFilmPreset = preset
            if preset.isAIFullAuto {
                isAIFullColorEnabled = true
            } else {
                isAIFullColorEnabled = false
                currentAIColorParams = nil
                geminiColorRecipe = nil
            }
        }
    }

    public func toggleAIFullColor() {
        haptics.triggerSelectionChange()
        withAnimation(.spring()) {
            isAIFullColorEnabled.toggle()
            if isAIFullColorEnabled {
                selectedFilmPreset = .aiFullAuto
                currentAIColorParams = geminiColorRecipe?.asAIColorParameters ?? detectedScene.aiFullColorParameters
            } else {
                selectedFilmPreset = .fujiPro400H
                currentAIColorParams = nil
            }
        }
    }

    public func toggleLivePhoto() {
        haptics.triggerSelectionChange()
        isLivePhotoEnabled.toggle()
        cameraService.setLivePhotoCaptureEnabled(isLivePhotoEnabled)
        CameraLogger.info("Người dùng chuyển chế độ Live Photo: \(isLivePhotoEnabled ? "BẬT" : "TẮT")", category: .capture)
    }

    public func toggleVideoRecording() {
        if isRecordingVideo {
            haptics.triggerShutterClick()
            cameraService.stopRecordingVideo()
            isRecordingVideo = false
            videoRecordingTimer?.invalidate()
            videoRecordingTimer = nil
            videoRecordingStartTime = nil
            videoRecordedDurationSeconds = 0
            videoRecordingTimeString = "00:00:00"
        } else {
            haptics.triggerShutterClick()
            videoRecordingStartTime = Date()
            videoRecordedDurationSeconds = 0
            videoRecordingTimeString = "00:00:00"
            videoRecordingTimer?.invalidate()
            videoRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVideoRecordingClock()
                }
            }
            cameraService.startRecordingVideo(codec: self.selectedVideoCodec)
            isRecordingVideo = true
        }
    }

    private func updateVideoRecordingClock() {
        guard let start = videoRecordingStartTime, isRecordingVideo else { return }
        let elapsed = Date().timeIntervalSince(start)
        videoRecordedDurationSeconds = elapsed
        let totalSec = Int(elapsed)
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60
        videoRecordingTimeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

        // Khi AI Video Director đang hoạt động và đang quay, tự động đếm nhịp và chuyển tâm mượt mà
        if isAIVideoDirectorActive, let guidance = activeVideoGuidance, !hasCompletedAllWaypoints {
            waypointElapsedSeconds += 0.25
            if currentActiveWaypointIndex < guidance.waypoints.count {
                let activeWaypoint = guidance.waypoints[currentActiveWaypointIndex]
                if waypointElapsedSeconds >= activeWaypoint.recommendedDuration {
                    advanceWaypoint()
                }
            }
        }
    }

    // MARK: - AI Video Cinematography Director Actions

    public func requestAIVideoCinematographyGuidance() {
        haptics.triggerSelectionChange()
        isAIVideoDirectorActive = true
        isAIVideoDirectorAnalyzing = true
        activeVideoGuidance = nil
        currentActiveWaypointIndex = 0
        videoDirectorError = nil
        hasCompletedAllWaypoints = false
        waypointElapsedSeconds = 0.0

        let subjectRect = detectedSubjectRects.first ?? detectedFaceRects.first
        let faceRects = detectedFaceRects
        let lookDir = latestSubjectDetectionResult?.lookingDirection ?? .zero

        visionEngine.captureImmediateFrame { [weak self] cgImg in
            guard let self = self else { return }
            guard let image = cgImg else {
                let fallback = GeminiService.generateLocalVideoGuidance(
                    sceneContext: self.detectedScene,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookDir
                )
                DispatchQueue.main.async {
                    self.applyVideoGuidance(fallback)
                }
                return
            }

            self.geminiService.analyzeVideoCinematography(
                image: image,
                sceneContext: self.detectedScene,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookDir
            ) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let guidance):
                        self.applyVideoGuidance(guidance)
                    case .failure(let err):
                        self.videoDirectorError = err.localizedDescription
                        let fallback = GeminiService.generateLocalVideoGuidance(
                            sceneContext: self.detectedScene,
                            subjectRect: subjectRect,
                            faceRects: faceRects,
                            lookingDirection: lookDir
                        )
                        self.applyVideoGuidance(fallback)
                    }
                }
            }
        }
    }

    private func applyVideoGuidance(_ guidance: AIVideoDirectorGuidance) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            self.activeVideoGuidance = guidance
            self.isAIVideoDirectorAnalyzing = false
            self.currentActiveWaypointIndex = 0
            self.hasCompletedAllWaypoints = false
            self.waypointElapsedSeconds = 0.0
        }
        self.haptics.triggerMagneticSnap()

        if self.isAutoZoomEnabled && guidance.suggestedZoom > 1.05 && abs(guidance.suggestedZoom - self.currentZoom) > 0.1 {
            self.cameraService.smoothZoomFactor(to: guidance.suggestedZoom, rate: 1.5)
        }
    }

    public func selectWaypoint(index: Int) {
        guard let guidance = activeVideoGuidance, index >= 0, index < guidance.waypoints.count else { return }
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut(duration: 0.25)) {
            currentActiveWaypointIndex = index
            waypointElapsedSeconds = 0.0
        }
    }

    public func advanceWaypoint() {
        guard let guidance = activeVideoGuidance else { return }
        let nextIndex = currentActiveWaypointIndex + 1
        if nextIndex < guidance.waypoints.count {
            haptics.triggerMagneticSnap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                currentActiveWaypointIndex = nextIndex
                waypointElapsedSeconds = 0.0
            }
        } else {
            haptics.triggerShutterClick()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                hasCompletedAllWaypoints = true
            }
        }
    }

    public func dismissAIVideoDirector() {
        haptics.triggerLight()
        withAnimation(.easeInOut(duration: 0.25)) {
            isAIVideoDirectorActive = false
            isAIVideoDirectorAnalyzing = false
            activeVideoGuidance = nil
            currentActiveWaypointIndex = 0
            hasCompletedAllWaypoints = false
            videoDirectorError = nil
            waypointElapsedSeconds = 0.0
        }
    }


    // MARK: - Smart Autofocus & Exposure Control (Apple Camera App Style)

    private func handleSubjectAreaChanged() {
        let now = CACurrentMediaTime()
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard now >= manualFocusLockUntil, !isAEAFLocked else { return }
        guard now - lastForcedResetTime >= 1.5 else {
            CameraLogger.info("Bỏ qua subject area change - vừa reset gần đây, tránh vòng lặp phơi sáng", category: .general)
            return
        }
        lastForcedResetTime = now

        // Cảnh vật hoặc chủ thể di chuyển -> Kích hoạt lấy nét lại ngay lập tức
        if showTargetCircle, let target = currentTargetPoint {
            applyFocusAndExposure(to: target, source: .aiTarget, force: true)
        } else {
            applyFocusAndExposure(to: lastFocusPoint, source: .center, force: true)
        }
    }

    private func handleSmartFocusCalculated(point: CGPoint, type: SmartFocusType) {
        let now = CACurrentMediaTime()
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard now >= manualFocusLockUntil, !isAEAFLocked else { return }

        // 1. Ưu tiên số 1: Nếu AI đã khóa mục tiêu target (vòng tròn vàng), luôn lấy nét vào target
        if showTargetCircle, let target = currentTargetPoint {
            applyFocusAndExposure(to: target, source: .aiTarget)
            return
        }

        // 2. Chế độ rảnh (chưa khóa target, kể cả chưa bấm AI lần nào): lọc
        // nhiễu — chỉ đổi điểm đo sáng khi vật được phát hiện ổn định qua
        // nhiều lần liên tiếp, tránh nhảy loạn ISO do thuật toán saliency
        // chọn nhầm qua lại giữa 2 vật có điểm số gần bằng nhau.
        if let pending = pendingSmartFocusPoint {
            let dist = hypot(point.x - pending.x, point.y - pending.y)
            if dist < 0.06 {
                pendingSmartFocusStableCount += 1
            } else {
                pendingSmartFocusPoint = point
                pendingSmartFocusStableCount = 0
                return
            }
        } else {
            pendingSmartFocusPoint = point
            pendingSmartFocusStableCount = 0
            return
        }

        guard pendingSmartFocusStableCount >= 2, now - lastSmartFocusExposureTime >= 1.0 else { return }

        lastSmartFocusExposureTime = now
        applyFocusAndExposure(to: point, source: type)
    }

    public func triggerFocusSquareAnimation(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) {
            self.activeFocusSquarePoint = point
        }
        focusSquareHideTask?.cancel()
        focusSquareHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            await MainActor.run {
                if !self.isAEAFLocked && self.activeFocusSquarePoint == point {
                    withAnimation(.easeIn(duration: 0.3)) {
                        self.activeFocusSquarePoint = nil
                        self.isShowingSunSlider = false
                    }
                }
            }
        }
    }

    // MARK: - Chạm Lấy Nét & Khóa AE/AF (iPhone Camera Standard)
    public func handleViewfinderTap(at normalizedPoint: CGPoint, devicePoint: CGPoint) {
        guard normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite,
              devicePoint.x.isFinite,
              devicePoint.y.isFinite else { return }

        if isAEAFLocked {
            unlockAEAF()
        } else if case .targetPlaced = aiSessionState {
            pinTargetAndStartMotion(at: normalizedPoint)
        } else {
            userDidTapToFocus(at: normalizedPoint, devicePoint: devicePoint)
        }
    }

    public func userDidTapToFocus(at normalizedPoint: CGPoint, devicePoint: CGPoint? = nil) {
        if isAEAFLocked {
            unlockAEAF()
            return
        }

        haptics.triggerSelectionChange()
        if captureMode == .proVideo && !proVideoService.isAutoFocus {
            proVideoService.setAutoFocus(true)
        }
        manualFocusLockUntil = CACurrentMediaTime() + manualFocusCooldown
        lastFocusPoint = normalizedPoint
        activeFocusSquarePoint = normalizedPoint
        isShowingSunSlider = true

        let devPoint = devicePoint ?? CameraService.convertUIPointToDevicePoint(normalizedPoint)
        cameraService.focusAndExpose(at: devPoint)
        triggerFocusSquareAnimation(at: normalizedPoint)
    }

    public func userDidLongPressToLockAEAF(at normalizedPoint: CGPoint) {
        let devPoint = CameraService.convertUIPointToDevicePoint(normalizedPoint)
        lockAEAF(at: normalizedPoint, devicePoint: devPoint)
    }

    public func adjustSunExposureBias(delta: Float) {
        let newBias = max(-2.0, min(2.0, activeSunExposureBias + delta))
        activeSunExposureBias = newBias
        setExposure(newBias)
    }

    // MARK: - Thước Cân Bằng Chân Trời (Virtual Horizon Leveler)
    private func startHorizonLeveler() {
        guard horizonMotionManager.isDeviceMotionAvailable else { return }
        horizonMotionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        horizonMotionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] (motion: CMDeviceMotion?, error: Error?) in
            guard let self = self, let motion = motion, self.isHorizonLevelerEnabled, !self.isShowingSettings else { return }
            let gx = Double(motion.gravity.x)
            let gy = Double(motion.gravity.y)
            let roll = atan2(gx, -gy) * 180.0 / .pi
            self.currentRollDegrees = roll
            let level = abs(roll) <= 0.8
            if level && !self.isDeviceLevel && !self.hasTriggeredLevelHaptic {
                self.haptics.triggerSelectionChange()
                self.hasTriggeredLevelHaptic = true
            } else if !level {
                self.hasTriggeredLevelHaptic = false
            }
            self.isDeviceLevel = level
        }
    }

    public func applyFocusAndExposure(to point: CGPoint, source _: SmartFocusType, force: Bool = false) {
        let now = CACurrentMediaTime()
        let isManualFocus = now < manualFocusLockUntil || (captureMode == .proVideo && !proVideoService.isAutoFocus)
        guard AutofocusUpdatePolicy.shouldIssueUpdate(
            point: point,
            previousPoint: lastFocusPoint,
            now: now,
            previousUpdateTime: lastHardwareAFUpdateTime,
            isAEAFLocked: isAEAFLocked,
            isManualFocus: isManualFocus,
            force: force
        ) else { return }
        let safePoint = CGPoint(x: min(max(point.x, 0.01), 0.99), y: min(max(point.y, 0.01), 0.99))
        lastHardwareAFUpdateTime = now
        lastFocusPoint = safePoint
        let devicePoint = CameraService.convertUIPointToDevicePoint(safePoint)
        cameraService.setSmartFocusAndExposure(at: devicePoint)
        triggerFocusSquareAnimation(at: safePoint)
    }


    // MARK: - Manual Shutter Click (Nút chụp màu trắng)
    public func takePhotoManual() {
        if captureMode.isVideo {
            toggleVideoRecording()
            return
        }
        guard !isShutterPressing else { return }

        // Cho phép chụp thủ công bất kỳ lúc nào (ngay cả khi chưa bật AI hoặc AI đã hoàn tất)
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        cameraService.capturePhoto(isDNG: selectedPhotoFormat == .dng)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
    }

    // MARK: - Live Photo Metadata Injection (Preserves Film Filter & Apple Content Identifier)
    private nonisolated static func makeLivePhotoColorGradedData(
        from processedCGImage: CGImage,
        rawData: Data?,
        format: PhotoSaveFormat
    ) -> Data? {
        guard let rawData = rawData,
              let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            CameraLogger.warning("Không thể đọc metadata từ rawPhotoData để trích xuất Content Identifier", category: .photoKit)
            return nil
        }

        let makerAppleKey = kCGImagePropertyMakerAppleDictionary as String
        guard let makerDict = metadata[makerAppleKey] as? [String: Any],
              let contentIdentifier = makerDict["17"] as? String else {
            CameraLogger.warning("Không tìm thấy Apple Maker Note Content Identifier (tag 17) trong raw metadata", category: .photoKit)
            return nil
        }

        CameraLogger.info("Đã trích xuất Live Photo Content Identifier: \(contentIdentifier)", category: .photoKit)

        var updatedMetadata = metadata
        var updatedMakerDict = makerDict
        updatedMakerDict["17"] = contentIdentifier
        updatedMetadata[makerAppleKey] = updatedMakerDict

        // QUAN TRỌNG: SỬA LỖI XOAY NGANG LIVE PHOTO KHI XEM ẢNH TĨNH TRONG PHOTOS
        // processedCGImage đã được xoay vật lý thành ảnh đứng (portrait) tại CameraService.
        // Cần ghi đè EXIF Orientation về 1 (.up / Top, left) và cập nhật kích thước ảnh,
        // nếu không Apple Photos sẽ xoay thêm 90 độ khiến ảnh tĩnh bị nằm ngang!
        updatedMetadata[kCGImagePropertyOrientation as String] = 1
        if var tiffDict = updatedMetadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiffDict[kCGImagePropertyTIFFOrientation as String] = 1
            updatedMetadata[kCGImagePropertyTIFFDictionary as String] = tiffDict
        }
        if var iptcDict = updatedMetadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            iptcDict["Orientation"] = 1
            updatedMetadata[kCGImagePropertyIPTCDictionary as String] = iptcDict
        }
        updatedMetadata[kCGImagePropertyPixelWidth as String] = processedCGImage.width
        updatedMetadata[kCGImagePropertyPixelHeight as String] = processedCGImage.height
        if var exifDict = updatedMetadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exifDict[kCGImagePropertyExifPixelXDimension as String] = processedCGImage.width
            exifDict[kCGImagePropertyExifPixelYDimension as String] = processedCGImage.height
            updatedMetadata[kCGImagePropertyExifDictionary as String] = exifDict
        }

        let outputData = NSMutableData()
        let uti: CFString = (format == .heic) ? (UTType.heic.identifier as CFString) : (UTType.jpeg.identifier as CFString)
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, uti, 1, nil) else {
            CameraLogger.error("Không thể tạo CGImageDestination cho Live Photo", category: .photoKit)
            return nil
        }

        CGImageDestinationAddImage(destination, processedCGImage, updatedMetadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            CameraLogger.error("Không thể hoàn tất CGImageDestination cho Live Photo", category: .photoKit)
            return nil
        }

        CameraLogger.success("✅ Đã nhúng Content Identifier vào ảnh đã lọc màu film thành công (\(outputData.length) bytes)", category: .photoKit)
        return outputData as Data
    }

    public func savePhotoToLibrary(_ item: CapturedPhotoItem) {
        CameraLogger.info("Bắt đầu lưu ảnh vào Cuộn Camera (Photo Library)... (Live Photo: \(item.isLivePhoto ? "CÓ" : "KHÔNG"))", category: .photoKit)
        let photoFormat = selectedPhotoFormat
        let shouldSaveOriginal = isSaveOriginalPhotoEnabled

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                CameraLogger.warning("Chưa được cấp quyền truy cập Photo Library", category: .photoKit)
                DispatchQueue.main.async {
                    self.saveErrorMessage = "Chưa cấp quyền Photos. Vào Cài đặt > AI Smart Framing Camera > Ảnh để bật quyền lưu ảnh."
                }
                return
            }

            if let liveMovieURL = item.livePhotoMovieURL, FileManager.default.fileExists(atPath: liveMovieURL.path) {
                // LƯU LIVE PHOTO CHUẨN APPLE
                CameraLogger.info("Đang tạo PHAssetCreationRequest cho Live Photo (Kèm video: \(liveMovieURL.lastPathComponent))", category: .photoKit)

                PHPhotoLibrary.shared().performChanges({
                    let creationRequest = PHAssetCreationRequest.forAsset()

                    // Thêm tài nguyên ảnh (ảnh đã lọc màu kèm Live Photo Content Identifier khớp với paired video)
                    let photoOptions = PHAssetResourceCreationOptions()
                    if let gradedData = Self.makeLivePhotoColorGradedData(
                        from: item.processedImage,
                        rawData: item.rawPhotoData,
                        format: photoFormat
                    ) {
                        creationRequest.addResource(with: .photo, data: gradedData, options: photoOptions)
                    } else if let rawData = item.rawPhotoData {
                        CameraLogger.warning("Fallback dùng rawPhotoData gốc (giữ Live Photo, không màu film)", category: .photoKit)
                        creationRequest.addResource(with: .photo, data: rawData, options: photoOptions)
                    } else {
                        let image = UIImage(cgImage: item.processedImage)
                        if let jpegData = image.jpegData(compressionQuality: 0.95) {
                            creationRequest.addResource(with: .photo, data: jpegData, options: photoOptions)
                        }
                    }

                    // Thêm tài nguyên video ghép đôi (Paired Video)
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.shouldMoveFile = false
                    creationRequest.addResource(with: .pairedVideo, fileURL: liveMovieURL, options: videoOptions)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            CameraLogger.success("✅ Đã lưu LIVE PHOTO vào Cuộn Camera thành công!", category: .photoKit)
                            self.haptics.triggerSuccess()
                            self.saveErrorMessage = nil
                        } else {
                            CameraLogger.error("Lưu Live Photo thất bại, chuyển sang lưu ảnh tĩnh dự phòng", error: error, category: .photoKit)
                            self.saveFallbackStaticPhoto(item)
                        }
                    }
                }
            } else {
                // LƯU ẢNH TĨNH THƯỜNG (RAW DNG / HEIC / JPEG)
                if photoFormat == .dng, let rawData = item.rawPhotoData {
                    PHPhotoLibrary.shared().performChanges({
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        creationRequest.addResource(with: .photo, data: rawData, options: options)
                    }) { success, error in
                        DispatchQueue.main.async {
                            if success {
                                CameraLogger.success("✅ Đã lưu ảnh RAW DNG gốc vào Cuộn Camera thành công!", category: .photoKit)
                                self.haptics.triggerSuccess()
                                self.saveErrorMessage = nil
                            } else {
                                CameraLogger.error("Lưu ảnh RAW DNG thất bại, thử lưu JPEG dự phòng", error: error, category: .photoKit)
                                self.saveFallbackStaticPhoto(item)
                            }
                        }
                    }
                    return
                }

                if photoFormat == .heic {
                    let ciImage = CIImage(cgImage: item.processedImage)
                    let context = CIContext()
                    let colorSpace = ciImage.colorSpace
                        ?? CGColorSpace(name: CGColorSpace.sRGB)
                        ?? CGColorSpaceCreateDeviceRGB()
                    if let heicData = context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:]) {
                        PHPhotoLibrary.shared().performChanges({
                            let creationRequest = PHAssetCreationRequest.forAsset()
                            creationRequest.addResource(with: .photo, data: heicData, options: nil)
                        }) { success, error in
                            DispatchQueue.main.async {
                                if success {
                                    CameraLogger.success("✅ Đã lưu ảnh HEIC vào Cuộn Camera thành công!", category: .photoKit)
                                    self.haptics.triggerSuccess()
                                    self.saveErrorMessage = nil
                                } else {
                                    CameraLogger.error("Lưu ảnh HEIC thất bại, thử lưu JPEG dự phòng", error: error, category: .photoKit)
                                    self.saveFallbackStaticPhoto(item)
                                }
                            }
                        }
                        return
                    }
                }

                let image = UIImage(cgImage: item.processedImage)
                let origImage = shouldSaveOriginal ? UIImage(cgImage: item.originalImage) : nil
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                    if let orig = origImage {
                        PHAssetChangeRequest.creationRequestForAsset(from: orig)
                    }
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            CameraLogger.success("✅ Đã lưu ảnh vào Cuộn Camera thành công!", category: .photoKit)
                            self.haptics.triggerSuccess()
                            self.saveErrorMessage = nil
                        } else {
                            CameraLogger.error("Lưu ảnh thất bại", error: error, category: .photoKit)
                            self.saveErrorMessage = "Lưu ảnh thất bại: \(error?.localizedDescription ?? "không rõ lỗi")"
                        }
                    }
                }
            }
        }
    }

    private func saveFallbackStaticPhoto(_ item: CapturedPhotoItem) {
        let image = UIImage(cgImage: item.processedImage)
        let origImage = self.isSaveOriginalPhotoEnabled ? UIImage(cgImage: item.originalImage) : nil
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
            if let orig = origImage {
                PHAssetChangeRequest.creationRequestForAsset(from: orig)
            }
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    CameraLogger.success("Đã lưu ảnh tĩnh dự phòng thành công!", category: .photoKit)
                    self.haptics.triggerSuccess()
                    self.saveErrorMessage = nil
                } else {
                    self.saveErrorMessage = "Lưu ảnh thất bại: \(error?.localizedDescription ?? "không rõ lỗi")"
                }
            }
        }
    }

    // MARK: - Computed helpers
    public var isAISessionActive: Bool { aiSessionState.isSessionActive }

    public var showTargetCircle: Bool {
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect: return currentTargetPoint != nil
        default: return false
        }
    }

    public var showGuidanceRay: Bool {
        guard isGuidanceRayEnabled else { return false }
        switch aiSessionState {
        case .targetPlaced: return !isPerfectAlignment && currentTargetPoint != nil
        default: return false
        }
    }
}

// MARK: - CameraServiceDelegate
extension CameraViewModel: CameraServiceDelegate {
    public nonisolated func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        frameProcessor.process(sampleBuffer)
    }

    public func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {
        self.recordedVideoURL = url
        self.isShowingVideoPreview = true
        self.haptics.triggerSuccess()
    }

    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double) {
        CameraLogger.info("Bắt đầu xử lý bộ lọc ảnh màu AI (Kích thước: \(photo.width)x\(photo.height), LivePhoto: \(livePhotoMovieURL != nil ? "CÓ" : "KHÔNG"))", category: .capture)

        let finalColorParams: AIColorParameters?
        if isAIFullColorEnabled {
            finalColorParams = geminiColorRecipe?.asAIColorParameters ?? currentAIColorParams ?? detectedScene.aiFullColorParameters
        } else {
            finalColorParams = nil
        }

        var activePreset = self.selectedFilmPreset
        if activePreset.isAIFullAuto {
            activePreset = self.aiRecommendedPreset ?? self.detectedScene.recommendedFilter
        }
        let effectivePreset = activePreset
        let activeScene = self.detectedScene
        let activeRule = self.activeCompositionRule
        let sessionState = self.aiSessionState
        let score: Double = (sessionState == .alignmentPerfect || sessionState == .capturing) ? 1.0 : (framingResult?.alignmentScore ?? 0.8)

        // Chuyển sang luồng phụ userInitiated để render CoreImage, không làm đơ Main UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var processedImageResult: CGImage = photo
            autoreleasepool {
                if let params = finalColorParams {
                    processedImageResult = FilmFilterEngine.shared.applyPresetAndAIParameters(to: photo, preset: effectivePreset, params: params) ?? photo
                } else {
                    processedImageResult = FilmFilterEngine.shared.applyPreset(to: photo, preset: effectivePreset) ?? photo
                }
            }

            let item = CapturedPhotoItem(
                originalImage: photo,
                processedImage: processedImageResult,
                rawPhotoData: rawData,
                livePhotoMovieURL: livePhotoMovieURL,
                sceneType: activeScene,
                appliedPreset: effectivePreset,
                compositionRule: activeRule,
                alignmentScore: score,
                iso: iso,
                shutterSpeed: shutterSpeed,
                aiColorParameters: finalColorParams
            )

            DispatchQueue.main.async {
                CameraLogger.success("Render bộ lọc hoàn tất, hiển thị xem trước & lưu ảnh (LivePhoto: \(item.isLivePhoto))", category: .capture)
                withAnimation {
                    self.latestCapturedPhoto = item
                    self.isShowingPhotoDetail = true
                    self.aiSessionState = .done
                }
                self.savePhotoToLibrary(item)
            }
        }
    }

    public func cameraService(_ service: CameraService, didFailCaptureWithError error: Error) {
        haptics.triggerSelectionChange()
        withAnimation {
            aiSessionState = .targetPlaced(locked: true)
            isShutterPressing = false
        }
        saveErrorMessage = "Chụp ảnh thất bại: \(error.localizedDescription). Vui lòng thử lại."
    }

    public func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {
        self.currentZoom = zoom
        self.displayZoom = self.cameraService.convertDeviceZoomToDisplayZoom(zoom)
        SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
        StreetSpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
    }
}
