import Foundation
import AVFoundation
import UIKit
import CoreImage

@MainActor
public protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutputSampleBuffer sampleBuffer: CMSampleBuffer)
    func cameraService(_ service: CameraService, didCapturePhoto photo: CGImage, iso: Float, shutterSpeed: Double)
    func cameraService(_ service: CameraService, didChangeZoomFactor zoom: CGFloat)
}

public final class CameraService: NSObject, @unchecked Sendable {
    public static let shared = CameraService()
    
    public weak var delegate: CameraServiceDelegate?
    
    public let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.aismartframing.cameraSessionQueue")
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    public private(set) var activeCamera: AVCaptureDevice?
    public private(set) var currentZoomFactor: CGFloat = 1.0
    public var flashMode: AVCaptureDevice.FlashMode = .auto
    
    // Zoom limits
    public var minZoom: CGFloat = 1.0
    public var maxZoom: CGFloat = 10.0
    
    public override init() {
        super.init()
    }
    
    // MARK: - Setup Session
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
                
                // Video Data Output for Real-time Vision
                if self.captureSession.canAddOutput(self.videoDataOutput) {
                    self.captureSession.addOutput(self.videoDataOutput)
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoDataOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    // Fix orientation: rotate video output to portrait
                    if let connection = self.videoDataOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = false
                        }
                    }
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                }
                
                // High-resolution Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    
                    // Fix photo orientation
                    if let connection = self.photoOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                }
                
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(true) }
                
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
    
    // MARK: - Start / Stop
    public func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }
    
    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }
    
    // MARK: - Zoom Controls
    public func setZoomFactor(_ zoom: CGFloat, animated: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeCamera else { return }
            
            let clampedZoom = max(self.minZoom, min(zoom, self.maxZoom))
            
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: clampedZoom, withRate: 4.0)
                } else {
                    device.videoZoomFactor = clampedZoom
                }
                device.unlockForConfiguration()
                
                DispatchQueue.main.async {
                    self.currentZoomFactor = clampedZoom
                    self.delegate?.cameraService(self, didChangeZoomFactor: clampedZoom)
                }
            } catch {
                print("Failed to set zoom: \(error)")
            }
        }
    }
    
    // MARK: - Exposure Bias Adjustment
    public func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeCamera else { return }
            do {
                try device.lockForConfiguration()
                let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
                device.setExposureTargetBias(clampedBias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                print("Failed to set exposure bias: \(error)")
            }
        }
    }
    
    // MARK: - Focus & Exposure Point
    public func focusAndExpose(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeCamera else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to focus: \(error)")
            }
        }
    }
    
    // MARK: - Photo Capture
    public func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let photoSettings = AVCapturePhotoSettings()
            if let device = self.activeCamera, device.hasFlash {
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
        
        // ✅ Fix: Properly orient the photo using pixelBuffer for correct upright portrait output
        guard let pixelBuffer = photo.pixelBuffer else {
            // Fallback: use fileData with orientation correction
            guard let data = photo.fileDataRepresentation(),
                  let uiImage = UIImage(data: data) else { return }
            
            // Force upright orientation
            let uprightImage = Self.fixOrientation(uiImage)
            guard let cgImage = uprightImage.cgImage else { return }
            
            let metadata = photo.metadata
            let (iso, shutter) = Self.parseExif(metadata)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.cameraService(self, didCapturePhoto: cgImage, iso: iso, shutterSpeed: shutter)
            }
            return
        }
        
        // Use CIImage → CGImage pipeline with correct orientation
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Apply orientation from photo metadata
        if let orientationNum = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let cgOrientation = CGImagePropertyOrientation(rawValue: orientationNum) {
            ciImage = ciImage.oriented(cgOrientation)
        } else {
            // Default: cameras typically return right-rotation for portrait, force upright
            ciImage = ciImage.oriented(.right)
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
    
    /// Force UIImage to upright orientation by redrawing into a new CGContext
    private static func fixOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return normalized
    }
}
