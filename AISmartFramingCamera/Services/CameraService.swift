import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import UIKit
import ImageIO

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    @MainActor
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double)
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

    public var errorDescription: String? {
        switch self {
        case .captureAlreadyInProgress:
            return "A photo capture is already in progress."
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

    // Virtual multi-camera mapping. UI intentionally exposes only 1x and 2x.
    public private(set) var displayMultiplier: CGFloat = 1.0
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

    // Live Photo capture coordination state
    private var isCapturingLivePhotoRequest = false
    private var currentPhotoCaptured: (cgImage: CGImage, rawData: Data?, iso: Float, shutter: Double)?
    private var currentLivePhotoURL: URL?
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

    // MARK: - Session Setup
    public func setupSession(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

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
                self.defaultDisplayZoom = 1.0
                CameraLogger.info("CameraService: Khởi tạo Multi-Camera Apple (Wide Base: \(wideBase))", category: .capture)
            } else {
                self.displayMultiplier = 1.0
                self.defaultDisplayZoom = 1.0
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
                    self.videoDataOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    if let connection = self.videoDataOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
                }

                // Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.updateMaxPhotoDimensions(for: camera)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality

                    if #available(iOS 17.0, *) {
                        if self.photoOutput.isZeroShutterLagSupported {
                            self.photoOutput.isZeroShutterLagEnabled = true
                        }
                        if self.photoOutput.isResponsiveCaptureSupported {
                            self.photoOutput.isResponsiveCaptureEnabled = true
                        }
                        if self.photoOutput.isFastCapturePrioritizationSupported {
                            self.photoOutput.isFastCapturePrioritizationEnabled = true
                        }
                        if self.photoOutput.isAutoDeferredPhotoDeliverySupported {
                            self.photoOutput.isAutoDeferredPhotoDeliveryEnabled = true
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

    // MARK: - Zoom Control
    public func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard factor.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua zoom không hữu hạn", category: .capture)
                return
            }
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.videoZoomFactor = clampedZoom
                self.currentZoom = clampedZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: clampedZoom)
                }
            } catch {
                CameraLogger.error("CameraService: Error setting zoom", error: error, category: .capture)
            }
        }
    }

    public func smoothZoomFactor(to factor: CGFloat, rate: Float = 2.2) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard factor.isFinite, rate.isFinite, rate > 0 else {
                CameraLogger.warning("CameraService: Bỏ qua zoom/rate không hợp lệ", category: .capture)
                return
            }
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                camera.ramp(toVideoZoomFactor: clampedZoom, withRate: rate)
                self.currentZoom = clampedZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: clampedZoom)
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
        CameraCoordinateMapper.uiToDevice(uiPoint)
    }

    /// Inverse of `convertUIPointToDevicePoint`, used so UIKit gestures and SwiftUI overlays
    /// share one normalized top-left coordinate system.
    public static func convertDevicePointToUIPoint(_ devicePoint: CGPoint) -> CGPoint {
        CameraCoordinateMapper.deviceToUI(devicePoint)
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
            guard devicePoint.x.isFinite, devicePoint.y.isFinite else {
                CameraLogger.warning("CameraService: Bỏ qua điểm AF/AE không hữu hạn", category: .capture)
                return
            }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
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
            } catch {
                CameraLogger.error("CameraService: Error configuring smart focus & exposure", error: error, category: .capture)
            }
        }
    }

    // MARK: - Focus & Exposure Tap (Người dùng chạm màn hình lấy nét thủ công)
    public func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard devicePoint.x.isFinite, devicePoint.y.isFinite else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
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
            } catch {
                CameraLogger.error("CameraService: Error setting focus and exposure", error: error, category: .capture)
            }
        }
    }

    public func lockFocusAndExposure(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            guard devicePoint.x.isFinite, devicePoint.y.isFinite else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
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
                defer { camera.unlockForConfiguration() }
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
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
            guard let self = self else { return }
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

    // MARK: - Capture Photo
    public func capturePhoto(isDNG: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isPhotoCaptureInFlight else {
                CameraLogger.warning("CameraService: Bỏ qua thao tác chụp lặp khi capture trước chưa hoàn tất", category: .capture)
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didFailCaptureWithError: CameraServiceError.captureAlreadyInProgress)
                }
                return
            }
            self.isPhotoCaptureInFlight = true
            self.currentPhotoCaptured = nil
            self.currentLivePhotoURL = nil
            self.isCapturingLivePhotoRequest = false

            let photoSettings: AVCapturePhotoSettings
            if isDNG, let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
                CameraLogger.info("📸 Kích hoạt chụp RAW DNG thực thụ (Format: \(rawFormat))", category: .capture)
            } else {
                photoSettings = AVCapturePhotoSettings()
            }

            if self.activeCamera?.isFlashAvailable == true {
                photoSettings.flashMode = self.flashMode
            }
            photoSettings.photoQualityPrioritization = .quality
            let maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if maxPhotoDimensions.width > 0, maxPhotoDimensions.height > 0 {
                photoSettings.maxPhotoDimensions = maxPhotoDimensions
            }

            if !isDNG && self.isLivePhotoMode && self.photoOutput.isLivePhotoCaptureSupported {
                if !self.photoOutput.isLivePhotoCaptureEnabled {
                    self.captureSession.beginConfiguration()
                    self.photoOutput.isLivePhotoCaptureEnabled = true
                    self.captureSession.commitConfiguration()
                }
                let tempDir = FileManager.default.temporaryDirectory
                let movieURL = tempDir.appendingPathComponent("livephoto_\(UUID().uuidString).mov")
                try? FileManager.default.removeItem(at: movieURL)
                photoSettings.livePhotoMovieFileURL = movieURL
                self.isCapturingLivePhotoRequest = true
                CameraLogger.info("📸 Kích hoạt chụp LIVE PHOTO (Movie URL: \(movieURL.lastPathComponent))", category: .capture)
            } else {
                if !isDNG {
                    CameraLogger.info("📸 Chụp ẢNH TĨNH tiêu chuẩn", category: .capture)
                }
            }

            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
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
            if let camera = self.activeCamera {
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
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            CameraLogger.error("Lỗi chụp ảnh từ phần cứng AVFoundation", error: error, category: .capture)
            self.currentPhotoCaptured = nil
            self.currentLivePhotoURL = nil
            self.isCapturingLivePhotoRequest = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.cameraService(self, didFailCaptureWithError: error)
            }
            return
        }

        CameraLogger.info("Đã nhận buffer ảnh từ cảm biến camera", category: .capture)
        let metadata = photo.metadata
        let (iso, shutter) = Self.parseExif(metadata)
        let rawData = photo.fileDataRepresentation()

        autoreleasepool {
            var finalCGImage: CGImage? = nil

            if let pixelBuffer = photo.pixelBuffer {
                var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                if let orientationNum = metadata[kCGImagePropertyOrientation as String] as? UInt32,
                   let cgOrientation = CGImagePropertyOrientation(rawValue: orientationNum) {
                    ciImage = ciImage.oriented(cgOrientation)
                } else {
                    ciImage = ciImage.oriented(.right)
                }

                finalCGImage = self.sharedPhotoContext.createCGImage(ciImage, from: ciImage.extent)
            }

            if finalCGImage == nil, let data = rawData, let uiImage = UIImage(data: data) {
                let uprightImage = Self.fixOrientation(uiImage)
                finalCGImage = uprightImage.cgImage
            }

            guard let cgImage = finalCGImage else {
                CameraLogger.error("Không thể tạo CGImage từ AVCapturePhoto", category: .capture)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.cameraService(self, didFailCaptureWithError: CameraServiceError.photoProcessingFailed)
                }
                return
            }

            CameraLogger.info("Đã render CGImage thành công (\(cgImage.width)x\(cgImage.height))", category: .capture)

            if self.isCapturingLivePhotoRequest {
                // Tạm lưu lại và chờ file video Live Photo hoàn tất
                self.currentPhotoCaptured = (cgImage, rawData, iso, shutter)
            } else {
                // Ảnh tĩnh thường: Dispatch ngay
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.cameraService(self, didCapturePhoto: cgImage, rawData: rawData, livePhotoMovieURL: nil, iso: iso, shutterSpeed: shutter)
                }
            }
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            CameraLogger.error("Lỗi ghi file video Live Photo: \(error.localizedDescription)", error: error, category: .capture)
            self.currentLivePhotoURL = nil
        } else {
            CameraLogger.success("✅ Đã ghi xong file video Live Photo (\(outputFileURL.lastPathComponent))", category: .capture)
            self.currentLivePhotoURL = outputFileURL
        }
    }

    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            self?.isPhotoCaptureInFlight = false
        }
        if let error = error {
            CameraLogger.error("Phiên chụp kết thúc với lỗi", error: error, category: .capture)
            currentPhotoCaptured = nil
            currentLivePhotoURL = nil
            isCapturingLivePhotoRequest = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.cameraService(self, didFailCaptureWithError: error)
            }
            return
        }
        if self.isCapturingLivePhotoRequest {
            guard let captured = self.currentPhotoCaptured else { return }
            let movieURL = self.currentLivePhotoURL
            self.currentPhotoCaptured = nil
            self.currentLivePhotoURL = nil
            self.isCapturingLivePhotoRequest = false

            CameraLogger.info("Hoàn tất phiên Live Photo -> Gửi ảnh + movie (\(movieURL?.lastPathComponent ?? "không có"))", category: .capture)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.cameraService(self, didCapturePhoto: captured.cgImage, rawData: captured.rawData, livePhotoMovieURL: movieURL, iso: captured.iso, shutterSpeed: captured.shutter)
            }
        }
    }

    // MARK: - Helpers

    private static func parseExif(_ metadata: [String: Any]) -> (iso: Float, shutter: Double) {
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
