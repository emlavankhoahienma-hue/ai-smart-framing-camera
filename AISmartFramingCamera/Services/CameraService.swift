import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import UIKit
import ImageIO

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, rawData: Data?, livePhotoMovieURL: URL?, iso: Float, shutterSpeed: Double)
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL)
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat)
}

public extension CameraServiceDelegate {
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {}
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat) {}
}

public struct LiveCameraStats {
    public var iso: Float
    public var shutterSpeedString: String
    public var exposureDurationSeconds: Double
    
    public init(iso: Float, shutterSpeedString: String, exposureDurationSeconds: Double) {
        self.iso = iso
        self.shutterSpeedString = shutterSpeedString
        self.exposureDurationSeconds = exposureDurationSeconds
    }
}

public final class CameraService: NSObject {
    public static let shared = CameraService()
    
    public weak var delegate: CameraServiceDelegate?
    public var onLiveCameraStatsUpdated: ((LiveCameraStats) -> Void)?
    
    // Core AVFoundation objects
    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.alignai.camera.sessionQueue", qos: .userInteractive)
    
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
    
    public var flashMode: AVCaptureDevice.FlashMode = .auto
    public var isLivePhotoMode = false
    
    // Callback thông báo độ phân giải và FPS video phần cứng
    public var onActiveVideoFormatChanged: ((String) -> Void)?
    
    // Live Photo capture coordination state
    private var isCapturingLivePhotoRequest = false
    private var currentPhotoCaptured: (cgImage: CGImage, rawData: Data?, iso: Float, shutter: Double)?
    private var currentLivePhotoURL: URL?
    
    private override init() {
        super.init()
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
            
            do {
                try camera.lockForConfiguration()
                if camera.activeFormat.isVideoHDRSupported {
                    camera.automaticallyAdjustsVideoHDREnabled = true
                }
                if camera.isLowLightBoostSupported {
                    camera.automaticallyEnablesLowLightBoostWhenAvailable = false
                }
                camera.unlockForConfiguration()
            } catch {
                print("Không thể bật HDR/LowLightBoost: \(error)")
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
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                }
                
                // Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
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
                
                // Subject Area Did Change Notification Observer (Apple Camera App style)
                NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil)
                NotificationCenter.default.addObserver(
                    forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                    object: camera,
                    queue: .main
                ) { [weak self] _ in
                    self?.onSubjectAreaDidChange?()
                }
                
