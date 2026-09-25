import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import UIKit
import ImageIO

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    @MainActor
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double, format: PhotoSaveFormat, requestedHighResolution: Bool)
    @MainActor
    func cameraService(_ service: CameraService, didFailCaptureWithError error: Error)
    @MainActor
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL)
    @MainActor
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat)
}

public extension CameraServiceDelegate {
    @MainActor
    func cameraService(_ service: CameraService, didFailCaptureWithError error: Error) {}
    @MainActor
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {}
    @MainActor
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {}
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
        }
    }
}

public final class CameraService: NSObject {
    public static let shared = CameraService()

    public weak var delegate: CameraServiceDelegate?
    public var onLiveCameraStatsUpdated: ((LiveCameraStats) -> Void)?

    // Core AVFoundation objects
    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.alignai.camera.sessionQueue", qos: .userInteractive)
    private let videoDataQueue = DispatchQueue(label: "com.alignai.camera.videoDataQueue", qos: .userInteractive)

    private var activeCamera: AVCaptureDevice?
    private var zoomObservation: NSKeyValueObservation?
    public var onLiveZoomFactorChanged: ((CGFloat) -> Void)?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieFileOutput = AVCaptureMovieFileOutput()
    private let sharedPhotoContext = CIContext(options: [.useSoftwareRenderer: false])

    // State
    public private(set) var isSessionRunning = false
    public private(set) var currentZoom: CGFloat = 1.0
    public private(set) var minZoom: CGFloat = 1.0
    public private(set) var maxZoom: CGFloat = 10.0
    public private(set) var isRecordingVideo = false
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

    public var flashMode: AVCaptureDevice.FlashMode = .auto
    public var isLivePhotoMode = false
    public var selectedVideoFormatOption: VideoFormatOption = .hd60
    public var selectedVideoCodec: VideoCodec = .hevc
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

    private var notificationObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
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

