import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import QuartzCore
import ImageIO

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    @MainActor
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, processedCompanionData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double, format: PhotoSaveFormat, requestedHighResolution: Bool)
    @MainActor
    func cameraService(_ service: CameraService, didFailCaptureWithError error: Error)
    @MainActor
    func cameraService(_ service: CameraService, didChangePhotoPhase phase: PhotoCapturePhase)
    @MainActor
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL)
    @MainActor
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat)
    @MainActor
    func cameraService(_ service: CameraService, didChangeRecordingState state: CameraRecordingState)
    @MainActor
    func cameraService(_ service: CameraService, didFailRecordingWithError error: Error)
    @MainActor
    func cameraService(_ service: CameraService, didChangeSessionRunning isRunning: Bool)
}

public extension CameraServiceDelegate {
    @MainActor
    func cameraService(_ service: CameraService, didFailCaptureWithError error: Error) {}
    @MainActor
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {}
    @MainActor
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {}
    @MainActor
    func cameraService(_ service: CameraService, didChangeRecordingState state: CameraRecordingState) {}
    @MainActor
    func cameraService(_ service: CameraService, didFailRecordingWithError error: Error) {}
    @MainActor
    func cameraService(_ service: CameraService, didChangeSessionRunning isRunning: Bool) {}
}

public enum CameraRecordingState: Equatable {
    case idle
    case starting
    case recording
    case stopping
}

public enum PhotoCapturePhase: Sendable {
    case preparing, exposing, processing
}

public struct LiveCameraStats {
    public var iso: Float
    public var shutterSpeedString: String
    public var exposureDurationSeconds: Double
    public var lensPosition: Float

    public init(iso: Float, shutterSpeedString: String, exposureDurationSeconds: Double, lensPosition: Float) {
        self.iso = iso
        self.shutterSpeedString = shutterSpeedString
        self.exposureDurationSeconds = exposureDurationSeconds
        self.lensPosition = lensPosition
    }
}

public enum CameraServiceError: LocalizedError {
    case captureAlreadyInProgress
    case photoProcessingFailed
    case rawUnavailable
    case cameraNotReady
    case captureTimedOut
    case recordingUnavailable
    case recordingInterrupted

    public var errorDescription: String? {
        switch self {
        case .captureAlreadyInProgress:
            return "A photo capture is already in progress."
        case .rawUnavailable:
            return "Camera hiện tại không hỗ trợ DNG. Chọn camera sau hỗ trợ RAW hoặc đổi định dạng."
        case .cameraNotReady:
            return "Camera chưa sẵn sàng chụp ảnh."
        case .captureTimedOut:
            return "Camera mất quá nhiều thời gian để trả ảnh."
        case .photoProcessingFailed:
            return "The camera returned photo data that could not be decoded."
        case .recordingUnavailable:
            return "Camera chưa sẵn sàng quay video."
        case .recordingInterrupted:
            return "Phiên quay video đã bị gián đoạn."
        }
    }
}

public final class CameraService: NSObject {
    public static let shared = CameraService()

    public weak var delegate: CameraServiceDelegate?
    public var onLiveCameraStatsUpdated: ((LiveCameraStats) -> Void)?
    public var onAudioLevelsUpdated: ((Float, Float) -> Void)?

    // Core AVFoundation objects
    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.alignai.camera.sessionQueue", qos: .userInteractive)
    private let videoDataQueue = DispatchQueue(label: "com.alignai.camera.videoDataQueue", qos: .userInteractive)
    private let audioDataQueue = DispatchQueue(label: "com.alignai.camera.audioDataQueue", qos: .userInitiated)
    private let photoProcessingQueue = DispatchQueue(label: "com.alignai.camera.photoProcessingQueue", qos: .userInitiated)

    private var activeCamera: AVCaptureDevice?
    private var zoomObservation: NSKeyValueObservation?
    public var onLiveZoomFactorChanged: ((CGFloat) -> Void)?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieFileOutput = AVCaptureMovieFileOutput()
    private let sharedPhotoContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastAudioMeterUpdateTime: CFTimeInterval = 0

    // State
    public private(set) var isSessionRunning = false
    public private(set) var currentZoom: CGFloat = 1.0
    public private(set) var minZoom: CGFloat = 1.0
    public private(set) var maxZoom: CGFloat = 10.0
    public private(set) var currentCameraPosition: AVCaptureDevice.Position = .back

    // Virtual Multi-Camera Mapping (Apple Camera App style: 0.5x, 1x, 2x, 3x/5x)
    public private(set) var displayMultiplier: CGFloat = 1.0
    public private(set) var hasUltraWideLens: Bool = false
    public private(set) var availableDisplayZoomOptions: [CGFloat] = [1.0, 2.0, 3.0, 5.0]
    public private(set) var defaultDisplayZoom: CGFloat = 1.0

    public func convertDisplayZoomToDeviceZoom(_ displayZoom: CGFloat) -> CGFloat {
        guard displayZoom.isFinite, displayMultiplier.isFinite, displayMultiplier > 0 else {
            return max(minZoom, min(defaultDisplayZoom, maxZoom))
        }
        let devZoom = displayZoom * displayMultiplier
        guard devZoom.isFinite else { return max(minZoom, min(defaultDisplayZoom, maxZoom)) }
        return max(minZoom, min(devZoom, maxZoom))
    }

    public func convertDeviceZoomToDisplayZoom(_ deviceZoom: CGFloat) -> CGFloat {
        guard deviceZoom.isFinite, displayMultiplier.isFinite, displayMultiplier > 0 else {
            return defaultDisplayZoom
        }
        return deviceZoom / displayMultiplier
    }

    public private(set) var flashMode: AVCaptureDevice.FlashMode = .auto
    public private(set) var isLivePhotoMode = false
    public private(set) var selectedVideoFormatOption: VideoFormatOption = .hd60
    public private(set) var selectedVideoCodec: VideoCodec = .hevc
    public private(set) var currentCaptureMode: CameraCaptureMode = .photo

    // Callback thông báo độ phân giải và FPS video phần cứng
    public var onActiveVideoFormatChanged: ((String) -> Void)?

