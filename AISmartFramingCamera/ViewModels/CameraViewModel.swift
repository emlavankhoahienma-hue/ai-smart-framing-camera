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
    var showHistogramInViewfinder = true
    var isVideo = false
    var isAIVideoDirectorActive = false
    var isDualCameraActive = false
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
    private var lastVisionProcessTime: CFTimeInterval = 0

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

        // Zero-Cost Gate 1: Khi đang ngủ đông hoặc đang quay video,
        // lập tức thoát ngay mà không chạy bất kỳ tác vụ AI Vision, YOLO, Optical Flow, Histogram hay Peaking nào!
        guard !snapshot.isHibernating && !snapshot.isRecordingVideo else { return }

        // Zero-Cost Gate 2: Trong chế độ Video chuẩn (không bật AI Video Director),
        // TUYỆT ĐỐI KHÔNG nạp VisionFramingEngine, YOLOv12 hay tracking để đạt 60 FPS cứng, hoàn toàn không giật lag!
        if snapshot.isVideo && !snapshot.isAIVideoDirectorActive {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            stateLock.lock()
            latestPixelBuffer = pixelBuffer
            stateLock.unlock()

            guard !snapshot.isSettingsVisible else { return }
            let now = CACurrentMediaTime()

            if snapshot.isFocusPeakingEnabled, now - lastFocusPeakingComputeTime >= 0.05 {
                lastFocusPeakingComputeTime = now
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                FocusPeakingEngine.shared.processFrame(ciImage: ciImage, color: snapshot.focusPeakingColor) { [weak self] cgImage in
                    DispatchQueue.main.async {
                        self?.owner?.focusPeakingCGImage = cgImage
                    }
                }
            }

            if snapshot.showHistogramInViewfinder, now - lastHistogramComputeTime >= 0.10 {
                lastHistogramComputeTime = now
                let bars = RealtimeHistogramEngine.shared.computeHistogram(from: pixelBuffer)
                DispatchQueue.main.async { [weak self] in
                    self?.owner?.histogramBars = bars
                }
            }
            return
        }

        let frame = TrackingFrameContext.read(sampleBuffer,
            zoom: SpatialTrackingEngine.shared.currentDisplayZoom,
            fovLongDegrees: SpatialTrackingEngine.shared.currentCameraFOV)

        // CameraService invokes this method on its serial videoDataQueue. Processing
        // in place avoids an extra frame copy and never sends CMSampleBuffer across
        // another concurrency boundary.
        let now = CACurrentMediaTime()
        let visionInterval: CFTimeInterval = snapshot.isDualCameraActive ? (1.0 / 5.0) : 0
        if visionInterval == 0 || (now - lastVisionProcessTime >= visionInterval) {
            lastVisionProcessTime = now
            VisionFramingEngine.shared.processVideoSampleBuffer(sampleBuffer, orientation: .up, frameContext: frame)
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameContext = frame
        stateLock.unlock()

        guard !snapshot.isSettingsVisible else { return }

        if snapshot.tracksSuggestions, let frame,
           now - lastSuggestionUpdateTime >= 1.0 / 30.0 {
            lastSuggestionUpdateTime = now
            DispatchQueue.main.async { [weak self] in
                self?.owner?.refreshSuggestionProjection(frame: frame)
            }
        }
        if snapshot.showHistogramInViewfinder, now - lastHistogramComputeTime >= 0.10 {
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
    private var localCompositionAim: CompositionAimGeometry?
    @Published private(set) var localCompositionAimPoint: CGPoint?
    @Published private(set) var localAnalysisSummary = ""
    private var localAnalysisRequestID = UUID()
    private var localAnalysisCompletedAt: TimeInterval?
    private var localAnalysisTask: Task<Void, Never>?
    private var localAnalysisCancellation: CompositionAnalysisCancellation?
    private var localEvidenceCandidates: [NeuralSubjectCandidate] = []
    private var postZoomFaceCount = 0
    private var localAnalysisExpired = false
    private var localAnalysisFinished = false
    @Published public private(set) var localSuggestionRects: [CGRect] = []
    @Published public private(set) var localSelectionMessage: String? = nil
    @Published public private(set) var localAnalysisProgress = "Đang đọc ảnh và nhận diện chủ thể…"
    private var allowsAutoCaptureForCurrentTarget = true
    // MARK: - Services
    public let cameraService = CameraService.shared
    public weak var previewLayer: AVCaptureVideoPreviewLayer?
    public weak var previewContainerView: PreviewContainerView?
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
            localAnalysisRequestID = UUID()
            localAnalysisSummary = ""
            localAnalysisCompletedAt = nil
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
            localCompositionAim = nil
            localCompositionAimPoint = nil
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
                localCompositionAim = nil
                localCompositionAimPoint = nil
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
    @Published public var filmSimulationIntensity: Double = 1.0 {
        didSet { UserDefaults.standard.set(filmSimulationIntensity, forKey: "filmSimulationIntensity") }
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
            windowedZoomAspectRatio = captureMode.isVideo ? .ratio16_9 : .ratio3_4
            if oldValue == .proVideo && captureMode != .proVideo {
                proVideoService.resetToFullAuto()
            } else if captureMode == .proVideo {
                proVideoService.syncHardwareCapabilities()
            }
            updateFrameProcessingConfiguration()
            if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
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

    public var supportedVideoFormatOptions: [VideoFormatOption] {
        let opts = cameraService.supportedVideoFormatOptions
        return opts.isEmpty ? VideoFormatOption.allCases : opts
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
        let opts = cameraService.availableDisplayZoomOptions
        return opts.isEmpty ? [1.0, 2.0, 3.0] : opts
    }
    @Published public var activeZoomHUDText: String? = nil
    @Published public var isZoomHUDVisible: Bool = false
    private var zoomHUDDismissWorkItem: DispatchWorkItem? = nil

    public func presentZoomChangeHUD(displayZoom: CGFloat) {
        let label: String
        let isTele = displayZoom >= 1.95 && cameraService.hasPhysicalTelephotoLens
        if displayZoom < 0.75 {
            label = "0.5x • 13mm ULTRA WIDE"
        } else if displayZoom < 1.4 {
            label = "1.0x • 24mm WIDE"
        } else if displayZoom < 2.5 {
            label = isTele ? "2.0x • 48mm TELE" : "2.0x • 48mm"
        } else if displayZoom < 4.0 {
            label = isTele ? "\(String(format: "%.1f", displayZoom))x • 77mm TELE" : "\(String(format: "%.1f", displayZoom))x"
        } else {
            label = isTele ? "\(String(format: "%.1f", displayZoom))x • 120mm TELE" : "\(String(format: "%.1f", displayZoom))x"
        }

        zoomHUDDismissWorkItem?.cancel()
        activeZoomHUDText = label
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
            self.isZoomHUDVisible = true
        }

        let workItem = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.35)) {
                self?.isZoomHUDVisible = false
            }
        }
        zoomHUDDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
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

    // MARK: - Dual Concurrent Camera (PIP)
    @Published public var isDualCameraActive: Bool = false
    @Published public var isDualCameraSupported: Bool = CameraService.isDualCameraSupported

    public func toggleDualCamera() {
        guard isDualCameraSupported else {
            haptics.triggerError()
            showHUDNotice("Không hỗ trợ MultiCam")
            return
        }

        haptics.triggerSelectionChange()
        if isDualCameraActive {
            cameraService.stopDualCamera(primaryPreviewLayer: self.previewLayer) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isDualCameraActive = false
                    self.isCameraReady = true
                    self.updateFrameProcessingConfiguration()
                    self.previewContainerView?.syncDualCameraPrimaryLayer(
                        nil,
                        isDualActive: false,
                        singleSession: self.cameraService.captureSession
                    )
                    self.previewContainerView?.updateMetalPreviewState(
                        isActive: self.isFilmSimulationActive,
                        isDualCamera: false,
                        preset: self.selectedFilmPreset,
                        intensity: Float(self.filmSimulationIntensity)
                    )
                    self.showHUDNotice("Dual Cam: Tắt")
                }
            }
        } else {
            cameraService.startDualCamera(primaryPreviewLayer: self.previewLayer) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if success {
                        self.isDualCameraActive = true
                        self.isCameraReady = true
                        self.updateFrameProcessingConfiguration()
                        self.previewContainerView?.syncDualCameraPrimaryLayer(
                            self.cameraService.multiCamPrimaryPreviewLayer,
                            isDualActive: true,
                            singleSession: self.cameraService.captureSession
                        )
                        self.previewContainerView?.updateMetalPreviewState(
                            isActive: self.isFilmSimulationActive,
                            isDualCamera: true,
                            preset: self.selectedFilmPreset,
                            intensity: Float(self.filmSimulationIntensity)
                        )
                        self.showHUDNotice("Dual Cam PIP: Bật")
                    } else {
                        self.isDualCameraActive = false
                        self.isCameraReady = true
                        self.previewContainerView?.syncDualCameraPrimaryLayer(
                            nil,
                            isDualActive: false,
                            singleSession: self.cameraService.captureSession
                        )
                        self.previewContainerView?.updateMetalPreviewState(
                            isActive: self.isFilmSimulationActive,
                            isDualCamera: false,
                            preset: self.selectedFilmPreset,
                            intensity: Float(self.filmSimulationIntensity)
                        )
                        self.showHUDNotice("Không thể mở Dual Cam")
                    }
                }
            }
        }
    }

    public func setDualCameraPIPCorner(_ corner: DualCameraPIPCorner) {
        cameraService.currentDualCameraPIPCorner = corner
        DualCameraAssetRecorder.shared.pipCorner = corner
    }

    public func setDualCameraPIPScale(_ scale: CGFloat) {
        cameraService.currentDualCameraPIPScale = scale
        DualCameraAssetRecorder.shared.pipScale = scale
    }

    public func showHUDNotice(_ text: String) {
        zoomHUDDismissWorkItem?.cancel()
        activeZoomHUDText = text
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
            self.isZoomHUDVisible = true
        }

        let workItem = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.35)) {
                self?.isZoomHUDVisible = false
            }
        }
        zoomHUDDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    // MARK: - Screen Flash (Low-Light Selfie)
    @Published public var isScreenFlashOverlayVisible: Bool = false
    @Published public private(set) var currentCameraPosition: AVCaptureDevice.Position = .back
    @Published public private(set) var currentLiveISO: Float = 100
    @Published public private(set) var currentLiveExposureDuration: Double = 0.0
    private var previousScreenBrightness: CGFloat? = nil
    private var screenFlashWatchdogTask: Task<Void, Never>? = nil

    public var isFrontCamera: Bool {
        currentCameraPosition == .front
    }

    /// Phat hien dieu kien thieu sang cho camera truoc qua do choi Histogram hoac thong so ISO/man trap
    public var isLowLightCondition: Bool {
        let avgLum = RealtimeHistogramEngine.shared.averageLuminance
        if avgLum < 0.28 {
            return true
        }
        if currentLiveISO >= 450 || currentLiveExposureDuration >= 0.033 {
            return true
        }
        return false
    }

    /// Xac dinh xem co nen kich hoat Screen Flash khi chup anh khong
    public var shouldActivateScreenFlash: Bool {
        guard !captureMode.isVideo else { return false }
        guard isFrontCamera else { return false }
        switch activeFlashMode {
        case .on:
            return true
        case .auto:
            return isLowLightCondition
        case .off:
            return false
        @unknown default:
            return false
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
    @Published public var liveDetectedEntities: [LiveDetectedEntity] = [] {
        didSet { updateHeroPresentation() }
    }
    @Published public private(set) var heroDetectedEntities: [LiveDetectedEntity] = []
    private var heroIdentity = HeroIdentitySelector()

    private func updateHeroPresentation() {
        let now = CACurrentMediaTime()
        let candidates = liveDetectedEntities.filter { entity in
            guard entity.confidence.isFinite, entity.confidence >= 0.48,
                  now - entity.lastSeen < 0.35 else { return false }
            return entity.category != .face || !liveDetectedEntities.contains {
                $0.category == .human && $0.rect.contains(CGPoint(x: entity.rect.midX, y: entity.rect.midY))
            }
        }
        let scores = candidates.map { entity -> (UUID, Double) in
            let kind: CompositionSubjectKind
            switch entity.category {
            case .human: kind = .person
            case .face: kind = .face
            case .animal: kind = .animal
            case .foregroundObject: kind = .object
            case .general: kind = .scenery
            }
            let hasFace = liveDetectedEntities.contains {
                $0.category == .face && entity.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
            }
            return (entity.id, HeroSubjectPolicy.score(bounds: entity.rect, kind: kind,
                confidence: Double(entity.confidence), evidence: nil, hasFace: hasFace))
        }
        let selected = heroIdentity.select(scores, timestamp: now)
        guard var hero = candidates.first(where: { $0.id == selected }) else {
            heroDetectedEntities = []; return
        }
        if hero.category == .human {
            let members = candidates.filter { $0.category == .human &&
                ($0.id == hero.id || HeroSubjectPolicy.coherent(hero.rect, $0.rect)) }
            if members.count > 1 {
                hero.rect = members.dropFirst().reduce(hero.rect) { $0.union($1.rect) }
                hero.label = "Nhóm \(members.count) người"
            }
        }
        heroDetectedEntities = [hero]
    }
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

    /// Trạng thái khóa cứng mục tiêu khi tâm trắng khớp với tâm Target (0.5, 0.5)
    @Published public private(set) var isTargetLocked: Bool = false
    @Published public private(set) var lockedTargetPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var lockedDevicePose: simd_quatd? = nil
    private var lockedAtTime: CFTimeInterval = 0
    private var lastSubjectInLockTime: CFTimeInterval = 0

    /// Ngưỡng thoát khóa cơ sở (ở 1.0x: ~5.73° = 0.10 rad). Tự động co giãn theo mức Zoom thực tế (FOV).
    private let baseUnlockAngleThreshold: Double = 0.10

    /// Ngưỡng thoát khóa góc quay tích lũy Gyro co giãn động theo FOV/Zoom hiện tại
    private var dynamicUnlockAngleThreshold: Double {
        let zoom = max(1.0, Double(displayZoom))
        return baseUnlockAngleThreshold / zoom
    }

    // Smooth Unlock Handoff: Chuyển tiếp mượt từ (0.5, 0.5) sang vị trí mục tiêu mới khi mở khóa
    private var unlockHandoffStartTime: CFTimeInterval = 0
    private var unlockHandoffStartPoint: CGPoint? = nil
    private let unlockHandoffDuration: CFTimeInterval = 0.20

    private func lockHardTarget() {
        guard !isTargetLocked else { return }
        isTargetLocked = true
        lockedTargetPosition = CGPoint(x: 0.5, y: 0.5)
        currentTargetPoint = lockedTargetPosition
        lockedDevicePose = SpatialTrackingEngine.shared.latestPose()
        lockedAtTime = CACurrentMediaTime()
        lastSubjectInLockTime = lockedAtTime
        unlockHandoffStartPoint = nil
        unlockHandoffStartTime = 0
        alignmentGate.lockTarget()
        HapticFeedbackService.shared.triggerMagneticSnap()

        // Phase 4: Đồng bộ chu trình Khóa tâm Hard Lock với chuyển Zoom quang học Z* mượt mà
        let targetZoom = pendingSuggestedZoom
        if abs(displayZoom - targetZoom) > 0.15, !hasExecutedAutoZoomForSession {
            hasExecutedAutoZoomForSession = true
            triggerZoomRevealAnimation(targetZoom: targetZoom)
        }
    }

    private func unlockHardTargetLock() {
        guard isTargetLocked else { return }
        isTargetLocked = false
        lockedDevicePose = nil
        alignmentGate.unlockTarget()
        // Kích hoạt chuyển tiếp mượt (Smooth Unlock Handoff) từ (0.5, 0.5) sang vị trí mới
        unlockHandoffStartPoint = CGPoint(x: 0.5, y: 0.5)
        unlockHandoffStartTime = CACurrentMediaTime()
    }

    /// Quyết định Giữ khóa / Mở khóa bằng "Độ đồng thuận Không gian - Thị giác" (Spatial-Visual Coherence)
    private func shouldUnlockHardTarget() -> Bool {
        guard isTargetLocked else { return false }

        // 1. Nếu đang trong tiến trình chụp ảnh (Capture Sequence Active): Tuyệt đối giữ khóa 100%
        if aiSessionState == .capturing || isShutterPressing {
            return false
        }

        // 2. Điều kiện (a): Người dùng chủ động lia máy đi chỗ khác (Góc quay Gyro tích lũy vượt ngưỡng theo Zoom/FOV)
        if let lockedPose = lockedDevicePose,
           let currentPose = SpatialTrackingEngine.shared.latestPose() {
            let normLocked = simd_normalize(lockedPose)
            let normCurrent = simd_normalize(currentPose)
            let dot = max(-1.0, min(1.0, abs(simd_dot(normLocked.vector, normCurrent.vector))))
            let gyroAngle = 2.0 * acos(dot)
            if gyroAngle >= dynamicUnlockAngleThreshold {
                return true
            }
        }

        // 3. Điều kiện (b): Chống lỗi "Khóa vào không khí" (Subject moved away while phone is stationary)
        // Nếu máy tương đối tĩnh nhưng chủ thể AI/tâm điểm thực tế đã di chuyển ra xa hoặc mất dấu liên tục > 400ms:
        let now = CACurrentMediaTime()
        if now - lockedAtTime > 0.25 {
            let currentEstimated = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
            let distanceToCenter = hypot(currentEstimated.x - 0.5, currentEstimated.y - 0.5)
            let exitRadius = max(0.06, Double(alignmentRadius) * 2.2)

            let subjectStillNear = distanceToCenter <= exitRadius && hasFreshOpticalLock
            if subjectStillNear {
                lastSubjectInLockTime = now
            } else if now - lastSubjectInLockTime > 0.40 {
                // Chủ thể đã thực sự rời xa tâm khóa > 400ms trong khi máy đứng yên
                return true
            }
        }

        return false
    }

    private func hasUserPannedAwayFromLock() -> Bool {
        shouldUnlockHardTarget()
    }

    /// Tính tọa độ chuyển tiếp mượt (Smooth Unlock Handoff) nếu vừa mở khóa
    private func resolveUnlockHandoffPoint(target: CGPoint) -> CGPoint {
        guard let handoffStart = unlockHandoffStartPoint, unlockHandoffStartTime > 0 else {
            return target
        }
        let elapsed = CACurrentMediaTime() - unlockHandoffStartTime
        if elapsed < unlockHandoffDuration {
            let t = elapsed / unlockHandoffDuration
            let smoothT = t * t * (3.0 - 2.0 * t) // Hermite smoothstep
            return CGPoint(
                x: handoffStart.x + (target.x - handoffStart.x) * smoothT,
                y: handoffStart.y + (target.y - handoffStart.y) * smoothT
            )
        } else {
            unlockHandoffStartPoint = nil
            unlockHandoffStartTime = 0
            return target
        }
    }

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
    @Published public var isAIVideoDirectorActive: Bool = false {
        didSet { updateFrameProcessingConfiguration() }
    }
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
            let isConnected = NetworkMonitor.shared.checkConnection().isConnected
            return (useGeminiForAnalysis && geminiService.hasAPIKey && isConnected) ? .cloud : .local
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
                updateWindowedCameraHardwareZoom()
            } else {
                requestManualZoom(selectedZoomPreset, smooth: true)
            }
        }
    }
    @Published public var windowedZoomFocalLength: Double = 24.0 {
        didSet {
            if isWindowedZoomActive {
                updateWindowedCameraHardwareZoom()
            }
        }
    }
    @Published public var windowedZoomAspectRatio: WindowedZoomAspectRatio = .ratio3_4
    @Published public var windowedZoomNormalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published public var lastRecordedVideoWindowedFocal: Double? = nil
    @Published public var lastRecordedVideoWindowedAspect: WindowedZoomAspectRatio? = nil
    @Published public var lastRecordedVideoWindowedBaseZoom: CGFloat = 1.0
    @Published public var lastRecordedVideoWindowedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)

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
        let isBackground = (phase == .background)
        isAppInBackground = isBackground
        updateCameraHibernationState()
        if isBackground {
            if isDualCameraActive {
                toggleDualCamera()
            }
            deactivateScreenFlash()
            isCameraReady = false
            if wantsVideoRecording || recordingState != .idle {
                wantsVideoRecording = false
                cameraService.stopRecordingVideo()
            }
            if isAIVideoDirectorActive { dismissAIVideoDirector() }
            suspendSpatialTracking()
            cameraService.stop()
        } else if phase == .active {
            SpatialTrackingEngine.shared.prepare()
            guard hasCameraPermission else { return }
            if !cameraService.isSessionRunning {
                cameraService.start { [weak self] running in
                    self?.isCameraReady = running
                    if running { self?.applyPendingCaptureModeIfPossible() }
                }
            } else {
                isCameraReady = true
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
        didSet {
            UserDefaults.standard.set(showHistogramInViewfinder, forKey: "showHistogramInViewfinder")
            updateFrameProcessingConfiguration()
        }
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
    private var smoothedSmartFocusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private let focusEMAAlpha: CGFloat = 0.28
    private var ignoreSubjectAreaChangeUntil: CFTimeInterval = 0
    private var lastUserSunAdjustTime: CFTimeInterval = 0

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
        if defaults.object(forKey: "filmSimulationIntensity") != nil {
            let savedIntensity = defaults.double(forKey: "filmSimulationIntensity")
            self.filmSimulationIntensity = max(0.1, min(1.0, savedIntensity))
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
        // Mặc định ưu tiên Cloud AI khi người dùng đã cấu hình API Key;
        // nếu chưa có API Key hoặc mất mạng thì tự động dùng Local AI trên máy.
        if self.geminiService.hasAPIKey {
            if defaults.object(forKey: "useGeminiForAnalysis") != nil {
                self.useGeminiForAnalysis = defaults.bool(forKey: "useGeminiForAnalysis")
            } else {
                self.useGeminiForAnalysis = true
            }
        } else {
            self.useGeminiForAnalysis = defaults.bool(forKey: "useGeminiForAnalysis")
        }
        self.geminiService.onActiveKeyConfigured = { [weak self] hasKey in
            DispatchQueue.main.async {
                guard let self else { return }
                if hasKey {
                    self.useGeminiForAnalysis = true
                }
            }
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
        self.currentCameraPosition = self.cameraService.currentCameraPosition

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
                isRecordingVideo: isRecordingVideo,
                showHistogramInViewfinder: showHistogramInViewfinder,
                isVideo: captureMode.isVideo,
                isAIVideoDirectorActive: isAIVideoDirectorActive,
                isDualCameraActive: isDualCameraActive
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
        // 1. Kiểm tra ngay kho ảnh cục bộ Align Studio (0ms delay, không phụ thuộc quyền Photos)
        if let latest = AppPhotoStorageService.shared.latestRecord(),
           let thumb = AppPhotoStorageService.shared.loadThumbnailImage(for: latest) {
            let uiThumb = UIImage(cgImage: thumb)
            DispatchQueue.main.async { [weak self] in
                self?.latestAlbumThumbnail = uiThumb
            }
            return
        }

        // 2. Fallback: Nếu kho cục bộ rỗng, tải từ Apple Photos nếu đã cấp quyền
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
            SpatialTrackingEngine.shared.updateCameraFieldOfView(self.cameraService.effectiveVideoFieldOfView)
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
    /// Chuyen doi bounding box chuan hoa [0...1] upright (goc tren-trai) sang toa do hien thi tren preview layer
    public func convertMetadataRectToLayerRect(_ uprightRect: CGRect, in screenSize: CGSize) -> CGRect {
        guard !uprightRect.isEmpty, !uprightRect.isNull else { return .zero }
        let metadataOutputRect = CompositionPureCalculations.uprightToMetadataOutputRect(uprightRect)

        if let previewLayer = self.previewLayer, previewLayer.bounds.width > 0 && previewLayer.bounds.height > 0 {
            let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataOutputRect)
            if converted.width > 0 && converted.height > 0 && !converted.origin.x.isNaN && !converted.origin.y.isNaN {
                return converted
            }
        }

        // Fallback khi chua co previewLayer: su dung ty le aspect-fill cua camera buffer
        let aspect = SpatialTrackingEngine.shared.currentBufferAspect
        let scale = max(screenSize.width / aspect, screenSize.height)
        let midX = screenSize.width / 2.0
        let midY = screenSize.height / 2.0

        let posX = (uprightRect.midX - 0.5) * scale * aspect + midX
        let posY = (uprightRect.midY - 0.5) * scale + midY
        let boxW = uprightRect.width * scale * aspect
        let boxH = uprightRect.height * scale

        return CGRect(x: posX - boxW / 2.0,
                      y: posY - boxH / 2.0,
                      width: max(0, boxW),
                      height: max(0, boxH))
    }

    /// Chuyen doi diem Upright sang toa do man hinh Preview Layer (dung layerPointConverted hoac fallback)
    public func convertUprightPointToLayerPoint(_ uprightPoint: CGPoint, in screenSize: CGSize) -> CGPoint {
        if let previewLayer = self.previewLayer, previewLayer.bounds.width > 0 && previewLayer.bounds.height > 0 {
            let devPt = CompositionPureCalculations.uprightToCaptureDevicePoint(uprightPoint)
            let layerPt = previewLayer.layerPointConverted(fromCaptureDevicePoint: devPt)
            if layerPt.x.isFinite && layerPt.y.isFinite {
                return layerPt
            }
        }
        let aspect = SpatialTrackingEngine.shared.currentBufferAspect
        return TrackingGeometry.screenPoint(uprightPoint, size: screenSize, aspect: aspect)
    }

    public func cancelAIZoomForGesture() {
        manualZoomRequestID = nil
        // Tuyet doi khong xoa AI session, targetPoint hoac mang bounding box khi zoom 1x <-> 2x
        targetPinGeneration &+= 1
        alignmentGate.reset()
        pinchSettleWorkItem?.cancel()
        pinchSettleWorkItem = nil
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

        cameraService.onSelectedVideoFormatFallback = { [weak self] fallback in
            DispatchQueue.main.async {
                self?.selectedVideoFormatOption = fallback
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
                self.selectedZoomPreset = self.resolveClosestZoomPreset(for: disp)
            }
            SpatialTrackingEngine.shared.updateCameraFieldOfView(self.cameraService.effectiveVideoFieldOfView)
            SpatialTrackingEngine.shared.updateZoomFactor(disp)
            self.finishManualZoomIfSettled(zoom)
        }

        // Realtime Exposure Stats Listener (ISO & Shutter Speed)
        // Khi đang mở Cài đặt: bỏ qua cập nhật để không ép SwiftUI re-render toàn bộ
        // Form cài đặt mỗi frame (gây lag khi lướt). Đóng cài đặt là tự cập nhật lại.
        cameraService.onLiveCameraStatsUpdated = { [weak self] stats in
            guard let self = self, !self.isShowingSettings else { return }
            self.currentLiveISO = stats.iso
            self.currentLiveExposureDuration = stats.exposureDurationSeconds
            let isoInt = Int(round(stats.iso))
            let newISO = "ISO \(isoInt)"
            if self.liveISO != newISO {
                self.liveISO = newISO
            }
            if self.liveShutterSpeed != stats.shutterSpeedString {
                self.liveShutterSpeed = stats.shutterSpeedString
            }
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

        cameraService.onDualCameraStateChanged = { [weak self] isActive in
            guard let self = self else { return }
            self.isDualCameraActive = isActive
            self.isCameraReady = true
            self.updateFrameProcessingConfiguration()
            let dualLayer = isActive ? self.cameraService.multiCamPrimaryPreviewLayer : nil
            self.previewContainerView?.syncDualCameraPrimaryLayer(
                dualLayer,
                isDualActive: isActive,
                singleSession: self.cameraService.captureSession
            )
            self.previewContainerView?.updateMetalPreviewState(
                isActive: self.isFilmSimulationActive,
                isDualCamera: isActive,
                preset: self.selectedFilmPreset,
                intensity: Float(self.filmSimulationIntensity)
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
        let operational = isCameraReady || isDualCameraActive || cameraService.isAnySessionRunning
        if !operational {
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
        if isDualCameraActive {
            toggleDualCamera()
            showHUDNotice("Đã tắt Dual Cam để đổi camera")
            completion(true)
            return
        }
        isSwitchingCamera = true
        if aiSessionState != .idle {
            cancelAISession()
        }
        cameraService.switchCamera { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { completion(false); return }
                self.isSwitchingCamera = false
                if success {
                    self.currentCameraPosition = self.cameraService.currentCameraPosition
                    self.proVideoService.syncHardwareCapabilities()
                    SpatialTrackingEngine.shared.updateCameraFieldOfView(self.cameraService.effectiveVideoFieldOfView)
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
        let availableOptions = supportedVideoFormatOptions
        if let idx = availableOptions.firstIndex(of: selectedVideoFormatOption) {
            let nextIdx = (idx + 1) % availableOptions.count
            selectedVideoFormatOption = availableOptions[nextIdx]
        } else {
            selectedVideoFormatOption = availableOptions.first ?? .hd60
        }
    }


    private func setupMotionCallbacks() {
        SpatialTrackingEngine.shared.prepare()
        // Động cơ Tracking Không Gian Chuẩn Xác: Thống nhất một callback duy nhất
        SpatialTrackingEngine.shared.onSpatialTargetUpdated = { [weak self] point, _, quality in
            guard let self = self, !self.isShowingSettings else { return }

            if self.isTargetLocked {
                if self.lockedDevicePose == nil {
                    self.lockedDevicePose = SpatialTrackingEngine.shared.latestPose()
                }
                if self.shouldUnlockHardTarget() {
                    self.unlockHardTargetLock()
                    self.currentTargetPoint = self.resolveUnlockHandoffPoint(target: point)
                } else {
                    self.currentTargetPoint = self.lockedTargetPosition
                }
            } else {
                // Luồng Gyro 100Hz đi thẳng 100% không bị kẹp bước nhảy để tâm dính chặt không gian thực.
                // Nếu vừa mở khóa, áp dụng Smooth Unlock Handoff để chuyển tiếp êm ái từ tâm (0.5, 0.5).
                self.currentTargetPoint = self.resolveUnlockHandoffPoint(target: point)
            }
            // Quality describes evidence, not the colour/lifetime of the guide.
            // A predicted bearing remains visible without pretending it is optical.
            let seeding = quality == .reacquiring && self.latestOpticalPoint == nil &&
                CACurrentMediaTime() - self.targetPinStartedAt < 1.2
            self.trackingQuality = seeding ? .predicting : quality
            // Chỉ đánh giá alignment & countdown khi đang ở phase targetPlaced
            switch self.aiSessionState {
            case .targetPlaced, .alignmentPerfect:
                self.evaluateAlignment(at: self.currentTargetPoint ?? point)
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
        if isCameraHibernating { return }
        if captureMode != .photo { selectCaptureMode(.photo) }
        if isShutterPressing { isShutterPressing = false }
        if aiSessionState != .idle && aiSessionState != .done { cancelAISession() }

        let isOperational = isCameraReady || isDualCameraActive || cameraService.isAnySessionRunning
        guard isOperational, recordingState == .idle else { return }
        unlockHardTargetLock()
        if isWindowedZoomActive { isWindowedZoomActive = false }
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

        let isOnline = NetworkMonitor.shared.checkConnection().isConnected
        let shouldUseCloud = useGeminiForAnalysis && geminiService.hasAPIKey && isOnline
        let requestedAt = CACurrentMediaTime()

        if shouldUseCloud {
            activeModelUsedName = geminiService.activeModelID
            // Keep the exact camera frame and CoreMotion pose used by Gemini.
            requestFreshAIFrame(generation: requestGeneration, requestedAt: requestedAt) { [weak self] frame, buffer, context, pose in
                guard let self else { return }
                let nearbyDetection = self.latestSubjectDetectionResult
                self.cloudTrackingSource = AITrackingSource(buffer: buffer, frame: context, pose: pose,
                    subjectRect: nearbyDetection?.dominantSubjectRect,
                    faceRects: nearbyDetection?.faceRectangles ?? [])
                self.localTrackingSource = nil
                self.callGeminiAnalysis(frame: frame)
            }

            // If no camera frame arrives, use the local analysis instead of
            // leaving the session in .analyzing indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self = self else { return }
                if self.aiSessionGeneration == requestGeneration && self.aiSessionState == .analyzing && !self.isOneShotCaptured {
                    self.isOneShotCaptured = true
                    self.localSelectionMessage = "Camera chua gui anh AI. Cham vung muon chup hoac chup tay."
                }
            }
            // A captured frame can still be followed by a stalled cloud call.
            DispatchQueue.main.asyncAfter(deadline: .now() + geminiService.cloudAnalysisDeadline) { [weak self] in
                guard let self, self.aiSessionGeneration == requestGeneration,
                      self.aiSessionState == .analyzing, self.isGeminiAnalyzing else { return }
                self.isGeminiAnalyzing = false
                self.geminiError = "Cloud AI phan hoi cham, da tu dong chuyen sang AI tren may"
                self.analyzeCloudCaptureLocally()
            }
        } else {
            if !isOnline {
                self.localSelectionMessage = "Ngoai tuyen (khong co mang/4G) - Su dung AI tren may"
            }
            requestFreshAIFrame(generation: requestGeneration, requestedAt: requestedAt) { [weak self] _, buffer, context, pose in
                let source = AITrackingSource(buffer: buffer, frame: context, pose: pose,
                                              subjectRect: nil, faceRects: [])
                self?.beginLocalCompositionAnalysis(source: source)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
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
        unlockHardTargetLock()
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
        unlockHardTargetLock()
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

        var subjectAnchor = CGPoint(x: response.targetX, y: response.targetY)
        let subjectRect = normalizedSubjectRect(cloudTrackingSource?.subjectRect)

        // Nếu Cloud AI trả về tọa độ trung tâm (0.5, 0.5) nhưng cảm biến phát hiện chủ thể lệch tâm,
        // ưu tiên lấy mỏ neo thực tế của chủ thể.
        if let sRect = subjectRect, abs(subjectAnchor.x - 0.5) < 0.05 && abs(subjectAnchor.y - 0.5) < 0.05 {
            let sCenter = CGPoint(x: sRect.midX, y: sRect.midY)
            if abs(sCenter.x - 0.5) > 0.06 || abs(sCenter.y - 0.5) > 0.06 {
                subjectAnchor = sCenter
            }
        }

        let effectiveRect = subjectRect ?? CGRect(
            x: max(0.02, subjectAnchor.x - 0.12),
            y: max(0.02, subjectAnchor.y - 0.16),
            width: 0.24,
            height: 0.32
        )

        // Tính toán điểm ngắm bố cục (Composition Aim Projection) để đưa chủ thể về đúng điểm mạnh Tỷ lệ vàng / 1/3
        let cat: NeuralSubjectCategory = response.sceneType == .portrait ? .human : (response.sceneType == .pet ? .animal : .foregroundObject)
        let sceneEvidence = VisionFramingEngine.shared.latestSceneEvidence ?? SceneCompositionEvidence(
            primarySubjectRect: effectiveRect,
            focalAnchorPoint: subjectAnchor,
            focalCategory: cat,
            focalSaliencyRatio: 0.65,
            edgeClutterScore: 0.0,
            detectedScene: response.sceneType,
            detectedHorizonY: nil,
            timestamp: CACurrentMediaTime()
        )
        let evaluated = calculator.evaluateFramingResult(
            anchor: subjectAnchor,
            subjectRect: effectiveRect,
            category: cat,
            gaze: 0.0,
            sceneType: response.sceneType,
            currentZoom: displayZoom,
            availableZooms: cameraService.availableDisplayZoomOptions,
            sceneEvidence: sceneEvidence
        )
        self.framingResult = evaluated

        let chosenZoom = response.suggestedZoom > 1.05 ? response.suggestedZoom : evaluated.recommendedZoomFactor
        self.aiSuggestedZoom = chosenZoom
        self.pendingSuggestedZoom = chosenZoom

        var liveAim = evaluated.targetPoint
        var guideWorldRay: simd_double3? = nil
        if let source = cloudTrackingSource {
            let worldRay = source.pose.act(source.frame.calibration.deviceRay(at: evaluated.targetPoint))
            guideWorldRay = worldRay
            if let currentFrame = frameProcessor.latestTrackingFrameSnapshot()?.1,
               let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                    ?? SpatialTrackingEngine.shared.latestPose() {
                let proj = currentFrame.calibration.project(deviceRay: currentPose.inverse.act(worldRay))
                if proj.point.x.isFinite, proj.point.y.isFinite {
                    liveAim = proj.point
                }
            }
        }

        pinTargetAndStartMotion(
            at: liveAim,
            subjectRect: effectiveRect,
            source: cloudTrackingSource,
            trackedPoint: subjectAnchor,
            pinnedGuideRay: guideWorldRay
        )
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
        localCompositionAim = nil
        localCompositionAimPoint = nil
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

    private func requestFreshAIFrame(generation: Int, requestedAt: TimeInterval,
        completion: @escaping (CGImage, CVPixelBuffer, TrackingFrameContext, simd_quatd) -> Void) {
        visionEngine.captureNextFrameForGemini = true
        visionEngine.onFrameCapturedForAIWithSource = { [weak self] image, buffer, frame in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.aiSessionGeneration == generation,
                      self.aiSessionState == .analyzing, !self.isOneShotCaptured else { return }
                self.visionEngine.capturedGeminiFrame = nil
                let now = CACurrentMediaTime()
                let effectiveBuffer = buffer ?? self.cameraService.currentMultiCamPixelBuffer() ?? self.latestCameraPixelBuffer()
                let effectiveFrame = frame ?? TrackingFrameContext(
                    timestamp: now,
                    calibration: TrackingCalibration.fallback(fovLongDegrees: CompositionTuning.defaultCameraFOVWide, zoom: Double(self.displayZoom), aspect: 9.0/16.0),
                    imageSize: CGSize(width: effectiveBuffer.map { CGFloat(CVPixelBufferGetWidth($0)) } ?? 1080,
                                      height: effectiveBuffer.map { CGFloat(CVPixelBufferGetHeight($0)) } ?? 1920),
                    displayZoom: Double(self.displayZoom)
                )
                let frameTimestamp = effectiveFrame.timestamp
                let isFresh = frameTimestamp >= (requestedAt - 0.25) || (now - requestedAt >= 0.8)
                guard self.manualZoomRequestID == nil, !self.isPinchingZoom, isFresh else {
                    if now - requestedAt < 5 {
                        self.requestFreshAIFrame(generation: generation, requestedAt: requestedAt, completion: completion)
                        self.visionEngine.captureNextFrameForGemini = true
                    } else {
                        self.localAnalysisFinished = true
                        self.localSelectionMessage = "Chưa lấy được ảnh mới. Bấm AI để thử lại."
                    }
                    return
                }
                let effectivePose = SpatialTrackingEngine.shared.pose(at: frameTimestamp)
                    ?? SpatialTrackingEngine.shared.latestPose()
                    ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
                guard let finalBuffer = effectiveBuffer else {
                    self.localAnalysisFinished = true
                    self.localSelectionMessage = "Không lấy được khung hình camera. Bấm AI để thử lại."
                    return
                }
                self.isOneShotCaptured = true
                completion(image, finalBuffer, effectiveFrame, effectivePose)
            }
        }
    }

    private func beginLocalCompositionAnalysis(source: AITrackingSource) {
        localAnalysisCompletedAt = nil
        localAnalysisCancellation?.cancel()
        localAnalysisTask?.cancel()
        let cancellation = CompositionAnalysisCancellation()
        localAnalysisCancellation = cancellation
        localTrackingSource = source
        localSelectionMessage = nil
        localAnalysisExpired = false
        localAnalysisFinished = false
        localAnalysisProgress = "Đang đọc ảnh và nhận diện chủ thể…"
        let generation = aiSessionGeneration
        let requestID = localAnalysisRequestID
        let zooms = cameraService.availableDisplayZoomOptions
        localAnalysisTask = Task { [weak self] in
            let preferences = await CompositionPreferenceStore.shared.bonuses()
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    NeuralSubjectIntelligenceEngine.shared.analyzeComposition(
                        pixelBuffer: source.buffer, frame: source.frame, pose: source.pose,
                        allowedZooms: zooms, preferences: preferences, requestID: requestID, cancellation: cancellation,
                        progress: { [weak self] message in
                            Task { @MainActor [weak self] in
                                guard let self, self.aiSessionGeneration == generation,
                                      self.aiSessionState == .analyzing, !self.localAnalysisFinished,
                                      !cancellation.isCancelled else { return }
                                self.localAnalysisProgress = message
                            }
                        })
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
        guard let receipt = analysis.receipt,
              receipt.belongs(to: localAnalysisRequestID, timestamp: source.frame.timestamp) else { return }
        localAnalysisSummary = receipt.usedSpecialist ?
            String(format: "%d khung · AI tối ưu · %.2f giây", receipt.assessedFrames, receipt.elapsed) :
            "Chưa hoàn tất mô hình bố cục"
        CameraLogger.info("Composition request \(receipt.requestID): frame=\(receipt.sourceTimestamp), assessments=\(receipt.assessedFrames), seconds=\(receipt.elapsed)", category: .ai)
        localAnalysisCompletedAt = CACurrentMediaTime()
        localAnalysisFinished = true
        geminiError = nil
        guard source.frame.displayZoom.isFinite, source.frame.displayZoom > 0,
              abs(displayZoom - CGFloat(source.frame.displayZoom)) <= 0.35 else {
            localTrackingSource = nil
            localSelectionMessage = nil
            cancelAISession()
            startAISession()
            return
        }
        let output = analysis.detection
        detectedScene = output.detectedScene
        detectedFaceRects = output.allFaceRects
        postZoomFaceCount = output.primaryFaceCount
        let localPreset = output.detectedScene.recommendedFilter
        aiRecommendedPreset = localPreset
        aiPresetMatchReason = "\(localPreset.displayName) — Gợi ý theo bối cảnh \(output.detectedScene.localizedName)"
        if selectedFilmPreset.isAIFullAuto { selectedFilmPreset = localPreset }
        if isAIFullColorEnabled { currentAIColorParams = output.detectedScene.aiFullColorParameters }
        localCompositionChoices = analysis.choices
        localEvidenceCandidates = !analysis.choices.isEmpty ? analysis.choices.map(\.candidate) :
            (!analysis.fallbackCandidates.isEmpty ? analysis.fallbackCandidates : analysis.detection.allCandidates)
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
        if analysis.usedCompositionModel {
            activeEngineSource = .compositionLocal(label: output.detectedScene.localizedName)
        } else if output.usedSemanticModel {
            activeEngineSource = .semanticLocal(label: output.detectedScene.localizedName)
        } else if YOLODetectionEngine.shared.hasYOLOModel {
            activeEngineSource = .yoloNeural(label: output.detectedScene.localizedName)
        } else {
            activeEngineSource = .appleNeuralEngine(scene: output.detectedScene.localizedName)
        }
        // AI decides the best photographic composition and zoom; accept the active photographic plan directly
        let activeChoice = localCompositionChoices.first(where: { !$0.preservesOriginalFrame }) ?? localCompositionChoices.first
        if let first = activeChoice,
           CACurrentMediaTime() - source.frame.timestamp <= 30,
           first.plan.confidence >= first.plan.minimumAutoselectConfidence {
            acceptLocalPlan(first.plan, source: source)
        } else if let first = activeChoice,
                  CACurrentMediaTime() - source.frame.timestamp <= 30 {
            acceptLocalPlan(first.plan, source: source)
        } else if let first = localEvidenceCandidates.first {
            allowsAutoCaptureForCurrentTarget = true
            let anchor = first.eyePosition ?? (first.category == .human ? CGPoint(x: first.center.x, y: first.boundingBox.minY + first.boundingBox.height * 0.28) : first.center)

            // Phase 4: AI Tự Quyết định Mức Zoom bằng Đấu loại Khung cắt Ảo & Pre-Zoom Target Projection
            let sceneEvidence = VisionFramingEngine.shared.latestSceneEvidence ?? SceneCompositionEvidence(
                primarySubjectRect: first.boundingBox,
                focalAnchorPoint: anchor,
                focalCategory: first.category,
                focalSaliencyRatio: 0.50,
                edgeClutterScore: 0.0,
                detectedScene: self.detectedScene,
                detectedHorizonY: nil,
                timestamp: CACurrentMediaTime()
            )
            let evaluatedFraming = self.calculator.evaluateFramingResult(
                anchor: anchor,
                subjectRect: first.boundingBox,
                category: first.category,
                gaze: first.gaze,
                sceneType: self.detectedScene,
                currentZoom: self.displayZoom,
                availableZooms: self.cameraService.availableDisplayZoomOptions,
                sceneEvidence: sceneEvidence
            )
            let aimPoint = evaluatedFraming.targetPoint
            self.activeCompositionRule = evaluatedFraming.optimalRule
            self.framingResult = evaluatedFraming
            self.pendingSuggestedZoom = evaluatedFraming.recommendedZoomFactor
            self.aiSuggestedZoom = evaluatedFraming.recommendedZoomFactor
            var liveAim = aimPoint
            let worldRay = source.pose.act(source.frame.calibration.deviceRay(at: aimPoint))
            if let currentFrame = frameProcessor.latestTrackingFrameSnapshot()?.1,
               let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                    ?? SpatialTrackingEngine.shared.latestPose() {
                let proj = currentFrame.calibration.project(deviceRay: currentPose.inverse.act(worldRay))
                if proj.point.x.isFinite, proj.point.y.isFinite {
                    liveAim = proj.point
                }
            }
            pinTargetAndStartMotion(at: liveAim, subjectRect: first.boundingBox, source: source, pinnedGuideRay: worldRay)
            localTrackingSource = nil
            localSelectionMessage = nil
        } else {
            allowsAutoCaptureForCurrentTarget = false
            let centerRect = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
            let centerAim = localEvidenceCandidates.first?.center ?? CGPoint(x: 0.5, y: 0.45)
            let worldRay = source.pose.act(source.frame.calibration.deviceRay(at: centerAim))
            pinTargetAndStartMotion(at: centerAim, subjectRect: centerRect, source: source, pinnedGuideRay: worldRay)
            localTrackingSource = nil
            localSelectionMessage = nil
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
              let completedAt = localAnalysisCompletedAt,
              CompositionAnalysisReceipt.acceptsSelection(sourceTimestamp: source.frame.timestamp,
                  completedAt: completedAt, now: CACurrentMediaTime()) else {
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
        allowsAutoCaptureForCurrentTarget = true
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
        let hero = localEvidenceCandidates.first
        let anchor = hero?.eyePosition ?? plan.subjectPoint
        let category = hero?.category ?? .foregroundObject
        let gaze = hero?.gaze ?? 0
        let availableZooms = cameraService.availableDisplayZoomOptions
        let evaluatedFraming = calculator.evaluateFramingResult(
            anchor: anchor,
            subjectRect: plan.subjectRect,
            category: category,
            gaze: gaze,
            sceneType: detectedScene,
            currentZoom: displayZoom,
            availableZooms: availableZooms,
            horizonY: visionEngine.latestSceneEvidence?.detectedHorizonY,
            activeRule: nil,
            sceneEvidence: visionEngine.latestSceneEvidence
        )

        var sourceAimPoint = plan.aimPointInSource
        var effectiveGuideRay = plan.aimWorldRay
        let planDistFromCenter = hypot(sourceAimPoint.x - 0.5, sourceAimPoint.y - 0.5)
        // Khắc phục triệt để lỗi Target nằm lì ở tâm (0.5, 0.5):
        // Khi static crop ở 1x không dịch được góc ảnh ra ngoài [0, 1], dùng phép chiếu hướng xoay máy 3D
        // từ CompositionCalculator để dẫn đường đưa chủ thể vào điểm mạnh Tỷ lệ vàng / 1/3.
        if planDistFromCenter < 0.09 && detectedScene != .architecture {
            sourceAimPoint = evaluatedFraming.targetPoint
            effectiveGuideRay = source.pose.act(source.frame.calibration.deviceRay(at: sourceAimPoint))
        }

        var effectiveZoom = plan.zoom
        if effectiveZoom <= displayZoom * 1.12 && evaluatedFraming.recommendedZoomFactor > effectiveZoom * 1.12 {
            effectiveZoom = evaluatedFraming.recommendedZoomFactor
        }
        effectiveZoom = cameraService.convertDeviceZoomToDisplayZoom(
            cameraService.convertDisplayZoomToDeviceZoom(effectiveZoom))

        var liveAimPoint = sourceAimPoint
        if let currentFrame = frameProcessor.latestTrackingFrameSnapshot()?.1,
           let currentPose = SpatialTrackingEngine.shared.pose(at: currentFrame.timestamp)
                ?? SpatialTrackingEngine.shared.latestPose() {
            let projectedAim = currentFrame.calibration.project(
                deviceRay: currentPose.inverse.act(effectiveGuideRay))
            if projectedAim.point.x.isFinite, projectedAim.point.y.isFinite {
                liveAimPoint = projectedAim.point
            }
        }
        let dx = liveAimPoint.x - 0.5
        let dy = liveAimPoint.y - 0.5
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        if planDistFromCenter < 0.09 && detectedScene != .architecture {
            activeCompositionRule = evaluatedFraming.optimalRule
        } else if plan.explanation.contains("Tỷ lệ vàng") || plan.explanation.contains("Golden") {
            activeCompositionRule = .goldenRatio
        } else if plan.usesCenter && detectedScene == .architecture {
            activeCompositionRule = .centerSymmetry
        } else {
            activeCompositionRule = .ruleOfThirds
        }
        localCompositionIntent = plan.intent
        let zoomText = abs(effectiveZoom - displayZoom) > 0.12 ? String(format: " · Smart Zoom %.1fx", effectiveZoom) : ""
        localCompositionExplanation = plan.explanation + zoomText
        framingResult = FramingTargetResult(targetPoint: liveAimPoint,
            currentCenter: CGPoint(x: 0.5, y: 0.5),
            offsetVector: CGVector(dx: dx, dy: dy), distance: distance,
            angleDegrees: angle < 0 ? angle + 360 : angle,
            alignmentScore: max(0, min(1, 1 - Double(distance / 0.40))),
            isAligned: distance <= calculator.alignmentTolerance,
            recommendedZoomFactor: effectiveZoom, optimalRule: activeCompositionRule,
            guideDescription: localCompositionExplanation)
        pendingSuggestedZoom = effectiveZoom
        aiSuggestedZoom = effectiveZoom
        hasExecutedAutoZoomForSession = false
        allowsAutoCaptureForCurrentTarget = true
        localCompositionChoices = []
        localEvidenceCandidates = []
        localSuggestionRects = []
        detectedSubjectRects = []
        localSelectionMessage = nil
        // Track the physical subject with Vision/EKF while guiding the reticle along effectiveGuideRay.
        let trackedSubjectPoint = hero?.trackingPoint ?? anchor
        pinTargetAndStartMotion(at: liveAimPoint,
            subjectRect: plan.subjectRect, source: source,
            trackedPoint: trackedSubjectPoint, pinnedGuideRay: effectiveGuideRay)
        if let seed = pinTrackingBox {
            setSubjectCropBounds(plan.cropProtectionRect, seedBox: seed)
        }
        localCompositionAim = nil
        localCompositionAimPoint = nil
        localTrackingSource = nil
    }

    private func compositionAlignmentPoint(fallback: CGPoint) -> CGPoint {
        return fallback
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
        unlockHardTargetLock()
        unlockHandoffStartPoint = nil
        unlockHandoffStartTime = 0
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
                // Show the composition guide bearing so the user pans the subject into the power point.
                let reticleRay = ray
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
        guard pendingManualZoomTarget == nil,
              latestOpticalFrameTimestamp > manualZoomSettledAt + 0.05 else { return false }
        if ((0...0.35).contains(age) || (0...0.55).contains(age)),
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
        guard displayZoom > 0, target > 0 else { return false }
        guard let box = currentSubjectCropBox else { return true }
        let k = latestOpticalCalibration ?? TrackingCalibration.fallback(fovLongDegrees: cameraService.effectiveVideoFieldOfView, zoom: Double(displayZoom))
        let ratio = target / displayZoom
        let cx = CGFloat(k.cx), cy = CGFloat(k.cy)
        let projectedMinX = cx + (box.minX - cx) * ratio
        let projectedMaxX = cx + (box.maxX - cx) * ratio
        let projectedMinY = cy + (box.minY - cy) * ratio
        let projectedMaxY = cy + (box.maxY - cy) * ratio
        let centerInside = (0.04...0.96).contains((projectedMinX + projectedMaxX) * 0.5) &&
            (0.04...0.96).contains((projectedMinY + projectedMaxY) * 0.5)
        let boundsReasonable = projectedMinX >= -0.12 && projectedMaxX <= 1.12 &&
            projectedMinY >= -0.06 && projectedMaxY <= 1.18
        return centerInside && boundsReasonable
    }

    private var alignmentRadius: CGFloat {
        let aspect = max(0.1, SpatialTrackingEngine.shared.currentBufferAspect)
        let width = max(viewfinderSize.width, viewfinderSize.height * aspect)
        return width > 0 ? 16 / width : calculator.alignmentTolerance
    }

    private func evaluateAlignment(at point: CGPoint) {
        guard !captureMode.isVideo, !isCameraHibernating, !isShutterPressing else { return }
        if zoomFallbackAfter.isFinite, CACurrentMediaTime() - zoomFallbackAfter > 1.8 {
            zoomFallbackAfter = .infinity
            zoomVerified = true
            allowsAutoCaptureForCurrentTarget = true
            localSelectionMessage = nil
        }
        let aim = isTargetLocked ? lockedTargetPosition : compositionAlignmentPoint(fallback: point)
        let dx = aim.x - 0.5, dy = aim.y - 0.5
        let aspect = max(0.1, SpatialTrackingEngine.shared.currentBufferAspect)
        let distance = hypot(dx, dy / aspect)
        alignmentDistance = distance
        let state = alignmentGate.update(time: CACurrentMediaTime(), distance: Double(distance),
            radius: Double(alignmentRadius), freshEvidence: (hasFreshOpticalLock || isTargetLocked) && !isPinchingZoom)
        isPerfectAlignment = alignmentGate.isAligned && !localCompositionNeedsLevel
        if !isTargetLocked && state == .ready && !localCompositionNeedsLevel {
            lockHardTarget()
        }
        guard state != .outside else {
            autoCaptureTask?.cancel(); autoCaptureTask = nil
            lastFailedCaptureOpticalTimestamp = -.infinity
            lastFailedCaptureAttemptTime = -.infinity
            if !zoomAwaitingVerification && pendingManualZoomTarget == nil {
                zoomVerified = true
            }
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
        guard state == .ready, (hasFreshOpticalLock || isTargetLocked), !isPreparingPinZoom,
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
                } else {
                    hasExecutedAutoZoomForSession = true
                }
            } else {
                hasExecutedAutoZoomForSession = true
            }
        }
        guard zoomVerified, !localCompositionNeedsLevel, isAutoCaptureOnAlignEnabled, allowsAutoCaptureForCurrentTarget,
              autoCaptureTask == nil,
              (latestOpticalFrameTimestamp > lastFailedCaptureOpticalTimestamp || CACurrentMediaTime() - lastFailedCaptureAttemptTime >= 0.20) else { return }
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
                (self.hasFreshOpticalLock || self.isTargetLocked) && self.alignmentGate.isAligned &&
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
        let deadline = CACurrentMediaTime() + 3.8
        var reachedAt: TimeInterval?
        while CACurrentMediaTime() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard !Task.isCancelled, targetPinGeneration == pinGeneration,
                  !isPinchingZoom else { return }
            let reached = abs(displayZoom - pendingTargetZoomForReveal) <= 0.08
            if reached {
                if reachedAt == nil { reachedAt = CACurrentMediaTime() }
                if latestOpticalFrameTimestamp > (reachedAt ?? .infinity) + 0.05 || CACurrentMediaTime() - (reachedAt ?? 0) >= 0.12 {
                    guard await verifyPostZoomFaces(after: (reachedAt ?? CACurrentMediaTime())) else {
                        restoreOriginalZoomAfterVerificationFailure()
                        return
                    }
                    // Zoom reached target and settled
                    zoomVerified = true
                    zoomAwaitingVerification = false
                    zoomFallbackAfter = .infinity
                    localSelectionMessage = nil

                    let point = currentTargetPoint ?? CGPoint(x: 0.5, y: 0.5)
                    latestOpticalPoint = point
                    latestOpticalFrameTimestamp = CACurrentMediaTime()
                    latestOpticalBox = CGRect(x: max(0, point.x - 0.08), y: max(0, point.y - 0.08), width: 0.16, height: 0.16)
                    latestOpticalCalibration = latestOpticalCalibration ?? TrackingCalibration.fallback(fovLongDegrees: cameraService.effectiveVideoFieldOfView, zoom: Double(displayZoom))
                    alignmentGate.reset()
                    lastFailedCaptureOpticalTimestamp = -.infinity
                    lastFailedCaptureAttemptTime = -.infinity

                    withAnimation(.easeOut(duration: 0.35)) {
                        self.isRevealingZoomTarget = false
                        self.isZoomRampPhase = false
                    }
                    selectedZoomPreset = resolveClosestZoomPreset(for: displayZoom)
                    return
                }
            } else {
                reachedAt = nil
            }
        }
        guard !Task.isCancelled, targetPinGeneration == pinGeneration else { return }
        restoreOriginalZoomAfterVerificationFailure()
    }

    private func restoreOriginalZoomAfterVerificationFailure() {
        zoomVerificationTask?.cancel()
        zoomVerificationTask = nil
        cameraService.cancelZoomRamp()
        zoomVerified = false
        zoomAwaitingVerification = false
        zoomFallbackAfter = CACurrentMediaTime()
        alignmentGate.reset()
        postZoomRecovery.reset()
        lastFailedCaptureOpticalTimestamp = -.infinity
        lastFailedCaptureAttemptTime = -.infinity
        let originalDeviceZoom = cameraService.convertDisplayZoomToDeviceZoom(zoomRevealStartDisplayZoom)
        cameraService.setZoomFactor(originalDeviceZoom)
        hasExecutedAutoZoomForSession = true
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
              snapshot.1.timestamp > max(minimumTimestamp - 0.25, latestOpticalFrameTimestamp - 0.5) else {
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
                if (try? cancellation.perform(request, with: handler)) != nil,
                   let results = request.results, !results.isEmpty {
                    return results.filter { $0.confidence >= 0.35 }.map(\.boundingBox)
                }
                let rightHandler = VNImageRequestHandler(cvPixelBuffer: frame.buffer,
                                                         orientation: .right, options: [:])
                guard (try? cancellation.perform(request, with: rightHandler)) != nil,
                      let results = request.results else { return nil }
                return results.filter { $0.confidence >= 0.35 }.map(\.boundingBox)
            }.value
        } onCancel: { cancellation.cancel() }
        guard !Task.isCancelled, let faces = rectangles,
              CACurrentMediaTime() - snapshot.1.timestamp <= 0.50 else { return false }
        return faces.count >= min(1, postZoomFaceCount) && faces.allSatisfy {
            let r = $0
            return r.minX >= 0.01 && r.maxX <= 0.99 &&
                   r.minY >= 0.01 && r.maxY <= 0.99
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
        guard hasFreshOpticalLock || isTargetLocked else { return false }
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
    private var pinchSettleWorkItem: DispatchWorkItem?

    public func beginManualZoomGesture() {
        guard !isPinchingZoom, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        pinchSettleWorkItem?.cancel()
        pinchSettleWorkItem = nil
        isPinchingZoom = true
    }

    public func resolveClosestZoomPreset(for disp: CGFloat) -> CGFloat {
        let options = cameraService.availableDisplayZoomOptions
        if options.isEmpty {
            if disp < 0.75 { return 0.5 }
            if disp < 1.5 { return 1.0 }
            if disp < 2.5 { return 2.0 }
            return 3.0
        }
        return options.min(by: { abs($0 - disp) < abs($1 - disp) }) ?? 1.0
    }

    public func updateWindowedCameraHardwareZoom() {
        guard isWindowedZoomActive, isCameraReady, !isCameraHibernating else { return }
        let focal = windowedZoomFocalLength
        let requestedDisplayZoom = focal / 24.0
        let targetDisplayZoom: CGFloat
        let teleOpticalDisplay = cameraService.telephotoOpticalDisplayZoom ?? 2.0

        if cameraService.hasPhysicalTelephotoLens && requestedDisplayZoom >= (teleOpticalDisplay - 0.1) {
            // Tieu cu tuong duong telephoto quang hoc: kich hoat truc tiep cam Telephoto vat ly
            targetDisplayZoom = teleOpticalDisplay
        } else {
            // Tieu cu goc rong: Dung cam Chinh Wide
            targetDisplayZoom = 1.0
        }

        cameraService.applyDisplayZoomWithPhysicalLensSwitching(targetDisplayZoom, smooth: true, rate: 4.5, allowPhysicalSwitch: true)
        presentZoomChangeHUD(displayZoom: targetDisplayZoom)
    }

    private func requestManualZoom(_ displayZoomVal: CGFloat, smooth: Bool = false) {
        presentZoomChangeHUD(displayZoom: displayZoomVal)
        let requestID = UUID()
        manualZoomRequestID = requestID
        manualZoomSettledAt = CACurrentMediaTime()
        cameraService.applyDisplayZoomWithPhysicalLensSwitching(displayZoomVal, smooth: smooth, rate: 4.5, allowPhysicalSwitch: true) { [weak self] actualDeviceZoom in
            guard let self, self.manualZoomRequestID == requestID else { return }
            self.manualZoomRequestID = nil
            self.pendingManualZoomTarget = nil
            self.manualZoomSettledAt = CACurrentMediaTime()
            self.zoomVerified = actualDeviceZoom != nil
            self.alignmentGate.reset()
        }
    }

    public func setZoom(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        requestManualZoom(displayZoomVal, smooth: true)
    }

    /// Zoom lien tuc muot ma khi nguoi dung vuot/pinch bang hai ngon tay
    /// Thuat toan tach pha cu chi (Gesture-Phase Decoupling) phong cach Google Camera / GCam:
    /// - Khi hai ngon tay dang di chuyen: KHONG reconfigure captureSession de giu pipeline 60 FPS cuc ky muot ma (allowPhysicalSwitch = false).
    /// - Khi dung tay 160ms (debounced settle) hoac nhac tay (finishZoomGesture): Kich hoat switch sang camera Telephoto vat ly voi allowPhysicalSwitch = true.
    public func setZoomContinuous(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        if !isPinchingZoom { beginManualZoomGesture() }
        selectedZoomPreset = resolveClosestZoomPreset(for: displayZoomVal)
        let now = CACurrentMediaTime()
        if now - lastContinuousZoomTime >= 0.025 || abs(displayZoomVal - lastContinuousAppliedZoom) > 0.08 {
            lastContinuousZoomTime = now
            lastContinuousAppliedZoom = displayZoomVal
            cameraService.applyDisplayZoomWithPhysicalLensSwitching(displayZoomVal, smooth: false, allowPhysicalSwitch: false)
        }

        pinchSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPinchingZoom else { return }
            self.cameraService.applyDisplayZoomWithPhysicalLensSwitching(displayZoomVal, smooth: false, allowPhysicalSwitch: true)
        }
        pinchSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    /// Chot zoom cuoi cung khi nguoi dung nhac ngon tay ket thuc pinch
    public func finishZoomGesture(_ finalDisplayZoom: CGFloat) {
        pinchSettleWorkItem?.cancel()
        pinchSettleWorkItem = nil
        guard isCameraReady, !isShutterPressing, !isCameraHibernating else {
            isPinchingZoom = false
            return
        }
        guard finalDisplayZoom.isFinite else { return }
        if !isPinchingZoom { beginManualZoomGesture() }
        selectedZoomPreset = resolveClosestZoomPreset(for: finalDisplayZoom)
        lastContinuousAppliedZoom = finalDisplayZoom
        isPinchingZoom = false
        requestManualZoom(finalDisplayZoom)
        haptics.triggerSelectionChange()
    }

    public func setZoomFromButton(_ displayZoomVal: CGFloat) {
        guard displayZoomVal.isFinite, isCameraReady, !isShutterPressing, !isCameraHibernating else { return }
        cancelAIZoomForGesture()
        haptics.triggerSelectionChange()
        selectedZoomPreset = displayZoomVal
        requestManualZoom(displayZoomVal, smooth: true)
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
        CameraLogger.info("[LOCK] DA KHOA AE/AF tai (\(String(format: "%.2f", normalizedPoint.x)), \(String(format: "%.2f", normalizedPoint.y)))", category: .capture)
    }

    public func unlockAEAF() {
        unlockHardTargetLock()
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
        CameraLogger.info("[UNLOCK] DA MO KHOA AE/AF", category: .capture)
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
        FilmFilterEngine.shared.clearCache()
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
        FilmFilterEngine.shared.clearCache()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            isFilmSimulationActive.toggle()
            if !isFilmSimulationActive {
                isAIFullColorEnabled = false
            }
        }
    }

    public func latestCameraPixelBuffer() -> CVPixelBuffer? {
        return frameProcessor.latestPixelBufferSnapshot()
    }

    public func disableFilmSimulation() {
        haptics.triggerSelectionChange()
        FilmFilterEngine.shared.clearCache()
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
            startVideoRecordingInternal()
        }
    }

    private func startVideoRecordingInternal() {
        guard captureMode.isVideo, pendingCaptureMode == nil,
              (isCameraReady || isDualCameraActive || cameraService.isAnySessionRunning),
              !isCameraHibernating, !isShutterPressing else { return }
        wantsVideoRecording = true
        if isWindowedZoomActive && windowedZoomFocalLength > 24.5 {
            lastRecordedVideoWindowedFocal = windowedZoomFocalLength
            lastRecordedVideoWindowedAspect = windowedZoomAspectRatio
            lastRecordedVideoWindowedBaseZoom = displayZoom
            lastRecordedVideoWindowedCenter = windowedZoomNormalizedCenter
        } else {
            lastRecordedVideoWindowedFocal = nil
            lastRecordedVideoWindowedAspect = nil
            lastRecordedVideoWindowedBaseZoom = 1.0
            lastRecordedVideoWindowedCenter = CGPoint(x: 0.5, y: 0.5)
        }
        haptics.triggerShutterClick()
        cameraService.startRecordingVideo(codec: self.selectedVideoCodec)
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
        guard now >= ignoreSubjectAreaChangeUntil else { return }
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard now >= manualFocusLockUntil, !isAEAFLocked else { return }
        guard now - lastForcedResetTime >= 1.5 else {
            return
        }
        lastForcedResetTime = now

        // Cảnh vật hoặc chủ thể di chuyển -> Tự động trả về tâm và lấy nét liên tục chuẩn Apple Camera
        if showTargetCircle, let target = currentTargetPoint {
            applyFocusAndExposure(to: target, source: .aiTarget, force: false, showUI: false)
        } else {
            smoothedSmartFocusPoint = CGPoint(x: 0.5, y: 0.5)
            lastFocusPoint = CGPoint(x: 0.5, y: 0.5)
            activeSunExposureBias = 0.0
            cameraService.resetFocusAndExposureToCenter(resetExposureBias: true)
            activeFocusSquarePoint = nil
            isShowingSunSlider = false
        }
    }

    private func handleSmartFocusCalculated(point: CGPoint, type: SmartFocusType) {
        let now = CACurrentMediaTime()
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard now >= manualFocusLockUntil, !isAEAFLocked else { return }

        // 1. Ưu tiên số 1: Nếu AI đã khóa mục tiêu target (vòng tròn vàng), luôn lấy nét vào target
        if showTargetCircle, let target = currentTargetPoint {
            smoothedSmartFocusPoint = CGPoint(
                x: focusEMAAlpha * target.x + (1.0 - focusEMAAlpha) * smoothedSmartFocusPoint.x,
                y: focusEMAAlpha * target.y + (1.0 - focusEMAAlpha) * smoothedSmartFocusPoint.y
            )
            guard now - lastSmartFocusExposureTime >= 0.45 else { return }
            applyFocusAndExposure(to: smoothedSmartFocusPoint, source: .aiTarget, force: false, showUI: false)
            return
        }

        // 2. Chế độ rảnh (chưa khóa target):
        if type == .center {
            if hypot(lastFocusPoint.x - 0.5, lastFocusPoint.y - 0.5) > 0.12 && now - lastSmartFocusExposureTime >= 2.0 {
                smoothedSmartFocusPoint = CGPoint(x: 0.5, y: 0.5)
                applyFocusAndExposure(to: smoothedSmartFocusPoint, source: .center, force: false, showUI: false)
            }
            return
        }

        // Lọc nhiễu cho .face và .salientObject: chỉ đổi điểm khi vật được phát hiện ổn định
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

        let requiredCooldown: TimeInterval = (type == .face) ? 0.65 : 1.1
        guard pendingSmartFocusStableCount >= 2, now - lastSmartFocusExposureTime >= requiredCooldown else { return }

        smoothedSmartFocusPoint = CGPoint(
            x: focusEMAAlpha * point.x + (1.0 - focusEMAAlpha) * smoothedSmartFocusPoint.x,
            y: focusEMAAlpha * point.y + (1.0 - focusEMAAlpha) * smoothedSmartFocusPoint.y
        )
        applyFocusAndExposure(to: smoothedSmartFocusPoint, source: type, force: false, showUI: false)
    }

    public func triggerFocusSquareAnimation(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) {
            self.activeFocusSquarePoint = point
        }
        focusSquareHideTask?.cancel()
        focusSquareHideTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                let timeSinceLastAdjust = CACurrentMediaTime() - self.lastUserSunAdjustTime
                if timeSinceLastAdjust >= 1.5 {
                    break
                }
            }
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
        unlockHardTargetLock()
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
        activeSunExposureBias = 0.0
        smoothedSmartFocusPoint = normalizedPoint
        let now = CACurrentMediaTime()
        manualFocusLockUntil = now + manualFocusCooldown
        ignoreSubjectAreaChangeUntil = now + manualFocusCooldown
        lastFocusPoint = normalizedPoint
        activeFocusSquarePoint = normalizedPoint
        isShowingSunSlider = true

        let devPoint = devicePoint ?? CameraService.convertUIPointToDevicePoint(normalizedPoint)
        cameraService.focusAndExpose(at: devPoint, resetExposureBias: true)
        triggerFocusSquareAnimation(at: normalizedPoint)
    }

    public func userDidLongPressToLockAEAF(at normalizedPoint: CGPoint) {
        let devPoint = CameraService.convertUIPointToDevicePoint(normalizedPoint)
        lockAEAF(at: normalizedPoint, devicePoint: devPoint)
    }

    public func adjustSunExposureBias(delta: Float) {
        lastUserSunAdjustTime = CACurrentMediaTime()
        manualFocusLockUntil = max(manualFocusLockUntil, lastUserSunAdjustTime + manualFocusCooldown)
        let newBias = max(-2.0, min(2.0, activeSunExposureBias + delta))
        activeSunExposureBias = newBias
        setExposure(newBias)
    }

    // MARK: - Thước Cân Bằng Chân Trời (Virtual Horizon Leveler)
    private func startHorizonLeveler() {
        guard horizonMotionManager.isDeviceMotionAvailable else { return }
        horizonMotionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        horizonMotionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] (motion: CMDeviceMotion?, error: Error?) in
            // Auto capture needs current gravity even when its overlay is hidden.
            guard let self = self, let motion = motion, !self.isCameraHibernating else { return }
            let gx = Double(motion.gravity.x)
            let gy = Double(motion.gravity.y)
            let rawRoll = atan2(gx, -gy) * 180.0 / .pi
            let calibratedRoll = rawRoll - self.gyroRollOffsetDegrees

            // Separate entry/exit angles prevent repeated feedback at 0.8 degrees.
            let level = abs(calibratedRoll) <= (self.isDeviceLevel ? 1.3 : 0.8)

            // Deadband filtering: only publish when roll change is significant (>= 0.20 deg)
            // or when device level state transitions, eliminating continuous 30Hz SwiftUI invalidation.
            if abs(calibratedRoll - self.currentRollDegrees) >= 0.20 || level != self.isDeviceLevel {
                self.currentRollDegrees = calibratedRoll
            }

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
            if self.isDeviceLevel != level {
                self.isDeviceLevel = level
            }
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

    public func applyFocusAndExposure(to point: CGPoint, source: SmartFocusType, force: Bool = false, showUI: Bool = false) {
        guard captureMode != .proVideo || proVideoService.isAutoFocus else { return }
        guard point.x.isFinite, point.y.isFinite else { return }
        let dx = point.x - lastFocusPoint.x
        let dy = point.y - lastFocusPoint.y
        let dist = sqrt(dx * dx + dy * dy)

        let threshold: CGFloat = (source == .face || source == .aiTarget) ? 0.065 : 0.09
        if dist > threshold || force {
            let now = CACurrentMediaTime()
            lastFocusPoint = point
            lastSmartFocusExposureTime = now
            ignoreSubjectAreaChangeUntil = now + 1.8
            let devicePoint = CameraService.convertUIPointToDevicePoint(point)
            cameraService.setSmartFocusAndExposure(at: devicePoint, focusType: source)
            if showUI && !captureMode.isVideo && !isRecordingVideo {
                triggerFocusSquareAnimation(at: point)
            }
        }
    }


    // MARK: - Manual Shutter Click (Nút chụp màu trắng)
    public func takePhotoManual() {
        if captureMode.isVideo {
            toggleVideoRecording()
            return
        }
        guard (isCameraReady || isDualCameraActive || cameraService.isAnySessionRunning),
              !isCameraHibernating, pendingCaptureMode == nil,
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
        let baseOpticalZoom: CGFloat
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
            applyFilm: apply, crop: isWindowedZoomActive && windowedZoomFocalLength > 24.5, focalLength: windowedZoomFocalLength,
            aspect: windowedZoomAspectRatio,
            score: stateBeforeCapture == .alignmentPerfect ? 1 : (framingResult?.alignmentScore ?? 0.8),
            baseOpticalZoom: displayZoom)
    }

    private func captureNativePhoto(highResolution: Bool) {
        if shouldActivateScreenFlash {
            activateScreenFlash { [weak self] in
                guard let self else { return }
                self.executeNativePhotoCapture(highResolution: highResolution)
            }
        } else {
            executeNativePhotoCapture(highResolution: highResolution)
        }
    }

    private func executeNativePhotoCapture(highResolution: Bool) {
        photoCapturePhase = .preparing
        captureProcessingSettings = currentPhotoProcessingSettings()
        cameraService.capturePhoto(isDNG: selectedPhotoFormat == .dng,
            isHEIF: selectedPhotoFormat == .heif || selectedPhotoFormat == .heic,
            highResolution: highResolution)
    }

    private func activateScreenFlash(completion: @escaping @MainActor () -> Void) {
        if previousScreenBrightness == nil {
            previousScreenBrightness = UIScreen.main.brightness
        }
        withAnimation(.easeIn(duration: 0.10)) {
            isScreenFlashOverlayVisible = true
        }
        UIScreen.main.brightness = 1.0

        // Arm safety watchdog to prevent stuck brightness in any unexpected scenario
        screenFlashWatchdogTask?.cancel()
        screenFlashWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 giay timeout du phong
            self?.deactivateScreenFlash()
        }

        // Thoi gian on dinh phoi sang (AE settle) cho cam truoc duoi nguon sang man hinh (~200ms)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.isScreenFlashOverlayVisible else { return }
            completion()
        }
    }

    public func deactivateScreenFlash() {
        screenFlashWatchdogTask?.cancel()
        screenFlashWatchdogTask = nil
        guard isScreenFlashOverlayVisible || previousScreenBrightness != nil else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            isScreenFlashOverlayVisible = false
        }
        if let previous = previousScreenBrightness {
            UIScreen.main.brightness = previous
            previousScreenBrightness = nil
        }
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
        let access: PHAccessLevel = .readWrite
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
                    let mainData = (item.preservesOriginalFile ? item.rawPhotoData : nil) ??
                        item.processedCompanionData ??
                        item.rawPhotoData ??
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

                    // Tự động thêm vào Album "Align Studio" trong Apple Photos
                    let albumTitle = "Align Studio"
                    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                    var targetAlbum: PHAssetCollection? = nil
                    collections.enumerateObjects { col, _, stop in
                        if col.localizedTitle == albumTitle || col.localizedTitle == "AlignAI Studio" {
                            targetAlbum = col
                            stop.pointee = true
                        }
                    }
                    if let album = targetAlbum {
                        if let albumChange = PHAssetCollectionChangeRequest(for: album),
                           let placeholder = request.placeholderForCreatedAsset {
                            albumChange.addAssets([placeholder] as NSArray)
                        }
                    } else {
                        let albumChange = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                        if let placeholder = request.placeholderForCreatedAsset {
                            albumChange.addAssets([placeholder] as NSArray)
                        }
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
        if phase == .processing {
            deactivateScreenFlash()
        }
    }

    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, processedCompanionData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double, format: PhotoSaveFormat, requestedHighResolution: Bool) {
        deactivateScreenFlash()
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
        let windowBaseZoom = settings.baseOpticalZoom
        let windowCenter = self.windowedZoomNormalizedCenter
        let hasColorEdits = isFilmActive && (effectivePreset != .standard || finalColorParams != nil)
        let appliedIntensity = Float(self.filmSimulationIntensity)

        // Chuyển sang luồng phụ userInitiated để render CoreImage, không làm đơ Main UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Nếu đang bật Windowed Zoom -> Cắt ảnh gốc 48MP chính xác theo tỉ lệ và kích thước khung ngắm
            let effectiveSourcePhoto: CGImage
            if isWindowed {
                let fractions = windowAspect.windowFractions(focalLength: windowFocal, baseOpticalZoom: windowBaseZoom)
                if fractions.widthFraction < 0.999 && fractions.heightFraction < 0.999 {
                    let normCenter = windowCenter
                    let origW = CGFloat(photo.width)
                    let origH = CGFloat(photo.height)
                    let cropW = round(origW * fractions.widthFraction)
                    let cropH = round(origH * fractions.heightFraction)
                    let centerX = origW * normCenter.x
                    let centerY = origH * normCenter.y
                    let minCenterX = cropW / 2.0
                    let maxCenterX = origW - cropW / 2.0
                    let minCenterY = cropH / 2.0
                    let maxCenterY = origH - cropH / 2.0
                    let clampedCenterX = max(minCenterX, min(centerX, maxCenterX))
                    let clampedCenterY = max(minCenterY, min(centerY, maxCenterY))
                    let cropX = round(clampedCenterX - cropW / 2.0)
                    let cropY = round(clampedCenterY - cropH / 2.0)
                    let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                    effectiveSourcePhoto = photo.cropping(to: cropRect) ?? photo
                    CameraLogger.info("Windowed Zoom Crop: \(photo.width)x\(photo.height) -> \(effectiveSourcePhoto.width)x\(effectiveSourcePhoto.height) (\(Int(windowFocal))mm, \(windowAspect.rawValue))", category: .capture)
                } else {
                    effectiveSourcePhoto = photo
                }
            } else {
                effectiveSourcePhoto = photo
            }

            var processedImageResult: CGImage = effectiveSourcePhoto
            autoreleasepool {
                if hasColorEdits {
                    processedImageResult = FilmFilterEngine.shared.applyPresetAndAIParameters(
                        to: effectiveSourcePhoto, preset: effectivePreset, params: finalColorParams, intensity: appliedIntensity) ?? effectiveSourcePhoto
                    FilmFilterEngine.shared.clearCache()
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
                preservesOriginalFile: (format == .dng || (!isWindowed && !hasColorEdits)) && rawData != nil,
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

            // Lưu vĩnh viễn ảnh vào kho nội bộ app Align Studio (Documents/AlignStudioCaptures) để không bao giờ mất khi thoát app
            let persistedData: Data?
            if format == .dng {
                persistedData = rawData
            } else if item.preservesOriginalFile, let raw = rawData {
                persistedData = raw
            } else {
                persistedData = processedCompanionData ?? Self.encodeRenderedPhoto(processedImageResult, sourceData: rawData, format: format)
            }
            if let dataToSave = persistedData {
                AppPhotoStorageService.shared.persistCapture(
                    id: item.id,
                    image: processedImageResult,
                    mainData: dataToSave,
                    format: format,
                    sceneType: activeScene,
                    preset: isFilmActive ? effectivePreset : .standard,
                    compositionRule: activeRule,
                    score: score,
                    iso: iso,
                    shutterSpeed: shutterSpeed
                )
            }

            DispatchQueue.main.async {
                CameraLogger.success("Render bộ lọc hoàn tất, hiển thị xem trước & lưu ảnh (LivePhoto: \(item.isLivePhoto))", category: .capture)
                self.isShutterPressing = false
                self.haptics.triggerShutterClick()
                self.unlockHardTargetLock()
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
        deactivateScreenFlash()
        self.unlockHardTargetLock()
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
