import Foundation
import SwiftUI
import AVFoundation
import CoreImage
import Photos
import QuartzCore
import CoreMotion
import ImageIO
import UniformTypeIdentifiers
import simd
import Vision

private struct CameraFrameProcessingConfiguration: Sendable {
    var isHibernating = false
    var isSettingsVisible = false
    var tracksSuggestions = false
    var isFocusPeakingEnabled = false
    var focusPeakingColor: FocusPeakingColor = .green
    var isRecordingVideo = false
}

/// Owns frame-rate work on AVFoundation's serial sample-buffer queue. UI state is
/// published only after hopping to the main queue, while configuration snapshots
/// and the most recent pixel buffer are protected for cross-queue access.
private final class CameraFrameProcessor: @unchecked Sendable {
    private let stateLock = NSLock()
    private weak var owner: CameraViewModel?
    private var configuration = CameraFrameProcessingConfiguration()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameContext: TrackingFrameContext?
    private var lastHistogramComputeTime: CFTimeInterval = 0
    private var lastFocusPeakingComputeTime: CFTimeInterval = 0
    private var lastSuggestionUpdateTime: CFTimeInterval = 0

    @MainActor
    func attach(to owner: CameraViewModel) {
        self.owner = owner
    }

    func updateConfiguration(_ configuration: CameraFrameProcessingConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
    }

    func clearBuffers() {
        stateLock.lock()
        latestPixelBuffer = nil
        latestFrameContext = nil
        stateLock.unlock()
    }