                // Add Audio Input for Video Recording
                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    if let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                       self.captureSession.canAddInput(audioInput) {
                        self.captureSession.addInput(audioInput)
                    }
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
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
                }

                // Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    if self.photoOutput.isAppleProRAWSupported {
                        self.photoOutput.isAppleProRAWEnabled = true
                    }
                    self.updateMaxPhotoDimensions(for: camera)

                    if #available(iOS 17.0, *) {
                        if self.photoOutput.isZeroShutterLagSupported {
                            self.photoOutput.isZeroShutterLagEnabled = true
                        }
                        if self.photoOutput.isResponsiveCaptureSupported {
                            self.photoOutput.isResponsiveCaptureEnabled = true
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
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
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
                    queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    self.isSessionRunning = false
                    CameraLogger.warning("CameraService: AVCaptureSession was interrupted", category: .capture)
                }

                let interruptionEndedObserver = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.interruptionEndedNotification,
                    object: self.captureSession,
                    queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    CameraLogger.info("CameraService: AVCaptureSession interruption ended, resuming", category: .capture)
                    self.start()
                }
                self.notificationObservers = [subjectAreaObserver, interruptedObserver, interruptionEndedObserver]

                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Start / Stop Session
    public func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            self.isSessionRunning = self.captureSession.isRunning
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            self.isSessionRunning = false
        }
    }

    // MARK: - Camera Position (Switch Front / Back)
    public func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isPhotoCaptureInFlight else { return }
            let targetPosition: AVCaptureDevice.Position = (self.currentCameraPosition == .back) ? .front : .back
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: targetPosition == .front ? [.builtInWideAngleCamera] : [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                mediaType: .video,
                position: targetPosition
            )
            guard let newCamera = discovery.devices.first else {
                CameraLogger.warning("CameraService: Không tìm thấy thiết bị camera cho vị trí \(targetPosition == .front ? "Trước" : "Sau")", category: .capture)
                return
            }

            let restart = self.captureSession.isRunning
            if restart { self.captureSession.stopRunning() }
            self.captureSession.beginConfiguration()
            if let currentInput = self.videoDeviceInput {
                self.captureSession.removeInput(currentInput)
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: newCamera)
                if self.captureSession.canAddInput(newInput) {
                    self.captureSession.addInput(newInput)
                    self.videoDeviceInput = newInput
                    self.activeCamera = newCamera
                    self.currentCameraPosition = targetPosition
                    self.minZoom = newCamera.minAvailableVideoZoomFactor
                    self.maxZoom = min(newCamera.maxAvailableVideoZoomFactor, 5.0)
                    let factors = newCamera.virtualDeviceSwitchOverVideoZoomFactors
                    let wideBase = (newCamera.deviceType == .builtInTripleCamera ||
                                    newCamera.deviceType == .builtInDualWideCamera) ?
                        CGFloat(factors.first?.doubleValue ?? 1) : 1
                    self.displayMultiplier = wideBase
                    self.hasUltraWideLens = wideBase > 1
                    self.maxZoom = min(newCamera.maxAvailableVideoZoomFactor, wideBase * 5)
                    self.availableDisplayZoomOptions = (wideBase > 1 ? [0.5, 1, 2, 3, 5] : [1, 2, 3, 5])
                        .filter { $0 * wideBase <= self.maxZoom }
                    self.defaultDisplayZoom = 1.0
                    try newCamera.lockForConfiguration()
                    newCamera.videoZoomFactor = min(self.maxZoom, max(self.minZoom, wideBase))
                    newCamera.unlockForConfiguration()

                    self.zoomObservation?.invalidate()
                    self.zoomObservation = newCamera.observe(\.videoZoomFactor, options: [.new]) { [weak self] _, change in
                        guard let newValue = change.newValue else { return }
                        DispatchQueue.main.async {
                            self?.onLiveZoomFactorChanged?(newValue)
                        }
                    }

                    if let connection = self.videoDataOutput.connection(with: .video) {
                        self.configureTrackingConnection(connection)
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
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
                        self.photoOutput.isAppleProRAWEnabled = true
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
            if restart { self.captureSession.startRunning() }
        }
    }

    // MARK: - Zoom Control
    public func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isPhotoCaptureInFlight, let camera = self.activeCamera else { return }
            guard factor.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua zoom không hữu hạn", category: .capture)
                return
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
                }
            } catch {
                CameraLogger.error("CameraService: Error setting zoom", error: error, category: .capture)
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
            guard let self = self, !self.movieFileOutput.isRecording else { return }

            if let chosenCodec = codec {
                self.selectedVideoCodec = chosenCodec
            }
            if let connection = self.movieFileOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
                let availableCodecs = self.movieFileOutput.availableVideoCodecTypes
                let targetCodec: AVVideoCodecType = (self.selectedVideoCodec == .hevc && availableCodecs.contains(.hevc)) ? .hevc : .h264
                if availableCodecs.contains(targetCodec) {
                    self.movieFileOutput.setOutputSettings([AVVideoCodecKey: targetCodec], for: connection)
                }
            }

            let tempDir = FileManager.default.temporaryDirectory
            let outputURL = tempDir.appendingPathComponent("AlignAI_Video_\(UUID().uuidString).mov")

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }

            self.movieFileOutput.startRecording(to: outputURL, recordingDelegate: self)
            DispatchQueue.main.async { self.isRecordingVideo = true }
        }
    }

    public func stopRecordingVideo() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.movieFileOutput.isRecording else { return }
            self.movieFileOutput.stopRecording()
            DispatchQueue.main.async { self.isRecordingVideo = false }
        }
    }

    // MARK: - Video Format Dynamic Hardware Control
    public func setVideoFormatOption(_ option: VideoFormatOption) {
        self.selectedVideoFormatOption = option
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let formatStr: String
            if self.currentCaptureMode.isVideo {
                self.configureVideoFormatInternal(option: option)
                formatStr = self.getActiveVideoResolutionAndFPS()
            } else {
                formatStr = "\(option.rawValue) · Sẽ áp dụng khi quay video"
            }
            DispatchQueue.main.async {
                self.onActiveVideoFormatChanged?(formatStr)
            }
        }
    }

    private func configureVideoFormatInternal(option: VideoFormatOption) {
        guard let camera = self.activeCamera else { return }

        var bestFormat: AVCaptureDevice.Format?
        for format in camera.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxDim = max(dims.width, dims.height)
            let minDim = min(dims.width, dims.height)

            let matchesResolution: Bool
            if option.width == 1920 {
                matchesResolution = (minDim == 1080 && maxDim == 1920)
            } else {
                matchesResolution = (minDim >= 2160 && maxDim >= 3840)
            }

            if matchesResolution {
                for range in format.videoSupportedFrameRateRanges {
                    if range.minFrameRate <= option.fps && option.fps <= range.maxFrameRate {
                        bestFormat = format
                        break
                    }
                }
                if bestFormat != nil { break }
            }
        }

        // Fallback to highest available if exact match not found
        if bestFormat == nil {
            for format in camera.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let minDim = min(dims.width, dims.height)
                if (option.width == 1920 && minDim >= 1080) || (option.width == 3840 && minDim >= 2160) {
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate >= option.fps {
                            bestFormat = format
                            break
                        }
                    }
                    if bestFormat != nil { break }
                }
            }
        }

        guard let selectedFormat = bestFormat else {
            CameraLogger.warning("CameraService: Không tìm thấy format video phần cứng cho \(option.rawValue)", category: .capture)
            return
        }

        do {
            try camera.lockForConfiguration()
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .inputPriority
            camera.activeFormat = selectedFormat
            self.updateMaxPhotoDimensions(for: camera)

            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(option.fps))
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration

            self.captureSession.commitConfiguration()
            camera.unlockForConfiguration()

            CameraLogger.info("CameraService: Cấu hình phần cứng thành công \(option.rawValue)", category: .capture)
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
    public func updateCaptureMode(_ mode: CameraCaptureMode) {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.isPhotoCaptureInFlight else { return }
            self.currentCaptureMode = mode
            self.captureSession.beginConfiguration()
            if mode.isVideo {
                if self.photoOutput.isLivePhotoCaptureEnabled {
                    self.photoOutput.isLivePhotoCaptureEnabled = false
                }
                if !self.captureSession.outputs.contains(self.movieFileOutput) && self.captureSession.canAddOutput(self.movieFileOutput) {
                    self.captureSession.addOutput(self.movieFileOutput)
                    if let connection = self.movieFileOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
                    }
                }
                self.captureSession.commitConfiguration()

                // Configure hardware video format & frame rate
                self.configureVideoFormatInternal(option: self.selectedVideoFormatOption)
            } else {
                if self.captureSession.outputs.contains(self.movieFileOutput) {
                    self.captureSession.removeOutput(self.movieFileOutput)
                }
                if self.photoOutput.isLivePhotoCaptureSupported {
                    self.photoOutput.isLivePhotoCaptureEnabled = true
                }
                self.captureSession.sessionPreset = .photo
                if let camera = self.activeCamera {
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
                self.captureSession.commitConfiguration()
                if let camera = self.activeCamera {
                    self.updateMaxPhotoDimensions(for: camera)
                }
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                }
            }
            let formatStr = self.getActiveVideoResolutionAndFPS()
            DispatchQueue.main.async {
                self.onActiveVideoFormatChanged?(formatStr)
            }
            CameraLogger.info("Đã chuyển chế độ: \(mode.rawValue) (\(formatStr)) | LivePhotoSupported: \(self.photoOutput.isLivePhotoCaptureSupported)", category: .capture)
        }
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
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
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
                guard let raw = (highResolution ? proRAW ?? bayer : bayer ?? proRAW) else {
                    reject(CameraServiceError.rawUnavailable); return
                }
                // Apple supplies a processed companion solely for display. The
                // RAW callback's original fileDataRepresentation is what we save.
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                let isProRAW = AVCapturePhotoOutput.isAppleProRAWPixelFormat(raw)
                settings.photoQualityPrioritization = isProRAW ? .quality : .speed
                actualFormat = .dng
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                settings.photoQualityPrioritization = .quality
                actualFormat = codec == .hevc ? .heif : .jpeg
            }
            let supported = camera.activeFormat.supportedMaxPhotoDimensions.sorted {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            }
            // maxPhotoDimensions is a ceiling, not a promise of 48 MP. Never
            // upscale a smaller result or build a coloured image from a RAW buffer.
            if let dimensions = highResolution ? supported.last : supported.first {
                settings.maxPhotoDimensions = dimensions
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
                request.fileData = nil; request.preview = nil
                self.pendingPhoto = request
                // Keep the hardware busy flag until didFinishCaptureFor. A UI
                // timeout does not mean AVFoundation has finished the request.
                reject(CameraServiceError.captureTimedOut)
            }
        }
    }

}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
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
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
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
                } else {
                    request.preview = autoreleasepool {
                        SuperResolutionRAWEngine.decodeProcessedPhoto(data, context: self.sharedPhotoContext)
                    }
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
            guard !request.failureReported else { return }
            if let failure = error ?? request.error {
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didFailCaptureWithError: failure)
                }
                return
            }
            guard let image = request.preview, let data = request.fileData else {
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didFailCaptureWithError: CameraServiceError.photoProcessingFailed)
                }
                return
            }
            CameraLogger.info("Native photo: \(image.width)x\(image.height), \(request.format.rawValue)", category: .capture)
            DispatchQueue.main.async {
                self.delegate?.cameraService(self, didCapturePhoto: image, rawData: data,
                    livePhotoMovieURL: request.movieURL, iso: request.iso, shutterSpeed: request.shutter,
                    format: request.format, requestedHighResolution: request.highResolution)
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

    private static func fixOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraService: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        guard error == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraService(self, didFinishRecordingVideoAt: outputFileURL)
        }
    }
}
