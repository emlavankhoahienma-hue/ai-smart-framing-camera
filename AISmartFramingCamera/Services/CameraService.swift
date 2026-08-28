import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import UIKit
import ImageIO

public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double)
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL)
}

public extension CameraServiceDelegate {
    func cameraService(_ service: CameraService, didFinishRecordingVideoAt url: URL) {}
}

public final class CameraService: NSObject {
    public static let shared = CameraService()
    
    public weak var delegate: CameraServiceDelegate?
    
    // Core AVFoundation objects
    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.alignai.camera.sessionQueue", qos: .userInteractive)
    
    private var activeCamera: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieFileOutput = AVCaptureMovieFileOutput()
    
    // State
    public private(set) var isSessionRunning = false
    public private(set) var currentZoom: CGFloat = 1.0
    public private(set) var minZoom: CGFloat = 1.0
    public private(set) var maxZoom: CGFloat = 10.0
    public private(set) var isRecordingVideo = false
    
    public var flashMode: AVCaptureDevice.FlashMode = .auto
    public var isLivePhotoMode = false
    
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
            self.minZoom = camera.minAvailableVideoZoomFactor
            self.maxZoom = min(camera.maxAvailableVideoZoomFactor, 10.0)
            
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
                    }
                    if let connection = self.photoOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                }
                
                // Movie Output for Video Recording
                if self.captureSession.canAddOutput(self.movieFileOutput) {
                    self.captureSession.addOutput(self.movieFileOutput)
                    if let connection = self.movieFileOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .cinematicExtended
                        }
                    }
                }
                
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
            } catch {
                print("CameraService: Error setting zoom \(error)")
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
    
    // MARK: - Capture Photo
    public func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let photoSettings = AVCapturePhotoSettings()
            if self.activeCamera?.isFlashAvailable == true {
                photoSettings.flashMode = self.flashMode
            }
            photoSettings.photoQualityPrioritization = .quality
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraService(self, didOutputSampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraService: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        
        let zoomAtCapture = self.currentZoom
        
        guard let pixelBuffer = photo.pixelBuffer else {
            guard let data = photo.fileDataRepresentation(),
                  let uiImage = UIImage(data: data) else { return }
            
            var uprightImage = Self.fixOrientation(uiImage)
            if zoomAtCapture > 1.02, let cropped = Self.cropImageForZoom(uprightImage, zoom: zoomAtCapture) {
                uprightImage = cropped
            }
            guard let cgImage = uprightImage.cgImage else { return }
            
            let metadata = photo.metadata
            let (iso, shutter) = Self.parseExif(metadata)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.cameraService(self, didCapturePhoto: cgImage, iso: iso, shutterSpeed: shutter)
            }
            return
        }
        
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        if let orientationNum = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let cgOrientation = CGImagePropertyOrientation(rawValue: orientationNum) {
            ciImage = ciImage.oriented(cgOrientation)
        } else {
            ciImage = ciImage.oriented(.right)
        }
        
        // ✅ CẮT CHUẨN XÁC THEO TỶ LỆ ZOOM CỦA AI VÀ CAMERA (Fix ảnh lưu không zoom)
        if zoomAtCapture > 1.02 {
            let fullExtent = ciImage.extent
            let cropWidth = fullExtent.width / zoomAtCapture
            let cropHeight = fullExtent.height / zoomAtCapture
            let cropX = fullExtent.midX - (cropWidth / 2.0)
            let cropY = fullExtent.midY - (cropHeight / 2.0)
            let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
            ciImage = ciImage.cropped(to: cropRect)
        }
        
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        let metadata = photo.metadata
        let (iso, shutter) = Self.parseExif(metadata)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraService(self, didCapturePhoto: cgImage, iso: iso, shutterSpeed: shutter)
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
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return normalized
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
