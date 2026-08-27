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
            
            // Discover best dual/triple or wide camera
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
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                }
                
                // High-resolution Photo Output
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
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
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            return
        }
        
        let metadata = photo.metadata
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
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraService(self, didCapturePhoto: cgImage, iso: isoValue, shutterSpeed: shutterSpeed)
        }
    }
}
