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
    private var latestFrameContext: TrackingFrameContext?
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

        // Zero-Cost Gate: Khi đang ngủ đông (mở Cài đặt, Bố cục, Thư viện, Chi tiết ảnh, Xem video, hoặc ẩn nền),
        // lập tức thoát ngay mà không chạy bất kỳ tác vụ AI Vision, YOLO, Optical Flow, Histogram hay Peaking nào!
        guard !snapshot.isHibernating else { return }

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
    private var localCandidatePlans: [LocalFramingPlan] = []
    private var localEvidenceCandidates: [NeuralSubjectCandidate] = []
    private var postZoomFaceCount = 0
    private var localAnalysisExpired = false
    private var localAnalysisFinished = false
    @Published public private(set) var localSuggestionRects: [CGRect] = []
    @Published public private(set) var localSelectionMessage: String? = nil
    private var allowsAutoCaptureForCurrentTarget = true
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
    private var targetPinGeneration: UInt64 = 0
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
    @Published public var captureMode: CameraCaptureMode = .photo {
        didSet {
            UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode")
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
    @Published public var isSuperResolutionRAWEnabled: Bool = UserDefaults.standard.bool(forKey: "isSuperResolutionRAWEnabled") {
        didSet { UserDefaults.standard.set(isSuperResolutionRAWEnabled, forKey: "isSuperResolutionRAWEnabled") }
    }
    @Published public var superResolutionProgressText: String? = nil
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
    @Published public var isRecordingVideo: Bool = false
    @Published public var recordedVideoURL: URL? = nil
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
    private var zoomFallbackAfter = Double.infinity
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
            zoomRevealStartsIn ? zoomRevealStartDisplayZoom / pendingTargetZoomForReveal :
                pendingTargetZoomForReveal / zoomRevealStartDisplayZoom))

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
            let ratio = min(1.0, max(0.20,
                zoomRevealStartsIn ? liveZoomFactorForReveal / pendingTargetZoomForReveal :
                    pendingTargetZoomForReveal / liveZoomFactorForReveal))
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
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
        zoomVerified = false
        zoomAwaitingVerification = true
        zoomFallbackAfter = .infinity
        zoomStartFrameTimestamp = frameProcessor.latestTrackingFrameSnapshot()?.1.timestamp ?? CACurrentMediaTime()
        postZoomFaceMinimumTimestamp = -Double.infinity
        pendingTargetZoomForReveal = targetZoom
        zoomRevealStartDisplayZoom = max(0.1, displayZoom)
        zoomRevealStartsIn = targetZoom > displayZoom
        liveZoomFactorForReveal = displayZoom
        isZoomRampPhase = false
        lockOnProgress = 0
        isRevealingZoomTarget = true
        let pinGeneration = targetPinGeneration

        // Hiệu ứng chuyển động mượt mà điện ảnh (Cinematic Easing)
        withAnimation(.spring(response: 0.50, dampingFraction: 0.85)) {
            lockOnProgress = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self = self, self.targetPinGeneration == pinGeneration,
                  self.zoomAwaitingVerification, !self.isPinchingZoom else { return }
            self.isZoomRampPhase = true
            let octaveDistance = abs(log2(Double(targetDeviceZoom / max(0.5, self.currentZoom))))
            let targetDuration = min(1.8, max(1.2, octaveDistance * 1.3))
            let smoothRate = Float(max(0.65, min(1.4, octaveDistance / targetDuration)))
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
    @Published public var autoCaptureCountdown: Int = 0
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
            // 1. Khi mở màn hình che khuất camera, hủy phiên tracking hiện tại theo yêu cầu
            if isAISessionActive || currentTargetPoint != nil {
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
        }
    }

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        let isBg = (phase == .background)
        if isAppInBackground != isBg {
            isAppInBackground = isBg
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
            self.captureMode = mode
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
        if defaults.object(forKey: "useGeminiForAnalysis") != nil {
            self.useGeminiForAnalysis = defaults.bool(forKey: "useGeminiForAnalysis")
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
                isHibernating: isCameraHibernating,
                isSettingsVisible: isShowingSettings,
                isFocusPeakingEnabled: isFocusPeakingEnabled,
                focusPeakingColor: focusPeakingColor
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
            guard let self = self, success else { return }
            self.cameraService.updateCaptureMode(self.captureMode)
            self.cameraService.setLivePhotoCaptureEnabled(self.isLivePhotoEnabled)
            self.activeVideoResolutionString = self.cameraService.getActiveVideoResolutionAndFPS()
            self.displayZoom = self.cameraService.defaultDisplayZoom
            self.currentZoom = self.cameraService.currentZoom
            SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
            self.cameraService.start()
            self.isCameraReady = true
        }
    }

    private func handleVisionDetectionWithSource(_ detection: SubjectDetectionResult,
                                                   frame: TrackingFrameContext?) {
        guard !isShowingSettings else { return }
        // Suggestions need only the frame geometry; do not retain a live pool buffer.
        if localAnalysisFinished, !localEvidenceCandidates.isEmpty,
           let source = localTrackingSource, let frame,
           let pose = SpatialTrackingEngine.shared.pose(at: frame.timestamp) {
            localSuggestionRects = localEvidenceCandidates.map {
                reprojectSuggestion($0.boundingBox, from: source,
                                    to: frame.calibration, pose: pose)
            }
        }
        handleVisionDetection(detection)
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

    public func cancelAIZoomForGesture() {
        targetPinGeneration &+= 1
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        autoCaptureCountdown = 0
        cameraService.cancelZoomRamp()
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        zoomAwaitingVerification = false
        zoomVerified = false
        zoomFallbackAfter = .infinity
        postZoomFaceMinimumTimestamp = -Double.infinity
        allowsAutoCaptureForCurrentTarget = false
        hasExecutedAutoZoomForSession = true
        localSelectionMessage = "Bạn đã đổi zoom; kiểm tra bố cục và chụp tay."
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
            case .jpeg: selectedPhotoFormat = .heif
            case .heif, .heic: selectedPhotoFormat = .dng
            case .dng: selectedPhotoFormat = .jpeg
            }
        }
    }

    public func switchCamera() {
        targetPinGeneration &+= 1
        visionEngine.stopTrackingObject()
        SpatialTrackingEngine.shared.stopTracking()
        currentTargetPoint = nil
        isPerfectAlignment = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
        aiSessionState = .idle
        haptics.triggerSelectionChange()
        cameraService.switchCamera()
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
        guard aiSessionState == .idle || aiSessionState == .done else { return }
        targetPinGeneration &+= 1
        if zoomAwaitingVerification { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
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
        localCandidatePlans = []
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
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
                    self.localTrackingSource = source
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let output = NeuralSubjectIntelligenceEngine.shared.analyzeFrame(
                            pixelBuffer: buffer, orientation: context.orientation)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.aiSessionGeneration == requestGeneration,
                                  self.aiSessionState == .analyzing,
                                  !self.localAnalysisExpired else { return }
                            self.finishLocalAnalysis(output, source: source)
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.aiSessionGeneration == requestGeneration,
                      self.aiSessionState == .analyzing,
                      !self.localAnalysisFinished else { return }
                self.localAnalysisExpired = true
                self.localTrackingSource = nil
                self.localCandidatePlans = []
                self.localSuggestionRects = []
                self.localSelectionMessage = "AI quá thời gian. Chạm vùng muốn chụp hoặc chụp tay."
            }
        }
        // Register the callback before admitting the capture frame.
        visionEngine.captureNextFrameForGemini = true
    }

    public func cancelAISession() {
        targetPinGeneration &+= 1
        self.aiSessionGeneration += 1
        if zoomAwaitingVerification { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        zoomAwaitingVerification = false
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
            activeEngineSource = nil
            arTrackingWarning = nil
        }
    }

    /// Called when the camera overlay disappears or the app resigns active.
    /// A resumed CoreMotion reference frame must not inherit the old world ray.
    public func suspendSpatialTracking() {
        targetPinGeneration &+= 1
        aiSessionGeneration += 1
        if zoomAwaitingVerification { cameraService.cancelZoomRamp() }
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        zoomAwaitingVerification = false
        isRevealingZoomTarget = false
        isZoomRampPhase = false
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
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
        aiSessionState = .idle
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
        switch aiSessionState {
        case .idle, .done:
            // Khi ở chế độ idle: chỉ hiển thị face preview nhẹ nhàng, không tính toán target
            self.detectedScene = detection.detectedScene
            self.detectedFaceRects = detection.faceRectangles
            if let dominant = detection.dominantSubjectRect {
                self.detectedSubjectRects = [dominant]
            }
            return

        case .capturing:
            return

        case .targetPlaced, .alignmentPerfect:
            // Bỏ qua kết quả phân tích bố cục sau khi ghim. Chuỗi Vision bám vật thể
            // vẫn chạy riêng và hiệu chỉnh hướng thế giới qua onTargetMeasurement.
            return

        case .analyzing:
            // Giai đoạn phân tích 1 lần (One-shot)
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
        localTrackingSource = source
        localAnalysisFinished = false
        let generation = aiSessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = NeuralSubjectIntelligenceEngine.shared.analyzeFrame(
                pixelBuffer: source.buffer, orientation: source.frame.orientation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.aiSessionGeneration == generation,
                      self.aiSessionState == .analyzing,
                      !self.localAnalysisExpired else { return }
                self.finishLocalAnalysis(output, source: source)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.aiSessionGeneration == generation,
                  self.aiSessionState == .analyzing,
                  !self.localAnalysisFinished else { return }
            self.localAnalysisExpired = true
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

    private func finishLocalAnalysis(_ output: NeuralAnalysisOutput, source: AITrackingSource) {
        localAnalysisFinished = true
        guard source.frame.displayZoom.isFinite, source.frame.displayZoom > 0,
              abs(displayZoom - CGFloat(source.frame.displayZoom)) <= 0.08 else {
            localTrackingSource = nil
            localSelectionMessage = "Ống kính đã đổi trong lúc AI phân tích. Chạm vùng muốn chụp hoặc chạy AI lại."
            return
        }
        detectedScene = output.detectedScene
        detectedFaceRects = output.allFaceRects
        postZoomFaceCount = output.allFaceRects.count
        let localPreset = output.detectedScene.recommendedFilter
        aiRecommendedPreset = localPreset
        aiPresetMatchReason = "\(localPreset.displayName) — Tối ưu cho bối cảnh \(output.detectedScene.localizedName)"
        if selectedFilmPreset.isAIFullAuto { selectedFilmPreset = localPreset }
        if isAIFullColorEnabled { currentAIColorParams = output.detectedScene.aiFullColorParameters }
        let candidates = output.allCandidates.sorted {
            $0.prominenceScore * (1 + CompositionPreferenceStore.shared.bonus(
                scene: output.detectedScene, candidate: $0)) >
            $1.prominenceScore * (1 + CompositionPreferenceStore.shared.bonus(
                scene: output.detectedScene, candidate: $1))
        }.filter { candidate in
            guard candidate.boundingBox.minX >= 0, candidate.boundingBox.minY >= 0,
                  candidate.boundingBox.maxX <= 1, candidate.boundingBox.maxY <= 1 else { return false }
            // A weaker but localized Vision region may still be useful as a
            // tap suggestion. It never bypasses the calibrated auto-choice gate.
            return candidate.confidence >= 0.35
        }
        var distinct: [NeuralSubjectCandidate] = []
        for candidate in candidates {
            let duplicate = distinct.contains { existing in
                let intersection = existing.boundingBox.intersection(candidate.boundingBox)
                let smaller = min(existing.areaRatio, candidate.areaRatio)
                return Double(intersection.width * intersection.height) > smaller * 0.65
            }
            if !duplicate { distinct.append(candidate) }
            if distinct.count == 12 { break }
        }
        let feasible = distinct.compactMap { candidate -> (NeuralSubjectCandidate, LocalFramingPlan)? in
            let otherPeople = distinct.filter {
                $0.id != candidate.id && $0.category == .human
            }.map(\.boundingBox)
            // Even a face inside the chosen person's box can be cut by zoom.
            let companions = output.allFaceRects + otherPeople
            guard let plan = LocalFramingGeometry.plan(subject: candidate, companions: companions,
                scene: output.detectedScene, gaze: output.lookingDirection,
                frame: source.frame, pose: source.pose,
                currentZoom: CGFloat(source.frame.displayZoom),
                allowedZooms: cameraService.availableDisplayZoomOptions) else { return nil }
            return (candidate, plan)
        }.prefix(3)
        localCandidatePlans = feasible.map(\.1)
        // If no zoom/crop plan survives, still show up to three localized
        // regions for an explicit tap. Those taps remain manual capture only.
        localEvidenceCandidates = feasible.isEmpty ? Array(distinct.prefix(3)) : feasible.map(\.0)
        if let currentFrame = frameProcessor.latestTrackingFrameSnapshot()?.1,
           let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                ?? SpatialTrackingEngine.shared.latestPose() {
            localSuggestionRects = localEvidenceCandidates.map {
                reprojectSuggestion($0.boundingBox, from: source,
                                    to: currentFrame.calibration, pose: currentPose)
            }
        } else {
            // A delayed analysis cannot paint source-frame boxes at stale
            // screen coordinates. The next synchronized preview will reproject.
            localSuggestionRects = localEvidenceCandidates.map { _ in
                CGRect(x: -1, y: -1, width: 0, height: 0)
            }
        }
        detectedSubjectRects = localSuggestionRects
        if output.usedSemanticModel {
            activeEngineSource = .semanticLocal(label: output.detectedScene.localizedName)
        } else if YOLODetectionEngine.shared.hasYOLOModel {
            activeEngineSource = .yoloNeural(label: output.detectedScene.localizedName)
        } else {
            activeEngineSource = .appleNeuralEngine(scene: output.detectedScene.localizedName)
        }
        if let best = localCandidatePlans.first,
           let firstCandidate = localEvidenceCandidates.first,
           let measuredThreshold = LocalAutoselectCalibration.threshold(
                scene: output.detectedScene, category: firstCandidate.category),
           best.confidence >= max(0.72, measuredThreshold) {
            acceptLocalPlan(best, source: source)
        } else {
            if localEvidenceCandidates.isEmpty {
                localSelectionMessage = "Chưa xác định được vùng đáng tin cậy. Chạm vùng muốn chụp hoặc chụp tay."
            } else if localCandidatePlans.isEmpty {
                localSelectionMessage = "AI thấy vùng có thể chọn nhưng chưa kiểm định được bố cục. Chạm vùng đánh dấu để ghim và chụp tay."
            } else {
                localSelectionMessage = "Chọn một vùng được đánh dấu, hoặc chạm vùng khác để chụp tay."
            }
        }
    }

    public func chooseLocalSuggestion(at point: CGPoint) {
        guard case .analyzing = aiSessionState else { return }
        if let index = localSuggestionRects.firstIndex(where: {
            !$0.isEmpty && $0.insetBy(dx: -0.025, dy: -0.025).contains(point)
        }), index < localEvidenceCandidates.count,
           let source = localTrackingSource {
            if index < localCandidatePlans.count {
                CompositionPreferenceStore.shared.record(scene: detectedScene,
                    candidates: localEvidenceCandidates, selectedIndex: index,
                    actualZoom: displayZoom)
                acceptLocalPlan(localCandidatePlans[index], source: source)
            } else {
                let candidate = localEvidenceCandidates[index]
                localCandidatePlans = []
                localEvidenceCandidates = []
                localSuggestionRects = []
                detectedSubjectRects = []
                allowsAutoCaptureForCurrentTarget = true
                let area = candidate.boundingBox.width * candidate.boundingBox.height
                pendingSuggestedZoom = area < 0.05 ? 3.0 : (area < 0.15 ? 2.0 : 1.0)
                pinTargetAndStartMotion(at: candidate.center,
                    subjectRect: candidate.boundingBox, source: source)
                localTrackingSource = nil
                localSelectionMessage = nil
            }
        } else {
            allowsAutoCaptureForCurrentTarget = true
            localTrackingSource = nil
            localCandidatePlans = []
            localEvidenceCandidates = []
            localSuggestionRects = []
            detectedSubjectRects = []
            localSelectionMessage = nil
            pendingSuggestedZoom = displayZoom
            pinTargetAndStartMotion(at: point)
        }
    }

    private func acceptLocalPlan(_ plan: LocalFramingPlan, source: AITrackingSource) {
        let dx = plan.aimPointInSource.x - 0.5
        let dy = plan.aimPointInSource.y - 0.5
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        framingResult = FramingTargetResult(targetPoint: plan.aimPointInSource,
            currentCenter: CGPoint(x: 0.5, y: 0.5),
            offsetVector: CGVector(dx: dx, dy: dy), distance: distance,
            angleDegrees: angle < 0 ? angle + 360 : angle,
            alignmentScore: max(0, min(1, 1 - Double(distance / 0.40))),
            isAligned: distance <= calculator.alignmentTolerance,
            recommendedZoomFactor: plan.zoom, optimalRule: activeCompositionRule,
            guideDescription: "Đưa tâm trắng vào vòng vàng, sau đó AI sẽ zoom an toàn.")
        pendingSuggestedZoom = plan.zoom
        aiSuggestedZoom = plan.zoom
        hasExecutedAutoZoomForSession = false
        allowsAutoCaptureForCurrentTarget = true
        localCandidatePlans = []
        localEvidenceCandidates = []
        localSuggestionRects = []
        detectedSubjectRects = []
        localSelectionMessage = nil
        pinTargetAndStartMotion(at: plan.aimPointInSource,
            subjectRect: plan.subjectRect, source: source,
            trackedPoint: plan.subjectPoint, pinnedGuideRay: plan.aimWorldRay)
        localTrackingSource = nil
    }

    private func pinTargetAndStartMotion(at target: CGPoint, subjectRect: CGRect?,
                                          source: AITrackingSource?,
                                          trackedPoint: CGPoint? = nil,
                                          pinnedGuideRay: SIMD3<Double>? = nil) {
        guard target.x.isFinite, target.y.isFinite,
              (0...1).contains(target.x), (0...1).contains(target.y) else { return }
        let subjectRect = normalizedSubjectRect(subjectRect)
        let isManualRePin: Bool
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect: isManualRePin = true
        default: isManualRePin = false
        }
        targetPinGeneration &+= 1
        let pinGeneration = targetPinGeneration
        targetPinStartedAt = CACurrentMediaTime()
        lastFailedCaptureOpticalTimestamp = -.infinity
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
        isPerfectAlignment = false
        let hadZoomRamp = zoomAwaitingVerification
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
        hasExecutedAutoZoomForSession = isManualRePin
        allowsAutoCaptureForCurrentTarget = true

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

        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.targetPinGeneration == pinGeneration,
                  self.visionEngine.isTrackingTarget else { return }
            self.haptics.triggerSuccess()
            // The lens must not move until the user aligns the guide.
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
        latestOpticalBox = measurement.subjectBox
        latestOpticalCalibration = measurement.frame.calibration
        if zoomFallbackAfter.isFinite,
           measurement.frame.timestamp > zoomFallbackAfter + 0.05,
           currentSubjectBoxIsSafe {
            // A failed ramp is not a verified target zoom. A new accepted
            // image can still validate the actual hardware crop for capture.
            zoomVerified = true
            pendingSuggestedZoom = displayZoom
            aiSuggestedZoom = displayZoom
            postZoomFaceMinimumTimestamp = zoomFallbackAfter
            zoomFallbackAfter = .infinity
            localSelectionMessage = "Đã giữ mức zoom hiện tại để chụp an toàn."
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
        return trackingQuality == .locked && (0...0.35).contains(age) &&
            latestOpticalCalibration?.isValid == true && latestOpticalBox != nil
    }

    private func canZoomCurrentSubject(to target: CGFloat) -> Bool {
        guard let box = latestOpticalBox, let k = latestOpticalCalibration,
              displayZoom > 0, target > 0 else { return false }
        let ratio = target / displayZoom
        let cx = CGFloat(k.cx), cy = CGFloat(k.cy)
        return cx + (box.minX - cx) * ratio >= 0.025 &&
            cy + (box.minY - cy) * ratio >= 0.025 &&
            cx + (box.maxX - cx) * ratio <= 0.975 &&
            cy + (box.maxY - cy) * ratio <= 0.975
    }

    private func evaluateAlignment(at point: CGPoint) {
        let dx = point.x - 0.5, dy = point.y - 0.5
        let dist = hypot(dx, dy)
        alignmentDistance = dist
        let tolerance = calculator.alignmentTolerance
        if isProximityHapticsEnabled && dist < 0.15 && dist > tolerance {
            let now = CACurrentMediaTime()
            if now - lastProximityHapticTime >= 0.1 {
                lastProximityHapticTime = now
                haptics.triggerProximityPulse(intensity: 1 - dist / 0.15)
            }
        }
        let aligned = hasFreshOpticalLock &&
            dist <= tolerance * (isPerfectAlignment ? 1.30 : 1.0)
        if aligned {
            if !isPerfectAlignment {
                haptics.triggerMagneticSnap()
                showAlignmentSuccessFlash = true
                let pinGeneration = targetPinGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.targetPinGeneration == pinGeneration else { return }
                    self.showAlignmentSuccessFlash = false
                }
            }
            isPerfectAlignment = true
            aiSessionState = .alignmentPerfect
            // Evaluate the pending action on every usable update, including the
            // first good frame AFTER a cooldown, temporary blur or zoom ramp.
            let needsZoom = isAutoZoomEnabled && !hasExecutedAutoZoomForSession &&
                abs(pendingSuggestedZoom - displayZoom) > 0.12
            if needsZoom {
                if pendingSuggestedZoom < displayZoom - 0.12,
                   canZoomCurrentSubject(to: pendingSuggestedZoom) {
                    applyAISuggestedZoom(pendingSuggestedZoom)
                    alignmentState = .aligned(score: 1)
                    return
                }
                let safeOptions = Array(Set(cameraService.availableDisplayZoomOptions +
                    [pendingSuggestedZoom, 1.5])).filter {
                    $0 > displayZoom + 0.12 && $0 <= pendingSuggestedZoom + 0.01 &&
                    canZoomCurrentSubject(to: $0)
                }
                if let safeZoom = safeOptions.max() {
                    pendingSuggestedZoom = safeZoom
                    aiSuggestedZoom = safeZoom
                    applyAISuggestedZoom(safeZoom)
                } else {
                    // An unsafe zoom must not leave the shutter blocked when
                    // the user has already aligned a verified subject.
                    pendingSuggestedZoom = displayZoom
                    aiSuggestedZoom = displayZoom
                    hasExecutedAutoZoomForSession = true
                }
            } else if hasExecutedAutoZoomForSession && !zoomVerified &&
                        !zoomAwaitingVerification && !zoomFallbackAfter.isFinite &&
                        allowsAutoCaptureForCurrentTarget &&
                        abs(displayZoom - pendingTargetZoomForReveal) <= 0.08 {
                // Optical verification may recover after a timeout without
                // replaying the physical ramp or asking for another pin.
                zoomAwaitingVerification = true
                let pinGeneration = targetPinGeneration
                zoomVerificationTask?.cancel()
                zoomVerificationTask = Task { [weak self] in
                    await self?.verifyZoomAfterRamp(pinGeneration: pinGeneration)
                }
            } else if !zoomAwaitingVerification && zoomVerified &&
                        isAutoCaptureOnAlignEnabled && allowsAutoCaptureForCurrentTarget &&
                        autoCaptureTask == nil && !isPinchingZoom &&
                        latestOpticalFrameTimestamp > lastFailedCaptureOpticalTimestamp &&
                        CACurrentMediaTime() - lastFailedCaptureAttemptTime >= 0.40 {
                startAutoCaptureCountdown()
            }
            alignmentState = .aligned(score: 1)
        } else {
            isPerfectAlignment = false
            autoCaptureTask?.cancel()
            autoCaptureTask = nil
            autoCaptureCountdown = 0
            aiSessionState = .targetPlaced(locked: true)
            let angle = atan2(dy, dx) * 180 / .pi
            alignmentState = .guiding(distance: dist, angle: angle < 0 ? angle + 360 : angle)
        }
    }

    private func startAutoCaptureCountdown(isZooming: Bool = false) {
        autoCaptureTask?.cancel()
        autoCaptureCountdown = 0
        let pinGeneration = targetPinGeneration
        autoCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                if isZooming || self.zoomAwaitingVerification {
                    while self.zoomAwaitingVerification {
                        try await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled, self.targetPinGeneration == pinGeneration else { return }
                    }
                }
                self.autoCaptureCountdown = 1
                try await Task.sleep(nanoseconds: 850_000_000)
            } catch { return }
            guard !Task.isCancelled else { return }
            guard self.targetPinGeneration == pinGeneration else { return }
            let cropSafe = await self.currentCropSafeForCapture()
            guard !Task.isCancelled, self.targetPinGeneration == pinGeneration else { return }
            self.autoCaptureTask = nil
            self.autoCaptureCountdown = 0
            if self.aiSessionState == .alignmentPerfect && !self.isShutterPressing &&
                self.trackingQuality == .locked && self.hasFreshOpticalLock &&
                self.alignmentDistance <= self.calculator.alignmentTolerance * 1.30 &&
                !self.zoomAwaitingVerification && self.zoomVerified &&
                !self.isPinchingZoom && self.allowsAutoCaptureForCurrentTarget &&
                self.isAutoCaptureOnAlignEnabled && cropSafe && self.currentSubjectBoxIsSafe {
                self.executeCapture()
            } else {
                self.aiSessionState = .targetPlaced(locked: true)
                self.lastFailedCaptureOpticalTimestamp = self.latestOpticalFrameTimestamp
                self.lastFailedCaptureAttemptTime = CACurrentMediaTime()
            }
        }
    }

    private func verifyZoomAfterRamp(pinGeneration: UInt64) async {
        let deadline = CACurrentMediaTime() + 6.0
        var reachedAt: TimeInterval?
        var settledSince: TimeInterval?
        while CACurrentMediaTime() < deadline {
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard !Task.isCancelled, targetPinGeneration == pinGeneration,
                  !isPinchingZoom else { return }
            let reached = abs(displayZoom - pendingTargetZoomForReveal) <= 0.08
            if reached {
                if reachedAt == nil { reachedAt = CACurrentMediaTime() }
            } else { reachedAt = nil }
            let fresh = latestOpticalFrameTimestamp >
                max(zoomStartFrameTimestamp + 0.10, (reachedAt ?? .infinity) + 0.05)
            let boxSafe = latestOpticalBox.map {
                $0.minX >= 0.01 && $0.minY >= 0.01 &&
                $0.maxX <= 0.99 && $0.maxY <= 0.99
            } ?? false
            if reached && fresh && boxSafe && hasFreshOpticalLock &&
               latestOpticalCalibration?.isValid == true && trackingQuality == .locked {
                if settledSince == nil { settledSince = CACurrentMediaTime() }
                if CACurrentMediaTime() - (settledSince ?? 0) >= 0.50 {
                    guard await verifyPostZoomFaces(after: reachedAt ?? zoomStartFrameTimestamp) else { continue }
                    guard !Task.isCancelled, targetPinGeneration == pinGeneration,
                          !isPinchingZoom else { return }
                    guard hasFreshOpticalLock, currentSubjectBoxIsSafe,
                          abs(displayZoom - pendingTargetZoomForReveal) <= 0.08 else {
                        settledSince = nil
                        continue
                    }
                    postZoomFaceMinimumTimestamp = reachedAt ?? zoomStartFrameTimestamp
                    zoomVerified = true
                    zoomAwaitingVerification = false
                    zoomFallbackAfter = .infinity
                    localSelectionMessage = nil
                    withAnimation(.easeOut(duration: 0.45)) {
                        self.isRevealingZoomTarget = false
                        self.isZoomRampPhase = false
                    }
                    selectedZoomPreset = displayZoom < 1.5 ? 1.0 :
                        (displayZoom < 2.5 ? 2.0 : 3.0)
                    return
                }
            } else { settledSince = nil }
        }
        // A timeout is not proof that the lens reached the requested crop.
        guard !Task.isCancelled, targetPinGeneration == pinGeneration else { return }
        cameraService.cancelZoomRamp()
        zoomVerified = false
        zoomAwaitingVerification = false
        zoomFallbackAfter = CACurrentMediaTime()
        localSelectionMessage = "Đang kiểm tra khung hình mới để chụp ở mức zoom hiện tại."
        withAnimation(.easeOut(duration: 0.40)) {
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
        let rectangles = await Task.detached(priority: .userInitiated) { () -> [CGRect]? in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.buffer,
                                                orientation: .up, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let results = request.results else { return nil }
            return results.filter { $0.confidence >= 0.35 }.map(\.boundingBox)
        }.value
        guard !Task.isCancelled, let faces = rectangles,
              CACurrentMediaTime() - snapshot.1.timestamp <= 0.50 else { return false }
        return faces.count >= postZoomFaceCount && faces.allSatisfy {
            let r = $0
            return r.minX >= 0.02 && r.maxX <= 0.98 &&
                   r.minY >= 0.02 && r.maxY <= 0.98
        }
    }

    private var currentSubjectBoxIsSafe: Bool {
        guard let box = latestOpticalBox,
              box.minX >= 0.02, box.maxX <= 0.98,
              box.minY >= 0.02, box.maxY <= 0.98 else { return false }
        return true
    }

    private func currentCropSafeForCapture() async -> Bool {
        guard hasFreshOpticalLock, currentSubjectBoxIsSafe else { return false }
        // Face re-check is only needed after a lens ramp. On a 1x alignment,
        // a delayed or missed face detection must not veto a live object lock.
        guard postZoomFaceMinimumTimestamp.isFinite else { return true }
        return await verifyPostZoomFaces(after: postZoomFaceMinimumTimestamp)
    }

    private func executeCapture() {
        guard aiSessionState == .alignmentPerfect, !isShutterPressing else { return }
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        stateBeforeCapture = aiSessionState
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        // Dừng hẳn engine spatial — trước đây 60Hz gyro vẫn chạy nền sau khi chụp
        SpatialTrackingEngine.shared.stopTracking()
        haptics.triggerShutterClick()

        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        if isSuperResolutionRAWEnabled {
            executeSuperResolutionCapture()
        } else {
            cameraService.capturePhoto(
                isDNG: selectedPhotoFormat == .dng,
                isHEIF: selectedPhotoFormat == .heif || selectedPhotoFormat == .heic
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
        }
    }

    // MARK: - Actions
    private var lastContinuousZoomTime: CFTimeInterval = 0
    private var lastContinuousAppliedZoom: CGFloat = 1.0

    private func prioritizeManualZoom() {
        cancelAIZoomForGesture()
    }

    public func setZoom(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        prioritizeManualZoom()
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        cameraService.setZoomFactor(deviceZoom)
    }

    /// Zoom liên tục mượt mà khi người dùng vuốt/pinch bằng hai ngón tay
    /// Tự động throttle AVFoundation calls (25ms) để chống nghẽn hàng đợi camera phần cứng
    public func setZoomContinuous(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        prioritizeManualZoom()
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
        guard finalDisplayZoom.isFinite else { return }
        prioritizeManualZoom()
        selectedZoomPreset = finalDisplayZoom < 1.5 ? 1.0 : (finalDisplayZoom < 2.5 ? 2.0 : 3.0)
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(finalDisplayZoom)
        lastContinuousAppliedZoom = deviceZoom
        cameraService.setZoomFactor(deviceZoom)
        haptics.triggerSelectionChange()
    }

    public func setZoomFromButton(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite else { return }
        prioritizeManualZoom()
        haptics.triggerSelectionChange()
        selectedZoomPreset = displayZoomVal
        let deviceZoom = cameraService.convertDisplayZoomToDeviceZoom(displayZoomVal)
        cameraService.setZoomFactor(deviceZoom)
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
            guard let self = self, let motion = motion, self.isHorizonLevelerEnabled, !self.isCameraHibernating else { return }
            let gx = Double(motion.gravity.x)
            let gy = Double(motion.gravity.y)
            let rawRoll = atan2(gx, -gy) * 180.0 / .pi
            let calibratedRoll = rawRoll - self.gyroRollOffsetDegrees
            self.currentRollDegrees = calibratedRoll
            let level = abs(calibratedRoll) <= 0.8
            if level && !self.isDeviceLevel && !self.hasTriggeredLevelHaptic {
                self.haptics.triggerSelectionChange()
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
        guard !isShutterPressing, aiSessionState != .capturing else { return }
        if aiSessionState == .analyzing { cancelAISession() }
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        autoCaptureCountdown = 0
        isPerfectAlignment = false
        stateBeforeCapture = aiSessionState

        // Cho phép chụp thủ công bất kỳ lúc nào (ngay cả khi chưa bật AI hoặc AI đã hoàn tất)
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }

        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }

        if isSuperResolutionRAWEnabled {
            executeSuperResolutionCapture()
        } else {
            cameraService.capturePhoto(
                isDNG: selectedPhotoFormat == .dng,
                isHEIF: selectedPhotoFormat == .heif || selectedPhotoFormat == .heic
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
        }
    }

    // MARK: - Super-Resolution RAW Capture Coordinator
    private func executeSuperResolutionCapture() {
        self.superResolutionProgressText = "Đang chụp 8 frame RAW..."
        cameraService.captureSuperResolutionRAWBurst(
            count: 8,
            progress: { [weak self] (fraction: Float) in
                DispatchQueue.main.async {
                    self?.superResolutionProgressText = "Đang chụp RAW \(Int(fraction * 100))%..."
                }
            },
            completion: { [weak self] (frames: [SuperResolutionInputFrame]) in
                guard let self = self else { return }
                guard !frames.isEmpty else {
                    CameraLogger.warning("Super-Res: Không nhận được frame RAW nào, fallback chụp tiêu chuẩn", category: .capture)
                    self.cameraService.capturePhoto(
                        isDNG: self.selectedPhotoFormat == .dng,
                        isHEIF: self.selectedPhotoFormat == .heif || self.selectedPhotoFormat == .heic
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isShutterPressing = false
                        self.superResolutionProgressText = nil
                    }
                    return
                }

                Task {
                    do {
                        let finalCGImage = try await SuperResolutionRAWEngine.shared.processBurst(
                            frames: frames,
                            progress: { [weak self] (prog: Float, desc: String) in
                                DispatchQueue.main.async {
                                    self?.superResolutionProgressText = desc
                                }
                            }
                        )

                        let anchorFrame = frames[0]
                        DispatchQueue.main.async {
                            self.superResolutionProgressText = nil
                            self.isShutterPressing = false
                            self.cameraService(
                                self.cameraService,
                                didCapturePhoto: finalCGImage,
                                rawData: nil,
                                livePhotoMovieURL: nil,
                                iso: anchorFrame.iso,
                                shutterSpeed: anchorFrame.shutterSpeed
                            )
                        }
                    } catch {
                        CameraLogger.error("Lỗi xử lý Super-Resolution RAW: \(error)", category: .capture)
                        if let fallbackCG = SuperResolutionRAWEngine.decodeFrameToCGImage(frame: frames[0], ciContext: SuperResolutionRAWEngine.shared.ciContext) {
                            let anchorFrame = frames[0]
                            DispatchQueue.main.async {
                                self.superResolutionProgressText = nil
                                self.isShutterPressing = false
                                self.cameraService(
                                    self.cameraService,
                                    didCapturePhoto: fallbackCG,
                                    rawData: nil,
                                    livePhotoMovieURL: nil,
                                    iso: anchorFrame.iso,
                                    shutterSpeed: anchorFrame.shutterSpeed
                                )
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.superResolutionProgressText = nil
                                self.isShutterPressing = false
                                self.aiSessionState = .done
                            }
                        }
                    }
                }
            }
        )
    }

    // MARK: - HEIF Encoding Helper (Embeds Orientation and Full EXIF Metadata)
    private nonisolated static func encodeImageToHEIF(cgImage: CGImage, metadata: [String: Any]) -> Data? {
        let outputData = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) {
            CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return outputData as Data
            }
        }

        // Dự phòng bằng CoreImage CIContext
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = ciImage.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:])
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
        let isHEIFFormat = (format == .heic || format == .heif)
        let uti: CFString = isHEIFFormat ? (UTType.heic.identifier as CFString) : (UTType.jpeg.identifier as CFString)
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

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
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
                            self.loadLatestPhotoFromAlbum()
                        } else {
                            CameraLogger.error("Lưu Live Photo thất bại, chuyển sang lưu ảnh tĩnh dự phòng", error: error, category: .photoKit)
                            self.saveFallbackStaticPhoto(item)
                        }
                    }
                }
            } else {
                // LƯU ẢNH TĨNH THƯỜNG (RAW DNG / HEIC / JPEG)
                if photoFormat == .dng, let rawData = item.rawPhotoData {
                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent("raw_\(UUID().uuidString).dng")
                    do {
                        try rawData.write(to: tempURL)
                    } catch {
                        CameraLogger.error("Không thể ghi tệp tạm DNG", error: error, category: .photoKit)
                        DispatchQueue.main.async {
                            self.saveFallbackStaticPhoto(item)
                        }
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = true
                        let dngUTI = UTType(filenameExtension: "dng")?.identifier ?? "com.adobe.raw-image"
                        options.uniformTypeIdentifier = dngUTI
                        creationRequest.addResource(with: .photo, fileURL: tempURL, options: options)
                    }) { success, error in
                        try? FileManager.default.removeItem(at: tempURL)
                        DispatchQueue.main.async {
                            if success {
                                CameraLogger.success("✅ Đã lưu ảnh RAW DNG gốc vào Cuộn Camera thành công!", category: .photoKit)
                                self.haptics.triggerSuccess()
                                self.saveErrorMessage = nil
                                self.loadLatestPhotoFromAlbum()
                            } else {
                                CameraLogger.error("Lưu ảnh RAW DNG thất bại, thử lưu JPEG dự phòng", error: error, category: .photoKit)
                                self.saveFallbackStaticPhoto(item)
                            }
                        }
                    }
                    return
                }

                if photoFormat == .heic || photoFormat == .heif {
                    var metadata: [String: Any] = [:]
                    if let rawData = item.rawPhotoData,
                       let source = CGImageSourceCreateWithData(rawData as CFData, nil),
                       let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                        metadata = meta
                    }
                    metadata[kCGImagePropertyOrientation as String] = 1

                    let heicData = Self.encodeImageToHEIF(cgImage: item.processedImage, metadata: metadata)
                    let origHeicData: Data? = shouldSaveOriginal ? Self.encodeImageToHEIF(cgImage: item.originalImage, metadata: metadata) : nil

                    if let mainHeicData = heicData {
                        PHPhotoLibrary.shared().performChanges({
                            let creationRequest = PHAssetCreationRequest.forAsset()
                            creationRequest.addResource(with: .photo, data: mainHeicData, options: nil)
                            if let origData = origHeicData {
                                let origRequest = PHAssetCreationRequest.forAsset()
                                origRequest.addResource(with: .photo, data: origData, options: nil)
                            }
                        }) { success, error in
                            DispatchQueue.main.async {
                                if success {
                                    CameraLogger.success("✅ Đã lưu ảnh HEIF/HEIC vào Cuộn Camera thành công!", category: .photoKit)
                                    self.haptics.triggerSuccess()
                                    self.saveErrorMessage = nil
                                    self.loadLatestPhotoFromAlbum()
                                } else {
                                    CameraLogger.error("Lưu ảnh HEIF thất bại, thử lưu JPEG dự phòng", error: error, category: .photoKit)
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
                            self.loadLatestPhotoFromAlbum()
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
                    self.loadLatestPhotoFromAlbum()
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
        let isFilmActive = self.isFilmSimulationActive
        let isWindowed = self.isWindowedZoomActive
        let windowFocal = self.windowedZoomFocalLength
        let windowAspect = self.windowedZoomAspectRatio

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
                if !isFilmActive || effectivePreset == .standard {
                    // Chế độ GỐC (TẮT màu) -> Giữ nguyên 100% cảm biến gốc iPhone, không qua CoreImage
                    processedImageResult = effectiveSourcePhoto
                } else if effectivePreset != .standard && !effectivePreset.isAIFullAuto {
                    // Ưu tiên 100% chất màu chuẩn mực của dòng máy vintage người dùng đã chọn
                    processedImageResult = FilmFilterEngine.shared.applyPreset(to: effectiveSourcePhoto, preset: effectivePreset) ?? effectiveSourcePhoto
                } else if let params = finalColorParams {
                    processedImageResult = FilmFilterEngine.shared.applyPresetAndAIParameters(to: effectiveSourcePhoto, preset: effectivePreset, params: params) ?? effectiveSourcePhoto
                } else {
                    processedImageResult = FilmFilterEngine.shared.applyPreset(to: effectiveSourcePhoto, preset: effectivePreset) ?? effectiveSourcePhoto
                }
            }

            let item = CapturedPhotoItem(
                originalImage: effectiveSourcePhoto,
                processedImage: processedImageResult,
                rawPhotoData: isWindowed ? nil : rawData,
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
        // AVCapture can reject a new request while an earlier capture is
        // finishing. Restore this request's UI state instead of stranding it
        // in .capturing; repeated failure callbacks are ignored below.
        guard aiSessionState == .capturing else { return }
        haptics.triggerSelectionChange()
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
        saveErrorMessage = "Chụp ảnh thất bại: \(error.localizedDescription). Vui lòng thử lại."
    }

    public func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {
        self.currentZoom = zoom
        self.displayZoom = self.cameraService.convertDeviceZoomToDisplayZoom(zoom)
        SpatialTrackingEngine.shared.updateZoomFactor(self.displayZoom)
    }
}
