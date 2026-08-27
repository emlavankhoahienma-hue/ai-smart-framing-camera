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
    
    // MARK: - AI Session State Machine
    @Published public var aiSessionState: AISessionState = .idle
    
    // MARK: - Published UI States
    @Published public var isCameraReady: Bool = false
    @Published public var hasCameraPermission: Bool = false
    @Published public var activeCompositionRule: CompositionRule = .goldenRatio
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H
    @Published public var isAIFullColorEnabled: Bool = false
    @Published public var isAutoZoomEnabled: Bool = false
    
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
    
    // TARGET TRACKING (sniper model)
    /// The PINNED target position (screen-normalized, 0-1) determined by AI/Gemini
    /// This is FIXED — it doesn't change until next AI session
    @Published public var pinnedTargetPoint: CGPoint? = nil
    
    /// Current WHITE CROSSHAIR position — FOLLOWS the tracked subject
    /// As user moves camera, Vision tracks subject and reports its current screen position
    /// When trackedSubjectPoint == pinnedTargetPoint → CAPTURE
    @Published public var trackedSubjectPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    
    /// Distance from trackedSubjectPoint to pinnedTargetPoint (0 = perfect)
    @Published public var alignmentDistance: CGFloat = 1.0
    @Published public var isPerfectAlignment: Bool = false
    
    // Gemini State
    @Published public var isGeminiAnalyzing: Bool = false
    @Published public var geminiError: String? = nil
    @Published public var geminiExplanation: String = ""
    @Published public var geminiColorRecipe: GeminiColorRecipe? = nil
    @Published public var useGeminiForAnalysis: Bool = true  // Toggle Gemini vs local Vision
    
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
    
    // MARK: - Internal State
    private var previousWasAligned = false
    private var lastAutoZoomTime: TimeInterval = 0
    private var autoCaptureTask: Task<Void, Never>? = nil
    
    // Gemini captured frame (one frame taken when button pressed)
    private var capturedFrameForGemini: CGImage? = nil
    
    // Vision analysis accumulation (for local mode fallback)
    private var analysisFrames: [SubjectDetectionResult] = []
    private let analysisFramesNeeded = 6
    
    // Subject tracking description (set at lock time) for continuous tracking
    private var targetSubjectAnchor: CGRect? = nil  // Last known subject position
    private var trackingLostFrames: Int = 0
    private let trackingLostThreshold = 20  // frames before fallback
    
    public init() {
        setupCallbacks()
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
    }
    
    // MARK: - AI Session Control
    
    public func startAISession() {
        guard aiSessionState == .idle || aiSessionState == .done else { return }
        haptics.triggerSelectionChange()
        
        // Reset state
        analysisFrames = []
        pinnedTargetPoint = nil
        targetSubjectAnchor = nil
        trackingLostFrames = 0
        framingResult = nil
        detectedSubjectRects = []
        detectedFaceRects = []
        isPerfectAlignment = false
        alignmentDistance = 1.0
        geminiError = nil
        geminiExplanation = ""
        trackedSubjectPoint = CGPoint(x: 0.5, y: 0.5)
        capturedFrameForGemini = nil
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            aiSessionState = .analyzing
        }
        
        // Tell Vision engine to capture a frame for Gemini
        visionEngine.captureNextFrameForGemini = true
    }
    
    public func cancelAISession() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        haptics.triggerSelectionChange()
        visionEngine.captureNextFrameForGemini = false
        
        withAnimation(.easeInOut(duration: 0.3)) {
            aiSessionState = .idle
            pinnedTargetPoint = nil
            framingResult = nil
            isPerfectAlignment = false
            alignmentDistance = 1.0
            detectedSubjectRects = []
            detectedFaceRects = []
            trackedSubjectPoint = CGPoint(x: 0.5, y: 0.5)
        }
    }
    
    // MARK: - Gemini Analysis
    
    /// Call Gemini API with a captured frame
    func callGeminiAnalysis(frame: CGImage) {
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
                // Fallback to local Vision analysis
                self.fallbackToLocalAnalysis()
            }
        }
    }
    
    private func handleGeminiResponse(_ response: GeminiFramingResponse) {
        // Store color recipe from Gemini
        self.geminiColorRecipe = response.colorRecipe
        self.geminiExplanation = response.explanation
        self.detectedScene = response.sceneType
        self.activeCompositionRule = response.compositionRule
        
        // Apply Gemini color if AI Full Color enabled
        if isAIFullColorEnabled {
            currentAIColorParams = response.colorRecipe.asAIColorParameters
            // Auto-correct exposure from Gemini's luminance suggestion
            // (built into color recipe via shadow/highlight parameters)
        }
        
        // PIN the target at Gemini-specified coordinates
        let targetPoint = CGPoint(x: response.targetX, y: response.targetY)
        lockTarget(at: targetPoint, detection: nil)
    }
    
    private func fallbackToLocalAnalysis() {
        // Use accumulated Vision frames if Gemini fails
        guard !analysisFrames.isEmpty else {
            // No frames yet — keep collecting
            return
        }
        consolidateAndLockTarget()
    }
    
    // MARK: - Vision Detection Handler
    
    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        switch aiSessionState {
        case .idle, .capturing, .done:
            // Preview mode — show faces
            self.detectedScene = detection.detectedScene
            self.detectedFaceRects = detection.faceRectangles
            return
            
        case .analyzing:
            handleAnalyzingPhase(detection)
            
        case .targetPlaced:
            // *** SNIPER MODEL: track subject, update crosshair position ***
            handleSubjectTracking(detection)
            
        case .alignmentPerfect:
            // Keep tracking while countdown
            handleSubjectTracking(detection)
        }
        
        // Check for captured Gemini frame
        if let frame = visionEngine.capturedGeminiFrame {
            visionEngine.capturedGeminiFrame = nil
            capturedFrameForGemini = frame
            
            if useGeminiForAnalysis && geminiService.hasAPIKey {
                callGeminiAnalysis(frame: frame)
            }
            // Local Vision continues collecting frames in parallel
        }
    }
    
    // MARK: - Phase 1: Collecting Vision frames (during 'analyzing')
    
    private func handleAnalyzingPhase(_ detection: SubjectDetectionResult) {
        self.detectedScene = detection.detectedScene
        self.detectedFaceRects = detection.faceRectangles
        if let dominant = detection.dominantSubjectRect {
            self.detectedSubjectRects = [dominant]
        }
        
        analysisFrames.append(detection)
        
        // If Gemini is being called, wait for it
        // If not using Gemini OR Gemini is not available → lock after enough frames
        if (!useGeminiForAnalysis || !geminiService.hasAPIKey) && analysisFrames.count >= analysisFramesNeeded {
            consolidateAndLockTarget()
        } else if useGeminiForAnalysis && !geminiService.hasAPIKey && analysisFrames.count >= analysisFramesNeeded {
            consolidateAndLockTarget()
        }
    }
    
    /// Consolidate Vision frames (local mode) → lock target
    private func consolidateAndLockTarget() {
        guard !analysisFrames.isEmpty else { return }
        
        // Most common scene
        var sceneCounts: [DetectedSceneType: Int] = [:]
        for f in analysisFrames { sceneCounts[f.detectedScene, default: 0] += 1 }
        let dominantScene = sceneCounts.max(by: { $0.value < $1.value })?.key ?? .general
        
        // Average subject position
        let validFrames = analysisFrames.filter { $0.dominantSubjectRect != nil }
        var avgDetection = SubjectDetectionResult()
        
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
        
        // Compute composition target point
        let result = calculator.calculateTarget(from: avgDetection, rule: activeCompositionRule, currentZoom: currentZoom)
        lockTarget(at: result.targetPoint, detection: avgDetection)
        
        // AI Full Color (local mode)
        if isAIFullColorEnabled {
            currentAIColorParams = dominantScene.aiFullColorParameters
            let lumaError: Float = 0.50 - avgDetection.averageLuminance
            setExposure(max(-2.0, min(2.0, lumaError * 3.0)))
        }
        
        detectedScene = dominantScene
    }
    
    /// Lock the yellow target at a specific screen point, start subject tracking
    private func lockTarget(at point: CGPoint, detection: SubjectDetectionResult?) {
        pinnedTargetPoint = point
        targetSubjectAnchor = detection?.dominantSubjectRect ?? detection?.faceRectangles.first
        trackingLostFrames = 0
        
        // Initial WHITE crosshair = current subject position (if known)
        if let anchor = targetSubjectAnchor {
            trackedSubjectPoint = CGPoint(x: anchor.midX, y: anchor.midY)
        } else {
            trackedSubjectPoint = CGPoint(x: 0.5, y: 0.5)
        }
        
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.haptics.triggerSuccess()
        }
    }
    
    // MARK: - Phase 2: Subject Tracking (sniper model)
    // The white CROSSHAIR = current subject position (tracked by Vision)
    // The yellow TARGET = FIXED pinned position (where AI said to frame)
    // User moves camera → subject moves on screen → crosshair follows
    // When crosshair reaches fixed target → CAPTURE
    
    private func handleSubjectTracking(_ detection: SubjectDetectionResult) {
        guard let pinned = pinnedTargetPoint else { return }
        
        // Find current subject screen position from Vision
        var currentSubjectPos: CGPoint? = nil
        
        if !detection.faceRectangles.isEmpty {
            let face = detection.faceRectangles[0]
            currentSubjectPos = CGPoint(x: face.midX, y: face.midY)
        } else if let subjRect = detection.dominantSubjectRect {
            currentSubjectPos = CGPoint(x: subjRect.midX, y: subjRect.midY)
        } else if !detection.saliencyPoints.isEmpty {
            currentSubjectPos = detection.saliencyPoints[0]
        }
        
        if let pos = currentSubjectPos {
            // Subject found — update white crosshair
            trackingLostFrames = 0
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.8)) {
                trackedSubjectPoint = pos
            }
        } else {
            // Subject lost — interpolate toward center gradually
            trackingLostFrames += 1
            if trackingLostFrames > trackingLostThreshold {
                // Too many frames lost — slowly drift toward center
                let alpha: CGFloat = 0.05
                trackedSubjectPoint = CGPoint(
                    x: trackedSubjectPoint.x + (0.5 - trackedSubjectPoint.x) * alpha,
                    y: trackedSubjectPoint.y + (0.5 - trackedSubjectPoint.y) * alpha
                )
            }
        }
        
        // Distance: crosshair (tracked subject) → pinned target
        let dx = trackedSubjectPoint.x - pinned.x
        let dy = trackedSubjectPoint.y - pinned.y
        let dist = sqrt(dx * dx + dy * dy)
        
        self.alignmentDistance = dist
        
        // Proximity haptic (soft pulse when getting close)
        if dist < 0.18 && dist > calculator.alignmentTolerance {
            let intensity = 1.0 - (dist / 0.18)
            haptics.triggerProximityPulse(intensity: intensity)
        }
        
        let isPerfect = dist <= calculator.alignmentTolerance
        
        if isPerfect && !isPerfectAlignment {
            // Just entered perfect alignment
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
            // Left alignment before capture
            isPerfectAlignment = false
            autoCaptureTask?.cancel()
            autoCaptureTask = nil
            autoCaptureCountdown = 0
            withAnimation {
                aiSessionState = .targetPlaced(locked: true)
            }
        }
        
        // Update alignment guide state
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
        autoCaptureCountdown = 2
        
        autoCaptureTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run { self.autoCaptureCountdown = 1 }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run { self.autoCaptureCountdown = 0 }
            try? await Task.sleep(nanoseconds: 400_000_000)
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
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.05)) { activeFlashMode2 = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.activeFlashMode2 = false }
        
        withAnimation { aiSessionState = .capturing; isShutterPressing = true }
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
                // Use Gemini recipe if available, otherwise use scene defaults
                currentAIColorParams = geminiColorRecipe?.asAIColorParameters ?? detectedScene.aiFullColorParameters
            } else {
                selectedFilmPreset = .fujiPro400H
                currentAIColorParams = nil
            }
        }
    }
    
    public func toggleGemini() {
        haptics.triggerSelectionChange()
        useGeminiForAnalysis.toggle()
    }
    
    public func toggleARMode() {
        haptics.triggerSelectionChange()
        isARModeEnabled.toggle()
        if isARModeEnabled { arSession.startSession() } else { arSession.pauseSession() }
    }
    
    public func takePhotoManual() {
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
        case .targetPlaced, .alignmentPerfect: return pinnedTargetPoint != nil
        default: return false
        }
    }
    
    public var showGuidanceRay: Bool {
        switch aiSessionState {
        case .targetPlaced: return !isPerfectAlignment && pinnedTargetPoint != nil
        default: return false
        }
    }
    
    public var geminiStatusText: String {
        if isGeminiAnalyzing { return "Gemini đang phân tích..." }
        if let err = geminiError { return "Lỗi: \(err.prefix(60))" }
        if !geminiExplanation.isEmpty { return geminiExplanation }
        return ""
    }
}

// MARK: - CameraServiceDelegate
extension CameraViewModel: CameraServiceDelegate {
    public func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        visionEngine.processVideoSampleBuffer(sampleBuffer)
    }
    
    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double) {
        // Determine color processing
        let finalColorParams: AIColorParameters?
        if isAIFullColorEnabled {
            // Gemini recipe takes priority over local AI recipe
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
        default: alignmentScore = framingResult?.alignmentScore ?? 0.7
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