                // Session Interruption Observers (Tự động phục hồi camera preview khi hết gián đoạn)
                NotificationCenter.default.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: self.captureSession)
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.wasInterruptedNotification,
                    object: self.captureSession,
                    queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    self.isSessionRunning = false
                    print("CameraService: AVCaptureSession was interrupted")
                }
                
                NotificationCenter.default.removeObserver(self, name: AVCaptureSession.interruptionEndedNotification, object: self.captureSession)
                NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.interruptionEndedNotification,
                    object: self.captureSession,
                    queue: .main
                ) { [weak self] _ in
                    guard let self = self else { return }
                    print("CameraService: AVCaptureSession interruption ended, resuming...")
                    self.start()
                }
                
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
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = clampedZoom
                camera.unlockForConfiguration()
                self.currentZoom = clampedZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: clampedZoom)
                }
            } catch {
                print("CameraService: Error setting zoom \(error)")
            }
        }
    }
    
    public func smoothZoomFactor(to factor: CGFloat, rate: Float = 2.2) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            let clampedZoom = max(self.minZoom, min(factor, self.maxZoom))
            do {
                try camera.lockForConfiguration()
                camera.ramp(toVideoZoomFactor: clampedZoom, withRate: rate)
                camera.unlockForConfiguration()
                self.currentZoom = clampedZoom
                DispatchQueue.main.async {
                    self.delegate?.cameraService(self, didChangeZoomFactor: clampedZoom)
                }
            } catch {
                print("CameraService: Error smooth zoom \(error)")
            }
        }
    }
    
    // MARK: - Exposure Bias
    public func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let camera = self.activeCamera else { return }
            let clamped = max(camera.minExposureTargetBias, min(bias, camera.maxExposureTargetBias))
            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(clamped, completionHandler: nil)
                camera.unlockForConfiguration()
            } catch {
                print("CameraService: Error setting exposure bias \(error)")
            }
        }
    }
    
    public var onSubjectAreaDidChange: (() -> Void)?
    private var subjectAreaObserver: NSObjectProtocol?
    
    // MARK: - Smart Focus & Exposure (Apple Camera App Style)
    
    /// Chuyển đổi tọa độ chuẩn hóa UI (Top-Left 0,0) sang tọa độ AVCaptureDevice sensor (Portrait 0,0)
    public static func convertUIPointToDevicePoint(_ uiPoint: CGPoint) -> CGPoint {
        // Trên iOS Portrait: AVCaptureDevice point x = UI y, point y = 1.0 - UI x
        let devX = max(0.01, min(0.99, uiPoint.y))
        let devY = max(0.01, min(0.99, 1.0 - uiPoint.x))
        return CGPoint(x: devX, y: devY)
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
                print("CameraService: Error configuring smart focus & exposure: \(error)")
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
                print("CameraService: Error setting focus and exposure \(error)")
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
                print("CameraService: Error locking AE/AF \(error)")
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
                print("CameraService: Error unlocking AE/AF \(error)")
            }
        }
    }
    
    // MARK: - Video Recording
    public func startRecordingVideo() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.movieFileOutput.isRecording else { return }
            
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
    
    // MARK: - Capture Mode & Live Photo Dynamic Control
    public func updateCaptureMode(_ mode: CameraCaptureMode) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            if mode == .video {
                if self.photoOutput.isLivePhotoCaptureEnabled {
                    self.photoOutput.isLivePhotoCaptureEnabled = false
                }
                if !self.captureSession.outputs.contains(self.movieFileOutput) && self.captureSession.canAddOutput(self.movieFileOutput) {
                    self.captureSession.addOutput(self.movieFileOutput)
                    if let connection = self.movieFileOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .cinematicExtended }
                    }
                }
            } else {
                if self.captureSession.outputs.contains(self.movieFileOutput) {
                    self.captureSession.removeOutput(self.movieFileOutput)
                }
                if self.photoOutput.isLivePhotoCaptureSupported {
                    self.photoOutput.isLivePhotoCaptureEnabled = true
                }
            }
            self.captureSession.commitConfiguration()
            let formatStr = self.getActiveVideoResolutionAndFPS()
            DispatchQueue.main.async {
                self.onActiveVideoFormatChanged?(formatStr)
            }
            CameraLogger.info("Đã chuyển chế độ: \(mode == .video ? "VIDEO" : "ẢNH") (\(formatStr)) | LivePhotoSupported: \(self.photoOutput.isLivePhotoCaptureSupported)", category: .capture)
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
    public func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentPhotoCaptured = nil
            self.currentLivePhotoURL = nil
            self.isCapturingLivePhotoRequest = false
            
            let photoSettings = AVCapturePhotoSettings()
            if self.activeCamera?.isFlashAvailable == true {
                photoSettings.flashMode = self.flashMode
            }
            photoSettings.photoQualityPrioritization = .quality
            
            if self.isLivePhotoMode && self.photoOutput.isLivePhotoCaptureSupported {
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
                CameraLogger.info("📸 Chụp ẢNH TĨNH tiêu chuẩn", category: .capture)
            }
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var currentStats: LiveCameraStats? = nil
        if let camera = self.activeCamera {
            let iso = camera.iso
            let duration = camera.exposureDuration
            let seconds = CMTimeGetSeconds(duration)
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
            currentStats = LiveCameraStats(iso: iso, shutterSpeedString: shutterString, exposureDurationSeconds: seconds)
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let stats = currentStats {
                self.onLiveCameraStatsUpdated?(stats)
            }
            self.delegate?.cameraService(self, didOutputSampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            CameraLogger.error("Lỗi chụp ảnh từ phần cứng AVFoundation", error: error, category: .capture)
            return
        }
        
        CameraLogger.info("Đã nhận buffer ảnh từ cảm biến camera", category: .capture)
        let zoomAtCapture = self.currentZoom
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
    
    private static func cropImageForZoom(_ image: UIImage, zoom: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let cropW = width / zoom
        let cropH = height / zoom
        let cropX = (width - cropW) / 2.0
        let cropY = (height - cropH) / 2.0
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let croppedCG = cg.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
    }
    
    private static func parseExif(_ metadata: [String: Any]) -> (iso: Float, shutter: Double) {
        var isoValue: Float = 100.0
        var shutterSpeed: Double = 0.016
        if let exif = metadata["{Exif}"] as? [String: Any] {
            if let isos = exif["ISOSpeedRatings"] as? [NSNumber], let first = isos.first {
                isoValue = first.floatValue
            }
            if let speed = exif["ExposureTime"] as? NSNumber {
                shutterSpeed = speed.doubleValue
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
