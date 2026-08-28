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
    @Published public var aiSessionState: AISessionState = .idle
    
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
    @Published public var activeFlashMode: AVCaptureDevice.FlashMode = .auto
    
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
    
    // Internal State
    private var autoCaptureTask: Task<Void, Never>? = nil
    private var analysisFrames: [SubjectDetectionResult] = []
    private let analysisFramesNeeded = 5 // Collect 5 quick frames (~0.25s) for rock-solid stabilization
    private var isOneShotCaptured = false
    
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
    }
    
    private func setupMotionCallbacks() {
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
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        analysisFrames = []
        initialTargetPoint = nil
        currentTargetPoint = nil
        lastTrackedVisualPoint = nil
        lastVisualConfidence = 0
        isOneShotCaptured = false
        isPerfectAlignment = false
        alignmentDistance = 1.0
        geminiError = nil
        geminiExplanation = ""
        activeModelUsedName = ""
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            aiSessionState = .analyzing
        }
        
        // Yêu cầu Vision Engine chụp 1 frame chất lượng cao gửi cho Gemini
        visionEngine.captureNextFrameForGemini = true
    }
    
    public func cancelAISession() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        motionService.stopTracking()
        visionEngine.stopTrackingObject()
        haptics.triggerSelectionChange()
        visionEngine.captureNextFrameForGemini = false
        
        withAnimation(.easeInOut(duration: 0.3)) {
            aiSessionState = .idle
            initialTargetPoint = nil
            currentTargetPoint = nil
            isOneShotCaptured = false
            isPerfectAlignment = false
            alignmentDistance = 1.0
            detectedSubjectRects = []
            detectedFaceRects = []
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
        
        if isAIFullColorEnabled {
            currentAIColorParams = dominantScene.aiFullColorParameters
            let lumaError: Float = 0.50 - avgDetection.averageLuminance
            setExposure(max(-2.0, min(2.0, lumaError * 3.0)))
        }
        
        pinTargetAndStartMotion(at: result.targetPoint)
    }
    
    // MARK: - State for Hybrid Optical Visual + Gyro Tracking
    private var lastVisualConfidence: Double = 0
    private var lastTrackedVisualPoint: CGPoint? = nil
    
    // MARK: - Pin Target & Start Tracking (Chuẩn Apple Measure App: Optical Visual Lock + Gyro Odometry)
    
    private func pinTargetAndStartMotion(at target: CGPoint) {
        initialTargetPoint = target
        currentTargetPoint = target
        lastTrackedVisualPoint = target
        lastVisualConfidence = 1.0
        
        let dx = target.x - 0.5
        let dy = target.y - 0.5
        alignmentDistance = sqrt(dx * dx + dy * dy)
        
        // 1. Khởi động Vision Optical Tracking (VNTrackObjectRequest) bám chặt vào texture/chữ/vật thể tại target
        visionEngine.startTrackingObject(at: target, size: CGSize(width: 0.18, height: 0.18))
        
        // 2. Khởi động 60Hz Gyroscope làm mỏ neo không gian quán tính (Inertial Fallback)
        motionService.startTracking()
        
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.haptics.triggerSuccess()
        }
    }
    
    // MARK: - Optical Visual Object Tracking Handler (Bám chặt vào vật thể/chữ thực tế trên màn hình)
    
    private func handleVisualTargetTracked(point: CGPoint?, confidence: Double) {
        guard case .targetPlaced = aiSessionState else { return }
        self.lastVisualConfidence = confidence
        
        if let visualPoint = point, confidence > 0.25 {
            self.lastTrackedVisualPoint = visualPoint
            
            // Lọc EMA để khử nhiễu micro-jitter quang học
            let current = self.currentTargetPoint ?? visualPoint
            let alpha: CGFloat = 0.70 // 70% vị trí quang học mới, 30% vị trí trước
            let smoothedX = current.x * (1.0 - alpha) + visualPoint.x * alpha
            let smoothedY = current.y * (1.0 - alpha) + visualPoint.y * alpha
            let smoothedPoint = CGPoint(x: smoothedX, y: smoothedY)
            
            self.currentTargetPoint = smoothedPoint
            evaluateAlignment(at: smoothedPoint)
        }
    }
    
    // MARK: - 60Hz Gyro Motion Handler (Inertial Odometry khi mất dấu hoặc chuyển động nhanh)
    
    private func handleGyroMotion(deltaX: CGFloat, deltaY: CGFloat) {
        guard case .targetPlaced = aiSessionState, let initial = initialTargetPoint else { return }
        
        // Nếu Vision Tracking đang mất dấu (ví dụ lia máy quá nhanh bị mờ hình)
        // Dùng Gyroscope tiếp quản làm mỏ neo không gian để tâm vàng không bị văng
        if lastVisualConfidence <= 0.25 {
            let newX = initial.x - deltaX
            let newY = initial.y - deltaY
            let gyroPoint = CGPoint(x: newX, y: newY)
            
            let current = self.currentTargetPoint ?? gyroPoint
            let alpha: CGFloat = 0.50
            let smoothedX = current.x * (1.0 - alpha) + newX * alpha
            let smoothedY = current.y * (1.0 - alpha) + newY * alpha
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
        
        // Haptic rung khi tiến gần tâm
        if dist < 0.15 && dist > calculator.alignmentTolerance {
            let intensity = 1.0 - (dist / 0.15)
            haptics.triggerProximityPulse(intensity: intensity)
        }
        
        let isPerfect = dist <= calculator.alignmentTolerance
        
        if isPerfect && !isPerfectAlignment {
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
        haptics.triggerSelectionChange()
        currentZoom = zoom
        cameraService.setZoomFactor(zoom)
    }
    
    public func setExposure(_ bias: Float) {
        exposureBias = bias
        cameraService.setExposureBias(bias)
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
    
    public func takePhotoManual() {
        if captureMode == .video {
            toggleVideoRecording()
            return
        }
        
        guard aiSessionState == .idle else { return }
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.1)) { isShutterPressing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.isShutterPressing = false }
        cameraService.capturePhoto()
    }
    
    public func savePhotoToLibrary(_ item: CapturedPhotoItem) {
        let image = UIImage(cgImage: item.processedImage)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                DispatchQueue.main.async { self.haptics.triggerSuccess() }
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
        let orientation: CGImagePropertyOrientation
        switch UIDevice.current.orientation {
        case .landscapeLeft: orientation = .up
        case .landscapeRight: orientation = .down
        case .portraitUpsideDown: orientation = .left
        default: orientation = .right
        }
        visionEngine.processVideoSampleBuffer(sampleBuffer, orientation: orientation)
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