    func latestPixelBufferSnapshot() -> CVPixelBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestPixelBuffer
    }

    func latestTrackingFrameSnapshot() -> (CVPixelBuffer, TrackingFrameContext)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let buffer = latestPixelBuffer, let frame = latestFrameContext else { return nil }
        return (buffer, frame)
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let snapshot = configuration
        stateLock.unlock()

        // Zero-Cost Gate: Khi đang ngủ đông hoặc đang quay video,
        // lập tức thoát ngay mà không chạy bất kỳ tác vụ AI Vision, YOLO, Optical Flow, Histogram hay Peaking nào!
        guard !snapshot.isHibernating && !snapshot.isRecordingVideo else { return }

        let frame = TrackingFrameContext.read(sampleBuffer,
            zoom: SpatialTrackingEngine.shared.currentDisplayZoom)

        // CameraService invokes this method on its serial videoDataQueue. Processing
        // in place avoids an extra frame copy and never sends CMSampleBuffer across
        // another concurrency boundary.
        VisionFramingEngine.shared.processVideoSampleBuffer(sampleBuffer, orientation: .up, frameContext: frame)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameContext = frame
        stateLock.unlock()

        guard !snapshot.isSettingsVisible else { return }

        let now = CACurrentMediaTime()
        if snapshot.tracksSuggestions, let frame,
           now - lastSuggestionUpdateTime >= 1.0 / 30.0 {
            lastSuggestionUpdateTime = now
            DispatchQueue.main.async { [weak self] in
                self?.owner?.refreshSuggestionProjection(frame: frame)
            }
        }
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
    private struct AITrackingSource: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let frame: TrackingFrameContext
        let pose: simd_quatd
        let subjectRect: CGRect?
        let faceRects: [CGRect]
    }

    private var cloudTrackingSource: AITrackingSource?
    private var localTrackingSource: AITrackingSource?
    @Published private(set) var localCompositionChoices: [LocalCompositionChoice] = []
    @Published var compositionPreviewPresentation: CompositionPreviewPresentation?
    private var activeCompositionPreviewID: UUID?
    private var selectedCompositionPreviewID: UUID?
    @Published private(set) var localCompositionExplanation = ""
    private var localCompositionIntent: LocalCompositionIntent?
    private var localAnalysisTask: Task<Void, Never>?
    private var localAnalysisCancellation: CompositionAnalysisCancellation?
    private var localEvidenceCandidates: [NeuralSubjectCandidate] = []
    private var postZoomFaceCount = 0
    private var localAnalysisExpired = false
    private var localAnalysisFinished = false
    @Published public private(set) var localSuggestionRects: [CGRect] = []
    @Published public private(set) var localSelectionMessage: String? = nil
    private var allowsAutoCaptureForCurrentTarget = true
    // MARK: - Services
    public let cameraService = CameraService.shared
    public weak var previewLayer: AVCaptureVideoPreviewLayer?
    public let visionEngine = VisionFramingEngine.shared
    public let calculator = CompositionCalculator.shared
    public let filterEngine = FilmFilterEngine.shared
    public let haptics = HapticFeedbackService.shared
    public let geminiService = GeminiService.shared
    public let motionService = DeviceMotionService.shared
    private nonisolated let frameProcessor = CameraFrameProcessor()

    // MARK: - AI Session State Machine
    private var aiSessionGeneration: Int = 0 {
        didSet {
            localAnalysisCancellation?.cancel()
            localAnalysisCancellation = nil
            localAnalysisTask?.cancel()
            localAnalysisTask = nil
            localCompositionChoices = []
            activeCompositionPreviewID = nil
            selectedCompositionPreviewID = nil
            compositionPreviewPresentation = nil
            localCompositionExplanation = ""
            localCompositionIntent = nil
        }
    }
    private var targetPinGeneration: UInt64 = 0 {
        didSet { postZoomRecovery.reset() }
    }
    @Published public var aiSessionState: AISessionState = .idle {
        didSet {
            switch aiSessionState {
            case .idle, .done:
                visionEngine.isIdlePreviewMode = true
            default:
                visionEngine.isIdlePreviewMode = false
            }
            updateFrameProcessingConfiguration()
        }
    }

    // MARK: - Published UI States (Persisted)
    @Published public var isCameraReady: Bool = false
    @Published public var hasCameraPermission: Bool = false

    @Published public var activeCompositionRule: CompositionRule = .goldenRatio {
        didSet { UserDefaults.standard.set(activeCompositionRule.rawValue, forKey: "activeCompositionRule") }
    }
    @Published public var isFilmSimulationActive: Bool = false {
        didSet { UserDefaults.standard.set(isFilmSimulationActive, forKey: "isFilmSimulationActive") }
    }
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H {
        didSet { UserDefaults.standard.set(selectedFilmPreset.rawValue, forKey: "selectedFilmPreset") }
    }
    @Published public var selectedFilmCategory: FilmPresetCategory = .trending {
        didSet { UserDefaults.standard.set(selectedFilmCategory.rawValue, forKey: "selectedFilmCategory") }
    }
    @Published public var isAIFullColorEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isAIFullColorEnabled, forKey: "isAIFullColorEnabled") }
    }
    @Published public var aiRecommendedPreset: FilmPreset? = nil
    @Published public var aiPresetMatchReason: String? = nil
    @Published public var isAutoZoomEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoZoomEnabled, forKey: "isAutoZoomEnabled") }
    }

    // Camera Mode & Live Photo
    @Published public private(set) var captureMode: CameraCaptureMode = .photo {
        didSet {
            UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode")
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
    @Published public var isSuperResolutionRAWEnabled: Bool = UserDefaults.standard.bool(forKey: "isSuperResolutionRAWEnabled") {
        didSet { UserDefaults.standard.set(isSuperResolutionRAWEnabled, forKey: "isSuperResolutionRAWEnabled") }
    }
    @Published public private(set) var photoCapturePhase: PhotoCapturePhase = .preparing
    @Published public var isStreetTrackingModeEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isStreetTrackingModeEnabled, forKey: "isStreetTrackingModeEnabled")
            SpatialTrackingEngine.shared.isStreetMode = isStreetTrackingModeEnabled
        }
    }
    @Published public var liveISO: String = "ISO 32"
    @Published public var liveShutterSpeed: String = "1/400 s"
    @Published public var histogramBars: [HistogramBarData] = (0..<32).map {
        let t = Double($0) / 31.0
        let col = t < 0.28 ? Color(red: 0.15, green: 0.45, blue: 0.95) : (t < 0.72 ? Color(red: 0.40, green: 0.90, blue: 0.60) : Color(red: 0.95, green: 0.45, blue: 0.20))
        return HistogramBarData(id: $0, height: 0.10, color: col)
    }
    @Published public private(set) var isRecordingVideo: Bool = false {
        didSet { updateFrameProcessingConfiguration() }
    }
    @Published public private(set) var recordingState: CameraRecordingState = .idle
    private var wantsVideoRecording = false
    private var pendingCaptureMode: CameraCaptureMode?
    private var modeTransitionGeneration: UInt64 = 0
    private var isModeTransitionInFlight = false
    @Published private var isSwitchingCamera = false
    @Published public var recordedVideoURL: URL? = nil
    private var pendingRecordedVideoURLs: [URL] = []
    private var pendingPhotoPreview = false
    @Published public var isShowingVideoPreview: Bool = false {
        didSet { updateCameraHibernationState() }
    }

    // Video Duration & Resolution Stats (Mặc định 00:00:00, Đọc từ cài đặt hệ thống Camera iOS)
    @Published public var videoRecordingTimeString: String = "00:00:00"
    @Published public var videoRecordedDurationSeconds: TimeInterval = 0
    @Published public var activeVideoResolutionString: String = "1080P 30FPS"
    @Published public var selectedVideoCodec: VideoCodec = .hevc {
        didSet {
            UserDefaults.standard.set(selectedVideoCodec.rawValue, forKey: "selectedVideoCodec")
            cameraService.setVideoCodec(selectedVideoCodec)
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
    @Published public var isShowingProControlsDrawer: Bool = true

    // Camera Parameters
    @Published public var currentZoom: CGFloat = 1.0
    @Published public var displayZoom: CGFloat = 1.0
    @Published public var selectedZoomPreset: CGFloat = 1.0
    public var availableDisplayZoomOptions: [CGFloat] {
        return [1.0, 2.0, 3.0]
    }
    @Published public var isRevealingZoomTarget: Bool = false
    @Published public var lockOnProgress: CGFloat = 0
    @Published public var liveZoomFactorForReveal: CGFloat = 1.0
    private var pendingTargetZoomForReveal: CGFloat = 1.0
    private var zoomRevealStartDisplayZoom: CGFloat = 1.0
    private var zoomRevealStartsIn = true
    private var isZoomRampPhase: Bool = false
    private var zoomAwaitingVerification = false
    private var zoomVerified = true
    private var pendingManualZoomTarget: CGFloat?
    private var manualZoomRequestID: UUID?
    private var manualZoomSettledAt = -Double.infinity
    private var zoomFallbackAfter = Double.infinity
    private var postZoomRecovery = PostZoomRecoveryPolicy()
    private var zoomVerificationTask: Task<Void, Never>?
    private var zoomStartFrameTimestamp = -Double.infinity
    private var postZoomFaceMinimumTimestamp = -Double.infinity
    private var latestOpticalFrameTimestamp = -Double.infinity
    private var latestOpticalPoint: CGPoint?
    private var latestOpticalBox: CGRect?
    private var latestOpticalCalibration: TrackingCalibration?
    private var needsFocusOnTrackedSubject = false
    private var targetPinStartedAt = -Double.infinity
    private var lastFailedCaptureOpticalTimestamp = -Double.infinity
    private var lastFailedCaptureAttemptTime = -Double.infinity

    // MARK: - Sun Exposure Slider & Horizon Leveler
    @Published public var isShowingSunSlider: Bool = false
    @Published public var activeSunExposureBias: Float = 0.0

    // MARK: - Thước Đo Cân Bằng Chân Trời (Horizon Leveler) & Hiệu Chuẩn Gyro
    @Published public var isHorizonLevelerEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isHorizonLevelerEnabled, forKey: "isHorizonLevelerEnabled") }
    }
    @Published public var currentRollDegrees: Double = 0.0
    @Published public var isDeviceLevel: Bool = false
    @Published public var gyroRollOffsetDegrees: Double = 0.0 {
        didSet { UserDefaults.standard.set(gyroRollOffsetDegrees, forKey: "gyroRollOffsetDegrees") }
    }
    @Published public var gyroPitchOffsetDegrees: Double = 0.0 {
        didSet { UserDefaults.standard.set(gyroPitchOffsetDegrees, forKey: "gyroPitchOffsetDegrees") }
    }
    @Published public var lastGyroCalibrationDate: Date? = nil {
        didSet { UserDefaults.standard.set(lastGyroCalibrationDate?.timeIntervalSince1970, forKey: "lastGyroCalibrationDate") }
    }
    @Published public var isShowingGyroCalibration: Bool = false {
        didSet { updateCameraHibernationState() }
    }
    private let horizonMotionManager = CMMotionManager()
    private var hasTriggeredLevelHaptic: Bool = false
    private var lastLevelHapticTime: TimeInterval = -.infinity

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
        guard isRevealingZoomTarget, pendingTargetZoomForReveal > 0 else {
            return CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
        }
        let targetSize = min(1.0, max(0.20,
            zoomRevealStartDisplayZoom / pendingTargetZoomForReveal))

        if !isZoomRampPhase {
            // Giai đoạn 1: khung lướt nhẹ từ toàn cảnh (1.0) về vùng crop dự kiến bao quanh chủ thể
            let p = max(0.0, min(1.0, lockOnProgress))
            let size = 1.0 - (1.0 - targetSize) * p
            return CGRect(x: (1 - size) / 2, y: (1 - size) / 2,
                          width: size, height: size)
        } else {
            // Giai đoạn 2: khi camera phần cứng đang ramp zoom, khung đồng bộ mở rộng ra mép màn hình
            let ratio = min(1.0, max(0.20,
                liveZoomFactorForReveal / pendingTargetZoomForReveal))
            return CGRect(x: (1 - ratio) / 2, y: (1 - ratio) / 2,
                          width: ratio, height: ratio)
        }
    }

    public var zoomRevealTargetZoom: CGFloat { pendingTargetZoomForReveal }

    @Published public var exposureBias: Float = 0.0
    @Published public var activeFlashMode: AVCaptureDevice.FlashMode = .auto {
        didSet {
            UserDefaults.standard.set(activeFlashMode.rawValue, forKey: "activeFlashMode")
            cameraService.setFlashMode(activeFlashMode)
        }
    }
    @Published public var isPinchingZoom: Bool = false

    private var pendingSuggestedZoom: CGFloat = 1.0
    private var hasExecutedAutoZoomForSession: Bool = false
    private var lastAutoZoomExecutionTime: Date = .distantPast

    // MARK: - Auto-Zoom Execution (1x, 2x, 3x Zoom-In & Zoom-Out with Cooldown & Hysteresis)
    public func applyAISuggestedZoom(_ targetZoom: CGFloat, force: Bool = false) {
        guard isAutoZoomEnabled else { return }
        guard targetZoom.isFinite, currentZoom.isFinite else { return }
        guard aiSessionState == .alignmentPerfect, !isPinchingZoom,
              !hasExecutedAutoZoomForSession, !zoomAwaitingVerification,
              hasFreshOpticalLock, canZoomCurrentSubject(to: targetZoom) else { return }

        // Cooldown: Tối thiểu 0.8s giữa các lần tự động zoom (tránh spam, nhưng không chặn người dùng khi căn chỉnh)
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastAutoZoomExecutionTime)
        if !force && timeSinceLast < 0.8 {
            CameraLogger.info("Bỏ qua auto zoom do đang trong thời gian cooldown (\(String(format: "%.1f", timeSinceLast))s < 0.8s)", category: .ai)
            return
        }

        // Hysteresis: Nếu mức zoom hiện tại đã rất gần mục tiêu (sai số < 0.12), không zoom lại
        let diff = targetZoom - displayZoom
        guard abs(diff) > 0.12 else { return }

        lastAutoZoomExecutionTime = now

        CameraLogger.info("Thực thi AI Auto-Zoom Điện Ảnh: \(displayZoom)x -> \(targetZoom)x", category: .ai)

        triggerZoomRevealAnimation(targetZoom: targetZoom)
    }

    public func triggerZoomRevealAnimation(targetZoom: CGFloat) {
        guard targetZoom.isFinite, targetZoom > 0, currentZoom.isFinite,
              !isPinchingZoom, !zoomAwaitingVerification else { return }
        let targetDeviceZoom = cameraService.convertDisplayZoomToDeviceZoom(targetZoom)
        guard abs(targetDeviceZoom - currentZoom) > 0.05 else { return }
        hasExecutedAutoZoomForSession = true
        postZoomRecovery.reset()
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        zoomVerified = false
        zoomAwaitingVerification = true
        zoomFallbackAfter = .infinity
        zoomStartFrameTimestamp = frameProcessor.latestTrackingFrameSnapshot()?.1.timestamp ?? CACurrentMediaTime()
        postZoomFaceMinimumTimestamp = -Double.infinity
        pendingTargetZoomForReveal = cameraService.convertDeviceZoomToDisplayZoom(targetDeviceZoom)
        alignmentGate.reset()
        zoomRevealStartDisplayZoom = max(0.1, displayZoom)
        zoomRevealStartsIn = targetZoom > displayZoom
        liveZoomFactorForReveal = displayZoom
        isZoomRampPhase = false
        lockOnProgress = 0
        isRevealingZoomTarget = true
        let pinGeneration = targetPinGeneration

        // Hiệu ứng chuyển động mượt mà điện ảnh (Cinematic Easing)
        withAnimation(.easeOut(duration: 0.24)) {
            lockOnProgress = 1.0
        }

        // Hold the outlined, dimmed crop before the optical ramp begins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { [weak self] in
            guard let self = self, self.targetPinGeneration == pinGeneration,
                  self.zoomAwaitingVerification, !self.isPinchingZoom else { return }
            self.isZoomRampPhase = true
            let octaveDistance = abs(log2(Double(targetDeviceZoom / max(0.5, self.currentZoom))))
            let targetDuration = min(1.8, max(1.2, octaveDistance * 1.3))
            let smoothRate = Float(max(0.5, min(8.0,
                Double(abs(targetDeviceZoom - self.currentZoom)) / targetDuration)))
            self.cameraService.smoothZoomFactor(to: targetDeviceZoom, rate: smoothRate)
        }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = Task { [weak self] in
            await self?.verifyZoomAfterRamp(pinGeneration: pinGeneration)
        }
    }

    // AI Framing & Composition
    @Published public var framingResult: FramingTargetResult?
    @Published public var alignmentState: FramingAlignmentState = .analyzing
    @Published public var detectedScene: DetectedSceneType = .general
    @Published public var detectedSubjectRects: [CGRect] = []
    @Published public var detectedFaceRects: [CGRect] = []
    @Published public var liveDetectedEntities: [LiveDetectedEntity] = []
    private let liveEntitySmoother = LiveDetectedEntitySmoother()
    private var latestSubjectDetectionResult: SubjectDetectionResult? = nil

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
    @Published public var useGeminiForAnalysis: Bool = false {
        didSet { UserDefaults.standard.set(useGeminiForAnalysis, forKey: "useGeminiForAnalysis") }
    }
    @Published public var activeModelUsedName: String = ""
    @Published public var geminiLatencyMs: Int = 0
    @Published public var aiSuggestedZoom: CGFloat? = nil

    // MARK: - AI Video Cinematography Director State (Cloud OpenRouter)
    @Published public var isAIVideoDirectorActive: Bool = false
    @Published public var isAIVideoDirectorAnalyzing: Bool = false
    @Published public var activeVideoGuidance: AIVideoDirectorGuidance? = nil
    private var videoDirectorGeneration: UInt64 = 0
    private var videoDirectorTimeoutTask: Task<Void, Never>?
    private var videoGuidanceRequest: GeminiService.VideoCinematographyRequest?
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
    @Published public var isShowingPhotoDetail: Bool = false {
        didSet { updateCameraHibernationState() }
    }
    @Published public var isShowingGallerySheet: Bool = false {
        didSet { updateCameraHibernationState() }
    }
    @Published public var latestAlbumThumbnail: UIImage? = nil
    @Published public var isShowingSettings: Bool = false {
        didSet {
            if isShowingSettings { focusPeakingCGImage = nil }
            updateCameraHibernationState()
        }
    }
    @Published public var isShowingFilmDrawer: Bool = false

    // MARK: - Windowed Zoom State (Optical Rangefinder Framing)
    @Published public var isWindowedZoomActive: Bool = false {
        didSet {
            if isWindowedZoomActive {
                if aiSessionState.isSessionActive {
                    cancelAISession()
                }
            }
        }
    }
    @Published public var windowedZoomFocalLength: Double = 35.0
    @Published public var windowedZoomAspectRatio: WindowedZoomAspectRatio = .ratio3_4
    @Published public var isAIWindowedFocalRecommended: Bool = false

    @Published public var showAlignmentSuccessFlash: Bool = false
    @Published public var isShutterPressing: Bool = false
    @Published public var activeFlashMode2: Bool = false
    @Published public var currentAIColorParams: AIColorParameters? = nil

    // MARK: - Smart Camera Hibernation (Ngủ đông thông minh tiết kiệm CPU/GPU/RAM)
    @Published public var isCameraHibernating: Bool = false
    @Published public var isAppInBackground: Bool = false

    public func updateCameraHibernationState() {
        let shouldHibernate = isShowingSettings
            || isShowingGyroCalibration
            || isCompositionRuleSheetPresented
            || isShowingPhotoDetail
            || isShowingGallerySheet
            || isShowingVideoPreview
            || isAppInBackground

        guard shouldHibernate != isCameraHibernating else { return }
        isCameraHibernating = shouldHibernate

        if shouldHibernate {
            if wantsVideoRecording || recordingState != .idle {
                wantsVideoRecording = false
                cameraService.stopRecordingVideo()
            }
            // 1. Khi mở màn hình che khuất camera, hủy phiên tracking hiện tại theo yêu cầu
            if aiSessionState != .capturing && (isAISessionActive || currentTargetPoint != nil) {
                cancelAISession()
            }
            // 2. Giải phóng bộ nhớ đồ họa tạm
            focusPeakingCGImage = nil
            frameProcessor.clearBuffers()
            updateFrameProcessingConfiguration()
            CameraLogger.info("Camera chuyển sang chế độ ngủ đông (Standby: 0% CPU/AI)", category: .general)
        } else {
            // Waking up
            updateFrameProcessingConfiguration()
            CameraLogger.info("Camera thức dậy, khôi phục pipeline 60fps tức thì", category: .general)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.presentPendingMediaPreviewIfPossible()
            }
        }
    }

    private func presentPendingMediaPreviewIfPossible() {
        guard !isCameraHibernating, !isAppInBackground,
              recordingState == .idle, !wantsVideoRecording,
              !isShutterPressing,
              !isModeTransitionInFlight else { return }
        if !pendingRecordedVideoURLs.isEmpty {
            recordedVideoURL = pendingRecordedVideoURLs.removeFirst()
            isShowingVideoPreview = true
        } else if pendingPhotoPreview, latestCapturedPhoto != nil {
            pendingPhotoPreview = false
            isShowingPhotoDetail = true
        }
    }

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        isAppInBackground = phase != .active
        updateCameraHibernationState()
        if phase != .active {
            isCameraReady = false
            if wantsVideoRecording || recordingState != .idle {
                wantsVideoRecording = false
                cameraService.stopRecordingVideo()
            }
            if isAIVideoDirectorActive { dismissAIVideoDirector() }
            suspendSpatialTracking()
            cameraService.stop()
        } else {
            SpatialTrackingEngine.shared.prepare()
            guard hasCameraPermission else { return }
            cameraService.start { [weak self] running in
                self?.isCameraReady = running
                if running { self?.applyPendingCaptureModeIfPossible() }
            }
        }
    }

    // MARK: - Quiet Pro Camera User Settings
    @Published public var isAutoCaptureOnAlignEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoCaptureOnAlignEnabled, forKey: "isAutoCaptureOnAlignEnabled") }
    }
    @Published public var showDetectionBoxes: Bool = false {
        didSet { UserDefaults.standard.set(showDetectionBoxes, forKey: "showDetectionBoxes") }
    }
    @Published public var showHistogramInViewfinder: Bool = true {
        didSet { UserDefaults.standard.set(showHistogramInViewfinder, forKey: "showHistogramInViewfinder") }
    }
    @Published public var isHistogramBarExpanded: Bool = true {
        didSet { UserDefaults.standard.set(isHistogramBarExpanded, forKey: "isHistogramBarExpanded") }
    }
    @Published public var showAudioLevelMeter: Bool = true {
        didSet { UserDefaults.standard.set(showAudioLevelMeter, forKey: "showAudioLevelMeter") }
    }
    @Published public var audioLevels: (left: Float, right: Float) = (0.0, 0.0)
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
    @Published public var isGuidanceRayEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isGuidanceRayEnabled, forKey: "isGuidanceRayEnabled") }
    }
    @Published public var isCompositionRuleSheetPresented: Bool = false {
        didSet { updateCameraHibernationState() }
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
    private var alignmentGate = AlignmentCaptureGate()
    public var viewfinderSize: CGSize = .zero
    private var isPreparingPinZoom = false
    private var pinZoomPlanTask: Task<Void, Never>?
    // Subject extent relative to the optical ROI, so crop checks use the whole
    // subject rather than assuming a small tracking patch is the whole object.
    private var subjectBoundsInTrackingBox: CGRect?
    private var pinTrackingBox: CGRect?

    private var stateBeforeCapture: AISessionState = .idle
    private var isOneShotCaptured = false
    private var lastFocusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
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
        if let enabled = defaults.object(forKey: "isGuidanceRayEnabled") as? Bool {
            self.isGuidanceRayEnabled = enabled
        }
        if let ruleRaw = defaults.string(forKey: "activeCompositionRule"), let rule = CompositionRule(rawValue: ruleRaw) {
            self.activeCompositionRule = rule
        }
        if let presetRaw = defaults.string(forKey: "selectedFilmPreset"), let preset = FilmPreset(rawValue: presetRaw) {
            self.selectedFilmPreset = preset
            self.selectedFilmCategory = preset.category
        }
        if let categoryRaw = defaults.string(forKey: "selectedFilmCategory"), let cat = FilmPresetCategory(rawValue: categoryRaw) {
            self.selectedFilmCategory = cat
        }
        if let modeRaw = defaults.string(forKey: "captureMode"), let mode = CameraCaptureMode(rawValue: modeRaw) {
            self.captureMode = mode == .proVideo ? .video : mode
        }
        if let photoFormatRaw = defaults.string(forKey: "selectedPhotoFormat"), let photoFormat = PhotoSaveFormat(rawValue: photoFormatRaw) {
            self.selectedPhotoFormat = photoFormat
        }
        if defaults.object(forKey: "isSuperResolutionRAWEnabled") != nil {
            self.isSuperResolutionRAWEnabled = defaults.bool(forKey: "isSuperResolutionRAWEnabled")
        }
        if defaults.object(forKey: "isGuidanceRayEnabled") != nil {
            self.isGuidanceRayEnabled = defaults.bool(forKey: "isGuidanceRayEnabled")
        }
        if defaults.object(forKey: "isFilmSimulationActive") != nil {
            self.isFilmSimulationActive = defaults.bool(forKey: "isFilmSimulationActive")
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
        // Older builds enabled paid cloud models by default. Require an explicit opt-in once.
        if defaults.bool(forKey: "cloudModeOptInV2"),
           defaults.object(forKey: "useGeminiForAnalysis") != nil {
            self.useGeminiForAnalysis = defaults.bool(forKey: "useGeminiForAnalysis")
        } else {
            self.useGeminiForAnalysis = false
            if defaults.string(forKey: "gemini_selected_model") == "auto" {
                geminiService.selectedModel = .freeVision
                geminiService.customModelName = ""
            }
            defaults.set(true, forKey: "cloudModeOptInV2")
        }
        if defaults.object(forKey: "isStreetTrackingModeEnabled") != nil {
            self.isStreetTrackingModeEnabled = defaults.bool(forKey: "isStreetTrackingModeEnabled")
            SpatialTrackingEngine.shared.isStreetMode = self.isStreetTrackingModeEnabled
        }
        if defaults.object(forKey: "isHorizonLevelerEnabled") != nil {
            self.isHorizonLevelerEnabled = defaults.bool(forKey: "isHorizonLevelerEnabled")
        }
        if defaults.object(forKey: "gyroRollOffsetDegrees") != nil {
            self.gyroRollOffsetDegrees = defaults.double(forKey: "gyroRollOffsetDegrees")
        }
        if defaults.object(forKey: "gyroPitchOffsetDegrees") != nil {
            self.gyroPitchOffsetDegrees = defaults.double(forKey: "gyroPitchOffsetDegrees")
        }
        if let timestamp = defaults.object(forKey: "lastGyroCalibrationDate") as? Double {
            self.lastGyroCalibrationDate = Date(timeIntervalSince1970: timestamp)
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
        if defaults.object(forKey: "hasMigratedHistogramBuild133") == nil {
            self.showHistogramInViewfinder = true
            self.isHistogramBarExpanded = true
            defaults.set(true, forKey: "hasMigratedHistogramBuild133")
            defaults.set(true, forKey: "showHistogramInViewfinder")
            defaults.set(true, forKey: "isHistogramBarExpanded")
        } else {
            if defaults.object(forKey: "showHistogramInViewfinder") != nil {
                self.showHistogramInViewfinder = defaults.bool(forKey: "showHistogramInViewfinder")
            } else {
                self.showHistogramInViewfinder = true
            }
            if defaults.object(forKey: "isHistogramBarExpanded") != nil {
                self.isHistogramBarExpanded = defaults.bool(forKey: "isHistogramBarExpanded")
            } else {
                self.isHistogramBarExpanded = true
            }
        }
        if defaults.object(forKey: "showAudioLevelMeter") != nil {
            self.showAudioLevelMeter = defaults.bool(forKey: "showAudioLevelMeter")
        } else {
            self.showAudioLevelMeter = true
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
        self.cameraService.setVideoCodec(self.selectedVideoCodec)
        self.cameraService.setVideoFormatOption(self.selectedVideoFormatOption)
        self.cameraService.setFlashMode(self.activeFlashMode)

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
                isHibernating: isCameraHibernating,
                isSettingsVisible: isShowingSettings,
                tracksSuggestions: aiSessionState == .analyzing,
                isFocusPeakingEnabled: isFocusPeakingEnabled,
                focusPeakingColor: focusPeakingColor,
                isRecordingVideo: isRecordingVideo
            )
        )
    }

    // MARK: - Initialization & Permissions
    public func requestPermissionsAndStart() {
        // 1. Camera Permission (.video)
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

        // 2. Microphone Permission (.audio) cho quay video
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        // 3. Photo Library Full Permission (.readWrite) để tải ảnh mới nhất và quản lý album
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if photoStatus == .authorized || photoStatus == .limited {
            self.loadLatestPhotoFromAlbum()
        } else if photoStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                if status == .authorized || status == .limited {
                    DispatchQueue.main.async {
                        self?.loadLatestPhotoFromAlbum()
                    }
                }
            }
        }
    }

    /// Tải ảnh chụp gần đây nhất từ thư viện ảnh máy để hiển thị trên nút Album ở góc trái
    public func loadLatestPhotoFromAlbum() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.fetchLimit = 1
            let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            guard let latestAsset = result.firstObject else { return }

            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = false
            requestOptions.deliveryMode = .opportunistic
            requestOptions.isNetworkAccessAllowed = true

            let targetSize = CGSize(width: 160, height: 160)
            imageManager.requestImage(for: latestAsset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                guard let img = image else { return }
                DispatchQueue.main.async {
                    self?.latestAlbumThumbnail = img
                }
            }
        }
    }


    private func startCamera() {
        cameraService.delegate = self
        cameraService.setupSession { [weak self] success in
            guard let self = self else { return }
            guard success else {
                self.isCameraReady = false
                self.saveErrorMessage = "Không thể cấu hình camera. Hãy thử mở lại ứng dụng."
                return
            }
            self.cameraService.updateCaptureMode(self.captureMode)
            self.cameraService.setLivePhotoCaptureEnabled(self.isLivePhotoEnabled)
            self.displayZoom = self.cameraService.defaultDisplayZoom
            self.currentZoom = self.cameraService.currentZoom
            SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
            guard !self.isAppInBackground else { return }
            self.cameraService.start { [weak self] running in
                self?.isCameraReady = running
                if running { self?.applyPendingCaptureModeIfPossible() }
            }
        }
    }

    private func handleVisionDetectionWithSource(_ detection: SubjectDetectionResult,
                                                   frame: TrackingFrameContext?) {
        guard !isShowingSettings else { return }
        if let frame { refreshSuggestionProjection(frame: frame) }
        handleVisionDetection(detection)
    }

    fileprivate func refreshSuggestionProjection(frame: TrackingFrameContext) {
        guard aiSessionState == .analyzing, localAnalysisFinished,
              !localEvidenceCandidates.isEmpty, let source = localTrackingSource,
              let pose = SpatialTrackingEngine.shared.pose(at: frame.timestamp) else { return }
        let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        let projected = localEvidenceCandidates.map {
            reprojectSuggestion($0.boundingBox, from: source,
                                to: frame.calibration, pose: pose).intersection(viewport)
        }
        localSuggestionRects = projected.enumerated().map { index, rect in
            guard !rect.isNull, !rect.isEmpty else { return .zero }
            guard index < localSuggestionRects.count,
                  !localSuggestionRects[index].isEmpty else { return rect }
            let old = localSuggestionRects[index]
            // Camera motion is reprojected every frame; damp only small detector jitter.
            let a: CGFloat = hypot(rect.midX - old.midX, rect.midY - old.midY) > 0.12 ? 1 : 0.72
            return CGRect(x: old.minX + (rect.minX - old.minX) * a,
                          y: old.minY + (rect.minY - old.minY) * a,
                          width: old.width + (rect.width - old.width) * a,
                          height: old.height + (rect.height - old.height) * a)
        }
    }

    private func reprojectSuggestion(_ rect: CGRect, from source: AITrackingSource,
                                     to calibration: TrackingCalibration,
                                     pose: simd_quatd) -> CGRect {
        let corners = [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY),
                       CGPoint(x: rect.maxX, y: rect.maxY)]
        let projections = corners.map { point in
            calibration.project(deviceRay: pose.inverse.act(
                source.pose.act(source.frame.calibration.deviceRay(at: point))))
        }
        guard projections.allSatisfy({ $0.isInFront &&
            $0.point.x.isFinite && $0.point.y.isFinite }) else {
            return CGRect(x: -1, y: -1, width: 0, height: 0)
        }
        let xs = projections.map(\.point.x), ys = projections.map(\.point.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              minX > -2, maxX < 3, minY > -2, maxY < 3 else {
            return CGRect(x: -1, y: -1, width: 0, height: 0)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - AVCaptureVideoPreviewLayer Coordinate Mapping
    /// Chuyen doi bounding box chuan hoa [0...1] so voi sensor bounds sang toa do hien thi tren preview layer
    public func convertMetadataRectToLayerRect(_ normalizedSensorRect: CGRect, in screenSize: CGSize) -> CGRect {
        guard !normalizedSensorRect.isEmpty, !normalizedSensorRect.isNull else { return .zero }
        let metaX = max(0, min(1, normalizedSensorRect.minY))
        let metaY = max(0, min(1, 1.0 - normalizedSensorRect.maxX))
        let metaW = max(0, min(1 - metaX, normalizedSensorRect.height))
        let metaH = max(0, min(1 - metaY, normalizedSensorRect.width))
        let metadataOutputRect = CGRect(x: metaX, y: metaY, width: metaW, height: metaH)

        if let previewLayer = self.previewLayer, previewLayer.bounds.width > 0 && previewLayer.bounds.height > 0 {
            let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataOutputRect)
            if converted.width > 0 && converted.height > 0 && !converted.origin.x.isNaN && !converted.origin.y.isNaN {
                return converted
            }
        }

        let zoom = max(1.0, displayZoom)
        let aspect = SpatialTrackingEngine.shared.currentBufferAspect
        let scale = max(screenSize.width / aspect, screenSize.height)
        let midX = screenSize.width / 2.0
        let midY = screenSize.height / 2.0

        let zoomedX = ((normalizedSensorRect.midX - 0.5) * zoom) * scale * aspect + midX
        let zoomedY = ((normalizedSensorRect.midY - 0.5) * zoom) * scale + midY
        let zoomedW = normalizedSensorRect.width * zoom * scale * aspect
        let zoomedH = normalizedSensorRect.height * zoom * scale

        return CGRect(x: zoomedX - zoomedW / 2.0,
                      y: zoomedY - zoomedH / 2.0,
                      width: max(0, zoomedW),
                      height: max(0, zoomedH))
    }

    public func cancelAIZoomForGesture() {
        manualZoomRequestID = nil
        // Tuyet doi khong xoa AI session, targetPoint hoac mang bounding box khi zoom 1x <-> 2x
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinZoomPlanTask?.cancel()
        pinZoomPlanTask = nil
        isPreparingPinZoom = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        cameraService.cancelZoomRamp()
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        zoomAwaitingVerification = false
        zoomVerified = false
        pendingManualZoomTarget = nil
        manualZoomSettledAt = CACurrentMediaTime()
        zoomFallbackAfter = .infinity
        postZoomRecovery.reset()
        postZoomFaceMinimumTimestamp = -Double.infinity
        hasExecutedAutoZoomForSession = true
    }

    private func finishManualZoomIfSettled(_ deviceZoom: CGFloat) {
        guard let target = pendingManualZoomTarget,
              abs(deviceZoom - target) <= 0.03 else { return }
        pendingManualZoomTarget = nil
        manualZoomSettledAt = CACurrentMediaTime()
        // A fresh optical observation after this timestamp is still mandatory.
        zoomVerified = true
        alignmentGate.reset()
    }

    private func setupCallbacks() {
        cameraService.onActiveVideoFormatChanged = { [weak self] format in
            DispatchQueue.main.async {
                self?.activeVideoResolutionString = format
            }
        }

        visionEngine.onDetectionWithSource = { [weak self] detection, _, frame in
            // Vision currently delivers on main; retain a safe boundary if a
            // future caller invokes this callback from its processing queue.
            if Thread.isMainThread {
                self?.handleVisionDetectionWithSource(detection, frame: frame)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.handleVisionDetectionWithSource(detection, frame: frame)
                }
            }
        }

        visionEngine.onTargetMeasurement = { [weak self] measurement in
            guard let self = self, !self.isShowingSettings else { return }
            self.handleVisualTargetTracked(measurement)
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
            self.currentZoom = zoom
            let disp = self.cameraService.convertDeviceZoomToDisplayZoom(zoom)
            self.liveZoomFactorForReveal = disp
            self.displayZoom = disp
            if self.isPinchingZoom {
                self.selectedZoomPreset = disp < 1.5 ? 1.0 : (disp < 2.5 ? 2.0 : 3.0)
            }
            SpatialTrackingEngine.shared.updateZoomFactor(disp)
            self.finishManualZoomIfSettled(zoom)
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

        cameraService.onAudioLevelsUpdated = { [weak self] left, right in
            guard let self = self, self.showAudioLevelMeter, !self.isCameraHibernating else { return }
            self.audioLevels = (left, right)
        }
    }

    public func togglePhotoFormat() {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut(duration: 0.2)) {
            switch selectedPhotoFormat {
            case .jpeg: selectedPhotoFormat = .heif
            case .heif, .heic: selectedPhotoFormat = .dng
            case .dng: selectedPhotoFormat = .jpeg
            }
        }
    }

    public func selectCaptureMode(_ mode: CameraCaptureMode) {
        guard mode != captureMode || pendingCaptureMode != nil else { return }
        modeTransitionGeneration &+= 1
        let generation = modeTransitionGeneration
        pendingCaptureMode = mode
        if isShutterPressing || recordingState != .idle || wantsVideoRecording {
            if wantsVideoRecording || recordingState != .idle {
                wantsVideoRecording = false
                cameraService.stopRecordingVideo()
            }
            return
        }
        if !isCameraReady {
            return
        }
        if aiSessionState != .idle {
            cancelAISession()
        }
        if isAIVideoDirectorActive {
            dismissAIVideoDirector()
        }
        isModeTransitionInFlight = true
        cameraService.updateCaptureMode(mode) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.modeTransitionGeneration == generation else { return }
                self.isModeTransitionInFlight = false
                self.pendingCaptureMode = nil
                if success {
                    self.captureMode = mode
                } else {
                    self.saveErrorMessage = "Không thể chuyển chế độ camera. Vui lòng thử lại."
                }
                self.presentPendingMediaPreviewIfPossible()
            }
        }
    }

    private func applyPendingCaptureModeIfPossible() {
        guard isCameraReady, !isShutterPressing, recordingState == .idle, !wantsVideoRecording,
              !isModeTransitionInFlight, let mode = pendingCaptureMode else { return }
        selectCaptureMode(mode)
    }

    public var canSwitchCamera: Bool {
        isCameraReady && !isCameraHibernating && !isShutterPressing &&
        recordingState == .idle && !wantsVideoRecording &&
        pendingCaptureMode == nil && !isSwitchingCamera
    }

    public func switchCamera(completion: @escaping (Bool) -> Void = { _ in }) {
        guard canSwitchCamera else { completion(false); return }
        isSwitchingCamera = true
        if aiSessionState != .idle {
            cancelAISession()
        }
        cameraService.switchCamera { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { completion(false); return }
                self.isSwitchingCamera = false
                if success {
                    self.proVideoService.syncHardwareCapabilities()
                    self.haptics.triggerSelectionChange()
                }
                completion(success)
            }
        }
    }

    public func toggleVideoCodec() {
        guard recordingState == .idle, !wantsVideoRecording else { return }
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedVideoCodec = (selectedVideoCodec == .hevc) ? .h264 : .hevc
        }
    }

    public func toggleVideoFormat() {
        guard recordingState == .idle, !wantsVideoRecording else { return }
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
        SpatialTrackingEngine.shared.prepare()
        // Động cơ Tracking Không Gian Chuẩn Xác: Thống nhất một callback duy nhất
        SpatialTrackingEngine.shared.onSpatialTargetUpdated = { [weak self] point, _, quality in
            guard let self = self, !self.isShowingSettings else { return }
            // Vòng vàng luôn bám vật thể (kể cả trong lúc zoom reveal) để không nhảy sau khi zoom
            self.currentTargetPoint = point
            // Quality describes evidence, not the colour/lifetime of the guide.
            // A predicted bearing remains visible without pretending it is optical.
            let seeding = quality == .reacquiring && self.latestOpticalPoint == nil &&
                CACurrentMediaTime() - self.targetPinStartedAt < 1.2
            self.trackingQuality = seeding ? .predicting : quality
            // Chỉ đánh giá alignment & countdown khi đang ở phase targetPlaced
            switch self.aiSessionState {
            case .targetPlaced, .alignmentPerfect:
                self.evaluateAlignment(at: point)
            default: break
            }
        }
    }

    // Nạp thông số chống nhảy đột biến & ngưỡng nhận confidence của ViewModel (theo trackingSensitivity)
    // xuống engine spatial
    private func applyTrackingSensitivityToEngines() {
        SpatialTrackingEngine.shared.maxObservationJump = maxJumpPerFrame
        SpatialTrackingEngine.shared.opticalAcceptThreshold = confidenceAcceptThreshold
    }

    // MARK: - AI Session Control (One-Shot Trigger)

    /// Bắt đầu phiên AI khi người dùng bấm nút AI — chỉ phân tích ĐÚNG 1 LẦN duy nhất
    public func startAISession() {
        guard captureMode == .photo, pendingCaptureMode == nil,
              isCameraReady, !isCameraHibernating,
              !isShutterPressing, recordingState == .idle,
              (aiSessionState == .idle || aiSessionState == .done) else { return }
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinZoomPlanTask?.cancel()
        pinZoomPlanTask = nil
        isPreparingPinZoom = false
        if zoomAwaitingVerification || zoomFallbackAfter.isFinite { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        haptics.triggerSelectionChange()
        self.aiSessionGeneration += 1
        let requestGeneration = self.aiSessionGeneration

        // Reset state
        SpatialTrackingEngine.shared.stopTracking()
        visionEngine.stopTrackingObject()
        visionEngine.onFrameCapturedForAI = nil
        visionEngine.onFrameCapturedForAIWithSource = nil
        visionEngine.capturedGeminiFrame = nil
        cloudTrackingSource = nil
        localTrackingSource = nil
        localCompositionChoices = []
        localEvidenceCandidates = []
        postZoomFaceCount = 0
        localAnalysisExpired = false
        localAnalysisFinished = false
        localSuggestionRects = []
        localSelectionMessage = nil
        allowsAutoCaptureForCurrentTarget = true
        lastAutoZoomExecutionTime = .distantPast
        zoomAwaitingVerification = false
        zoomVerified = true
        zoomFallbackAfter = .infinity
        postZoomFaceMinimumTimestamp = -Double.infinity
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        isGeminiAnalyzing = false
        initialTargetPoint = nil
        currentTargetPoint = nil
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

        if useGeminiForAnalysis && geminiService.hasAPIKey {
            // Keep the exact camera frame and CoreMotion pose used by Gemini.
            visionEngine.onFrameCapturedForAIWithSource = { [weak self] frame, buffer, context in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.visionEngine.capturedGeminiFrame = nil
                    if self.aiSessionGeneration == requestGeneration && self.aiSessionState == .analyzing && !self.isOneShotCaptured {
                        self.isOneShotCaptured = true
                        guard let buffer, let context,
                              let pose = SpatialTrackingEngine.shared.pose(at: context.timestamp) else {
                            self.geminiError = "Không đồng bộ được khung hình AI với chuyển động camera"
                            self.localSelectionMessage = "Không có ảnh đồng bộ. Chạm vùng muốn chụp hoặc chụp tay."
                            return
                        }
                        let nearbyDetection = self.latestSubjectDetectionResult
                        self.cloudTrackingSource = AITrackingSource(
                            buffer: buffer, frame: context, pose: pose,
                            subjectRect: nearbyDetection?.dominantSubjectRect,
                            faceRects: nearbyDetection?.faceRectangles ?? [])
                        // This cloud buffer is detached from AVCapture's pool.
                        // Drop the last local pool buffer while Gemini runs.
                        self.localTrackingSource = nil
                        self.callGeminiAnalysis(frame: frame)
                    }
                }
            }

            // If no camera frame arrives, use the local analysis instead of
            // leaving the session in .analyzing indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self = self else { return }
                if self.aiSessionGeneration == requestGeneration && self.aiSessionState == .analyzing && !self.isOneShotCaptured {
                    self.isOneShotCaptured = true
                    self.localSelectionMessage = "Camera chưa gửi ảnh AI. Chạm vùng muốn chụp hoặc chụp tay."
                }
            }
            // A captured frame can still be followed by a stalled cloud call.
            DispatchQueue.main.asyncAfter(deadline: .now() + geminiService.cloudAnalysisDeadline) { [weak self] in
                guard let self, self.aiSessionGeneration == requestGeneration,
                      self.aiSessionState == .analyzing, self.isGeminiAnalyzing else { return }
                self.isGeminiAnalyzing = false
                self.geminiError = "Phân tích cloud quá thời gian, đã chuyển sang AI trên máy"
                self.analyzeCloudCaptureLocally()
            }
        } else {
            visionEngine.onFrameCapturedForAIWithSource = { [weak self] _, buffer, context in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.aiSessionGeneration == requestGeneration,
                          self.aiSessionState == .analyzing, !self.isOneShotCaptured else { return }
                    self.isOneShotCaptured = true
                    self.visionEngine.capturedGeminiFrame = nil
                    guard let buffer, let context,
                          let pose = SpatialTrackingEngine.shared.pose(at: context.timestamp) else {
                        self.localAnalysisFinished = true
                        self.localSelectionMessage = "Không đồng bộ được ảnh và cảm biến. Chạm vùng muốn chụp."
                        return
                    }
                    let source = AITrackingSource(buffer: buffer, frame: context, pose: pose,
                                                  subjectRect: nil, faceRects: [])
                    self.beginLocalCompositionAnalysis(source: source)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.aiSessionGeneration == requestGeneration,
                      self.aiSessionState == .analyzing,
                      !self.localAnalysisFinished else { return }
                self.localAnalysisExpired = true
                self.localAnalysisCancellation?.cancel()
                self.localAnalysisTask?.cancel()
                self.localTrackingSource = nil
                self.localCompositionChoices = []
                self.localSuggestionRects = []
                self.localSelectionMessage = "AI quá thời gian. Chạm vùng muốn chụp hoặc chụp tay."
            }
        }
        // Register the callback before admitting the capture frame.
        visionEngine.captureNextFrameForGemini = true
    }

    public func cancelAISession() {
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinZoomPlanTask?.cancel()
        pinZoomPlanTask = nil
        isPreparingPinZoom = false
        self.aiSessionGeneration += 1
        if zoomAwaitingVerification || zoomFallbackAfter.isFinite { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        zoomAwaitingVerification = false
        zoomFallbackAfter = .infinity
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        visionEngine.stopTrackingObject()
        SpatialTrackingEngine.shared.stopTracking()
        haptics.triggerSelectionChange()
        visionEngine.captureNextFrameForGemini = false
        visionEngine.onFrameCapturedForAI = nil
        visionEngine.onFrameCapturedForAIWithSource = nil
        cloudTrackingSource = nil
        localTrackingSource = nil
        localEvidenceCandidates = []
        localCompositionChoices = []
        localSuggestionRects = []
        localSelectionMessage = nil
        isGeminiAnalyzing = false
        trackingQuality = .locked

        withAnimation(.easeInOut(duration: 0.3)) {
            aiSessionState = .idle
            initialTargetPoint = nil
            currentTargetPoint = nil
            isOneShotCaptured = false
            isPerfectAlignment = false
            alignmentDistance = 1.0
            detectedSubjectRects = []
            detectedFaceRects = []
            liveDetectedEntities = []
            activeEngineSource = nil
            arTrackingWarning = nil
        }
        liveEntitySmoother.reset()
    }

    /// Called when the camera overlay disappears or the app resigns active.
    /// A resumed CoreMotion reference frame must not inherit the old world ray.
    public func suspendSpatialTracking() {
        isPinchingZoom = false
        pendingManualZoomTarget = nil
        manualZoomRequestID = nil
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinZoomPlanTask?.cancel()
        pinZoomPlanTask = nil
        isPreparingPinZoom = false
        aiSessionGeneration += 1
        if zoomAwaitingVerification || zoomFallbackAfter.isFinite { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        zoomAwaitingVerification = false
        zoomFallbackAfter = .infinity
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        visionEngine.stopTrackingObject()
        visionEngine.captureNextFrameForGemini = false
        visionEngine.onFrameCapturedForAI = nil
        visionEngine.onFrameCapturedForAIWithSource = nil
        cloudTrackingSource = nil
        localTrackingSource = nil
        isGeminiAnalyzing = false
        SpatialTrackingEngine.shared.suspend()
        initialTargetPoint = nil
        currentTargetPoint = nil
        isPerfectAlignment = false
        liveEntitySmoother.reset()
        liveDetectedEntities = []
        if aiSessionState != .capturing { aiSessionState = .idle }
    }

    // MARK: - AI Windowed Focal Length Auto-Framing
    public func applyAIWindowedFocalLengthRecommendation() {
        let targetMm: Double

        if let face = detectedFaceRects.first {
            // Có khuôn mặt trong khung hình -> Đánh giá kích thước/khoảng cách
            let faceHeight = face.height
            if faceHeight < 0.20 {
                // Mặt nhỏ, chủ thể ở xa -> Tiêu cự chân dung nén viền 85mm
                targetMm = 85.0
            } else if faceHeight < 0.35 {
                // Mặt cỡ vừa -> Tiêu cự mắt người chuẩn 50mm
                targetMm = 50.0
            } else {
                // Cận cảnh lớn -> Tiêu cự đời thường 35mm
                targetMm = 35.0
            }
        } else {
            switch detectedScene {
            case .portrait:
                targetMm = 85.0
            case .macro, .food:
                targetMm = 50.0
            case .street, .pet:
                targetMm = 50.0
            case .landscape, .sunset, .architecture, .sky, .water, .foliage:
                targetMm = 28.0
            case .night:
                targetMm = 35.0
            case .general:
                targetMm = 35.0
            }
        }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) {
            self.windowedZoomFocalLength = targetMm
            self.isAIWindowedFocalRecommended = true
        }
        self.haptics.triggerSuccess()
        CameraLogger.info("AI Windowed Zoom đề xuất tiêu cự: \(Int(targetMm))mm cho bối cảnh \(self.detectedScene.rawValue)", category: .ai)
    }

    // MARK: - Vision & Gemini One-Shot Handling

    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        self.latestSubjectDetectionResult = detection

        if showDetectionBoxes || !detection.detectedEntities.isEmpty {
            let smoothed = liveEntitySmoother.update(with: detection.detectedEntities)
            self.liveDetectedEntities = smoothed
            self.detectedFaceRects = smoothed.filter { $0.category == .face }.map { $0.rect }
            self.detectedSubjectRects = smoothed.map { $0.rect }
        } else {
            self.detectedFaceRects = detection.faceRectangles
            if let dominant = detection.dominantSubjectRect {
                self.detectedSubjectRects = [dominant]
            }
        }

        switch aiSessionState {
        case .idle, .done:
            // Khi o che do idle: cap nhat canh de xu ly bo cuc
            self.detectedScene = detection.detectedScene
            return

        case .capturing:
            return

        case .targetPlaced, .alignmentPerfect:
            // Chuoi Vision bam vat the van chay rieng va hieu chinh huong the gioi qua onTargetMeasurement
            return

        case .analyzing:
            // Giai doan phan tich 1 lan (One-shot)
            handleAnalyzingPhase(detection)
        }
    }

    private func handleAnalyzingPhase(_ detection: SubjectDetectionResult) {
        guard !isOneShotCaptured else { return }

        self.detectedScene = detection.detectedScene
        self.detectedFaceRects = detection.faceRectangles
        if let dominant = detection.dominantSubjectRect {
            self.detectedSubjectRects = [dominant]
        }

        // 1. Cloud capture is delivered with its exact buffer and frame context
        // through onFrameCapturedForAIWithSource; do not launch from the legacy
        // image-only cache, which could lose the capture pose.
        if useGeminiForAnalysis && geminiService.hasAPIKey {
            return
        }

        // A detached one-shot image is analyzed separately; live detections
        // are only lightweight preview evidence and cannot select a target.
    }

    // MARK: - Gemini Analysis (One-shot)

    private func normalizedSubjectRect(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.minX.isFinite, rect.minY.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= 1, rect.maxY <= 1 else { return nil }
        return rect
    }

    private func callGeminiAnalysis(frame: CGImage) {
        guard !isGeminiAnalyzing else { return }
        isGeminiAnalyzing = true
        let requestGeneration = self.aiSessionGeneration

        let subjectRect = normalizedSubjectRect(cloudTrackingSource?.subjectRect)
        let faceRects = cloudTrackingSource?.faceRects ?? []

        geminiService.analyzeForComposition(
            image: frame,
            sceneContext: self.detectedScene,
            subjectRect: subjectRect,
            faceRects: faceRects
        ) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.aiSessionGeneration == requestGeneration, self.aiSessionState == .analyzing else {
                    CameraLogger.info("Bỏ qua phản hồi Gemini trễ (phiên đã đổi/kết thúc)", category: .ai)
                    return
                }
                guard self.isGeminiAnalyzing else { return }
                self.isGeminiAnalyzing = false
                switch result {
                case .success(let response):
                    self.handleGeminiResponse(response)
                case .failure(let error):
                    self.geminiError = error.localizedDescription
                    if case .insufficientCredits = error {
                        self.useGeminiForAnalysis = false
                    } else if case .invalidAPIKey = error {
                        self.useGeminiForAnalysis = false
                    }
                    self.analyzeCloudCaptureLocally()
                }
            }
        }
    }

    private func handleGeminiResponse(_ response: GeminiFramingResponse) {
        guard response.targetX.isFinite, response.targetY.isFinite,
              (0...1).contains(response.targetX), (0...1).contains(response.targetY),
              response.suggestedZoom.isFinite, response.suggestedZoom > 0 else {
            geminiError = "AI trả về tọa độ hoặc mức zoom không hợp lệ; đã chuyển sang AI trên máy"
            analyzeCloudCaptureLocally()
            return
        }
        self.geminiColorRecipe = response.colorRecipe
        self.geminiExplanation = response.explanation
        self.detectedScene = response.sceneType
        self.postZoomFaceCount = cloudTrackingSource?.faceRects.count ?? 0
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
        let subjectRect = normalizedSubjectRect(cloudTrackingSource?.subjectRect)

        // Nếu Gemini trả về tọa độ trung tâm (0.5, 0.5) nhưng ta có chủ thể thực tế rõ ràng phát hiện lệch tâm,
        // ưu tiên gắn target vào chủ thể để người dùng căn trúng chủ thể & zoom đẹp mắt!
        if let sRect = subjectRect, abs(targetPoint.x - 0.5) < 0.05 && abs(targetPoint.y - 0.5) < 0.05 {
            let sCenter = CGPoint(x: sRect.midX, y: sRect.midY)
            if abs(sCenter.x - 0.5) > 0.08 || abs(sCenter.y - 0.5) > 0.08 {
                targetPoint = sCenter
            }
        }

        pinTargetAndStartMotion(at: targetPoint, subjectRect: subjectRect,
                                source: cloudTrackingSource,
                                trackedPoint: subjectRect.map { CGPoint(x: $0.midX, y: $0.midY) })
        cloudTrackingSource = nil
        localTrackingSource = nil
    }

    // MARK: - Local Neural Engine Analysis (One-shot)

    private func analyzeCloudCaptureLocally() {
        guard let source = cloudTrackingSource else {
            localSelectionMessage = "Không có ảnh nguồn để phân tích. Chạm vùng muốn chụp hoặc chụp tay."
            return
        }
        cloudTrackingSource = nil
        beginLocalCompositionAnalysis(source: source)
        let generation = aiSessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.aiSessionGeneration == generation,
                  self.aiSessionState == .analyzing,
                  !self.localAnalysisFinished else { return }
            self.localAnalysisExpired = true
            self.localAnalysisCancellation?.cancel()
            self.localAnalysisTask?.cancel()
            self.localTrackingSource = nil
            self.localSelectionMessage = "AI trên máy quá thời gian. Chạm vùng muốn chụp hoặc chụp tay."
        }
    }

    // MARK: - State for Hybrid Optical + Spatial Tracking
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
        visionEngine.isLowTextureAnchor = isCurrentlyLowTexture
        CameraLogger.info("Texture Variance: \(String(format: "%.2f", variance)) -> LowTexture (Ưu tiên Gyro): \(isCurrentlyLowTexture ? "BẬT" : "TẮT")", category: .tracking)
    }

    private func computeTextureVariance(pixelBuffer: CVPixelBuffer, normalizedRect: CGRect) -> Double {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return 1000 }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                     format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return 1000 }
        let address = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let baseAddress = address else { return 1000 }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
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
                let offset = y * bytesPerRow + x * (planar ? 1 : 4)
                if planar {
                    let value = Double(buffer[offset])
                    values.append(format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ?
                                  max(0, min(255, (value - 16) * 255 / 219)) : value)
                } else if offset + 2 < bytesPerRow * height {
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
        allowsAutoCaptureForCurrentTarget = true
        pinTargetAndStartMotion(at: target, subjectRect: subjectRect, source: nil)
    }

    /// Tinh chinh tam target khi da ghim (Target Placed) ma khong tao target moi
    public func adjustTargetPoint(to newPoint: CGPoint) {
        guard case .targetPlaced = aiSessionState else { return }
        let clamped = CGPoint(x: max(0.05, min(0.95, newPoint.x)),
                              y: max(0.05, min(0.95, newPoint.y)))
        pinTargetAndStartMotion(at: clamped)
    }

    private func beginLocalCompositionAnalysis(source: AITrackingSource) {
        localAnalysisCancellation?.cancel()
        localAnalysisTask?.cancel()
        let cancellation = CompositionAnalysisCancellation()
        localAnalysisCancellation = cancellation
        localTrackingSource = source
        localAnalysisExpired = false
        localAnalysisFinished = false
        let generation = aiSessionGeneration
        let zooms = cameraService.availableDisplayZoomOptions
        localAnalysisTask = Task { [weak self] in
            let preferences = await CompositionPreferenceStore.shared.bonuses()
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    NeuralSubjectIntelligenceEngine.shared.analyzeComposition(
                        pixelBuffer: source.buffer, frame: source.frame, pose: source.pose,
                        allowedZooms: zooms, preferences: preferences, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            guard let self, !Task.isCancelled, !cancellation.isCancelled,
                  self.aiSessionGeneration == generation, self.aiSessionState == .analyzing,
                  !self.localAnalysisExpired, let result else { return }
            self.localAnalysisTask = nil
            self.localAnalysisCancellation = nil
            self.finishLocalAnalysis(result, source: source)
        }
    }

    private func finishLocalAnalysis(_ analysis: LocalCompositionAnalysis, source: AITrackingSource) {
        localAnalysisFinished = true
        guard source.frame.displayZoom.isFinite, source.frame.displayZoom > 0,
              abs(displayZoom - CGFloat(source.frame.displayZoom)) <= 0.08 else {
            localTrackingSource = nil
            localSelectionMessage = "Ống kính đã đổi trong lúc AI phân tích. Chạm vùng muốn chụp hoặc chạy AI lại."
            return
        }
        let output = analysis.detection
        detectedScene = output.detectedScene
        detectedFaceRects = output.allFaceRects
        postZoomFaceCount = output.allFaceRects.count
        let localPreset = output.detectedScene.recommendedFilter
        aiRecommendedPreset = localPreset
        aiPresetMatchReason = "\(localPreset.displayName) — Gợi ý theo bối cảnh \(output.detectedScene.localizedName)"
        if selectedFilmPreset.isAIFullAuto { selectedFilmPreset = localPreset }
        if isAIFullColorEnabled { currentAIColorParams = output.detectedScene.aiFullColorParameters }
        localCompositionChoices = analysis.choices
        localEvidenceCandidates = analysis.choices.isEmpty ? analysis.fallbackCandidates : analysis.choices.map(\.candidate)
        if let currentFrame = frameProcessor.latestTrackingFrameSnapshot()?.1,
           let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                ?? SpatialTrackingEngine.shared.latestPose() {
            localSuggestionRects = localEvidenceCandidates.map {
                reprojectSuggestion($0.boundingBox, from: source,
                                    to: currentFrame.calibration, pose: currentPose)
            }
        } else {
            localSuggestionRects = localEvidenceCandidates.map { _ in CGRect.zero }
        }
        detectedSubjectRects = localSuggestionRects
        if output.usedSemanticModel {
            activeEngineSource = .semanticLocal(label: output.detectedScene.localizedName)
        } else if YOLODetectionEngine.shared.hasYOLOModel {
            activeEngineSource = .yoloNeural(label: output.detectedScene.localizedName)
        } else {
            activeEngineSource = .appleNeuralEngine(scene: output.detectedScene.localizedName)
        }
        // Detector certainty and layout ranking are separate. Close alternatives
        // require an explicit choice; a high semantic score cannot authorize a shot.
        if let first = localCompositionChoices.first,
           first.plan.confidence >= first.plan.minimumAutoselectConfidence, first.plan.score >= 0.6,
           localCompositionChoices.count == 1 ||
                first.plan.score - localCompositionChoices[1].plan.score >= 0.06 {
            acceptLocalPlan(first.plan, source: source)
        } else if !localCompositionChoices.isEmpty {
            localSelectionMessage = "Chọn khung bạn muốn chụp."
            showCompositionPreviews()
        } else if !localEvidenceCandidates.isEmpty {
            localSelectionMessage = "Chưa đủ dữ liệu để chọn khung. Chạm vùng đánh dấu để căn và chụp tay."
        } else {
            localSelectionMessage = "Chưa có mốc rõ để căn máy. Thử hướng máy sang vùng có chi tiết hoặc chụp tay."
        }
    }

    func showCompositionPreviews() {
        guard aiSessionState == .analyzing, !localCompositionChoices.isEmpty,
              compositionPreviewPresentation == nil else { return }
        let presentation = CompositionPreviewPresentation()
        activeCompositionPreviewID = presentation.id
        selectedCompositionPreviewID = nil
        compositionPreviewPresentation = presentation
    }

    func selectCompositionPreview(id: UUID) {
        guard activeCompositionPreviewID != nil,
              localCompositionChoices.contains(where: { $0.id == id }) else { return }
        selectedCompositionPreviewID = id
        compositionPreviewPresentation = nil
    }

    func cancelCompositionPreview(id: UUID) {
        guard activeCompositionPreviewID == id else { return }
        cancelAISession()
    }

    func compositionPreviewDidDismiss(id: UUID) {
        // A dismissed sheet from an older session must not cancel a newer one.
        guard activeCompositionPreviewID == id else { return }
        activeCompositionPreviewID = nil
        let selection = selectedCompositionPreviewID
        selectedCompositionPreviewID = nil
        if let selection { chooseLocalComposition(id: selection) }
        else { cancelAISession() }
    }

    func chooseLocalComposition(id: UUID) {
        guard aiSessionState == .analyzing,
              let choice = localCompositionChoices.first(where: { $0.id == id }),
              let source = localTrackingSource else { return }
        guard abs(displayZoom - CGFloat(source.frame.displayZoom)) <= 0.08,
              CACurrentMediaTime() - source.frame.timestamp <= 30 else {
            localCompositionChoices = []
            localEvidenceCandidates = []
            localSuggestionRects = []
            localTrackingSource = nil
            localSelectionMessage = "Khung gợi ý đã cũ hoặc ống kính đã đổi. Bấm AI để phân tích lại."
            return
        }
        let keys = localCompositionChoices.map(\.plan.preferenceKey)
        let selected = choice.plan.preferenceKey
        Task { await CompositionPreferenceStore.shared.record(keys: keys, selected: selected) }
        acceptLocalPlan(choice.plan, source: source)
    }

    public func chooseLocalSuggestion(at point: CGPoint) {
        guard case .analyzing = aiSessionState else { return }
        if let index = localSuggestionRects.firstIndex(where: {
            !$0.isEmpty && $0.insetBy(dx: -0.025, dy: -0.025).contains(point)
        }), index < localEvidenceCandidates.count, let source = localTrackingSource {
            if localCompositionChoices.indices.contains(index) {
                chooseLocalComposition(id: localCompositionChoices[index].id)
            } else {
                let candidate = localEvidenceCandidates[index]
                localCompositionChoices = []
                localEvidenceCandidates = []
                localSuggestionRects = []
                detectedSubjectRects = []
                // Allow auto capture for the user-selected framing candidate
                allowsAutoCaptureForCurrentTarget = true
                pendingSuggestedZoom = displayZoom
                pinTargetAndStartMotion(at: candidate.center, subjectRect: candidate.boundingBox, source: source)
                localTrackingSource = nil
                localSelectionMessage = nil
            }
        } else {
            userDidTapToFocus(at: point)
        }
    }

    private func acceptLocalPlan(_ plan: LocalFramingPlan, source: AITrackingSource) {
        let dx = plan.aimPointInSource.x - 0.5
        let dy = plan.aimPointInSource.y - 0.5
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        activeCompositionRule = plan.usesCenter ? .centerSymmetry : .ruleOfThirds
        localCompositionIntent = plan.intent
        localCompositionExplanation = plan.explanation
        framingResult = FramingTargetResult(targetPoint: plan.aimPointInSource,
            currentCenter: CGPoint(x: 0.5, y: 0.5),
            offsetVector: CGVector(dx: dx, dy: dy), distance: distance,
            angleDegrees: angle < 0 ? angle + 360 : angle,
            alignmentScore: max(0, min(1, 1 - Double(distance / 0.40))),
            isAligned: distance <= calculator.alignmentTolerance,
            recommendedZoomFactor: plan.zoom, optimalRule: activeCompositionRule,
            guideDescription: plan.explanation)
        pendingSuggestedZoom = plan.zoom
        aiSuggestedZoom = plan.zoom
        hasExecutedAutoZoomForSession = false
        allowsAutoCaptureForCurrentTarget = plan.confidence >= plan.minimumAutoselectConfidence
        localCompositionChoices = []
        localEvidenceCandidates = []
        localSuggestionRects = []
        detectedSubjectRects = []
        localSelectionMessage = nil
        pinTargetAndStartMotion(at: plan.aimPointInSource,
            subjectRect: plan.subjectRect, source: source,
            trackedPoint: plan.subjectPoint, pinnedGuideRay: plan.aimWorldRay)
        localTrackingSource = nil
    }

    var localCompositionNeedsLevel: Bool {
        (localCompositionIntent == .landscape || localCompositionIntent == .architecture ||
         localCompositionIntent == .environmentalPortrait) && abs(currentRollDegrees) > 3
    }

    var needsManualShutter: Bool {
        !isAutoCaptureOnAlignEnabled || !allowsAutoCaptureForCurrentTarget
    }

    var alignmentStatusText: String {
        if !isCameraReady { return "Đang chờ camera sẵn sàng…" }
        if isPinchingZoom || pendingManualZoomTarget != nil { return "Đang điều chỉnh zoom…" }
        if isPreparingPinZoom { return "Đang chọn mức zoom phù hợp…" }
        if zoomAwaitingVerification { return "Đang zoom và xác nhận lại chủ thể…" }
        if zoomFallbackAfter.isFinite { return "Đang khôi phục khung trước zoom…" }
        if needsManualShutter {
            return localSelectionMessage ?? "Chế độ chụp tay · Bấm nút chụp khi vừa ý"
        }
        if !zoomVerified { return "Chưa xác nhận được zoom · Có thể bấm chụp tay" }
        if !hasFreshOpticalLock { return "Đang xác nhận lại chủ thể trong ảnh…" }
        if localCompositionNeedsLevel { return "Giữ máy ngang để cân lại khung" }
        if autoCaptureTask != nil { return "Đang kiểm tra khung trước khi chụp…" }
        return isPerfectAlignment ? "Đã khớp · Giữ máy ổn định" : "Di chuyển tâm trắng vào vòng mục tiêu"
    }

    var captureStatusText: String {
        switch photoCapturePhase {
        case .preparing: return "Đang chuẩn bị camera…"
        case .exposing: return "Đang chụp…"
        case .processing: return "Đang xử lý ảnh…"
        }
    }

    private func pinTargetAndStartMotion(at target: CGPoint, subjectRect: CGRect?,
                                          source: AITrackingSource?,
                                          trackedPoint: CGPoint? = nil,
                                          pinnedGuideRay: SIMD3<Double>? = nil) {
        guard target.x.isFinite, target.y.isFinite,
              (0...1).contains(target.x), (0...1).contains(target.y) else { return }
        guard !captureMode.isVideo, aiSessionState != .capturing, !isCameraHibernating else { return }
        localAnalysisCancellation?.cancel()
        localAnalysisCancellation = nil
        localAnalysisTask?.cancel()
        localAnalysisTask = nil
        activeCompositionPreviewID = nil
        selectedCompositionPreviewID = nil
        compositionPreviewPresentation = nil
        localCompositionChoices = []
        localEvidenceCandidates = []
        localSuggestionRects = []
        localTrackingSource = nil
        if pinnedGuideRay == nil {
            localCompositionExplanation = ""
            localCompositionIntent = nil
        }
        isWindowedZoomActive = false
        let subjectRect = normalizedSubjectRect(subjectRect)
        let isManualRePin: Bool
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect: isManualRePin = true
        default: isManualRePin = false
        }
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinZoomPlanTask?.cancel()
        pinZoomPlanTask = nil
        isPreparingPinZoom = false
        let pinGeneration = targetPinGeneration
        targetPinStartedAt = CACurrentMediaTime()
        lastFailedCaptureOpticalTimestamp = -.infinity
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        isPerfectAlignment = false
        let hadZoomRamp = zoomAwaitingVerification || zoomFallbackAfter.isFinite
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        zoomAwaitingVerification = false
        zoomVerified = true
        zoomFallbackAfter = .infinity
        postZoomFaceMinimumTimestamp = -Double.infinity
        latestOpticalPoint = nil
        latestOpticalFrameTimestamp = -.infinity
        latestOpticalBox = nil
        latestOpticalCalibration = nil
        needsFocusOnTrackedSubject = false
        subjectBoundsInTrackingBox = nil
        pinTrackingBox = nil
        localSelectionMessage = nil
        if source == nil { postZoomFaceCount = 0 }
        if isManualRePin || hadZoomRamp { cameraService.cancelZoomRamp() }
        // Gemini's point belongs to its captured image. Convert it to a world
        // bearing from that image's pose, then project into the current frame.
        let selectedFrame = frameProcessor.latestTrackingFrameSnapshot()
        var pinPoint = target
        var pinnedWorldRay: SIMD3<Double>? = pinnedGuideRay
        var trackedSubjectRay: SIMD3<Double>?
        var hasCurrentProjection = source == nil
        if let source {
            let ray = pinnedGuideRay ?? source.pose.act(source.frame.calibration.deviceRay(at: target))
            pinnedWorldRay = ray
            if let trackedPoint {
                trackedSubjectRay = source.pose.act(source.frame.calibration.deviceRay(at: trackedPoint))
            }
            if let currentFrame = selectedFrame?.1,
               let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                    ?? SpatialTrackingEngine.shared.latestPose() {
                // Show the physical subject, not the offset composition aim.
                let reticleRay = trackedSubjectRay ?? ray
                let projected = currentFrame.calibration.project(
                    deviceRay: currentPose.inverse.act(reticleRay)).point
                if projected.x.isFinite, projected.y.isFinite {
                    pinPoint = projected
                    hasCurrentProjection = true
                }
            }
        }

        initialTargetPoint = pinPoint
        currentTargetPoint = pinPoint
        trackingQuality = hasCurrentProjection ? .locked : .reacquiring
        hasExecutedAutoZoomForSession = false

        // Local/cloud plans already use the source image and intended composition.
        // Replacing their zoom by a bbox-area heuristic invalidates the guide ray.
        // A direct user pin gets a fresh, crop-checked centred plan instead.
        if source == nil {
            let selectedRect = subjectRect ?? detectedSubjectRects.first(where: {
                $0.contains(target)
            }) ?? detectedFaceRects.first(where: { $0.contains(target) })
            let frame = selectedFrame?.1
            pendingSuggestedZoom = selectedRect.flatMap { rect in
                frame.map { LocalFramingGeometry.centeredZoom(subject: rect, aim: target,
                    companions: detectedFaceRects, scene: detectedScene, frame: $0,
                    currentZoom: displayZoom, allowedZooms: cameraService.availableDisplayZoomOptions) }
            } ?? displayZoom
            hasExecutedAutoZoomForSession = false
        }
        aiSuggestedZoom = pendingSuggestedZoom

        let dx = pinPoint.x - 0.5
        let dy = pinPoint.y - 0.5
        alignmentDistance = sqrt(dx * dx + dy * dy)

        // Đồng bộ phân loại cảnh quan cho Dynamic EKF & Deformable Nature Tracking
        visionEngine.currentSceneType = self.detectedScene
        // Thông báo cho Vision engine: anchor low-texture (vật trắng/đơn sắc) -> siết ngưỡng re-ID
        visionEngine.isLowTextureAnchor = isCurrentlyLowTexture
        SpatialTrackingEngine.shared.isStreetMode = isStreetTrackingModeEnabled
        SpatialTrackingEngine.shared.activeSceneType = self.detectedScene
        if let selectedFrame {
            SpatialTrackingEngine.shared.registerFrame(selectedFrame.1)
            SpatialTrackingEngine.shared.lockAnchor(at: pinPoint, zoom: CGFloat(SpatialTrackingEngine.shared.currentDisplayZoom),
                                                      timestamp: selectedFrame.1.timestamp,
                                                      calibration: selectedFrame.1.calibration,
                                                      pinnedWorldRay: pinnedWorldRay,
                                                      trackedSubjectRay: trackedSubjectRay)
        } else {
            SpatialTrackingEngine.shared.lockAnchor(at: pinPoint,
                zoom: CGFloat(SpatialTrackingEngine.shared.currentDisplayZoom),
                timestamp: CACurrentMediaTime(), pinnedWorldRay: pinnedWorldRay,
                trackedSubjectRay: trackedSubjectRay)
        }

        // 1. Đánh giá độ phẳng Texture & Đăng ký Vân tay Nơ-ron AI trước để xác định kích thước khung bám tối ưu
        let anchorTarget = source == nil ? pinPoint : (trackedPoint ?? target)
        if let buffer = source?.buffer ?? selectedFrame?.0 {
            shouldCheckTextureOnNextFrame = false
            let region = CGRect(x: max(0, anchorTarget.x - 0.08), y: max(0, anchorTarget.y - 0.08), width: 0.16, height: 0.16)
            let variance = computeTextureVariance(pixelBuffer: buffer, normalizedRect: region)
            applyTextureVarianceHysteresis(variance: variance)
        } else {
            shouldCheckTextureOnNextFrame = true
        }

        // 2. Khởi động Optical Tracking bám CHÍNH XÁC VÀO VẬT THỂ THẬT (Apple Vision VNTrackObjectRequest)
        // Khi vật thể là màu trắng/đơn sắc (isCurrentlyLowTexture): Mở rộng khung bám để bao quát đường viền cạnh tương phản với nền
        let isLow = isCurrentlyLowTexture
        self.initialPhysicalSubjectCenter = anchorTarget
        let initialSize: CGSize
        if let sRect = subjectRect {
            // The optical box is centred on the subject, never on the guide.
            let expandRatio: CGFloat = isLow ? 1.35 : 1.10
            let minBox: CGFloat = isLow ? 0.20 : 0.08
            let clampedW = min(0.60, max(minBox, sRect.width * expandRatio))
            let clampedH = min(0.60, max(minBox, sRect.height * expandRatio))
            initialSize = CGSize(width: clampedW, height: clampedH)
        } else {
            let targetSize: CGFloat = isLow ? 0.22 : 0.14
            initialSize = CGSize(width: targetSize, height: targetSize)
        }

        let seedBox = CGRect(x: anchorTarget.x - initialSize.width / 2,
                             y: anchorTarget.y - initialSize.height / 2,
                             width: initialSize.width, height: initialSize.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        pinTrackingBox = seedBox
        if let subjectRect { setSubjectCropBounds(subjectRect, seedBox: seedBox) }
        if source == nil, let selectedFrame, isAutoZoomEnabled {
            prepareDirectPinZoom(point: anchorTarget, snapshot: selectedFrame,
                                 knownSubject: subjectRect, pinGeneration: pinGeneration)
        }

        // A delayed Gemini response seeds appearance from its original image;
        // the spatial bearing already points into the current camera view.
        visionEngine.startTrackingObject(
            at: anchorTarget,
            size: initialSize,
            refiningBuffer: source?.buffer ?? selectedFrame?.0,
            orientation: .up,
            sourceTimestamp: source?.frame.timestamp ?? selectedFrame?.1.timestamp
        )

        // 3. Tự động đồng bộ đo sáng & lấy nét phần cứng (Hardware ISP AE/AF) vào đúng tâm mục tiêu
        // AE/AF coordinates belong to the *current* preview. The selected
        // subject box and tracking patch can belong to an older AI frame.
        let focusTarget: CGPoint?
        if let trackedSubjectRay, let currentFrame = selectedFrame?.1,
           let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                ?? SpatialTrackingEngine.shared.latestPose() {
            let projected = currentFrame.calibration.project(
                deviceRay: currentPose.inverse.act(trackedSubjectRay))
            focusTarget = projected.isInsideImage ? projected.point : nil
            needsFocusOnTrackedSubject = focusTarget == nil
        } else if trackedSubjectRay != nil {
            focusTarget = nil
            needsFocusOnTrackedSubject = true
        } else {
            focusTarget = subjectRect.map { CGPoint(x: $0.midX, y: $0.midY) } ??
                CGPoint(x: min(1, max(0, anchorTarget.x)),
                        y: min(1, max(0, anchorTarget.y)))
        }
        if let focusTarget {
            let devPoint = CameraService.convertUIPointToDevicePoint(focusTarget)
            cameraService.setSmartFocusAndExposure(at: devPoint)
        }

        withAnimation(.easeOut(duration: 0.15)) {
            aiSessionState = .targetPlaced(locked: true)
        }

    }

    private func setSubjectCropBounds(_ subject: CGRect, seedBox: CGRect) {
        guard seedBox.width > 0, seedBox.height > 0 else { return }
        subjectBoundsInTrackingBox = CGRect(x: (subject.minX - seedBox.minX) / seedBox.width,
            y: (subject.minY - seedBox.minY) / seedBox.height,
            width: subject.width / seedBox.width, height: subject.height / seedBox.height)
    }

    private func prepareDirectPinZoom(point: CGPoint,
        snapshot: (CVPixelBuffer, TrackingFrameContext), knownSubject: CGRect?, pinGeneration: UInt64) {
        isPreparingPinZoom = true
        let sourceFrame = snapshot.1
        let held = FaceVerificationFrame(buffer: snapshot.0)
        let scene = detectedScene
        let companions = detectedFaceRects
        let zoom = displayZoom
        let options = cameraService.availableDisplayZoomOptions
        pinZoomPlanTask = Task { [weak self] in
            let subject = await Task.detached(priority: .userInitiated) { () -> CGRect? in
                if let knownSubject { return knownSubject }
                guard let r = VisionFramingEngine.shared.refineAnchorBox(around: point,
                    in: held.buffer, orientation: .up) else { return nil }
                return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
            }.value
            guard let self, !Task.isCancelled, self.targetPinGeneration == pinGeneration,
                  !self.hasExecutedAutoZoomForSession else { return }
            self.isPreparingPinZoom = false
            if let subject, let seedBox = self.pinTrackingBox {
                self.setSubjectCropBounds(subject, seedBox: seedBox)
                self.pendingSuggestedZoom = LocalFramingGeometry.centeredZoom(subject: subject,
                    aim: point, companions: companions, scene: scene, frame: sourceFrame,
                    currentZoom: zoom, allowedZooms: options + [zoom * 1.5])
            } else {
                // No object extent is known: a modest crop around the explicitly
                // selected patch is the upper limit, not an arbitrary 3x guess.
                self.pendingSuggestedZoom = zoom * 1.5
            }
            self.pendingSuggestedZoom = self.cameraService.convertDeviceZoomToDisplayZoom(
                self.cameraService.convertDisplayZoomToDeviceZoom(self.pendingSuggestedZoom))
            self.aiSuggestedZoom = self.pendingSuggestedZoom
        }
        // A stalled semantic request must never strand alignment indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.targetPinGeneration == pinGeneration,
                  self.isPreparingPinZoom else { return }
            self.pinZoomPlanTask?.cancel()
            self.isPreparingPinZoom = false
            self.pendingSuggestedZoom = self.cameraService.convertDeviceZoomToDisplayZoom(
                self.cameraService.convertDisplayZoomToDeviceZoom(zoom * 1.5))
            self.aiSuggestedZoom = self.pendingSuggestedZoom
        }
    }

    // MARK: - Optical Visual Object Tracking Handler

    private func handleVisualTargetTracked(_ measurement: TrackingOpticalMeasurement) {
        // Tiếp nhận cập nhật cả trong alignmentPerfect (zoom reveal) để vòng vàng bám vật thể
        // xuyên suốt quá trình zoom — tránh nhảy vị trí khi zoom hoàn tất
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect:
            break
        default:
            return
        }
        guard measurement.frame.timestamp > latestOpticalFrameTimestamp else { return }
        // Only an observation accepted by fusion can unlock zoom or the shutter.
        SpatialTrackingEngine.shared.updateWithOpticalDetection(
            point: measurement.point, confidence: measurement.confidence,
            frame: measurement.frame, evidence: measurement.evidence)
        guard SpatialTrackingEngine.shared.lastAcceptedOpticalTimestamp == measurement.frame.timestamp else { return }
        latestOpticalFrameTimestamp = measurement.frame.timestamp
        latestOpticalPoint = measurement.point
        latestOpticalBox = measurement.subjectBox ?? CGRect(x: max(0, measurement.point.x - 0.06), y: max(0, measurement.point.y - 0.06), width: 0.12, height: 0.12)
        latestOpticalCalibration = measurement.frame.calibration
        if measurement.evidence == .reidentified {
            alignmentGate.reset()
            lastFailedCaptureOpticalTimestamp = -.infinity
            lastFailedCaptureAttemptTime = -.infinity
        }
        if zoomFallbackAfter.isFinite,
           PostZoomRecoveryPolicy.hasRestoredFrame(
               originalZoom: Double(zoomRevealStartDisplayZoom), hardwareZoom: Double(displayZoom),
               frameZoom: measurement.frame.displayZoom, frameTime: measurement.frame.timestamp,
               recoveryBegan: zoomFallbackAfter, now: CACurrentMediaTime()) {
            zoomVerified = true
            pendingSuggestedZoom = displayZoom
            aiSuggestedZoom = displayZoom
            // The original field of view has not introduced an AI crop.
            postZoomFaceMinimumTimestamp = -.infinity
            zoomFallbackAfter = .infinity
            postZoomRecovery.reset()
            alignmentGate.reset()
            localSelectionMessage = nil
        }
        if needsFocusOnTrackedSubject, measurement.confidence >= 0.55,
           (0...1).contains(measurement.point.x),
           (0...1).contains(measurement.point.y) {
            needsFocusOnTrackedSubject = false
            cameraService.setSmartFocusAndExposure(at:
                CameraService.convertUIPointToDevicePoint(measurement.point))
        }
        if shouldCheckTextureOnNextFrame, let target = currentTargetPoint ?? initialTargetPoint {
            shouldCheckTextureOnNextFrame = false
            let region = CGRect(x: max(0, target.x - 0.08), y: max(0, target.y - 0.08), width: 0.16, height: 0.16)
            let variance = computeTextureVariance(pixelBuffer: measurement.pixelBuffer, normalizedRect: region)
            applyTextureVarianceHysteresis(variance: variance)
        }

    }

    private var hasFreshOpticalLock: Bool {
        let age = CACurrentMediaTime() - latestOpticalFrameTimestamp
        guard pendingManualZoomTarget == nil else { return false }
        if (0...0.55).contains(age),
           latestOpticalCalibration?.isValid == true,
           let point = latestOpticalPoint,
           (0...1).contains(point.x), (0...1).contains(point.y) {
            return true
        }
        // Fallback: If Spatial Fusion has confirmed lock and target is on-screen
        let spatial = SpatialTrackingEngine.shared
        if spatial.isTrackingActive && (trackingQuality == .locked || trackingQuality == .predicting),
           let current = currentTargetPoint,
           (0...1).contains(current.x), (0...1).contains(current.y) {
            return true
        }
        return false
    }

    private func canZoomCurrentSubject(to target: CGFloat) -> Bool {
        guard let box = currentSubjectCropBox,
              displayZoom > 0, target > 0 else { return false }
        let k = latestOpticalCalibration ?? TrackingCalibration.fallback(zoom: Double(displayZoom))
        let ratio = target / displayZoom
        let cx = CGFloat(k.cx), cy = CGFloat(k.cy)
        return cx + (box.minX - cx) * ratio >= 0.015 &&
            cy + (box.minY - cy) * ratio >= 0.015 &&
            cx + (box.maxX - cx) * ratio <= 0.985 &&
            cy + (box.maxY - cy) * ratio <= 0.985
    }

    private var alignmentRadius: CGFloat {
        let aspect = max(0.1, SpatialTrackingEngine.shared.currentBufferAspect)
        let width = max(viewfinderSize.width, viewfinderSize.height * aspect)
        return width > 0 ? 16 / width : calculator.alignmentTolerance
    }

    private func evaluateAlignment(at point: CGPoint) {
        guard !captureMode.isVideo, !isCameraHibernating, !isShutterPressing else { return }
        if zoomFallbackAfter.isFinite, CACurrentMediaTime() - zoomFallbackAfter > 3 {
            zoomFallbackAfter = .infinity
            allowsAutoCaptureForCurrentTarget = true
            localSelectionMessage = "Chưa xác nhận được zoom. Bạn có thể bấm chụp tay hoặc căn lại mục tiêu."
        }
        let dx = point.x - 0.5, dy = point.y - 0.5
        let aspect = max(0.1, SpatialTrackingEngine.shared.currentBufferAspect)
        let distance = hypot(dx, dy / aspect)
        alignmentDistance = distance
        let state = alignmentGate.update(time: CACurrentMediaTime(), distance: Double(distance),
            radius: Double(alignmentRadius), freshEvidence: hasFreshOpticalLock && !isPinchingZoom)
        isPerfectAlignment = alignmentGate.isAligned && !localCompositionNeedsLevel
        guard state != .outside else {
            autoCaptureTask?.cancel(); autoCaptureTask = nil
            aiSessionState = .targetPlaced(locked: hasFreshOpticalLock)
            let angle = atan2(dy, dx) * 180 / .pi
            alignmentState = .guiding(distance: distance, angle: angle < 0 ? angle + 360 : angle)
            return
        }
        if localCompositionNeedsLevel {
            aiSessionState = .targetPlaced(locked: hasFreshOpticalLock)
            alignmentState = .guiding(distance: distance, angle: 0)
            return
        }
        aiSessionState = .alignmentPerfect
        alignmentState = .aligned(score: 1)
        guard state == .ready, hasFreshOpticalLock, !isPreparingPinZoom,
              !zoomAwaitingVerification else { return }
        if isAutoZoomEnabled && !hasExecutedAutoZoomForSession {
            let desired = cameraService.convertDeviceZoomToDisplayZoom(
                cameraService.convertDisplayZoomToDeviceZoom(pendingSuggestedZoom))
            if abs(desired - displayZoom) > 0.12 {
                let options = Array(Set(cameraService.availableDisplayZoomOptions +
                    [desired, displayZoom * 1.5, displayZoom * 1.25]))
                let safe = options.filter {
                    (desired > displayZoom ? ($0 > displayZoom + 0.12 && $0 <= desired + 0.01) :
                        ($0 < displayZoom - 0.12 && $0 >= desired - 0.01)) && canZoomCurrentSubject(to: $0)
                }
                if let target = desired > displayZoom ? safe.max() : safe.min() {
                    pendingSuggestedZoom = target; aiSuggestedZoom = target
                    applyAISuggestedZoom(target, force: true)
                    hasExecutedAutoZoomForSession = true
                    if zoomAwaitingVerification { return }
                }
            } else {
                hasExecutedAutoZoomForSession = true
            }
        }
        guard zoomVerified, !localCompositionNeedsLevel, isAutoCaptureOnAlignEnabled, allowsAutoCaptureForCurrentTarget,
              autoCaptureTask == nil,
              latestOpticalFrameTimestamp > lastFailedCaptureOpticalTimestamp,
              CACurrentMediaTime() - lastFailedCaptureAttemptTime >= 0.20 else { return }
        verifyAndCaptureWhenReady()
    }

    private func verifyAndCaptureWhenReady() {
        guard autoCaptureTask == nil else { return }
        let pinGeneration = targetPinGeneration
        autoCaptureTask = Task { [weak self] in
            guard let self else { return }
            let cropSafe = await self.currentCropSafeForCapture()
            guard !Task.isCancelled, self.targetPinGeneration == pinGeneration else { return }
            self.autoCaptureTask = nil
            if !cropSafe, self.postZoomFaceMinimumTimestamp.isFinite,
               self.postZoomRecovery.shouldRestoreOriginal(afterFailedCheckAt: CACurrentMediaTime()) {
                self.restoreOriginalZoomAfterVerificationFailure()
                return
            }
            if cropSafe { self.postZoomRecovery.reset() }
            if self.aiSessionState == .alignmentPerfect && !self.isShutterPressing &&
                self.hasFreshOpticalLock && self.alignmentGate.isAligned &&
                self.alignmentDistance <= self.alignmentRadius * 1.6 &&
                !self.zoomAwaitingVerification && self.zoomVerified &&
                !self.isPinchingZoom && !self.isPreparingPinZoom &&
                self.allowsAutoCaptureForCurrentTarget && self.isAutoCaptureOnAlignEnabled &&
                !self.localCompositionNeedsLevel && cropSafe {
                self.executeCapture()
            } else {
                self.lastFailedCaptureOpticalTimestamp = self.latestOpticalFrameTimestamp
                self.lastFailedCaptureAttemptTime = CACurrentMediaTime()
            }
        }
    }

    private func verifyZoomAfterRamp(pinGeneration: UInt64) async {
        let deadline = CACurrentMediaTime() + 2.5
        var reachedAt: TimeInterval?
        while CACurrentMediaTime() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard !Task.isCancelled, targetPinGeneration == pinGeneration,
                  !isPinchingZoom else { return }
            let reached = abs(displayZoom - pendingTargetZoomForReveal) <= 0.08
            if reached {
                if reachedAt == nil { reachedAt = CACurrentMediaTime() }
                if CACurrentMediaTime() - (reachedAt ?? 0) >= 0.12 {
                    // Zoom reached target and settled
                    zoomVerified = true
                    zoomAwaitingVerification = false
                    zoomFallbackAfter = .infinity
                    localSelectionMessage = nil

                    let point = currentTargetPoint ?? CGPoint(x: 0.5, y: 0.5)
                    latestOpticalPoint = point
                    latestOpticalFrameTimestamp = CACurrentMediaTime()
                    latestOpticalBox = CGRect(x: max(0, point.x - 0.08), y: max(0, point.y - 0.08), width: 0.16, height: 0.16)
                    latestOpticalCalibration = latestOpticalCalibration ?? TrackingCalibration.fallback(zoom: Double(displayZoom))
                    alignmentGate.reset()

                    withAnimation(.easeOut(duration: 0.35)) {
                        self.isRevealingZoomTarget = false
                        self.isZoomRampPhase = false
                    }
                    selectedZoomPreset = displayZoom < 1.5 ? 1.0 : (displayZoom < 2.5 ? 2.0 : 3.0)
                    return
                }
            } else {
                reachedAt = nil
            }
        }
        guard !Task.isCancelled, targetPinGeneration == pinGeneration else { return }
        // Ensure camera never remains stranded or blocked from capturing
        zoomVerified = true
        zoomAwaitingVerification = false
        zoomFallbackAfter = .infinity
        let point = currentTargetPoint ?? CGPoint(x: 0.5, y: 0.5)
        latestOpticalPoint = point
        latestOpticalFrameTimestamp = CACurrentMediaTime()
        latestOpticalBox = CGRect(x: max(0, point.x - 0.08), y: max(0, point.y - 0.08), width: 0.16, height: 0.16)
        alignmentGate.reset()
        withAnimation(.easeOut(duration: 0.30)) {
            self.isRevealingZoomTarget = false
            self.isZoomRampPhase = false
        }
    }

    private func restoreOriginalZoomAfterVerificationFailure() {
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        cameraService.cancelZoomRamp()
        zoomVerified = true
        zoomAwaitingVerification = false
        zoomFallbackAfter = .infinity
        alignmentGate.reset()
        postZoomRecovery.reset()
        withAnimation(.easeOut(duration: 0.30)) {
            self.isRevealingZoomTarget = false
            self.isZoomRampPhase = false
        }
    }

    // Retain an immutable camera-pool frame across the detached Vision request.
    private struct FaceVerificationFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private func verifyPostZoomFaces(after minimumTimestamp: TimeInterval) async -> Bool {
        guard postZoomFaceCount > 0 else { return true }
        guard let snapshot = frameProcessor.latestTrackingFrameSnapshot(),
              snapshot.1.timestamp > max(minimumTimestamp, latestOpticalFrameTimestamp - 0.5) else {
            return false
        }
        let frame = FaceVerificationFrame(buffer: snapshot.0)
        let cancellation = CompositionAnalysisCancellation()
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            cancellation.cancel()
        }
        defer { timeout.cancel() }
        let rectangles = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> [CGRect]? in
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: frame.buffer,
                                                    orientation: .up, options: [:])
                guard (try? cancellation.perform(request, with: handler)) != nil,
                      let results = request.results else { return nil }
                return results.filter { $0.confidence >= 0.35 }.map(\.boundingBox)
            }.value
        } onCancel: { cancellation.cancel() }
        guard !Task.isCancelled, let faces = rectangles,
              CACurrentMediaTime() - snapshot.1.timestamp <= 0.50 else { return false }
        return faces.count >= postZoomFaceCount && faces.allSatisfy {
            let r = $0
            return r.minX >= 0.02 && r.maxX <= 0.98 &&
                   r.minY >= 0.02 && r.maxY <= 0.98
        }
    }

    private var currentSubjectCropBox: CGRect? {
        let box = latestOpticalBox ?? (latestOpticalPoint ?? currentTargetPoint).map {
            CGRect(x: max(0, $0.x - 0.08), y: max(0, $0.y - 0.08), width: 0.16, height: 0.16)
        }
        guard let b = box else { return nil }
        guard let relative = subjectBoundsInTrackingBox else { return b }
        return CGRect(x: b.minX + relative.minX * b.width,
                      y: b.minY + relative.minY * b.height,
                      width: relative.width * b.width, height: relative.height * b.height)
    }

    private var currentSubjectBoxIsSafe: Bool {
        guard let box = currentSubjectCropBox,
              box.minX >= 0.02, box.maxX <= 0.98,
              box.minY >= 0.02, box.maxY <= 0.98 else { return false }
        return true
    }

    private func currentCropSafeForCapture() async -> Bool {
        guard hasFreshOpticalLock else { return false }
        return true
    }

    private func executeCapture() {
        guard captureMode == .photo, pendingCaptureMode == nil,
              isCameraReady, !isCameraHibernating,
              aiSessionState == .alignmentPerfect, !isShutterPressing else { return }
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        stateBeforeCapture = aiSessionState
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        // Dừng hẳn engine spatial — trước đây 60Hz gyro vẫn chạy nền sau khi chụp
        SpatialTrackingEngine.shared.stopTracking()

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        captureNativePhoto(highResolution: isSuperResolutionRAWEnabled)
    }

    // MARK: - Actions
    private var lastContinuousZoomTime: CFTimeInterval = 0
    private var lastContinuousAppliedZoom: CGFloat = 1.0

    public func beginManualZoomGesture() {
        guard !isPinchingZoom, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        isPinchingZoom = true
    }

    private func requestManualZoom(_ displayZoomVal: CGFloat) {
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        let requestID = UUID()
        manualZoomRequestID = requestID
        pendingManualZoomTarget = deviceZoom
        manualZoomSettledAt = CACurrentMediaTime()
        cameraService.setZoomFactor(deviceZoom) { [weak self] actualZoom in
            guard let self, self.manualZoomRequestID == requestID else { return }
            self.manualZoomRequestID = nil
            self.pendingManualZoomTarget = nil
            self.manualZoomSettledAt = CACurrentMediaTime()
            self.zoomVerified = actualZoom != nil
            self.alignmentGate.reset()
        }
    }

    public func setZoom(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        requestManualZoom(displayZoomVal)
    }

    /// Zoom liên tục mượt mà khi người dùng vuốt/pinch bằng hai ngón tay
    /// Tự động throttle AVFoundation calls (25ms) để chống nghẽn hàng đợi camera phần cứng
    public func setZoomContinuous(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        if !isPinchingZoom { beginManualZoomGesture() }
        selectedZoomPreset = displayZoomVal < 1.5 ? 1.0 : (displayZoomVal < 2.5 ? 2.0 : 3.0)
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        let now = CACurrentMediaTime()
        if now - lastContinuousZoomTime >= 0.025 || abs(deviceZoom - lastContinuousAppliedZoom) > 0.08 {
            lastContinuousZoomTime = now
            lastContinuousAppliedZoom = deviceZoom
            cameraService.setZoomFactor(deviceZoom)
        }
    }

    /// Chốt zoom cuối cùng khi người dùng nhấc ngón tay kết thúc pinch
    public func finishZoomGesture(_ finalDisplayZoom: CGFloat) {
        guard isCameraReady, !isShutterPressing, !isCameraHibernating else {
            isPinchingZoom = false
            return
        }
        guard finalDisplayZoom.isFinite else { return }
        if !isPinchingZoom { beginManualZoomGesture() }
        selectedZoomPreset = finalDisplayZoom < 1.5 ? 1.0 : (finalDisplayZoom < 2.5 ? 2.0 : 3.0)
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(finalDisplayZoom)
        lastContinuousAppliedZoom = deviceZoom
        isPinchingZoom = false
        requestManualZoom(finalDisplayZoom)
        haptics.triggerSelectionChange()
    }

    public func setZoomFromButton(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        haptics.triggerSelectionChange()
        selectedZoomPreset = displayZoomVal
        requestManualZoom(displayZoomVal)
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
        CameraLogger.info("\u{1f512} ĐÃ KHÓA AE/AF tại (\(String(format: "%.2f", normalizedPoint.x)), \(String(format: "%.2f", normalizedPoint.y)))", category: .capture)
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
        CameraLogger.info("\u{1f513} ĐÃ MỞ KHÓA AE/AF", category: .capture)
    }

    public func toggleFlash() {
        haptics.triggerSelectionChange()
        switch activeFlashMode {
        case .auto: activeFlashMode = .on
        case .on: activeFlashMode = .off
        case .off: activeFlashMode = .auto
        @unknown default: activeFlashMode = .auto
        }
    }

    public func selectRule(_ rule: CompositionRule) {
        haptics.triggerSelectionChange()
        withAnimation(.spring()) { activeCompositionRule = rule }
    }

    public func selectPreset(_ preset: FilmPreset) {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut) {
            if preset == .standard {
                isFilmSimulationActive = false
                selectedFilmPreset = .standard
                selectedFilmCategory = .original
            } else {
                isFilmSimulationActive = true
                selectedFilmPreset = preset
                selectedFilmCategory = preset.category
            }
            if preset.isAIFullAuto {
                isAIFullColorEnabled = true
            } else {
                isAIFullColorEnabled = false
                currentAIColorParams = nil
                geminiColorRecipe = nil
            }
        }
    }

    public func toggleFilmSimulation() {
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            isFilmSimulationActive.toggle()
            if !isFilmSimulationActive {
                isAIFullColorEnabled = false
            }
        }
    }

    public func disableFilmSimulation() {
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            isFilmSimulationActive = false
            isAIFullColorEnabled = false
        }
    }

    public func enableFilmSimulation(preset: FilmPreset? = nil) {
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            isFilmSimulationActive = true
            if let p = preset, p != .standard {
                selectedFilmPreset = p
                selectedFilmCategory = p.category
            }
            isAIFullColorEnabled = false
        }
    }

    public func selectFilmCategory(_ category: FilmPresetCategory) {
        haptics.triggerSelectionChange()
        withAnimation(.easeInOut) {
            selectedFilmCategory = category
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
        guard captureMode == .photo, pendingCaptureMode == nil,
              !isShutterPressing else { return }
        haptics.triggerSelectionChange()
        isLivePhotoEnabled.toggle()
        CameraLogger.info("Người dùng chuyển chế độ Live Photo: \(isLivePhotoEnabled ? "BẬT" : "TẮT")", category: .capture)
    }

    public func toggleVideoRecording() {
        if wantsVideoRecording {
            wantsVideoRecording = false
            haptics.triggerShutterClick()
            cameraService.stopRecordingVideo()
        } else {
            guard captureMode.isVideo, pendingCaptureMode == nil, isCameraReady,
                  !isCameraHibernating, !isShutterPressing else { return }
            wantsVideoRecording = true
            haptics.triggerShutterClick()
            cameraService.startRecordingVideo(codec: self.selectedVideoCodec)
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
        guard captureMode.isVideo, pendingCaptureMode == nil,
              isCameraReady, !isCameraHibernating else { return }
        videoDirectorGeneration &+= 1
        let generation = videoDirectorGeneration
        videoDirectorTimeoutTask?.cancel()
        videoDirectorTimeoutTask = nil
        videoGuidanceRequest?.cancel()
        videoGuidanceRequest = nil
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
        let scene = detectedScene
        let fallback = GeminiService.generateLocalVideoGuidance(
            sceneContext: scene,
            subjectRect: subjectRect,
            faceRects: faceRects,
            lookingDirection: lookDir
        )

        // Video data delivery is disabled during movie recording, so use the
        // last measured scene instead of waiting for a frame that cannot arrive.
        guard recordingState == .idle, !wantsVideoRecording,
              useGeminiForAnalysis, geminiService.hasAPIKey else {
            applyVideoGuidance(fallback)
            return
        }

        videoDirectorTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard let self, self.videoDirectorGeneration == generation,
                  self.isAIVideoDirectorActive, self.isAIVideoDirectorAnalyzing else { return }
            self.videoDirectorError = "Phân tích video quá thời gian; dùng hướng dẫn trên máy."
            self.applyVideoGuidance(fallback)
        }

        visionEngine.captureImmediateFrame { [weak self] cgImg in
            guard let self, self.videoDirectorGeneration == generation,
                  self.isAIVideoDirectorActive, self.isAIVideoDirectorAnalyzing else { return }
            guard let image = cgImg else {
                self.applyVideoGuidance(fallback)
                return
            }

            self.videoGuidanceRequest = self.geminiService.analyzeVideoCinematography(
                image: image,
                sceneContext: scene,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookDir
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.videoDirectorGeneration == generation,
                          self.isAIVideoDirectorActive, self.isAIVideoDirectorAnalyzing else { return }
                    switch result {
                    case .success(let guidance):
                        self.applyVideoGuidance(guidance)
                    case .failure(let err):
                        self.videoDirectorError = err.localizedDescription
                        if case .insufficientCredits = err {
                            self.useGeminiForAnalysis = false
                        } else if case .invalidAPIKey = err {
                            self.useGeminiForAnalysis = false
                        }
                        self.applyVideoGuidance(fallback)
                    }
                }
            }
        }
    }

    private func applyVideoGuidance(_ guidance: AIVideoDirectorGuidance) {
        videoDirectorTimeoutTask?.cancel()
        videoDirectorTimeoutTask = nil
        videoGuidanceRequest?.cancel()
        videoGuidanceRequest = nil
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
        videoDirectorGeneration &+= 1
        videoDirectorTimeoutTask?.cancel()
        videoDirectorTimeoutTask = nil
        videoGuidanceRequest?.cancel()
        videoGuidanceRequest = nil
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
    public func userDidTapToFocus(at normalizedPoint: CGPoint, devicePoint: CGPoint? = nil) {
        guard aiSessionState != .capturing, !isCameraHibernating else { return }
        if isAEAFLocked {
            unlockAEAF()
            return
        }

        // Che do Camera thuong: Cham vao man hinh CHI goi co che lay net/do sang native
        // Tuyet doi KHONG gan toa do, khong ve them hoac pin target tai day.
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
            // Auto capture needs current gravity even when its overlay is hidden.
            guard let self = self, let motion = motion, !self.isCameraHibernating else { return }
            let gx = Double(motion.gravity.x)
            let gy = Double(motion.gravity.y)
            let rawRoll = atan2(gx, -gy) * 180.0 / .pi
            let calibratedRoll = rawRoll - self.gyroRollOffsetDegrees
            self.currentRollDegrees = calibratedRoll
            // Separate entry/exit angles prevent repeated feedback at 0.8 degrees.
            let level = abs(calibratedRoll) <= (self.isDeviceLevel ? 1.3 : 0.8)
            let now = CACurrentMediaTime()
            if level && !self.isDeviceLevel && !self.hasTriggeredLevelHaptic {
                if self.isHorizonLevelerEnabled && self.isProximityHapticsEnabled && !self.isAISessionActive &&
                   !self.isShutterPressing && now - self.lastLevelHapticTime >= 2 {
                    self.haptics.triggerSelectionChange()
                    self.lastLevelHapticTime = now
                }
                self.hasTriggeredLevelHaptic = true
            } else if !level {
                self.hasTriggeredLevelHaptic = false
            }
            self.isDeviceLevel = level
        }
    }

    // MARK: - Gyro Calibration API
    public func applyGyroCalibration(rollOffset: Double, pitchOffset: Double) {
        self.gyroRollOffsetDegrees = rollOffset
        self.gyroPitchOffsetDegrees = pitchOffset
        self.lastGyroCalibrationDate = Date()
        DeviceMotionService.shared.recalibrateBaselines()
        SpatialTrackingEngine.shared.stopTracking()
        self.haptics.triggerSuccess()
        CameraLogger.info("Đã áp dụng hiệu chuẩn Gyro mới: RollOffset=\(String(format: "%.2f", rollOffset))°, PitchOffset=\(String(format: "%.2f", pitchOffset))°", category: .motion)
    }

    public func resetGyroCalibration() {
        self.gyroRollOffsetDegrees = 0.0
        self.gyroPitchOffsetDegrees = 0.0
        self.lastGyroCalibrationDate = nil
        UserDefaults.standard.removeObject(forKey: "gyroRollOffsetDegrees")
        UserDefaults.standard.removeObject(forKey: "gyroPitchOffsetDegrees")
        UserDefaults.standard.removeObject(forKey: "lastGyroCalibrationDate")
        DeviceMotionService.shared.recalibrateBaselines()
        SpatialTrackingEngine.shared.stopTracking()
        self.haptics.triggerSelectionChange()
        CameraLogger.info("Đã đặt lại thông số Gyro calibration về mặc định 0.0°", category: .motion)
    }

    public func applyFocusAndExposure(to point: CGPoint, source: SmartFocusType, force: Bool = false) {
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard point.x.isFinite, point.y.isFinite else { return }
        let dx = point.x - lastFocusPoint.x
        let dy = point.y - lastFocusPoint.y
        let dist = sqrt(dx * dx + dy * dy)

        // Chỉ trigger refocus & animation khi điểm focus thay đổi đáng kể (> 0.08) hoặc khi cảnh thay đổi (force)
        if dist > 0.08 || force {
            lastFocusPoint = point
            let devicePoint = CameraService.convertUIPointToDevicePoint(point)
            cameraService.setSmartFocusAndExposure(at: devicePoint)
            triggerFocusSquareAnimation(at: point)
        }
    }


    // MARK: - Manual Shutter Click (Nút chụp màu trắng)
    public func takePhotoManual() {
        if captureMode.isVideo {
            toggleVideoRecording()
            return
        }
        guard isCameraReady, !isCameraHibernating, pendingCaptureMode == nil,
              recordingState == .idle,
              !isShutterPressing, aiSessionState != .capturing else { return }
        if aiSessionState == .analyzing { cancelAISession() }
        pinZoomPlanTask?.cancel()
        isPreparingPinZoom = false
        zoomVerificationTask?.cancel()
        if zoomAwaitingVerification || zoomFallbackAfter.isFinite { cameraService.cancelZoomRamp() }
        zoomAwaitingVerification = false
        isRevealingZoomTarget = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        isPerfectAlignment = false
        stateBeforeCapture = aiSessionState
        visionEngine.stopTrackingObject()
        SpatialTrackingEngine.shared.stopTracking()

        // Cho phép chụp thủ công bất kỳ lúc nào (ngay cả khi chưa bật AI hoặc AI đã hoàn tất)

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        captureNativePhoto(highResolution: isSuperResolutionRAWEnabled)
    }

    private struct PhotoProcessingSettings {
        let preset: FilmPreset
        let scene: DetectedSceneType
        let rule: CompositionRule
        let params: AIColorParameters?
        let applyFilm: Bool
        let crop: Bool
        let focalLength: Double
        let aspect: WindowedZoomAspectRatio
        let score: Double
    }
    private var captureProcessingSettings: PhotoProcessingSettings?

    private func currentPhotoProcessingSettings() -> PhotoProcessingSettings {
        let apply = isFilmSimulationActive || isAIFullColorEnabled
        let preset: FilmPreset
        if !isFilmSimulationActive {
            preset = .standard
        } else {
            preset = selectedFilmPreset.isAIFullAuto ?
                (aiRecommendedPreset ?? detectedScene.recommendedFilter) : selectedFilmPreset
        }
        return PhotoProcessingSettings(preset: preset, scene: detectedScene, rule: activeCompositionRule,
            params: isAIFullColorEnabled ?
                (geminiColorRecipe?.asAIColorParameters ?? currentAIColorParams ?? detectedScene.aiFullColorParameters) : nil,
            applyFilm: apply, crop: isWindowedZoomActive, focalLength: windowedZoomFocalLength,
            aspect: windowedZoomAspectRatio,
            score: stateBeforeCapture == .alignmentPerfect ? 1 : (framingResult?.alignmentScore ?? 0.8))
    }

    private func captureNativePhoto(highResolution: Bool) {
        photoCapturePhase = .preparing
        captureProcessingSettings = currentPhotoProcessingSettings()
        cameraService.capturePhoto(isDNG: selectedPhotoFormat == .dng,
            isHEIF: selectedPhotoFormat == .heif || selectedPhotoFormat == .heic,
            highResolution: highResolution)
    }

    /// Encodes only edited, already-upright pixels. Unedited captures and DNG
    /// bypass this function and retain the camera's file, profile and metadata.
    private nonisolated static func encodeRenderedPhoto(_ image: CGImage,
        sourceData: Data?, format: PhotoSaveFormat) -> Data? {
        var metadata: [String: Any] = [:]
        if let data = sourceData, !SuperResolutionRAWEngine.isDNGData(data),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            metadata = properties
        }
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata[kCGImagePropertyPixelWidth as String] = image.width
        metadata[kCGImagePropertyPixelHeight as String] = image.height
        var tiff = (metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = (metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        metadata[kCGImagePropertyExifDictionary as String] = exif
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 0.96
        let type = format == .jpeg ? UTType.jpeg : UTType.heic
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }

    @discardableResult
    public nonisolated static func saveRawFileToAppSandbox(data: Data, filename: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let rawDirectory = documentsURL.appendingPathComponent("RAW", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: rawDirectory.path) {
                try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            let destinationURL = rawDirectory.appendingPathComponent(filename)
            try data.write(to: destinationURL, options: .atomic)
            CameraLogger.success("Lưu tệp RAW DNG nguyên bản vào ứng dụng: \(destinationURL.path)", category: .capture)
            return destinationURL
        } catch {
            CameraLogger.error("Lỗi lưu tệp RAW vào sandbox ứng dụng: \(error.localizedDescription)", category: .capture)
            return nil
        }
    }

    public func savePhotoToLibrary(_ item: CapturedPhotoItem, completion: ((Bool) -> Void)? = nil) {
        let saveOriginal = isSaveOriginalPhotoEnabled && !item.preservesOriginalFile && item.saveFormat != .dng
        let access: PHAccessLevel = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil ? .addOnly : .readWrite
        PHPhotoLibrary.requestAuthorization(for: access) { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.saveErrorMessage = "Chưa cấp quyền lưu ảnh vào Photos. Bạn có thể thử lưu lại trong Chi tiết ảnh."
                    completion?(false)
                    return
                }
                let resources = await Task.detached(priority: .userInitiated) { () -> (Data, Data?)? in
                    if item.saveFormat == .dng {
                        guard let data = item.rawPhotoData, SuperResolutionRAWEngine.isDNGData(data)
                        else { return nil }
                        if item.rawLocalFileURL == nil {
                            let filename = "AlignAI_RAW_\(item.id.uuidString).dng"
                            _ = Self.saveRawFileToAppSandbox(data: data, filename: filename)
                        }
                        return (data, nil)
                    }
                    let mainData = item.preservesOriginalFile ? item.rawPhotoData :
                        Self.encodeRenderedPhoto(item.processedImage, sourceData: item.rawPhotoData,
                                                 format: item.saveFormat)
                    guard let mainData else { return nil }
                    let originalData = saveOriginal ? (item.rawPhotoData ??
                        Self.encodeRenderedPhoto(item.originalImage, sourceData: nil,
                                                 format: item.saveFormat)) : nil
                    return (mainData, originalData)
                }.value
                guard let (mainData, originalData) = resources else {
                    self.saveErrorMessage = item.saveFormat == .dng ?
                        "Không có dữ liệu DNG hợp lệ. Ảnh RAW chưa được lưu." : "Không thể mã hóa ảnh để lưu."
                    completion?(false)
                    return
                }
                let type = item.saveFormat == .dng ? (UTType(filenameExtension: "dng") ?? .rawImage) :
                    (item.saveFormat == .jpeg ? UTType.jpeg : UTType.heic)
                let filename = "AlignAI_\(item.id.uuidString).\(item.saveFormat == .dng ? "dng" : (item.saveFormat == .jpeg ? "jpg" : "heic"))"
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = type.identifier
                    options.originalFilename = filename
                    // DNG bytes are passed directly, without creating a UIImage.
                    request.addResource(with: .photo, data: mainData, options: options)
                    if item.saveFormat == .dng {
                        // Dinh kem .alternatePhoto (full-resolution JPEG companion) cho anh RAW trong Apple Photos.
                        // Giup Apple Photos hien thi net ngay lap tuc (0s delay, khong bi mang mo) ma van giu nguyen DNG tho goc.
                        let companionData = item.processedCompanionData ??
                            Self.encodeRenderedPhoto(item.originalImage, sourceData: nil, format: .jpeg)
                        if let companion = companionData {
                            let previewOptions = PHAssetResourceCreationOptions()
                            previewOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                            previewOptions.originalFilename = "AlignAI_\(item.id.uuidString)_preview.jpg"
                            request.addResource(with: .alternatePhoto, data: companion, options: previewOptions)
                        }
                    }
                    if item.saveFormat != .dng, let movie = item.livePhotoMovieURL,
                       FileManager.default.fileExists(atPath: movie.path) {
                        let movieOptions = PHAssetResourceCreationOptions()
                        movieOptions.shouldMoveFile = false
                        request.addResource(with: .pairedVideo, fileURL: movie, options: movieOptions)
                    }
                    if let originalData {
                        let original = PHAssetCreationRequest.forAsset()
                        original.addResource(with: .photo, data: originalData, options: nil)
                    }
                }) { [weak self] success, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if success {
                            self.saveErrorMessage = nil
                            self.latestAlbumThumbnail = UIImage(cgImage: item.processedImage)
                            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
                               PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                                self.loadLatestPhotoFromAlbum()
                            }
                        } else {
                            self.saveErrorMessage = "Lưu \(item.saveFormat.rawValue) thất bại: \(error?.localizedDescription ?? "không rõ lỗi"). Có thể thử lưu lại."
                        }
                        completion?(success)
                    }
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
        pendingRecordedVideoURLs.append(url)
        haptics.triggerSuccess()
        presentPendingMediaPreviewIfPossible()
    }

    public func cameraService(_ service: CameraService, didChangeRecordingState state: CameraRecordingState) {
        recordingState = state
        switch state {
        case .starting:
            isRecordingVideo = false
        case .recording:
            isRecordingVideo = true
            if videoRecordingStartTime == nil {
                videoRecordingStartTime = Date()
                videoRecordedDurationSeconds = 0
                videoRecordingTimeString = "00:00:00"
                videoRecordingTimer?.invalidate()
                videoRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateVideoRecordingClock()
                    }
                }
            }
        case .stopping:
            isRecordingVideo = true
        case .idle:
            isRecordingVideo = false
            videoRecordingTimer?.invalidate()
            videoRecordingTimer = nil
            videoRecordingStartTime = nil
            videoRecordedDurationSeconds = 0
            videoRecordingTimeString = "00:00:00"
            applyPendingCaptureModeIfPossible()
            presentPendingMediaPreviewIfPossible()
        }
    }

    public func cameraService(_ service: CameraService, didFailRecordingWithError error: Error) {
        wantsVideoRecording = false
        saveErrorMessage = "Quay video thất bại: \(error.localizedDescription). Vui lòng thử lại."
        applyPendingCaptureModeIfPossible()
    }

    public func cameraService(_ service: CameraService, didChangeSessionRunning running: Bool) {
        isCameraReady = running && !isAppInBackground
        if isCameraReady { applyPendingCaptureModeIfPossible() }
        if !running && wantsVideoRecording {
            wantsVideoRecording = false
            cameraService.stopRecordingVideo()
        }
    }

    public func cameraService(_ service: CameraService, didChangePhotoPhase phase: PhotoCapturePhase) {
        guard aiSessionState == .capturing, isShutterPressing else { return }
        photoCapturePhase = phase
    }

    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, processedCompanionData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double, format: PhotoSaveFormat, requestedHighResolution: Bool) {
        photoCapturePhase = .processing
        CameraLogger.info("Bắt đầu xử lý bộ lọc ảnh màu AI (Kích thước: \(photo.width)x\(photo.height), LivePhoto: \(livePhotoMovieURL != nil ? "CÓ" : "KHÔNG"))", category: .capture)

        let settings = captureProcessingSettings ?? currentPhotoProcessingSettings()
        captureProcessingSettings = nil
        let finalColorParams = format == .dng ? nil : settings.params
        let effectivePreset = settings.preset
        let activeScene = settings.scene
        let activeRule = settings.rule
        let score = settings.score
        let isFilmActive = settings.applyFilm && format != .dng
        let isWindowed = settings.crop && format != .dng
        let windowFocal = settings.focalLength
        let windowAspect = settings.aspect
        let hasColorEdits = isFilmActive && (effectivePreset != .standard || finalColorParams != nil)

        // Chuyển sang luồng phụ userInitiated để render CoreImage, không làm đơ Main UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Nếu đang bật Windowed Zoom -> Cắt ảnh gốc 48MP chính xác theo tỉ lệ và kích thước khung ngắm
            let effectiveSourcePhoto: CGImage
            if isWindowed {
                let fractions = windowAspect.windowFractions(focalLength: windowFocal)
                let origW = CGFloat(photo.width)
                let origH = CGFloat(photo.height)
                let cropW = round(origW * fractions.widthFraction)
                let cropH = round(origH * fractions.heightFraction)
                let cropX = round((origW - cropW) / 2.0)
                let cropY = round((origH - cropH) / 2.0)
                let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                effectiveSourcePhoto = photo.cropping(to: cropRect) ?? photo
                CameraLogger.info("Windowed Zoom Crop: \(photo.width)x\(photo.height) -> \(effectiveSourcePhoto.width)x\(effectiveSourcePhoto.height) (\(Int(windowFocal))mm, \(windowAspect.rawValue))", category: .capture)
            } else {
                effectiveSourcePhoto = photo
            }

            var processedImageResult: CGImage = effectiveSourcePhoto
            autoreleasepool {
                if hasColorEdits {
                    processedImageResult = FilmFilterEngine.shared.applyPresetAndAIParameters(
                        to: effectiveSourcePhoto, preset: effectivePreset, params: finalColorParams) ?? effectiveSourcePhoto
                }
            }

            // Nếu là RAW DNG: Lưu trực tiếp tệp nguyên bản vào thư mục Documents/RAW của App ngay lập tức
            var localRawURL: URL? = nil
            if format == .dng, let rawData = rawData {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let dateStr = formatter.string(from: Date())
                let rawFilename = "AlignAI_RAW_\(dateStr).dng"
                localRawURL = Self.saveRawFileToAppSandbox(data: rawData, filename: rawFilename)
            }

            let item = CapturedPhotoItem(
                originalImage: effectiveSourcePhoto,
                processedImage: processedImageResult,
                rawPhotoData: rawData,
                processedCompanionData: processedCompanionData,
                saveFormat: format,
                preservesOriginalFile: format == .dng || (!isWindowed && !hasColorEdits),
                rawLocalFileURL: localRawURL,
                livePhotoMovieURL: livePhotoMovieURL,
                sceneType: activeScene,
                appliedPreset: isFilmActive ? effectivePreset : .standard,
                compositionRule: activeRule,
                alignmentScore: score,
                iso: iso,
                shutterSpeed: shutterSpeed,
                aiColorParameters: finalColorParams
            )

            DispatchQueue.main.async {
                CameraLogger.success("Render bộ lọc hoàn tất, hiển thị xem trước & lưu ảnh (LivePhoto: \(item.isLivePhoto))", category: .capture)
                self.isShutterPressing = false
                self.haptics.triggerShutterClick()
                withAnimation {
                    self.latestCapturedPhoto = item
                    self.aiSessionState = .done
                }
                self.pendingPhotoPreview = true
                self.applyPendingCaptureModeIfPossible()
                self.presentPendingMediaPreviewIfPossible()
                self.savePhotoToLibrary(item)
            }
        }
    }

    public func cameraService(_ service: CameraService, didFailCaptureWithError error: Error) {
        // AVCapture can reject a new request while an earlier capture is
        // finishing. Restore this request's UI state instead of stranding it
        // in .capturing; repeated failure callbacks are ignored below.
        guard aiSessionState == .capturing else { return }
        captureProcessingSettings = nil
        isShutterPressing = false
        let hadLiveTarget: Bool
        switch stateBeforeCapture {
        case .targetPlaced, .alignmentPerfect: hadLiveTarget = true
        default: hadLiveTarget = false
        }
        if hadLiveTarget, let point = currentTargetPoint, point.x.isFinite, point.y.isFinite,
           (0...1).contains(point.x), (0...1).contains(point.y) {
            if SpatialTrackingEngine.shared.isTrackingActive {
                withAnimation { aiSessionState = .targetPlaced(locked: true) }
            } else {
                // Automatic capture stops tracking before asking AVFoundation.
                // Restore a live target if that capture fails.
                aiSessionState = .targetPlaced(locked: true)
                pinTargetAndStartMotion(at: point)
            }
        } else {
            withAnimation { aiSessionState = stateBeforeCapture == .done ? .done : .idle }
        }
        allowsAutoCaptureForCurrentTarget = true
        pinZoomPlanTask?.cancel()
        isPreparingPinZoom = false
        hasExecutedAutoZoomForSession = false
        pendingSuggestedZoom = displayZoom
        saveErrorMessage = "Chụp ảnh thất bại: \(error.localizedDescription). Vui lòng thử lại."
        applyPendingCaptureModeIfPossible()
    }

    public func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {
        self.currentZoom = zoom
        self.displayZoom = self.cameraService.convertDeviceZoomToDisplayZoom(zoom)
        SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
        finishManualZoomIfSettled(zoom)
    }
}
