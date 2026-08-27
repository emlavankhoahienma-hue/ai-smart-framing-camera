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
    
    // MARK: - AI Session State Machine
    /// State tổng thể của AI Framing Session
    @Published public var aiSessionState: AISessionState = .idle
    
    // MARK: - Published UI States
    @Published public var isCameraReady: Bool = false
    @Published public var hasCameraPermission: Bool = false
    @Published public var activeCompositionRule: CompositionRule = .goldenRatio
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H
    @Published public var isAIFullColorEnabled: Bool = false  // AI Full Color Mode
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
    /// Normalized offset distance 0..1 of white center from yellow target
    @Published public var alignmentDistance: CGFloat = 1.0
    /// Is perfect alignment achieved (white overlaps yellow)
    @Published public var isPerfectAlignment: Bool = false
    
    // Capture & Review
    @Published public var latestCapturedPhoto: CapturedPhotoItem?
    @Published public var isShowingPhotoDetail: Bool = false
    @Published public var isShowingSettings: Bool = false
    @Published public var isShowingFilmDrawer: Bool = false
    @Published public var showAlignmentSuccessFlash: Bool = false
    @Published public var isShutterPressing: Bool = false
    @Published public var isARModeEnabled: Bool = false
    @Published public var activeFlashMode2: Bool = false // visual flash overlay
    
    // AI Auto-capture countdown
    @Published public var autoCaptureCountdown: Int = 0
    
    // AI Color Parameters (from AI Full Color Mode)
    @Published public var currentAIColorParams: AIColorParameters? = nil
    
    // MARK: - Internal State
    private var previousWasAligned = false
    private var lastAutoZoomTime: TimeInterval = 0
    private var autoCaptureTask: Task<Void, Never>? = nil
    private var targetLockedDetection: SubjectDetectionResult? = nil
    
    // Analysis accumulation (AI waits for stable detection before locking target)
    private var analysisFrames: [SubjectDetectionResult] = []
    private let analysisFramesNeeded = 8   // 8 frames (~0.4s) before locking
    
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
    
    /// Người dùng nhấn nút AI — bắt đầu phân tích
    public func startAISession() {
        guard aiSessionState == .idle || aiSessionState == .done else { return }
        haptics.triggerSelectionChange()
        
        // Reset
        analysisFrames = []
        targetLockedDetection = nil
        framingResult = nil
        detectedSubjectRects = []
        detectedFaceRects = []
        isPerfectAlignment = false
        alignmentDistance = 1.0
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            aiSessionState = .analyzing
        }
    }
    
    /// Hủy session AI — về idle
    public func cancelAISession() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        haptics.triggerSelectionChange()
        
        withAnimation(.easeInOut(duration: 0.3)) {
            aiSessionState = .idle
            framingResult = nil
            isPerfectAlignment = false
            alignmentDistance = 1.0
            detectedSubjectRects = []
            detectedFaceRects = []
        }
    }
    
    // MARK: - AI Vision Loop Handler
    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        switch aiSessionState {
        case .idle, .capturing, .done:
            // Khi idle, vẫn hiển thị face/subject rects cho preview
            self.detectedScene = detection.detectedScene
            self.detectedFaceRects = detection.faceRectangles
            return
            
        case .analyzing:
            // Thu thập frames phân tích để ổn định kết quả
            handleAnalyzingPhase(detection)
            
        case .targetPlaced:
            // Target đã khóa — chỉ theo dõi offset tâm trắng → tâm vàng
            handleAlignmentTracking(detection)
            
        case .alignmentPerfect:
            // Đang countdown — không cần xử lý thêm
            break
        }
    }
    
    /// Phase 1: Thu thập frames ổn định để quyết định vị trí mục tiêu vàng
    private func handleAnalyzingPhase(_ detection: SubjectDetectionResult) {
        self.detectedScene = detection.detectedScene
        self.detectedFaceRects = detection.faceRectangles
        if let dominant = detection.dominantSubjectRect {
            self.detectedSubjectRects = [dominant]
        }
        
        analysisFrames.append(detection)
        
        // Đủ số frame → tổng hợp và khóa mục tiêu
        if analysisFrames.count >= analysisFramesNeeded {
            consolidateAndLockTarget()
        }
    }
    
    /// Tổng hợp n frames → tính trung bình → khóa vị trí tâm vàng
    private func consolidateAndLockTarget() {
        guard !analysisFrames.isEmpty else { return }
        
        // Lấy scene xuất hiện nhiều nhất
        var sceneCounts: [DetectedSceneType: Int] = [:]
        for frame in analysisFrames {
            sceneCounts[frame.detectedScene, default: 0] += 1
        }
        let dominantScene = sceneCounts.max(by: { $0.value < $1.value })?.key ?? .general
        
        // Tính trung bình vị trí chủ thể
        let validFrames = analysisFrames.filter { $0.dominantSubjectRect != nil }
        var avgDetection = SubjectDetectionResult()
        
        if !validFrames.isEmpty {
            let avgX = validFrames.compactMap { $0.dominantSubjectRect?.midX }.reduce(0, +) / CGFloat(validFrames.count)
            let avgY = validFrames.compactMap { $0.dominantSubjectRect?.midY }.reduce(0, +) / CGFloat(validFrames.count)
            let avgW = validFrames.compactMap { $0.dominantSubjectRect?.width }.reduce(0, +) / CGFloat(validFrames.count)
            let avgH = validFrames.compactMap { $0.dominantSubjectRect?.height }.reduce(0, +) / CGFloat(validFrames.count)
            avgDetection.dominantSubjectRect = CGRect(x: avgX - avgW/2, y: avgY - avgH/2, width: avgW, height: avgH)
        }
        
        // Tính trung bình luminance & color temp
        avgDetection.detectedScene = dominantScene
        avgDetection.averageLuminance = analysisFrames.map { $0.averageLuminance }.reduce(0, +) / Float(analysisFrames.count)
        avgDetection.estimatedColorTemp = analysisFrames.map { $0.estimatedColorTemp }.reduce(0, +) / Float(analysisFrames.count)
        
        // Nếu có faces, lấy frame đầu tiên có face
        if let faceFrame = analysisFrames.first(where: { !$0.faceRectangles.isEmpty }) {
            avgDetection.faceRectangles = faceFrame.faceRectangles
            avgDetection.primaryEyePosition = faceFrame.primaryEyePosition
            avgDetection.lookingDirection = faceFrame.lookingDirection
        }
        
        targetLockedDetection = avgDetection
        
        // Tính target composition
        let result = calculator.calculateTarget(
            from: avgDetection,
            rule: activeCompositionRule,
            currentZoom: currentZoom
        )
        
        // AI Full Color: áp dụng màu từ scene
        if isAIFullColorEnabled {
            let colorParams = dominantScene.aiFullColorParameters
            currentAIColorParams = colorParams
            // Điều chỉnh exposure bias theo luminance
            let targetLuminance: Float = 0.50
            let lumaError = targetLuminance - avgDetection.averageLuminance
            let exposureCorrection = lumaError * 3.0 // ~±1.5 EV correction
            setExposure(max(-2.0, min(2.0, exposureCorrection)))
        }
        
        // Cập nhật UI
        self.framingResult = result
        self.detectedScene = dominantScene
        
        haptics.triggerSelectionChange()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            aiSessionState = .targetPlaced(locked: true)
            alignmentDistance = result.distance
        }
        
        // Feedback rung xác nhận đặt mục tiêu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.haptics.triggerSuccess()
        }
    }
    
    /// Phase 2: Camera đã cố định mục tiêu → theo dõi offset và chụp khi trùng
    private func handleAlignmentTracking(_ detection: SubjectDetectionResult) {
        guard let locked = targetLockedDetection, let result = framingResult else { return }
        
        // Tâm trắng luôn là (0.5, 0.5) — bất biến
        // Target vàng đã được "bake in" từ lần phân tích trước — không thay đổi
        // Người dùng DI CHUYỂN máy → tâm hiện tại thay đổi so với target
        // Ta cần tính khoảng cách từ vị trí HIỆN TẠI của chủ thể đến vị trí TARGET
        
        // Cách tính: Nếu người dùng di chuyển máy đúng hướng, chủ thể trong khung sẽ dịch chuyển
        // gần về vị trí tương đương với target ban đầu ở tọa độ (0.5, 0.5)
        // Simplified: Tính khoảng cách của chủ thể hiện tại đến tâm màn hình
        
        var currentSubjectCenter = CGPoint(x: 0.5, y: 0.5)
        if let subjectRect = detection.dominantSubjectRect {
            currentSubjectCenter = CGPoint(x: subjectRect.midX, y: subjectRect.midY)
        } else if !detection.faceRectangles.isEmpty {
            let face = detection.faceRectangles[0]
            currentSubjectCenter = CGPoint(x: face.midX, y: face.midY)
        }
        
        // Target point của kết quả phân tích ban đầu (điểm vàng)
        let targetPoint = result.targetPoint
        
        // Khoảng cách hiện tại từ chủ thể → target
        let dx = currentSubjectCenter.x - targetPoint.x
        let dy = currentSubjectCenter.y - targetPoint.y
        let currentDistance = sqrt(dx * dx + dy * dy)
        
        self.alignmentDistance = currentDistance
        
        // Cập nhật alignment state
        let isPerfect = currentDistance <= calculator.alignmentTolerance
        
        if isPerfect != self.isPerfectAlignment {
            self.isPerfectAlignment = isPerfect
            
            if isPerfect {
                // Trùng khớp! → chuyển sang state perfect → auto-capture
                haptics.triggerMagneticSnap()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    aiSessionState = .alignmentPerfect
                    showAlignmentSuccessFlash = true
                }
                startAutoCaptureCountdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.showAlignmentSuccessFlash = false
                }
            }
        }
        
        // Haptic proximity pulse khi gần target
        if currentDistance < 0.15 && !isPerfect {
            let pulseIntensity = 1.0 - (currentDistance / 0.15)
            haptics.triggerProximityPulse(intensity: pulseIntensity)
        }
        
        // Update alignment state
        if !isPerfect {
            let angle = atan2(dy, dx) * 180 / .pi
            let normalizedAngle = angle < 0 ? angle + 360 : angle
            alignmentState = .guiding(distance: currentDistance, angle: normalizedAngle)
        } else {
            alignmentState = .aligned(score: 1.0)
        }
    }
    
    /// Countdown 2s rồi auto-chụp
    private func startAutoCaptureCountdown() {
        autoCaptureTask?.cancel()
        autoCaptureCountdown = 2
        
        autoCaptureTask = Task {
            for i in stride(from: 2, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                await MainActor.run { self.autoCaptureCountdown = i - 1 }
            }
            // Vẫn đang aligned? Chụp!
            await MainActor.run {
                if self.isPerfectAlignment {
                    self.executeCapture()
                } else {
                    // Người dùng đã lệch ra — reset về guiding
                    self.aiSessionState = .targetPlaced(locked: true)
                    self.autoCaptureCountdown = 0
                }
            }
        }
    }
    
    /// Thực hiện chụp ảnh
    private func executeCapture() {
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.05)) {
            activeFlashMode2 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.activeFlashMode2 = false
        }
        
        withAnimation {
            aiSessionState = .capturing
            isShutterPressing = true
        }
        
        cameraService.capturePhoto()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.isShutterPressing = false
        }
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
        withAnimation(.spring()) {
            activeCompositionRule = rule
        }
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
            }
        }
    }
    
    public func toggleAIFullColor() {
        haptics.triggerSelectionChange()
        withAnimation(.spring()) {
            isAIFullColorEnabled.toggle()
            if isAIFullColorEnabled {
                selectedFilmPreset = .aiFullAuto
                currentAIColorParams = detectedScene.aiFullColorParameters
            } else {
                selectedFilmPreset = .fujiPro400H
                currentAIColorParams = nil
            }
        }
    }
    
    public func toggleARMode() {
        haptics.triggerSelectionChange()
        isARModeEnabled.toggle()
        if isARModeEnabled {
            arSession.startSession()
        } else {
            arSession.pauseSession()
        }
    }
    
    /// Manual shutter — chỉ hoạt động khi không trong AI session
    public func takePhotoManual() {
        guard aiSessionState == .idle else { return }
        haptics.triggerShutterClick()
        withAnimation(.easeInOut(duration: 0.1)) {
            isShutterPressing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isShutterPressing = false
        }
        cameraService.capturePhoto()
    }
    
    public func savePhotoToLibrary(_ item: CapturedPhotoItem) {
        let image = UIImage(cgImage: item.processedImage)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                DispatchQueue.main.async {
                    self.haptics.triggerSuccess()
                }
            }
        }
    }
    
    // MARK: - Computed helpers
    
    public var isAISessionActive: Bool {
        aiSessionState.isSessionActive
    }
    
    public var showTargetCircle: Bool {
        switch aiSessionState {
        case .targetPlaced, .alignmentPerfect: return true
        default: return false
        }
    }
    
    public var showGuidanceRay: Bool {
        switch aiSessionState {
        case .targetPlaced: return !isPerfectAlignment
        default: return false
        }
    }
}

// MARK: - CameraServiceDelegate
extension CameraViewModel: CameraServiceDelegate {
    public func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        // Luôn xử lý frames để hiển thị face rects preview
        // VisionEngine sẽ tự throttle
        visionEngine.processVideoSampleBuffer(sampleBuffer)
    }
    
    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double) {
        let aiParams = isAIFullColorEnabled ? (currentAIColorParams ?? detectedScene.aiFullColorParameters) : nil
        
        let processed: CGImage
        if let params = aiParams {
            // AI Full Color Mode
            processed = filterEngine.applyAIColorParameters(to: photo, params: params) ?? photo
        } else {
            // Manual preset
            processed = filterEngine.applyPreset(to: photo, preset: selectedFilmPreset) ?? photo
        }
        
        let alignmentScore: Double
        if case .alignmentPerfect = aiSessionState {
            alignmentScore = 1.0
        } else {
            alignmentScore = framingResult?.alignmentScore ?? 0.7
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
            aiColorParameters: aiParams
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