    // All capture state belongs to sessionQueue. RAW and its processed preview
    // are delivered separately and may arrive in either order.
    private struct PhotoRequest {
        let id: Int64
        let format: PhotoSaveFormat
        let highResolution: Bool
        var fileData: Data?
        var processedData: Data?
        var preview: CGImage?
        var movieURL: URL?
        var iso: Float = 100
        var shutter: Double = 1.0 / 125.0
        var error: Error?
        var failureReported = false
    }
    private var pendingPhoto: PhotoRequest?
    private var lastStatsUpdateTime: TimeInterval = 0
    private var isPhotoCaptureInFlight = false
    private var desiredCaptureMode: CameraCaptureMode = .photo
    private var pendingModeCompletion: ((Bool) -> Void)?
    private var recordingState: CameraRecordingState = .idle
    private var wantsRecording = false
    private var recordingStopCommandIssued = false
    private var recordingURL: URL?
    private var recordingInterruptionError: Error?
    private var wantsSessionRunning = false
    private var pendingVideoFormatChange = false
    private var appliedVideoFormatOption: VideoFormatOption?

    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
    }

    // Called only from sessionQueue. Delegate notifications are serialized on main.
    private func publishRecordingState(_ state: CameraRecordingState, force: Bool = false) {
        guard recordingState != state || force else { return }
        recordingState = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraService(self, didChangeRecordingState: state)
        }
    }

    private func publishSessionRunning(_ running: Bool) {
        guard isSessionRunning != running else { return }
        isSessionRunning = running
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraService(self, didChangeSessionRunning: running)
        }
    }

    private func reportRecordingFailure(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraService(self, didFailRecordingWithError: error)
        }
    }

    private func completePendingMode(_ success: Bool) {
        guard let completion = pendingModeCompletion else { return }
        pendingModeCompletion = nil
        DispatchQueue.main.async { completion(success) }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        zoomObservation?.invalidate()
    }

    /// Runs all direct `AVCaptureDevice` access on the camera session queue.
    /// UI-facing services use this boundary instead of reading mutable hardware state cross-thread.
    @discardableResult
    public func scheduleDeviceConfiguration(
        after delay: TimeInterval = 0,
        operation: @escaping (AVCaptureDevice) -> Void
    ) -> DispatchWorkItem {
        let workItem = DispatchWorkItem { [weak self] in
            guard let camera = self?.activeCamera else { return }
            operation(camera)
        }
        let safeDelay = delay.isFinite ? max(0, delay) : 0
        sessionQueue.asyncAfter(deadline: .now() + safeDelay, execute: workItem)
        return workItem
    }

    /// Configure while the session is stopped: intrinsics describe each
    /// captured image, rather than a commanded zoom the lens has not reached.
    private func configureTrackingConnection(_ connection: AVCaptureConnection) {
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        if !captureSession.isRunning && connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }

    /// An explicit user re-pin cancels an earlier AI lens ramp at its current
    /// physical zoom. Configuration and the actual zoom read share sessionQueue.
    public func cancelZoomRamp() {
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                camera.cancelVideoZoomRamp()
                let zoom = camera.videoZoomFactor
                camera.unlockForConfiguration()
                self.currentZoom = zoom
                DispatchQueue.main.async { [weak self] in
                    self?.onLiveZoomFactorChanged?(zoom)
                }
            } catch {
                CameraLogger.error("Không thể dừng AI zoom khi đặt lại mục tiêu", error: error, category: .capture)
            }
        }
    }

    // MARK: - Session Setup
    public func setupSession(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if self.videoDeviceInput != nil {
                DispatchQueue.main.async { completion(true) }
                return
            }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .photo

            let deviceDiscovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInTripleCamera,
                    .builtInDualWideCamera,
                    .builtInWideAngleCamera
                ],
                mediaType: .video,
                position: .back
            )

            guard let camera = deviceDiscovery.devices.first else {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.activeCamera = camera
            self.currentCameraPosition = .back
            self.zoomObservation?.invalidate()
            self.zoomObservation = camera.observe(\.videoZoomFactor, options: [.new]) { [weak self] _, change in
                guard let newValue = change.newValue else { return }
                DispatchQueue.main.async {
                    self?.onLiveZoomFactorChanged?(newValue)
                }
            }
            self.minZoom = camera.minAvailableVideoZoomFactor
            self.maxZoom = min(camera.maxAvailableVideoZoomFactor, 10.0)

            // Cấu hình tỷ lệ zoom chuẩn phong cách Apple Camera App
            let switchFactors = camera.virtualDeviceSwitchOverVideoZoomFactors
            if (camera.deviceType == .builtInTripleCamera || camera.deviceType == .builtInDualWideCamera),
               let firstSwitch = switchFactors.first {
                let wideBase = CGFloat(firstSwitch.doubleValue)
                self.displayMultiplier = wideBase
                self.hasUltraWideLens = true
                self.defaultDisplayZoom = 1.0

                var options: [CGFloat] = [0.5, 1.0, 2.0]
                if switchFactors.count >= 2 {
                    let teleDeviceZoom = CGFloat(switchFactors[1].doubleValue)
                    let teleDisplay = round((teleDeviceZoom / wideBase) * 10) / 10
                    if teleDisplay > 2.0 {
                        options.append(teleDisplay)
                    } else {
                        options.append(3.0)
                    }
                } else if self.maxZoom >= wideBase * 3.0 {
                    options.append(3.0)
                }
                if self.maxZoom >= wideBase * 5.0 {
                    options.append(5.0)
                }
                self.availableDisplayZoomOptions = options
                CameraLogger.info("CameraService: Khởi tạo Multi-Camera Apple (Wide Base: \(wideBase), Options: \(options))", category: .capture)
            } else {
                self.displayMultiplier = 1.0
                self.hasUltraWideLens = false
                self.defaultDisplayZoom = 1.0
                var options: [CGFloat] = [1.0, 2.0]
                if self.maxZoom >= 3.0 { options.append(3.0) }
                if self.maxZoom >= 5.0 { options.append(5.0) }
                self.availableDisplayZoomOptions = options
            }

            // Đặt mức zoom khởi động mặc định là 1.0x (Cảm biến chính Wide sắc nét chuẩn xác)
            let initialDeviceZoom = self.convertDisplayZoomToDeviceZoom(1.0)
            self.currentZoom = initialDeviceZoom

            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = initialDeviceZoom
                if camera.activeFormat.isVideoHDRSupported {
                    camera.automaticallyAdjustsVideoHDREnabled = true
                }
                if camera.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                    camera.activeColorSpace = .P3_D65
                    CameraLogger.info("CameraService: Đã kích hoạt Apple Wide Color P3 (.P3_D65) cho Live View và Chụp ảnh", category: .capture)
                }
                if camera.isLowLightBoostSupported {
                    camera.automaticallyEnablesLowLightBoostWhenAvailable = false
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("Không thể bật HDR/LowLightBoost/P3/Zoom", error: error, category: .capture)
            }

            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(videoInput) {
                    self.captureSession.addInput(videoInput)
                    self.videoDeviceInput = videoInput
                }

                // Configure AVAudioSession for true multi-microphone stereo capture
                self.configureAudioSessionForStereoCapture()

                // Add Audio Input for Video Recording
                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    if let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                       self.captureSession.canAddInput(audioInput) {
                        self.captureSession.addInput(audioInput)
                    }
                }

                // Audio Data Output for Real-time VU Meter
                if self.captureSession.canAddOutput(self.audioDataOutput) {
                    self.captureSession.addOutput(self.audioDataOutput)
                    self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioDataQueue)
                }

                // Video Data Output for Real-time Vision
                if self.captureSession.canAddOutput(self.videoDataOutput) {
                    self.captureSession.addOutput(self.videoDataOutput)
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    // Tracking needs preview pixels, not 48 MP BGRA buffers.
                    self.videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
                    self.videoDataOutput.deliversPreviewSizedOutputBuffers = true
                    self.videoDataOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    if let connection = self.videoDataOutput.connection(with: .video) {
                        self.configureTrackingConnection(connection)
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                    }
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
                }

                // Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    if self.photoOutput.isAppleProRAWSupported {
                        // Pure RAW: Mac dinh tat isAppleProRAWEnabled de sensor xuat Pure Bayer RAW thuan tuy
                        self.photoOutput.isAppleProRAWEnabled = false
                    }
                    self.updateMaxPhotoDimensions(for: camera)

                    if #available(iOS 17.0, *) {
                        if self.photoOutput.isZeroShutterLagSupported {
                            // Zero Shutter Lag khong tuong thich voi RAW capture tren AVFoundation.
                            // Dat true se khien AVFoundation nem NSInvalidArgumentException va vang app ngay lap tuc.
                            self.photoOutput.isZeroShutterLagEnabled = false
                        }
                        if self.photoOutput.isResponsiveCaptureSupported {
                            self.photoOutput.isResponsiveCaptureEnabled = false
                        }
                        if self.photoOutput.isFastCapturePrioritizationSupported {
                            self.photoOutput.isFastCapturePrioritizationEnabled = false
                        }
                        if self.photoOutput.isAutoDeferredPhotoDeliverySupported {
                            // This app saves full files and does not consume deferred proxies.
                            self.photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
                        }
                    }

                    if self.photoOutput.isLivePhotoCaptureSupported {
                        self.photoOutput.isLivePhotoCaptureEnabled = true
                        CameraLogger.info("CameraService: Thiết bị hỗ trợ Live Photo -> isLivePhotoCaptureEnabled = true", category: .capture)
                    } else {
                        CameraLogger.warning("CameraService: isLivePhotoCaptureSupported = false", category: .capture)
                    }
                    if let connection = self.photoOutput.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                    }
                }

                // Movie Output: Không add sẵn vào session để tránh vô hiệu hoá Live Photo ở chế độ Ảnh
                // (Chỉ add khi người dùng chuyển sang chế độ VIDEO)

                // Initial Continuous Auto Focus & Exposure setup
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                if camera.isSmoothAutoFocusSupported {
                    camera.isSmoothAutoFocusEnabled = true
                }
                camera.isSubjectAreaChangeMonitoringEnabled = true
                camera.unlockForConfiguration()

                // Block-based observers must be retained and removed by token. Removing `self`
                // does not unregister block observers and leaked one set on every reconfiguration.
                self.notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
                self.notificationObservers.removeAll(keepingCapacity: true)

                let subjectAreaObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                    object: camera,
                    queue: .main
                ) { [weak self] _ in
                    self?.onSubjectAreaDidChange?()
                }

                // Session Interruption Observers (Tự động phục hồi camera preview khi hết gián đoạn)
                let interruptedObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: self.captureSession,
                    queue: nil
                ) { [weak self] _ in
                    self?.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.publishSessionRunning(false)
                        if self.recordingState != .idle {
                            self.recordingInterruptionError = CameraServiceError.recordingInterrupted
                            self.stopRecordingInternal()
                        }
                        CameraLogger.warning("CameraService: AVCaptureSession was interrupted", category: .capture)
                    }
                }

                let interruptionEndedObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.interruptionEndedNotification,
                    object: self.captureSession,
                    queue: nil
                ) { [weak self] _ in
                    self?.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        if self.wantsSessionRunning && !self.captureSession.isRunning {
                            self.captureSession.startRunning()
                        }
                        self.publishSessionRunning(self.wantsSessionRunning && self.captureSession.isRunning && !self.captureSession.isInterrupted)
                        CameraLogger.info("CameraService: AVCaptureSession interruption ended", category: .capture)
                    }
                }

                let runtimeErrorObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification,
                    object: self.captureSession,
                    queue: nil
                ) { [weak self] notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    self?.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.publishSessionRunning(false)
                        if self.recordingState != .idle {
                            self.recordingInterruptionError = error ?? CameraServiceError.recordingInterrupted
                            self.stopRecordingInternal()
                        }
                        if let error {
                            CameraLogger.error("CameraService: session runtime error", error: error, category: .capture)
                        }
                        let isMediaServicesReset = (error as? AVError)?.code == .mediaServicesWereReset
                        if isMediaServicesReset && self.wantsSessionRunning && !self.captureSession.isInterrupted {
                            if !self.captureSession.isRunning { self.captureSession.startRunning() }
                            self.publishSessionRunning(self.captureSession.isRunning)
                        }
                    }
                }
                self.notificationObservers = [subjectAreaObserver, interruptedObserver, interruptionEndedObserver, runtimeErrorObserver]

                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Start / Stop Session
    public func start(completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            self.wantsSessionRunning = true
            self.configureAudioSessionForStereoCapture()
            if self.videoDeviceInput != nil && !self.captureSession.isRunning && !self.captureSession.isInterrupted {
                self.captureSession.startRunning()
            }
            let running = self.captureSession.isRunning && !self.captureSession.isInterrupted
            self.publishSessionRunning(running)
            if let completion { DispatchQueue.main.async { completion(running) } }
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsSessionRunning = false
            if self.recordingState != .idle { self.stopRecordingInternal() }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
            self.publishSessionRunning(false)
        }
    }

    // MARK: - Camera Position (Switch Front / Back)
    public func switchCamera(completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isPhotoCaptureInFlight, self.recordingState == .idle,
                  !self.movieFileOutput.isRecording, !self.captureSession.isInterrupted,
                  self.videoDeviceInput != nil else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            let targetPosition: AVCaptureDevice.Position = (self.currentCameraPosition == .back) ? .front : .back
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: targetPosition == .front ? [.builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                mediaType: .video,
                position: targetPosition
            )
            guard let newCamera = discovery.devices.first else {
                CameraLogger.warning("CameraService: Không tìm thấy thiết bị camera cho vị trí \(targetPosition == .front ? "Trước" : "Sau")", category: .capture)
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }

            let restart = self.captureSession.isRunning
            if restart { self.captureSession.stopRunning() }
            self.captureSession.beginConfiguration()
            if let currentInput = self.videoDeviceInput {
                self.captureSession.removeInput(currentInput)
            }
            var didSwitch = false
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                let factors = newCamera.virtualDeviceSwitchOverVideoZoomFactors
                let wideBase = (newCamera.deviceType == .builtInTripleCamera ||
                                newCamera.deviceType == .builtInDualWideCamera) ?
                    CGFloat(factors.first?.doubleValue ?? 1) : 1
                let newMinZoom = newCamera.minAvailableVideoZoomFactor
                let newMaxZoom = max(newMinZoom, min(newCamera.maxAvailableVideoZoomFactor, wideBase * 5))
                try newCamera.lockForConfiguration()
                newCamera.videoZoomFactor = min(newMaxZoom, max(newMinZoom, wideBase))
                newCamera.unlockForConfiguration()
                if self.captureSession.canAddInput(newInput) {
                    self.captureSession.addInput(newInput)
                    self.videoDeviceInput = newInput
                    self.activeCamera = newCamera
                    self.currentCameraPosition = targetPosition
                    didSwitch = true
                    self.minZoom = newMinZoom
                    self.maxZoom = newMaxZoom
                    self.displayMultiplier = wideBase
                    self.hasUltraWideLens = wideBase > 1
                    self.availableDisplayZoomOptions = (wideBase > 1 ? [0.5, 1, 2, 3, 5] : [1, 2, 3, 5])
                        .filter { $0 * wideBase <= self.maxZoom }
                    self.defaultDisplayZoom = 1.0

                    self.zoomObservation?.invalidate()
                    self.zoomObservation = newCamera.observe(\.videoZoomFactor, options: [.new]) { [weak self] _, change in
                        guard let newValue = change.newValue else { return }
                        DispatchQueue.main.async {
                            self?.onLiveZoomFactorChanged?(newValue)
                        }
                    }

                    if let connection = self.videoDataOutput.connection(with: .video) {
                        self.configureTrackingConnection(connection)
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = (targetPosition == .front)
                        }
                    }
                    if let connection = self.photoOutput.connection(with: .video) {
                        self.configurePhotoConnection(connection)
                    }
                    if self.photoOutput.isAppleProRAWSupported {
                        // Pure RAW: Mac dinh tat isAppleProRAWEnabled de sensor xuat Pure Bayer RAW thuan tuy
                        self.photoOutput.isAppleProRAWEnabled = false
                    }
                    self.updateMaxPhotoDimensions(for: newCamera)
                    let initialZoom = newCamera.videoZoomFactor
                    self.currentZoom = initialZoom
                    DispatchQueue.main.async {
                        self.delegate?.cameraService(self, didChangeZoomFactor: initialZoom)
                    }
                    CameraLogger.info("CameraService: Đã chuyển sang camera \(targetPosition == .front ? "Trước" : "Sau")", category: .capture)
                } else if let currentInput = self.videoDeviceInput {
                    self.captureSession.addInput(currentInput)
                }
            } catch {
                CameraLogger.error("Không thể đổi camera sang \(targetPosition == .front ? "Trước" : "Sau")", error: error, category: .capture)
                if let currentInput = self.videoDeviceInput {
                    self.captureSession.addInput(currentInput)
                }
            }
            self.captureSession.commitConfiguration()
            if didSwitch {
                self.configureAudioSessionForStereoCapture()
            }
            if didSwitch && self.currentCaptureMode.isVideo {
                self.configureVideoFormatInternal(option: self.selectedVideoFormatOption)
            }
            if restart { self.captureSession.startRunning() }
            self.publishSessionRunning(self.captureSession.isRunning && !self.captureSession.isInterrupted)
            let success = didSwitch && (!restart || self.captureSession.isRunning)
            if let completion { DispatchQueue.main.async { completion(success) } }
        }
    }

    // MARK: - Zoom Control
    public func setZoomFactor(_ factor: CGFloat, completion: (@MainActor (CGFloat?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            func rejected() { DispatchQueue.main.async { completion?(nil) } }
            guard let self = self, !self.isPhotoCaptureInFlight, let camera = self.activeCamera else {
                rejected(); return
            }
            guard factor.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua zoom không hữu hạn", category: .capture)
                rejected(); return
            }
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.videoZoomFactor = clampedZoom
                let actualZoom = camera.videoZoomFactor
                self.currentZoom = actualZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: actualZoom)
                    completion?(actualZoom)
                }
            } catch {
                CameraLogger.error("CameraService: Error setting zoom", error: error, category: .capture)
                rejected()
            }
        }
    }

    public func smoothZoomFactor(to factor: CGFloat, rate: Float = 2.2) {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isPhotoCaptureInFlight, let camera = self.activeCamera else { return }
            guard factor.isFinite, rate.isFinite, rate > 0 else {
                CameraLogger.warning("CameraService: Bỏ qua zoom/rate không hợp lệ", category: .capture)
                return
            }
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.ramp(toVideoZoomFactor: clampedZoom, withRate: rate)
                // A ramp command is not a measurement. KVO supplies subsequent
                // actual factors; never project the target at the future zoom.
                let actualZoom = camera.videoZoomFactor
                self.currentZoom = actualZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: actualZoom)
                }
            } catch {
                CameraLogger.error("CameraService: Error smooth zoom", error: error, category: .capture)
            }
        }
    }

    // MARK: - Exposure Bias
    public func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard bias.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua EV không hữu hạn", category: .capture)
                return
            }
            let clamped = max(camera.minExposureTargetBias, min(bias, camera.maxExposureTargetBias))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setExposureTargetBias(clamped, completionHandler: nil)
            } catch {
                CameraLogger.error("CameraService: Error setting exposure bias", error: error, category: .capture)
            }
        }
    }

    public var onSubjectAreaDidChange: (() -> Void)?

    // MARK: - Smart Focus & Exposure (Apple Camera App Style)

    /// Chuyển đổi tọa độ chuẩn hóa UI (Top-Left 0,0) sang tọa độ AVCaptureDevice sensor (Portrait 0,0)
    public static func convertUIPointToDevicePoint(_ uiPoint: CGPoint) -> CGPoint {
        // Trên iOS Portrait: AVCaptureDevice point x = UI y, point y = 1.0 - UI x
        let safeX = uiPoint.x.isFinite ? uiPoint.x : 0.5
        let safeY = uiPoint.y.isFinite ? uiPoint.y : 0.5
        let devX = max(0.01, min(0.99, safeY))
        let devY = max(0.01, min(0.99, 1.0 - safeX))
        return CGPoint(x: devX, y: devY)
    }

    // MARK: - Manual Lens Focus

    public func setManualFocus(lensPosition: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard lensPosition.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua lens position không hữu hạn", category: .capture)
                return
            }
            guard camera.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.setFocusModeLocked(lensPosition: max(0, min(1, lensPosition)), completionHandler: nil)
            } catch {
                CameraLogger.error("CameraService: Lỗi khóa vị trí lens", error: error, category: .capture)
            }
        }
    }

    public func restoreContinuousAutoFocus() {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                } else if camera.isFocusModeSupported(.autoFocus) {
                    camera.focusMode = .autoFocus
                }
            } catch {
                CameraLogger.error("CameraService: Lỗi khôi phục continuous autofocus", error: error, category: .capture)
            }
        }
    }

    /// Thiết lập lấy nét & đo sáng thông minh tự động (Smart Continuous AF/AE)
    public func setSmartFocusAndExposure(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                let clampedPoint = CGPoint(
                    x: max(0.01, min(0.99, devicePoint.x)),
                    y: max(0.01, min(0.99, devicePoint.y))
                )
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = clampedPoint
                    if camera.isFocusModeSupported(.continuousAutoFocus) {
                        camera.focusMode = .continuousAutoFocus
                    } else if camera.isFocusModeSupported(.autoFocus) {
                        camera.focusMode = .autoFocus
                    }
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = clampedPoint
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                    } else if camera.isExposureModeSupported(.autoExpose) {
                        camera.exposureMode = .autoExpose
                    }
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("CameraService: Error configuring smart focus & exposure", error: error, category: .capture)
            }
        }
    }

    // MARK: - Focus & Exposure Tap (Người dùng chạm màn hình lấy nét thủ công)
    public func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                let clampedPoint = CGPoint(
                    x: max(0.01, min(0.99, devicePoint.x)),
                    y: max(0.01, min(0.99, devicePoint.y))
                )
                if camera.isFocusPointOfInterestSupported && camera.isFocusModeSupported(.autoFocus) {
                    camera.focusPointOfInterest = clampedPoint
                    camera.focusMode = .autoFocus
                }
                if camera.isExposurePointOfInterestSupported && camera.isExposureModeSupported(.autoExpose) {
                    camera.exposurePointOfInterest = clampedPoint
                    camera.exposureMode = .autoExpose
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("CameraService: Error setting focus and exposure", error: error, category: .capture)
            }
        }
    }

    public func lockFocusAndExposure(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                let clampedPoint = CGPoint(
                    x: max(0.01, min(0.99, devicePoint.x)),
                    y: max(0.01, min(0.99, devicePoint.y))
                )
                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = clampedPoint
                }
                if camera.isFocusModeSupported(.locked) {
                    camera.focusMode = .locked
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = clampedPoint
                }
                if camera.isExposureModeSupported(.locked) {
                    camera.exposureMode = .locked
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("CameraService: Error locking AE/AF", error: error, category: .capture)
            }
        }
    }

    public func unlockFocusAndExposure() {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            } catch {
                CameraLogger.error("CameraService: Error unlocking AE/AF", error: error, category: .capture)
            }
        }
    }

    // MARK: - Video Recording
    public func startRecordingVideo(codec: VideoCodec? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let codec { self.selectedVideoCodec = codec }
            self.wantsRecording = true
            switch self.recordingState {
            case .idle:
                self.startRecordingInternal()
            case .starting, .recording:
                break
            case .stopping:
                // A stop requested before didStart can still be withdrawn.
                if !self.recordingStopCommandIssued { self.publishRecordingState(.starting) }
            }
        }
    }

    public func setVideoCodec(_ codec: VideoCodec) {
        sessionQueue.async { [weak self] in self?.selectedVideoCodec = codec }
    }

    public func setFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        sessionQueue.async { [weak self] in self?.flashMode = mode }
    }

    public func stopRecordingVideo() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingInternal()
        }
    }

    // All recording intent and hardware transitions run on sessionQueue.
    private func startRecordingInternal() {
        guard wantsRecording, recordingState == .idle else { return }
        guard desiredCaptureMode.isVideo, currentCaptureMode.isVideo,
              appliedVideoFormatOption == selectedVideoFormatOption,
              !isPhotoCaptureInFlight, captureSession.isRunning, !captureSession.isInterrupted,
              captureSession.outputs.contains(movieFileOutput),
              let camera = activeCamera,
              let connection = movieFileOutput.connection(with: .video), connection.isActive else {
            wantsRecording = false
            publishRecordingState(.idle, force: true)
            reportRecordingFailure(CameraServiceError.recordingUnavailable)
            return
        }

        let targetFPS = selectedVideoFormatOption.fps
        let matchingRange = camera.activeFormat.videoSupportedFrameRateRanges.first(where: {
            $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        })
        guard let validRange = matchingRange else {
            wantsRecording = false
            publishRecordingState(.idle, force: true)
            reportRecordingFailure(CameraServiceError.recordingUnavailable)
            return
        }
        do {
            try camera.lockForConfiguration()
            let frameDuration = validRange.minFrameDuration
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration
            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = true
            }
            if camera.isLowLightBoostSupported {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            if camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
            }
            camera.unlockForConfiguration()
        } catch {
            wantsRecording = false
            publishRecordingState(.idle, force: true)
            reportRecordingFailure(error)
            return
        }

        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoStabilizationSupported {
            if camera.activeFormat.isVideoStabilizationModeSupported(.cinematicExtended) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            } else if camera.activeFormat.isVideoStabilizationModeSupported(.cinematic) {
                connection.preferredVideoStabilizationMode = .cinematic
            } else {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
        movieFileOutput.movieFragmentInterval = .invalid
        let availableCodecs = movieFileOutput.availableVideoCodecTypes
        let targetCodec: AVVideoCodecType = selectedVideoCodec == .hevc && availableCodecs.contains(.hevc) ? .hevc : .h264
        if availableCodecs.contains(targetCodec) {
            movieFileOutput.setOutputSettings([AVVideoCodecKey: targetCodec], for: connection)
        }

        videoDataOutput.connection(with: .video)?.isEnabled = false
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignAI_Video_\(UUID().uuidString).mov")
        recordingURL = outputURL
        recordingInterruptionError = nil
        recordingStopCommandIssued = false
        publishRecordingState(.starting)
        movieFileOutput.startRecording(to: outputURL, recordingDelegate: self)
    }

    private func stopRecordingInternal() {
        wantsRecording = false
        switch recordingState {
        case .idle:
            break
        case .starting:
            publishRecordingState(.stopping)
            if movieFileOutput.isRecording {
                recordingStopCommandIssued = true
                movieFileOutput.stopRecording()
            }
        case .recording:
            publishRecordingState(.stopping)
            if movieFileOutput.isRecording {
                recordingStopCommandIssued = true
                movieFileOutput.stopRecording()
            }
        case .stopping:
            break
        }
    }

    // MARK: - Video Format Dynamic Hardware Control
    public func setVideoFormatOption(_ option: VideoFormatOption) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.selectedVideoFormatOption = option
            let formatStr: String
            if self.recordingState != .idle {
                self.pendingVideoFormatChange = true
                formatStr = "\(option.rawValue) · Sẽ áp dụng sau khi quay"
            } else if self.currentCaptureMode.isVideo {
                self.configureVideoFormatInternal(option: option)
                formatStr = self.appliedVideoFormatOption == option
                    ? self.getActiveVideoResolutionAndFPS()
                    : "Không hỗ trợ \(option.rawValue) trên camera hiện tại"
            } else {
                formatStr = "\(option.rawValue) · Sẽ áp dụng khi quay video"
            }
            DispatchQueue.main.async {
                self.onActiveVideoFormatChanged?(formatStr)
            }
        }
    }

    private func configureVideoFormatInternal(option: VideoFormatOption) {
        appliedVideoFormatOption = nil
        guard let camera = self.activeCamera else { return }

        let targetWidth = option.width   // 3840 or 1920
        let targetHeight = option.height // 2160 or 1080
        let targetFPS = option.fps       // 60.0 or 30.0

        // Find candidate formats matching resolution and supporting targetFPS
        let candidates = camera.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxDim = max(dims.width, dims.height)
            let minDim = min(dims.width, dims.height)
            let matchesRes = (minDim == targetHeight && maxDim == targetWidth) ||
                             (minDim >= targetHeight && maxDim >= targetWidth && targetWidth >= 3840)
            guard matchesRes else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= targetFPS && targetFPS <= range.maxFrameRate
            }
        }

        // Pick optimal format for sustained, jitter-free 60.0 FPS:
        // 1. Exact resolution match
        // 2. Hardware YUV 420
        let selectedFormat = candidates.sorted { f1, f2 in
            let dims1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let dims2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
            let exact1 = (min(dims1.width, dims1.height) == targetHeight && max(dims1.width, dims1.height) == targetWidth)
            let exact2 = (min(dims2.width, dims2.height) == targetHeight && max(dims2.width, dims2.height) == targetWidth)
            if exact1 != exact2 { return exact1 }

            let maxFPS1 = f1.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let maxFPS2 = f2.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            if (maxFPS1 >= targetFPS) != (maxFPS2 >= targetFPS) {
                return maxFPS1 >= targetFPS
            }

            let sub1 = CMFormatDescriptionGetMediaSubType(f1.formatDescription)
            let sub2 = CMFormatDescriptionGetMediaSubType(f2.formatDescription)
            let isYUV1 = sub1 == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub1 == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let isYUV2 = sub2 == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub2 == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if isYUV1 != isYUV2 { return isYUV1 }

            return false
        }.first

        guard let targetFormat = selectedFormat else {
            CameraLogger.warning("CameraService: Không tìm thấy format video phần cứng cho \(option.rawValue)", category: .capture)
            return
        }

        do {
            try camera.lockForConfiguration()
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .inputPriority
            camera.activeFormat = targetFormat

            // In Video mode: do NOT set photoOutput.maxPhotoDimensions to 48MP!
            // Limit photoOutput max dimensions to video dimensions to avoid stealing 4K 60fps ISP memory
            if let videoMaxPhotoDim = targetFormat.supportedMaxPhotoDimensions.first {
                self.photoOutput.maxPhotoDimensions = videoMaxPhotoDim
            }

            let matchingRange = targetFormat.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
            })
            let frameDuration = matchingRange?.minFrameDuration ?? CMTime(value: 1, timescale: CMTimeScale(round(targetFPS)))
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration

            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = true
            }

            // Disable auto HDR adjustments and low-light frame rate drops
            if camera.isLowLightBoostSupported {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            if camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
            }

            self.captureSession.commitConfiguration()
            camera.unlockForConfiguration()

            appliedVideoFormatOption = option

            CameraLogger.info("CameraService: Khóa cứng phần cứng video thành công \(option.rawValue) @ \(targetFPS) FPS", category: .capture)
        } catch {
            CameraLogger.error("CameraService: Lỗi cấu hình video format \(option.rawValue)", error: error, category: .capture)
        }
    }

    private func updateMaxPhotoDimensions(for camera: AVCaptureDevice) {
        guard let maximumPhotoDimensions = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        photoOutput.maxPhotoDimensions = maximumPhotoDimensions
    }

    // MARK: - Capture Mode & Live Photo Dynamic Control
    public func updateCaptureMode(_ mode: CameraCaptureMode, completion: ((Bool) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            if self.desiredCaptureMode != mode || completion != nil {
                self.completePendingMode(false)
            }
            self.desiredCaptureMode = mode
            if let completion { self.pendingModeCompletion = completion }
            if !mode.isVideo && self.recordingState != .idle {
                self.stopRecordingInternal()
            }
            self.applyCaptureModeIfPossible()
        }
    }

    private func applyCaptureModeIfPossible() {
        guard !isPhotoCaptureInFlight, recordingState == .idle,
              !movieFileOutput.isRecording, videoDeviceInput != nil else { return }
        let mode = desiredCaptureMode
        if currentCaptureMode == mode {
            if pendingVideoFormatChange && mode.isVideo {
                configureVideoFormatInternal(option: selectedVideoFormatOption)
                pendingVideoFormatChange = false
                let formatStr = appliedVideoFormatOption == selectedVideoFormatOption
                    ? getActiveVideoResolutionAndFPS()
                    : "Không hỗ trợ \(selectedVideoFormatOption.rawValue) trên camera hiện tại"
                DispatchQueue.main.async { [weak self] in self?.onActiveVideoFormatChanged?(formatStr) }
            }
            completePendingMode(true)
            return
        }

        captureSession.beginConfiguration()
        if mode.isVideo {
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoCaptureEnabled = false }
            if !captureSession.outputs.contains(movieFileOutput) {
                guard captureSession.canAddOutput(movieFileOutput) else {
                    if photoOutput.isLivePhotoCaptureSupported {
                        photoOutput.isLivePhotoCaptureEnabled = isLivePhotoMode
                    }
                    captureSession.commitConfiguration()
                    desiredCaptureMode = currentCaptureMode
                    completePendingMode(false)
                    return
                }
                captureSession.addOutput(movieFileOutput)
                if let connection = movieFileOutput.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .auto }
                }
            }
            captureSession.sessionPreset = .inputPriority
            captureSession.commitConfiguration()
            configureVideoFormatInternal(option: selectedVideoFormatOption)
            pendingVideoFormatChange = false
        } else {
            if captureSession.outputs.contains(movieFileOutput) {
                captureSession.removeOutput(movieFileOutput)
            }
            if photoOutput.isLivePhotoCaptureSupported {
                photoOutput.isLivePhotoCaptureEnabled = isLivePhotoMode
            }
            captureSession.sessionPreset = .photo
            if let camera = activeCamera {
                do {
                    try camera.lockForConfiguration()
                    defer { camera.unlockForConfiguration() }
                    if camera.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                        camera.activeColorSpace = .P3_D65
                    }
                } catch {
                    CameraLogger.error("CameraService: Không thể khôi phục P3 color space", error: error, category: .capture)
                }
            }
            captureSession.commitConfiguration()
            if let camera = activeCamera { updateMaxPhotoDimensions(for: camera) }
            if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = false }
            pendingVideoFormatChange = false
            appliedVideoFormatOption = nil
        }
        currentCaptureMode = mode
        let formatStr = mode.isVideo && appliedVideoFormatOption != selectedVideoFormatOption
            ? "Không hỗ trợ \(selectedVideoFormatOption.rawValue) trên camera hiện tại"
            : getActiveVideoResolutionAndFPS()
        DispatchQueue.main.async { [weak self] in self?.onActiveVideoFormatChanged?(formatStr) }
        completePendingMode(true)
        CameraLogger.info("Đã chuyển chế độ: \(mode.rawValue) (\(formatStr))", category: .capture)
    }

    // MARK: - Video Hardware Resolution & Frame Rate Query (Read-Only từ Cài đặt Camera iOS)
    public func getActiveVideoResolutionAndFPS() -> String {
        guard let camera = self.activeCamera else { return "1080P 30FPS" }
        let format = camera.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Int(dims.width)
        let height = Int(dims.height)

        var fps = 30
        let minDuration = camera.activeVideoMinFrameDuration
        if minDuration.value > 0 {
            fps = Int(round(Double(minDuration.timescale) / Double(minDuration.value)))
        }

        let maxDim = max(width, height)
        let minDim = min(width, height)

        if maxDim >= 7680 || minDim >= 4320 {
            return "8K \(fps)FPS"
        } else if maxDim >= 5760 || minDim >= 3240 {
            return "6K \(fps)FPS"
        } else if maxDim >= 3840 || minDim >= 2160 {
            return "4K \(fps)FPS"
        } else if maxDim >= 1920 || minDim >= 1080 {
            return "1080P \(fps)FPS"
        } else if maxDim >= 1280 || minDim >= 720 {
            return "720P \(fps)FPS"
        } else {
            return "\(minDim)P \(fps)FPS"
        }
    }

    public func setLivePhotoCaptureEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isLivePhotoMode = enabled
            guard !self.isPhotoCaptureInFlight, !self.currentCaptureMode.isVideo else { return }
            if self.photoOutput.isLivePhotoCaptureSupported {
                if self.photoOutput.isLivePhotoCaptureEnabled != enabled {
                    self.captureSession.beginConfiguration()
                    self.photoOutput.isLivePhotoCaptureEnabled = enabled
                    self.captureSession.commitConfiguration()
                }
                CameraLogger.info("Chế độ Live Photo: \(enabled ? "BẬT" : "TẮT") (isLivePhotoCaptureEnabled = \(self.photoOutput.isLivePhotoCaptureEnabled))", category: .capture)
            } else {
                CameraLogger.warning("Thiết bị không hỗ trợ Live Photo ở cấu hình này", category: .capture)
            }
        }
    }

    private func configurePhotoConnection(_ connection: AVCaptureConnection) {
        // The app's viewfinder is portrait. Let AVFoundation write EXIF once;
        // processed preview decoding applies that EXIF once, DNG stays untouched.
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = currentCameraPosition == .front
        }
    }

    // MARK: - Native photo capture
    public func capturePhoto(isDNG: Bool = false, isHEIF: Bool = false,
                             highResolution: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            func reject(_ error: Error) {
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didFailCaptureWithError: error)
                }
            }
            guard !self.isPhotoCaptureInFlight else {
                reject(CameraServiceError.captureAlreadyInProgress); return
            }
            guard self.captureSession.isRunning, !self.captureSession.isInterrupted,
                  !self.currentCaptureMode.isVideo, let camera = self.activeCamera,
                  let connection = self.photoOutput.connection(with: .video),
                  connection.isActive else {
                reject(CameraServiceError.cameraNotReady); return
            }
            self.configurePhotoConnection(connection)
            let codec: AVVideoCodecType = isHEIF && self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? .hevc : .jpeg
            let settings: AVCapturePhotoSettings
            let actualFormat: PhotoSaveFormat
            if isDNG {
                let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
                let bayer = formats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
                let proRAW = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                // Uu tien Pure Bayer RAW (100% du lieu tho goc tu cam bien, khong computational tone mapping, khong HDR GainTableMap)
                guard let raw = (bayer ?? proRAW) ?? formats.first else {
                    reject(CameraServiceError.rawUnavailable); return
                }
                // Apple supplies a processed companion solely for display. The
                // RAW callback's original fileDataRepresentation is what we save.
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw,
                    rawFileType: .dng,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
                    processedFileType: .jpg)
                // Tuyet doi khong goi setPhotoQualityPrioritization tren settings khi chup RAW
                // vi AVFoundation se nem NSInvalidArgumentException: Unsupported when capturing RAW
                actualFormat = .dng
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
                actualFormat = codec == .hevc ? .heif : .jpeg
            }

            let supported = camera.activeFormat.supportedMaxPhotoDimensions.sorted {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            }
            let isProRAW = isDNG && AVCapturePhotoOutput.isAppleProRAWPixelFormat(settings.rawPhotoPixelFormatType)
            let maxOutputDim = self.photoOutput.maxPhotoDimensions
            let chosenDim: CMVideoDimensions
            if let last = supported.last, let first = supported.first {
                chosenDim = (isProRAW && highResolution) ? last : first
            } else if maxOutputDim.width > 0 && maxOutputDim.height > 0 {
                chosenDim = maxOutputDim
            } else {
                chosenDim = CMVideoDimensions(width: 4032, height: 3024)
            }
            let dimensions: CMVideoDimensions
            if maxOutputDim.width > 0 && maxOutputDim.height > 0 && (chosenDim.width > maxOutputDim.width || chosenDim.height > maxOutputDim.height) {
                dimensions = maxOutputDim
            } else {
                dimensions = chosenDim
            }
            settings.maxPhotoDimensions = dimensions

            if isDNG, let thumbnailCodec = settings.availableRawEmbeddedThumbnailPhotoCodecTypes.first(where: { $0 == .jpeg }) {
                // Kích thước thumbnail nhúng trong tệp RAW DNG chuẩn sắc nét (512x384)
                let isLandscape = dimensions.width >= dimensions.height
                let thumbW = isLandscape ? 512 : 384
                let thumbH = isLandscape ? 384 : 512
                settings.rawEmbeddedThumbnailPhotoFormat = [
                    AVVideoCodecKey: thumbnailCodec,
                    AVVideoWidthKey: thumbW,
                    AVVideoHeightKey: thumbH
                ]
            }
            if camera.isFlashAvailable && self.photoOutput.supportedFlashModes.contains(self.flashMode) {
                settings.flashMode = self.flashMode
            }
            // Maximum resolution and RAW deliberately use a still capture.
            if !isDNG && !highResolution && self.isLivePhotoMode &&
               self.photoOutput.isLivePhotoCaptureSupported && self.photoOutput.isLivePhotoCaptureEnabled {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("livephoto_\(UUID().uuidString).mov")
            }
            self.pendingPhoto = PhotoRequest(id: settings.uniqueID, format: actualFormat,
                                            highResolution: highResolution)
            self.isPhotoCaptureInFlight = true
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            let requestID = settings.uniqueID
            self.sessionQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, var request = self.pendingPhoto,
                      request.id == requestID, !request.failureReported else { return }
                request.failureReported = true
                request.fileData = nil; request.processedData = nil; request.preview = nil
                self.pendingPhoto = request
                // Keep the hardware busy flag until didFinishCaptureFor. A UI
                // timeout does not mean AVFoundation has finished the request.
                reject(CameraServiceError.captureTimedOut)
            }
        }
    }

    // MARK: - Audio Session Configuration for Stereo Multi-Mic Capture
    public func configureAudioSessionForStereoCapture() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])

            if let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try audioSession.setPreferredInput(builtInMic)

                if let dataSources = builtInMic.dataSources {
                    let targetOrientation: AVAudioSession.Orientation = (self.currentCameraPosition == .front) ? .front : .back
                    let stereoDataSource = dataSources.first(where: {
                        $0.orientation == targetOrientation && ($0.supportedPolarPatterns?.contains(.stereo) == true)
                    }) ?? dataSources.first(where: {
                        $0.supportedPolarPatterns?.contains(.stereo) == true
                    })

                    if let stereoDataSource = stereoDataSource {
                        try stereoDataSource.setPreferredPolarPattern(.stereo)
                        try builtInMic.setPreferredDataSource(stereoDataSource)
                    }
                }
            }

            let maxChannels = audioSession.maximumInputNumberOfChannels
            if maxChannels >= 2 {
                try audioSession.setPreferredInputNumberOfChannels(2)
            }

            if #available(iOS 14.0, *) {
                try audioSession.setPreferredInputOrientation(.portrait)
            }

            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            CameraLogger.info("CameraService: AudioSession configured for stereo capture with \(audioSession.inputNumberOfChannels) channels", category: .capture)
        } catch {
            CameraLogger.error("CameraService: Failed to configure stereo audio session", error: error, category: .capture)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == self.audioDataOutput {
            handleAudioSampleBuffer(sampleBuffer, from: connection)
            return
        }

        // Giới hạn tần số dispatch stats lên UI tối đa 5Hz (0.2s) để tránh lag main thread
        let now = CACurrentMediaTime()
        if now - lastStatsUpdateTime >= 0.20 {
            lastStatsUpdateTime = now
            sessionQueue.async { [weak self] in
                guard let self, let camera = self.activeCamera else { return }
                let iso = camera.iso
                let duration = camera.exposureDuration
                let rawSeconds = CMTimeGetSeconds(duration)
                let seconds = rawSeconds.isFinite && rawSeconds > 0 ? rawSeconds : 0
                let shutterString: String
                if seconds > 0 {
                    if seconds >= 1.0 {
                        shutterString = String(format: "%.1f s", seconds)
                    } else {
                        let denom = Int(round(1.0 / seconds))
                        shutterString = "1/\(denom) s"
                    }
                } else {
                    shutterString = "1/125 s"
                }
                let stats = LiveCameraStats(
                    iso: iso.isFinite ? iso : 100,
                    shutterSpeedString: shutterString,
                    exposureDurationSeconds: seconds,
                    lensPosition: camera.lensPosition.isFinite ? camera.lensPosition : 0.5
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onLiveCameraStatsUpdated?(stats)
                }
            }
        }

        // Deliver sampleBuffer directly to delegate on background queue (prevents main thread stutter)
        self.delegate?.cameraService(self, didOutputSampleBuffer: sampleBuffer)
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAudioMeterUpdateTime >= 0.04 else { return }
        lastAudioMeterUpdateTime = now

        var leftPower: Float = -60.0
        var rightPower: Float = -60.0

        let channels = connection.audioChannels
        if !channels.isEmpty {
            leftPower = channels[0].averagePowerLevel
            if channels.count > 1 {
                rightPower = channels[1].averagePowerLevel
            } else {
                rightPower = leftPower
            }
        } else {
            let levels = computePcmLevels(from: sampleBuffer)
            leftPower = levels.0
            rightPower = levels.1
        }

        let minDb: Float = -60.0
        let leftNorm = max(0.0, min(1.0, (leftPower - minDb) / (-minDb)))
        let rightNorm = max(0.0, min(1.0, (rightPower - minDb) / (-minDb)))

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevelsUpdated?(leftNorm, rightNorm)
        }
    }

    private func computePcmLevels(from sampleBuffer: CMSampleBuffer) -> (Float, Float) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return (-60, -60) }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer = dataPointer, totalLength > 0 else {
            return (-60, -60)
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return (-60, -60)
        }
        let channelCount = Int(asbd.mChannelsPerFrame)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: totalLength / 4)
            let sampleCount = totalLength / (4 * max(1, channelCount))
            guard sampleCount > 0 else { return (-60, -60) }
            var sumLeft: Float = 0
            var sumRight: Float = 0
            for i in 0..<sampleCount {
                let leftSample = floatPtr[i * channelCount]
                sumLeft += leftSample * leftSample
                if channelCount > 1 {
                    let rightSample = floatPtr[i * channelCount + 1]
                    sumRight += rightSample * rightSample
                }
            }
            let rmsLeft = sqrt(sumLeft / Float(sampleCount))
            let rmsRight = channelCount > 1 ? sqrt(sumRight / Float(sampleCount)) : rmsLeft
            let dbLeft = rmsLeft > 0.0001 ? 20 * log10(rmsLeft) : -60.0
            let dbRight = rmsRight > 0.0001 ? 20 * log10(rmsRight) : -60.0
            return (max(-60, dbLeft), max(-60, dbRight))
        } else if asbd.mBitsPerChannel == 16 {
            let int16Ptr = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: totalLength / 2)
            let sampleCount = totalLength / (2 * max(1, channelCount))
            guard sampleCount > 0 else { return (-60, -60) }
            var sumLeft: Float = 0
            var sumRight: Float = 0
            for i in 0..<sampleCount {
                let leftSample = Float(int16Ptr[i * channelCount]) / 32768.0
                sumLeft += leftSample * leftSample
                if channelCount > 1 {
                    let rightSample = Float(int16Ptr[i * channelCount + 1]) / 32768.0
                    sumRight += rightSample * rightSample
                }
            }
            let rmsLeft = sqrt(sumLeft / Float(sampleCount))
            let rmsRight = channelCount > 1 ? sqrt(sumRight / Float(sampleCount)) : rmsLeft
            let dbLeft = rmsLeft > 0.0001 ? 20 * log10(rmsLeft) : -60.0
            let dbRight = rmsRight > 0.0001 ? 20 * log10(rmsRight) : -60.0
            return (max(-60, dbLeft), max(-60, dbRight))
        }
        return (-60, -60)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput,
                            willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        publishPhotoPhase(.exposing, requestID: resolvedSettings.uniqueID)
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        publishPhotoPhase(.processing, requestID: resolvedSettings.uniqueID)
    }

    private func publishPhotoPhase(_ phase: PhotoCapturePhase, requestID: Int64) {
        sessionQueue.async { [weak self] in
            guard let self, let request = self.pendingPhoto,
                  request.id == requestID, !request.failureReported else { return }
            DispatchQueue.main.async {
                self.delegate?.cameraService(self, didChangePhotoPhase: phase)
            }
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, var request = self.pendingPhoto,
                  request.id == photo.resolvedSettings.uniqueID, !request.failureReported else { return }
            if let error { request.error = error }
            else if let data = photo.fileDataRepresentation() {
                if photo.isRawPhoto {
                    // No CIRAWFilter, tone map, crop, orientation rewrite or re-encode.
                    request.fileData = data
                    (request.iso, request.shutter) = Self.parseExif(photo.metadata)
                    if request.preview == nil, let cg = photo.previewCGImageRepresentation() {
                        request.preview = cg
                    }
                } else {
                    if request.format == .dng { request.processedData = data }
                    if request.format != .dng {
                        request.fileData = data
                        (request.iso, request.shutter) = Self.parseExif(photo.metadata)
                    }
                }
            } else { request.error = CameraServiceError.photoProcessingFailed }
            self.pendingPhoto = request
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                            duration: CMTime, photoDisplayTime: CMTime,
                            resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, var request = self.pendingPhoto,
                  request.id == resolvedSettings.uniqueID else { return }
            if error == nil { request.movieURL = outputFileURL }
            else { CameraLogger.warning("Live Photo movie unavailable; keeping the still", category: .capture) }
            self.pendingPhoto = request
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput,
                            didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                            error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, let request = self.pendingPhoto,
                  request.id == resolvedSettings.uniqueID else { return }
            self.pendingPhoto = nil
            self.isPhotoCaptureInFlight = false
            self.setLivePhotoCaptureEnabled(self.isLivePhotoMode)
            self.applyCaptureModeIfPossible()
            guard !request.failureReported else { return }
            if let failure = error ?? request.error {
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didFailCaptureWithError: failure)
                }
                return
            }
            self.photoProcessingQueue.async { [weak self] in
                guard let self else { return }
                var previewImage = request.preview
                if previewImage == nil, let proc = request.processedData {
                    previewImage = autoreleasepool {
                        SuperResolutionRAWEngine.decodeProcessedPhoto(proc, context: self.sharedPhotoContext)
                    }
                }
                if previewImage == nil, let fileData = request.fileData {
                    if request.format != .dng {
                        previewImage = autoreleasepool {
                            SuperResolutionRAWEngine.decodeProcessedPhoto(fileData, context: self.sharedPhotoContext)
                        }
                    }
                    if previewImage == nil, let source = CGImageSourceCreateWithData(fileData as CFData, nil) {
                        let thumbOptions = [
                            kCGImageSourceCreateThumbnailWithTransform as String: true,
                            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                            kCGImageSourceThumbnailMaxPixelSize as String: 2048,
                            kCGImageSourceShouldCacheImmediately as String: false
                        ] as CFDictionary
                        previewImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
                    }
                    if previewImage == nil {
                        previewImage = autoreleasepool {
                            SuperResolutionRAWEngine.decodeProcessedPhoto(fileData, context: self.sharedPhotoContext)
                        }
                    }
                }
                guard let image = previewImage, let data = request.fileData else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.cameraService(self, didFailCaptureWithError: CameraServiceError.photoProcessingFailed)
                    }
                    return
                }
                CameraLogger.info("Native photo: \(image.width)x\(image.height), \(request.format.rawValue)", category: .capture)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cameraService(self, didCapturePhoto: image, rawData: data,
                        processedCompanionData: request.processedData,
                        livePhotoMovieURL: request.movieURL, iso: request.iso, shutterSpeed: request.shutter,
                        format: request.format, requestedHighResolution: request.highResolution)
                }
            }
        }
    }

    // MARK: - Helpers

    fileprivate static func parseExif(_ metadata: [String: Any]) -> (iso: Float, shutter: Double) {
        var isoValue: Float = 100.0
        var shutterSpeed: Double = 0.016
        if let exif = metadata["{Exif}"] as? [String: Any] {
            if let isos = exif["ISOSpeedRatings"] as? [NSNumber], let first = isos.first {
                let parsedISO = first.floatValue
                if parsedISO.isFinite && parsedISO > 0 {
                    isoValue = parsedISO
                }
            }
            if let speed = exif["ExposureTime"] as? NSNumber {
                let parsedShutter = speed.doubleValue
                if parsedShutter.isFinite && parsedShutter > 0 {
                    shutterSpeed = parsedShutter
                }
            }
        }
        return (isoValue, shutterSpeed)
    }

}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraService: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async { [weak self] in
            guard let self, self.recordingURL == outputFileURL else { return }
            if self.wantsRecording && self.desiredCaptureMode.isVideo &&
                self.captureSession.isRunning && !self.captureSession.isInterrupted &&
                !self.recordingStopCommandIssued {
                self.publishRecordingState(.recording)
            } else {
                self.publishRecordingState(.stopping)
                if self.movieFileOutput.isRecording && !self.recordingStopCommandIssued {
                    self.recordingStopCommandIssued = true
                    self.movieFileOutput.stopRecording()
                }
            }
        }
    }

    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, self.recordingURL == outputFileURL else { return }
            self.recordingURL = nil
            self.recordingStopCommandIssued = false
            self.videoDataOutput.connection(with: .video)?.isEnabled = true
            self.publishRecordingState(.idle)
            let finalError = error ?? self.recordingInterruptionError
            self.recordingInterruptionError = nil
            if let finalError {
                self.wantsRecording = false
                self.reportRecordingFailure(finalError)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cameraService(self, didFinishRecordingVideoAt: outputFileURL)
                }
            }
            self.applyCaptureModeIfPossible()
            if self.wantsRecording { self.startRecordingInternal() }
        }
    }
}
