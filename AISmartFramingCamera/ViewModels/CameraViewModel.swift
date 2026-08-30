import Foundation
import SwiftUI
import AVFoundation
import CoreImage
import Photos
import QuartzCore

@MainActor
public final class CameraViewModel: ObservableObject {
    // MARK: - Services
    public let cameraService = CameraService.shared
    public let visionEngine = VisionFramingEngine.shared
    public let calculator = CompositionCalculator.shared
    public let filterEngine = FilmFilterEngine.shared
    public let haptics = HapticFeedbackService.shared
    public let arSession = ARCompositionSession.shared
    public let geminiService = GeminiService.shared
    public let motionService = DeviceMotionService.shared
    
    // MARK: - AI Session State Machine
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
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H {
        didSet { UserDefaults.standard.set(selectedFilmPreset.rawValue, forKey: "selectedFilmPreset") }
    }
    @Published public var isAIFullColorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAIFullColorEnabled, forKey: "isAIFullColorEnabled") }
    }
    @Published public var isAutoZoomEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoZoomEnabled, forKey: "isAutoZoomEnabled") }
    }
    
    // Camera Mode & Live Photo
    @Published public var captureMode: CameraCaptureMode = .photo {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published public var isLivePhotoEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isLivePhotoEnabled, forKey: "isLivePhotoEnabled") }
    }
    @Published public var isRecordingVideo: Bool = false
    @Published public var recordedVideoURL: URL? = nil
    @Published public var isShowingVideoPreview: Bool = false
    
    // Camera Parameters
    @Published public var currentZoom: CGFloat = 1.0
    @Published public var exposureBias: Float = 0.0
    @Published public var activeFlashMode: AVCaptureDevice.FlashMode = .auto {
        didSet { UserDefaults.standard.set(activeFlashMode.rawValue, forKey: "activeFlashMode") }
    }
    
    // AI Framing & Composition
    @Published public var framingResult: FramingTargetResult?
    @Published public var alignmentState: FramingAlignmentState = .analyzing
    @Published public var detectedScene: DetectedSceneType = .general
    @Published public var detectedSubjectRects: [CGRect] = []
    @Published public var detectedFaceRects: [CGRect] = []
    
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
    
    // Capture & Review
    @Published public var latestCapturedPhoto: CapturedPhotoItem?
    @Published public var isShowingPhotoDetail: Bool = false
    @Published public var isShowingSettings: Bool = false
    @Published public var isShowingFilmDrawer: Bool = false
    @Published public var showAlignmentSuccessFlash: Bool = false
    @Published public var isShutterPressing: Bool = false
    @Published public var isARModeEnabled: Bool = false
    @Published public var activeFlashMode2: Bool = false
    @Published public var autoCaptureCountdown: Int = 0
    @Published public var currentAIColorParams: AIColorParameters? = nil
    
    // ARKit 3D World Tracking & Engine Source Indicator
    public let arSessionService = ARCompositionSession.shared
    @Published public var activeEngineSource: AIEngineSource? = nil
    @Published public var arTrackingWarning: String? = nil
    @Published public var activeFocusSquarePoint: CGPoint? = nil
    @Published public var isAEAFLocked: Bool = false
    @Published public var aeafLockPoint: CGPoint? = nil
    @Published public var saveErrorMessage: String? = nil
    
    // MARK: - Advanced Predictive Tracking State Machine
    @Published public var trackingQuality: TrackingQuality = .locked
    @Published public var trackingSensitivity: TrackingSensitivityPreset = .medium {
        didSet { UserDefaults.standard.set(trackingSensitivity.rawValue, forKey: "trackingSensitivity") }
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
        case .low: return 0.15
        case .medium: return 0.12
        case .high: return 0.09
        }
    }
    
    private var consecutiveLowConfidenceFrames: Int = 0
    private var smoothedVelocity: CGVector = .zero
    private var lastVisualUpdateTime: CFTimeInterval = 0
    private let predictionGraceFrames: Int = 24   // ~0.8s ở 30fps: còn được phép ngoại suy vận tốc
    private let reacquireGraceFrames: Int = 90    // ~3.0s: sau mốc này coi như mất hẳn
    private var lastProximityHapticTime: TimeInterval = 0
    
    // Internal State
    private var autoCaptureTask: Task<Void, Never>? = nil
    private var analysisFrames: [SubjectDetectionResult] = []
    private let analysisFramesNeeded = 5 // Collect 5 quick frames (~0.25s) for rock-solid stabilization
    private var isOneShotCaptured = false
    private var lastFocusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var focusSquareHideTask: Task<Void, Never>? = nil
    
    public init() {
        // Load saved settings
        let defaults = UserDefaults.standard
        if let ruleRaw = defaults.string(forKey: "activeCompositionRule"), let rule = CompositionRule(rawValue: ruleRaw) {
            self.activeCompositionRule = rule
        }
        if let presetRaw = defaults.string(forKey: "selectedFilmPreset"), let preset = FilmPreset(rawValue: presetRaw) {
            self.selectedFilmPreset = preset
        }
        if let modeRaw = defaults.string(forKey: "captureMode"), let mode = CameraCaptureMode(rawValue: modeRaw) {
            self.captureMode = mode
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
        if let sensitivityRaw = defaults.string(forKey: "trackingSensitivity"), let sensitivity = TrackingSensitivityPreset(rawValue: sensitivityRaw) {
            self.trackingSensitivity = sensitivity
        }
        if let flashRaw = defaults.object(forKey: "activeFlashMode") as? Int,
           let flash = AVCaptureDevice.FlashMode(rawValue: flashRaw) {
            self.activeFlashMode = flash
        }
        
        setupCallbacks()
        setupMotionCallbacks()
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
            self.cameraService.start()
            self.isCameraReady = true
        }
    }
    
    private func setupCallbacks() {
        visionEngine.onDetectionCompleted = { [weak self] detection in
            guard let self = self else { return }
            self.handleVisionDetection(detection)
        }
        
        visionEngine.onTargetTracked = { [weak self] trackedPoint, confidence in
            guard let self = self else { return }
            self.handleVisualTargetTracked(point: trackedPoint, confidence: confidence)
        }
        
        // Smart Autofocus (Face Priority > Saliency > Center)
        visionEngine.onSmartFocusPointCalculated = { [weak self] point, focusType in
            guard let self = self else { return }
            self.handleSmartFocusCalculated(point: point, type: focusType)
        }
        
        // Subject Area Did Change Observer (Apple Camera App style)
        cameraService.onSubjectAreaDidChange = { [weak self] in
            guard let self = self else { return }
            self.handleSubjectAreaChanged()
        }
    }
    
    private func setupMotionCallbacks() {
        // 60Hz Gyroscope Quán tính
        motionService.onMotionUpdate = { [weak self] deltaX, deltaY in
            guard let self = self else { return }
            self.handleGyroMotion(deltaX: deltaX, deltaY: deltaY)
        }
    }
    
    // MARK: - AI Session Control (One-Shot Trigger)
    
    /// Bắt đầu phiên AI khi người dùng bấm nút AI — chỉ phân tích ĐÚNG 1 LẦN duy nhất
    public func startAISession() {
        guard aiSessionState == .idle || aiSessionState == .done else { return }
        haptics.triggerSelectionChange()
        
        // Reset state
        arSessionService.clearTarget()
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        analysisFrames = []
        initialTargetPoint = nil
        currentTargetPoint = nil
        lastTrackedVisualPoint = nil
        lastVisualConfidence = 0
        consecutiveLowConfidenceFrames = 0
        smoothedVelocity = .zero
        lastVisualUpdateTime = 0
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
    }
    
    public func cancelAISession() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        arSessionService.clearTarget()
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        haptics.triggerSelectionChange()
        visionEngine.captureNextFrameForGemini = false
        consecutiveLowConfidenceFrames = 0
        smoothedVelocity = .zero
        lastVisualUpdateTime = 0
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
    
    // MARK: - Vision & Gemini One-Shot Handling
    
    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        switch aiSessionState {
        case .idle, .done:
            // Khi ở chế độ idle: chỉ hiển thị face preview nhẹ nhàng, không tính toán target
            self.detectedScene = detection.detectedScene
            self.detectedFaceRects = detection.faceRectangles
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
        self.detectedFaceRects = detection.faceRectangles
        if let dominant = detection.dominantSubjectRect {
            self.detectedSubjectRects = [dominant]
        }
        
        // Kiểm tra xem đã có frame chụp cho Gemini chưa
        if let frame = visionEngine.capturedGeminiFrame {
            visionEngine.capturedGeminiFrame = nil
            
            if useGeminiForAnalysis && geminiService.hasAPIKey {
                isOneShotCaptured = true
                callGeminiAnalysis(frame: frame)
                return
            }
        }
        
        // Thu thập đủ 5 frames ban đầu để ổn định nhận diện cục bộ (nếu không dùng Gemini)
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
        
        geminiService.analyzeForComposition(image: frame) { [weak self] result in
            guard let self = self else { return }
            self.isGeminiAnalyzing = false
            
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
        
        // Tự động điều chỉnh Zoom quang học theo đề xuất của AI để tối ưu bố cục
        if isAutoZoomEnabled && response.suggestedZoom > 1.0 {
            setZoom(response.suggestedZoom)
        }
        
        if isAIFullColorEnabled {
            currentAIColorParams = response.colorRecipe.asAIColorParameters
        }
        
        let targetPoint = CGPoint(x: response.targetX, y: response.targetY)
        pinTargetAndStartMotion(at: targetPoint)
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
        }
        
        let result = calculator.calculateTarget(from: avgDetection, rule: activeCompositionRule, currentZoom: currentZoom)
        self.framingResult = result
        self.detectedScene = dominantScene
        self.activeEngineSource = .appleNeuralEngine(scene: dominantScene.localizedName)
        
        if isAIFullColorEnabled {
            currentAIColorParams = dominantScene.aiFullColorParameters
            let lumaError: Float = 0.50 - avgDetection.averageLuminance
            setExposure(max(-2.0, min(2.0, lumaError * 3.0)))
        }
        
        pinTargetAndStartMotion(at: result.targetPoint, subjectSize: avgDetection.dominantSubjectRect?.size)
    }
    
    // MARK: - State for Hybrid Optical Visual + Gyro Tracking
    @Published public var lastVisualConfidence: Double = 0
    private var lastTrackedVisualPoint: CGPoint? = nil
    private var gyroAnchorPoint: CGPoint? = nil
    
    // MARK: - Pin Target & Start Tracking (Hybrid Optical Flow + 60Hz Gyroscope Spatial Fusion)
    
    public func pinTargetAndStartMotion(at target: CGPoint, subjectSize: CGSize? = nil) {
        initialTargetPoint = target
        currentTargetPoint = target
        lastTrackedVisualPoint = target
        gyroAnchorPoint = target
        lastVisualConfidence = 1.0
        lastVisualUpdateTime = CACurrentMediaTime()
        consecutiveLowConfidenceFrames = 0
        smoothedVelocity = .zero
        trackingQuality = .locked
        
        let dx = target.x - 0.5
        let dy = target.y - 0.5
        alignmentDistance = sqrt(dx * dx + dy * dy)
        
        // 1. Khởi động Vision Optical Tracking (VNTrackObjectRequest) theo kích thước chủ thể thật
        let clampedW = min(0.42, max(0.10, (subjectSize?.width ?? 0.18) * 1.15))
        let clampedH = min(0.42, max(0.10, (subjectSize?.height ?? 0.18) * 1.15))
        visionEngine.startTrackingObject(at: target, size: CGSize(width: clampedW, height: clampedH))
        
        // 2. Khởi động 60Hz Gyroscope làm mỏ neo quán tính dự phòng
        motionService.resetReferenceAttitude()
        motionService.startTracking()
        
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.haptics.triggerSuccess()
        }
    }
    
    // MARK: - 1. Optical Visual Object Tracking Handler (Bám chặt 100% vào vật thể/chữ thực tế trên màn hình)
    
    private func handleVisualTargetTracked(point: CGPoint?, confidence: Double) {
        guard case .targetPlaced = aiSessionState else { return }
        self.lastVisualConfidence = confidence

        let now = CACurrentMediaTime()
        let dt = lastVisualUpdateTime > 0 ? min(0.2, now - lastVisualUpdateTime) : (1.0 / 30.0)
        lastVisualUpdateTime = now

        if let visualPoint = point, confidence > confidenceAcceptThreshold {
            // Giới hạn tọa độ hợp lệ trong khung hình preview
            let clampedVisual = CGPoint(
                x: max(0.02, min(0.98, visualPoint.x)),
                y: max(0.02, min(0.98, visualPoint.y))
            )
            
            // Lọc outlier cực đoan nếu nhảy đột ngột quá xa theo mức nhạy người dùng chọn
            if let current = self.currentTargetPoint {
                let rawJump = hypot(clampedVisual.x - current.x, clampedVisual.y - current.y)
                if rawJump > maxJumpPerFrame && consecutiveLowConfidenceFrames == 0 && trackingQuality == .locked {
                    handleTrackingDegraded()
                    return
                }
            }

            // Smooth EMA filter - Bám dính chắc chắn, làm mượt thích ứng theo confidence
            let current = self.currentTargetPoint ?? clampedVisual
            let confidenceMargin = max(0.0, min(1.0, (confidence - confidenceAcceptThreshold) / confidenceAcceptThreshold))
            let alpha = trackingEMAAlpha * max(0.3, confidenceMargin)
            let smoothedX = current.x * (1.0 - alpha) + clampedVisual.x * alpha
            let smoothedY = current.y * (1.0 - alpha) + clampedVisual.y * alpha
            let smoothedPoint = CGPoint(x: smoothedX, y: smoothedY)

            // Vận tốc thực tế có giới hạn vật lý để tránh phóng vọt
            if dt > 0.005 {
                let rawVX = (smoothedPoint.x - current.x) / CGFloat(dt)
                let rawVY = (smoothedPoint.y - current.y) / CGFloat(dt)
                let clampedVX = max(-1.5, min(1.5, rawVX))
                let clampedVY = max(-1.5, min(1.5, rawVY))
                smoothedVelocity = CGVector(
                    dx: smoothedVelocity.dx * 0.6 + clampedVX * 0.4,
                    dy: smoothedVelocity.dy * 0.6 + clampedVY * 0.4
                )
            }

            self.lastTrackedVisualPoint = smoothedPoint
            self.currentTargetPoint = smoothedPoint
            if confidence > confidenceAcceptThreshold * 1.5 {
                self.gyroAnchorPoint = smoothedPoint
                self.motionService.resetReferenceAttitude()
            }
            consecutiveLowConfidenceFrames = 0
            trackingQuality = .locked
            evaluateAlignment(at: smoothedPoint)
        } else {
            handleTrackingDegraded()
        }
    }

    // Xử lý khi 1 frame không có điểm hợp lệ (confidence thấp / bị che)
    private func handleTrackingDegraded() {
        consecutiveLowConfidenceFrames += 1

        guard let lastPoint = self.currentTargetPoint ?? lastTrackedVisualPoint else { return }

        let previousQuality = trackingQuality

        if consecutiveLowConfidenceFrames <= predictionGraceFrames {
            // Còn trong khoảng cho phép ngoại suy: dùng vận tốc giảm dần (damped) để không trôi dạt
            let dt: CGFloat = 1.0 / 30.0
            smoothedVelocity = CGVector(dx: smoothedVelocity.dx * 0.85, dy: smoothedVelocity.dy * 0.85)
            let predictedX = lastPoint.x + smoothedVelocity.dx * dt
            let predictedY = lastPoint.y + smoothedVelocity.dy * dt
            let clamped = CGPoint(x: min(0.98, max(0.02, predictedX)), y: min(0.98, max(0.02, predictedY)))
            self.currentTargetPoint = clamped
            trackingQuality = .predicting
            evaluateAlignment(at: clamped)
        } else if consecutiveLowConfidenceFrames <= reacquireGraceFrames {
            // Hết thời gian ngoại suy -> giữ nguyên vị trí cuối cùng, triệt tiêu vận tốc
            smoothedVelocity = .zero
            trackingQuality = .reacquiring
        } else {
            smoothedVelocity = .zero
            trackingQuality = .lost
            autoCaptureTask?.cancel()
            autoCaptureTask = nil
            autoCaptureCountdown = 0
            if previousQuality != .lost {
                haptics.triggerTrackingLostWarning()
            }
        }
    }
    
    // MARK: - 3. 60Hz Gyro Motion Handler (Inertial Odometry khi lia máy nhanh hoặc mất dấu quang học)
    
    private func handleGyroMotion(deltaX: CGFloat, deltaY: CGFloat) {
        guard case .targetPlaced = aiSessionState, let anchor = gyroAnchorPoint ?? initialTargetPoint else { return }
        
        // Khi lia máy nhanh hoặc quang học tạm thời mờ/khuất (confidence thấp), Gyroscope giữ vị trí không gian từ mỏ neo gần nhất
        if lastVisualConfidence <= 0.35 {
            let zoomCompensation = max(1.0, currentZoom)
            let newX = anchor.x - deltaX * zoomCompensation
            let newY = anchor.y - deltaY * zoomCompensation
            let gyroPoint = CGPoint(x: min(0.98, max(0.02, newX)), y: min(0.98, max(0.02, newY)))
            
            let current = self.currentTargetPoint ?? gyroPoint
            let alpha: CGFloat = 0.45
            let smoothedX = current.x * (1.0 - alpha) + gyroPoint.x * alpha
            let smoothedY = current.y * (1.0 - alpha) + gyroPoint.y * alpha
            let smoothedPoint = CGPoint(x: smoothedX, y: smoothedY)
            
            self.currentTargetPoint = smoothedPoint
            evaluateAlignment(at: smoothedPoint)
        }
    }
    
    private func evaluateAlignment(at point: CGPoint) {
        let dx = point.x - 0.5
        let dy = point.y - 0.5
        let dist = sqrt(dx * dx + dy * dy)
        self.alignmentDistance = dist
        
        // Haptic rung khi tiến gần tâm — giới hạn tần suất, tránh dồn lệnh gây lag
        if dist < 0.15 && dist > calculator.alignmentTolerance {
            let now = CACurrentMediaTime()
            if now - lastProximityHapticTime >= 0.1 {
                lastProximityHapticTime = now
                let intensity = 1.0 - (dist / 0.15)
                haptics.triggerProximityPulse(intensity: intensity)
            }
        }
        
        let isPerfect = dist <= calculator.alignmentTolerance
        
        // Chỉ kích hoạt tự động chụp khi thực sự khóa tốt (trackingQuality == .locked), không chụp khi đang đoán mò
        if isPerfect && !isPerfectAlignment && trackingQuality == .locked {
            // Tâm trắng đã đè khớp lên vùng target!
            isPerfectAlignment = true
            haptics.triggerMagneticSnap()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                aiSessionState = .alignmentPerfect
                showAlignmentSuccessFlash = true
            }
            startAutoCaptureCountdown()
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
    
    private func startAutoCaptureCountdown() {
        autoCaptureTask?.cancel()
        autoCaptureCountdown = 1 // 1 giây phản hồi nhanh chụp ngay
        
        autoCaptureTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
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
        arSessionService.clearTarget()
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        haptics.triggerShutterClick()
        
        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }
        
        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }
        
        cameraService.capturePhoto()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
    }
    
    // MARK: - Actions
    public func setZoom(_ zoom: CGFloat) {
        currentZoom = zoom
        cameraService.setZoomFactor(zoom)
    }
    
    public func setZoomFromButton(_ zoom: CGFloat) {
        haptics.triggerSelectionChange()
        setZoom(zoom)
    }
    
    public func setExposure(_ bias: Float) {
        exposureBias = bias
        cameraService.setExposureBias(bias)
    }
    
    public func lockAEAF(at normalizedPoint: CGPoint, devicePoint: CGPoint) {
        haptics.triggerSelectionChange()
        aeafLockPoint = normalizedPoint
        isAEAFLocked = true
        cameraService.lockFocusAndExposure(at: devicePoint)
    }
    
    public func unlockAEAF() {
        guard isAEAFLocked else { return }
        haptics.triggerSelectionChange()
        isAEAFLocked = false
        aeafLockPoint = nil
        cameraService.unlockFocusAndExposure()
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
        cameraService.isLivePhotoMode = isLivePhotoEnabled
    }
    
    public func toggleVideoRecording() {
        if isRecordingVideo {
            haptics.triggerShutterClick()
            cameraService.stopRecordingVideo()
            isRecordingVideo = false
        } else {
            haptics.triggerShutterClick()
            cameraService.startRecordingVideo()
            isRecordingVideo = true
        }
    }
    
    public func toggleARMode() {
        haptics.triggerSelectionChange()
        isARModeEnabled.toggle()
        if isARModeEnabled { arSession.startSession() } else { arSession.pauseSession() }
    }
    
    // MARK: - Smart Autofocus & Exposure Control (Apple Camera App Style)
    
    private func handleSubjectAreaChanged() {
        // Cảnh vật hoặc chủ thể di chuyển -> Kích hoạt lấy nét lại ngay lập tức
        if showTargetCircle, let target = currentTargetPoint {
            applyFocusAndExposure(to: target, source: .aiTarget, force: true)
        } else {
            applyFocusAndExposure(to: lastFocusPoint, source: .center, force: true)
        }
    }
    
    private func handleSmartFocusCalculated(point: CGPoint, type: SmartFocusType) {
        // 1. Ưu tiên số 1: Nếu AI đã khóa mục tiêu target (vòng tròn vàng), luôn lấy nét vào target
        if showTargetCircle, let target = currentTargetPoint {
            applyFocusAndExposure(to: target, source: .aiTarget)
            return
        }
        
        // 2. Nếu đang ở chế độ thường: Mặt người > Vật thể nổi bật (Saliency) > Tâm màn hình
        applyFocusAndExposure(to: point, source: type)
    }
    
    public func applyFocusAndExposure(to point: CGPoint, source: SmartFocusType, force: Bool = false) {
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
    
    public func triggerFocusSquareAnimation(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) {
            self.activeFocusSquarePoint = point
        }
        focusSquareHideTask?.cancel()
        focusSquareHideTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.3)) {
                    if self.activeFocusSquarePoint == point {
                        self.activeFocusSquarePoint = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Manual Shutter Click (Nút chụp màu trắng)
    public func takePhotoManual() {
        if captureMode == .video {
            toggleVideoRecording()
            return
        }
        
        // Cho phép chụp thủ công bất kỳ lúc nào (ngay cả khi chưa bật AI hoặc AI đã hoàn tất)
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }
        
        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }
        
        cameraService.capturePhoto()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isShutterPressing = false }
    }
    
    public func savePhotoToLibrary(_ item: CapturedPhotoItem) {
        let image = UIImage(cgImage: item.processedImage)
        let isAIColorEdited = item.aiColorParameters != nil
        let albumName = "AI Smart Framing - AI Color"
        let livePhotoURL = cameraService.pendingLivePhotoMovieURL
        
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.saveErrorMessage = "Chưa cấp quyền Photos. Vào Cài đặt > AI Smart Framing Camera > Ảnh để bật quyền lưu ảnh."
                }
                return
            }
            
            // 1. Kiểm tra Album trước khi vào performChanges (tránh crash performChangesAndWait)
            var existingAlbum: PHAssetCollection? = nil
            if isAIColorEdited {
                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
                let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
                existingAlbum = collections.firstObject
            }
            
            // 2. Kiểm tra file Live Photo video có tồn tại trên đĩa và dung lượng > 0 không
            let validLiveURL: URL?
            if self.isLivePhotoEnabled, let url = livePhotoURL, FileManager.default.fileExists(atPath: url.path) {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                validLiveURL = fileSize > 0 ? url : nil
            } else {
                validLiveURL = nil
            }
            
            guard let imageData = image.jpegData(compressionQuality: 0.95) else {
                DispatchQueue.main.async {
                    self.saveErrorMessage = "Lỗi nén ảnh JPEG"
                }
                return
            }
            
            // 3. Thực hiện lưu ảnh an toàn trong 1 transaction duy nhất
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: imageData, options: nil)
                
                if let liveURL = validLiveURL, liveURL.pathExtension.lowercased() == "mov" {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    creationRequest.addResource(with: .pairedVideo, fileURL: liveURL, options: options)
                }
                
                if isAIColorEdited, let placeholder = creationRequest.placeholderForCreatedAsset {
                    if let album = existingAlbum {
                        let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                    } else {
                        let albumCreateRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                        albumCreateRequest.addAssets([placeholder] as NSArray)
                    }
                }
            }) { success, error in
                // Dọn dẹp file tạm Live Photo sau khi xử lý xong
                if let liveURL = validLiveURL {
                    try? FileManager.default.removeItem(at: liveURL)
                }
                
                DispatchQueue.main.async {
                    if success {
                        self.haptics.triggerSuccess()
                        self.saveErrorMessage = nil
                    } else {
                        print("Lưu ảnh lỗi: \(String(describing: error))")
                        self.saveErrorMessage = "Lưu ảnh thất bại: \(error?.localizedDescription ?? "không rõ lỗi")"
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
        switch aiSessionState {
        case .targetPlaced: return !isPerfectAlignment && currentTargetPoint != nil
        default: return false
        }
    }
}

// MARK: - CameraServiceDelegate
extension CameraViewModel: CameraServiceDelegate {
    public func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        // Video connection is already set to .portrait in CameraService, so pixelBuffer is upright (.up)
        visionEngine.processVideoSampleBuffer(sampleBuffer, orientation: .up)
    }
    
    public func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {
        self.recordedVideoURL = url
        self.isShowingVideoPreview = true
        self.haptics.triggerSuccess()
    }
    
    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double) {
        let finalColorParams: AIColorParameters?
        if isAIFullColorEnabled {
            finalColorParams = geminiColorRecipe?.asAIColorParameters ?? currentAIColorParams ?? detectedScene.aiFullColorParameters
        } else {
            finalColorParams = nil
        }
        
        let processed: CGImage
        if let params = finalColorParams {
            processed = filterEngine.applyAIColorParameters(to: photo, params: params) ?? photo
        } else {
            processed = filterEngine.applyPreset(to: photo, preset: selectedFilmPreset) ?? photo
        }
        
        let alignmentScore: Double
        switch aiSessionState {
        case .alignmentPerfect, .capturing: alignmentScore = 1.0
        default: alignmentScore = framingResult?.alignmentScore ?? 0.8
        }
        
        let item = CapturedPhotoItem(
            originalImage: photo,
            processedImage: processed,
            sceneType: detectedScene,
            appliedPreset: selectedFilmPreset,
            compositionRule: activeCompositionRule,
            alignmentScore: alignmentScore,
            iso: iso,
            shutterSpeed: shutterSpeed,
            aiColorParameters: finalColorParams
        )
        
        withAnimation {
            self.latestCapturedPhoto = item
            self.isShowingPhotoDetail = true
            self.aiSessionState = .done
        }
        self.savePhotoToLibrary(item)
    }
    
    public func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {
        self.currentZoom = zoom
    }
}
