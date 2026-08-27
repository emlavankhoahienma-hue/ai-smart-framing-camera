import Foundation
import SwiftUI
import AVFoundation
import CoreImage
import Photos

@MainActor
public final class CameraViewModel: ObservableObject {
    // MARK: - Services
    public let cameraService = CameraService.shared
    public let visionEngine = VisionFramingEngine.shared
    public let calculator = CompositionCalculator.shared
    public let filterEngine = FilmFilterEngine.shared
    public let haptics = HapticFeedbackService.shared
    public let arSession = ARCompositionSession.shared
    
    // MARK: - Published UI States
    @Published public var isCameraReady: Bool = false
    @Published public var hasCameraPermission: Bool = false
    @Published public var isAIAnalysisActive: Bool = true
    @Published public var activeCompositionRule: CompositionRule = .goldenRatio
    @Published public var selectedFilmPreset: FilmPreset = .fujiPro400H
    @Published public var isAutoColorTuningEnabled: Bool = true
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
    
    // Capture & Review
    @Published public var latestCapturedPhoto: CapturedPhotoItem?
    @Published public var isShowingPhotoDetail: Bool = false
    @Published public var isShowingSettings: Bool = false
    @Published public var isShowingFilmDrawer: Bool = false
    @Published public var showAlignmentSuccessFlash: Bool = false
    @Published public var isShutterPressing: Bool = false
    @Published public var isARModeEnabled: Bool = false
    
    // Internal state tracking
    private var previousWasAligned = false
    private var lastAutoZoomTime: TimeInterval = 0
    
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
                    if granted {
                        self?.startCamera()
                    }
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
    
    // MARK: - AI Vision Loop Handler
    private func handleVisionDetection(_ detection: SubjectDetectionResult) {
        guard isAIAnalysisActive else { return }
        
        self.detectedScene = detection.detectedScene
        self.detectedFaceRects = detection.faceRectangles
        if let dominant = detection.dominantSubjectRect {
            self.detectedSubjectRects = [dominant]
        } else {
            self.detectedSubjectRects = []
        }
        
        // Auto Color Tuning based on detected scene
        if isAutoColorTuningEnabled {
            let autoPreset = detection.detectedScene.recommendedFilter
            if self.selectedFilmPreset != autoPreset {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.selectedFilmPreset = autoPreset
                }
            }
        }
        
        // Calculate Target Coordinates & Geometry
        let result = calculator.calculateTarget(
            from: detection,
            rule: activeCompositionRule,
            currentZoom: currentZoom
        )
        
        self.framingResult = result
        
        // Alignment State Logic
        if result.isAligned {
            self.alignmentState = .aligned(score: result.alignmentScore)
            
            if !previousWasAligned {
                previousWasAligned = true
                haptics.triggerMagneticSnap()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    self.showAlignmentSuccessFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.showAlignmentSuccessFlash = false
                }
            }
        } else {
            previousWasAligned = false
            self.alignmentState = .guiding(distance: result.distance, angle: result.angleDegrees)
        }
        
        // Auto Zoom Execution (if enabled by user)
        if isAutoZoomEnabled && abs(result.recommendedZoomFactor - currentZoom) > 0.4 {
            let now = CACurrentMediaTime()
            if now - lastAutoZoomTime > 1.8 {
                lastAutoZoomTime = now
                self.setZoom(result.recommendedZoomFactor)
            }
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
            isAutoColorTuningEnabled = false
        }
    }
    
    public func toggleAutoColorTuning() {
        haptics.triggerSelectionChange()
        isAutoColorTuningEnabled.toggle()
        if isAutoColorTuningEnabled {
            selectedFilmPreset = detectedScene.recommendedFilter
        }
    }
    
    public func toggleAIAnalysis() {
        haptics.triggerSelectionChange()
        isAIAnalysisActive.toggle()
        if !isAIAnalysisActive {
            framingResult = nil
            detectedSubjectRects = []
            detectedFaceRects = []
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
    
    // MARK: - Capture
    public func takePhoto() {
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
}

// MARK: - CameraServiceDelegate
extension CameraViewModel: CameraServiceDelegate {
    public func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer) {
        visionEngine.processVideoSampleBuffer(sampleBuffer)
    }
    
    public func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double) {
        let processed = filterEngine.applyPreset(to: photo, preset: selectedFilmPreset) ?? photo
        let alignmentScore = framingResult?.alignmentScore ?? 0.85
        
        let item = CapturedPhotoItem(
            originalImage: photo,
            processedImage: processed,
            sceneType: detectedScene,
            appliedPreset: selectedFilmPreset,
            compositionRule: activeCompositionRule,
            alignmentScore: alignmentScore,
            iso: iso,
            shutterSpeed: shutterSpeed
        )
        
        self.latestCapturedPhoto = item
        self.isShowingPhotoDetail = true
        self.savePhotoToLibrary(item)
    }
    
    public func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {
        self.currentZoom = zoom
    }
}
