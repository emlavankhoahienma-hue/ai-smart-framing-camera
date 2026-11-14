//
//  UltraSharpCaptureController.swift
//  AISmartFramingCamera
//
//  Bộ điều phối Chụp Chùm N Frame Đồng Phơi Sáng (Constant-Exposure Burst Controller)
//  - Tự động dò khả năng phần cứng (RAM, Thermal State, maxBracketedCapturePhotoCount)
//  - Khóa chặt AE/AF/AWB trong suốt chu kỳ chụp chùm và hoàn nguyên 100% sau khi kết thúc/lỗi/hủy
//  - Chuyển phát Frame theo luồng Streaming để tích lũy liên tục (Zero RAM Spike trên iPhone XS)
//

import Foundation
import AVFoundation
import UIKit

public final class UltraSharpCaptureController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    public static let shared = UltraSharpCaptureController()

    private let sessionQueue = DispatchQueue(label: "com.alignstudio.ultrasharp.session", qos: .userInitiated)
    private let captureLock = NSLock()

    // Trạng thái khóa phần cứng để hoàn nguyên
    private struct HardwareLockState {
        let exposureMode: AVCaptureDevice.ExposureMode
        let focusMode: AVCaptureDevice.FocusMode
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let isSmoothAutoFocusEnabled: Bool
    }
    private var savedLockState: HardwareLockState?
    private weak var activeCameraDevice: AVCaptureDevice?
    private weak var currentCameraService: CameraService?

    // Bộ nhớ đệm quản lý burst đang thực thi
    private var targetBurstCount: Int = 8
    private var capturedFrames: [UltraSharpFrame] = []
    private var isBurstInFlight: Bool = false
    private var isCancelled: Bool = false
    private var onFrameReceived: (@Sendable (UltraSharpFrame, Int, Int) -> Void)?
    private var onBurstFinished: (@Sendable (Result<[UltraSharpFrame], Error>) -> Void)?

    private override init() {
        super.init()
        setupSystemObservers()
    }

    private func setupSystemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppEnteredBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        CameraLogger.warning("UltraSharpCaptureController: Nhận cảnh báo bộ nhớ (Memory Warning) -> Hủy burst an toàn!", category: .capture)
        cancelBurst()
    }

    @objc private func handleAppEnteredBackground() {
        CameraLogger.warning("UltraSharpCaptureController: App vào nền -> Hủy burst an toàn!", category: .capture)
        cancelBurst()
    }

    // MARK: - Dò khả năng Phần cứng Động (Hardware Capacity Auto-Tuning)

    public func calculateOptimalBurstCount(requestedCount: Int) -> Int {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let thermal = ProcessInfo.processInfo.thermalState

        var safeCount = requestedCount

        // 1. Kiểm tra dung lượng RAM vật lý
        if ramBytes < 4_500_000_000 {
            // Thiết bị 4GB RAM (iPhone XS, XS Max, XR, 11)
            safeCount = min(safeCount, 6)
        } else if ramBytes < 6_500_000_000 {
            // Thiết bị 6GB RAM (iPhone 12 Pro, 13 Pro, 14, 15)
            safeCount = min(safeCount, 8)
        } else {
            // Thiết bị >= 8GB RAM (iPhone 15 Pro, 16 Pro...)
            safeCount = min(safeCount, 12)
        }

        // 2. Kiểm tra trạng thái nhiệt độ máy (Thermal Throttling)
        if thermal == .serious || thermal == .critical {
            safeCount = min(safeCount, 5)
        }

        return max(4, safeCount)
    }

    // MARK: - Khóa và Hoàn nguyên Cấu hình Camera (AE / AF / AWB)

    private func lockCameraConfiguration(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        activeCameraDevice = device

        savedLockState = HardwareLockState(
            exposureMode: device.exposureMode,
            focusMode: device.focusMode,
            whiteBalanceMode: device.whiteBalanceMode,
            isSmoothAutoFocusEnabled: device.isSmoothAutoFocusSupported && device.isSmoothAutoFocusEnabled
        )

        // 1. Khóa Phơi Sáng (AE) an toàn tuyệt đối (không gọi setExposureModeCustom dễ văng NSInvalidArgumentException khi ISO/Duration sát biên)
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }

        // 2. Khóa Lấy Nét (AF) ở cự ly ống kính thực tế hiện tại
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }

        // 3. Khóa Cân Bằng Trắng (AWB) an toàn tuyệt đối (không truyền raw gains dễ vượt [1.0, maxWhiteBalanceGain] gây văng NSInvalidArgumentException)
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }

        device.unlockForConfiguration()
    }

    private func restoreCameraConfiguration() {
        guard let device = activeCameraDevice, let state = savedLockState else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(state.exposureMode) {
                device.exposureMode = state.exposureMode
            }
            if device.isFocusModeSupported(state.focusMode) {
                device.focusMode = state.focusMode
            }
            if device.isWhiteBalanceModeSupported(state.whiteBalanceMode) {
                device.whiteBalanceMode = state.whiteBalanceMode
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = state.isSmoothAutoFocusEnabled
            }
            device.unlockForConfiguration()
        } catch {
            CameraLogger.error("UltraSharpCaptureController: Lỗi khi hoàn nguyên camera: \(error.localizedDescription)", category: .capture)
        }

        savedLockState = nil
        activeCameraDevice = nil
    }

    // MARK: - Thực thi Chuỗi Chụp Chùm (Burst Execution)

    public func startBurstCapture(
        cameraService: CameraService,
        requestedCount: Int = 8,
        onFrameReceived: @escaping @Sendable (UltraSharpFrame, Int, Int) -> Void,
        completion: @escaping @Sendable (Result<[UltraSharpFrame], Error>) -> Void
    ) {
        captureLock.lock()
        guard !isBurstInFlight else {
            captureLock.unlock()
            completion(.failure(CameraServiceError.captureAlreadyInProgress))
            return
        }
        isBurstInFlight = true
        isCancelled = false
        capturedFrames.removeAll()
        self.currentCameraService = cameraService
        self.onFrameReceived = onFrameReceived
        self.onBurstFinished = completion

        let finalCount = calculateOptimalBurstCount(requestedCount: requestedCount)
        self.targetBurstCount = finalCount
        captureLock.unlock()

        cameraService.sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let camera = (cameraService.captureSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }).first
            guard let camera = camera else {
                self.finishBurst(with: .failure(CameraServiceError.cameraNotReady))
                return
            }

            do {
                try self.lockCameraConfiguration(device: camera)
            } catch {
                self.finishBurst(with: .failure(error))
                return
            }

            // Kích hoạt phát chụp đầu tiên trong chuỗi burst trên sessionQueue của CameraService
            self.triggerNextPhotoShot(cameraService: cameraService, shotIndex: 0)
        }
    }

    private func triggerNextPhotoShot(cameraService: CameraService, shotIndex: Int) {
        captureLock.lock()
        guard isBurstInFlight, !isCancelled else {
            captureLock.unlock()
            return
        }
        let total = targetBurstCount
        captureLock.unlock()

        guard shotIndex < total else {
            // Đã thu thập đủ số lượng frame
            captureLock.lock()
            let frames = self.capturedFrames
            captureLock.unlock()
            finishBurst(with: .success(frames))
            return
        }

        guard let photoOutput = cameraService.captureSession.outputs.compactMap({ $0 as? AVCapturePhotoOutput }).first,
              let camera = (cameraService.captureSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }).first else {
            finishBurst(with: .failure(CameraServiceError.cameraNotReady))
            return
        }
        guard let connection = photoOutput.connection(with: .video), connection.isActive, connection.isEnabled else {
            finishBurst(with: .failure(CameraServiceError.cameraNotReady))
            return
        }

        // Cấu hình chụp 12MP tiêu chuẩn và kiểm tra chặt maxPhotoDimensions + maxPhotoQualityPrioritization
        // để tuyệt đối không bao giờ ném NSInvalidArgumentException trên máy 48MP (iPhone 14/15/16/17 Pro)
        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])

        let supportedDims = camera.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let maxOutDim = photoOutput.maxPhotoDimensions
        if let standard12MP = supportedDims.first,
           standard12MP.width > 0, standard12MP.height > 0 {
            if maxOutDim.width > 0, maxOutDim.height > 0,
               (standard12MP.width > maxOutDim.width || standard12MP.height > maxOutDim.height) {
                settings.maxPhotoDimensions = maxOutDim
            } else {
                settings.maxPhotoDimensions = standard12MP
            }
        } else if maxOutDim.width > 0, maxOutDim.height > 0 {
            settings.maxPhotoDimensions = maxOutDim
        }

        let selectedPixels = Int64(settings.maxPhotoDimensions.width) * Int64(settings.maxPhotoDimensions.height)
        if selectedPixels > 15_000_000 {
            // Với độ phân giải > 12MP (48MP), AVFoundation bắt buộc prioritization >= .balanced
            settings.photoQualityPrioritization = (photoOutput.maxPhotoQualityPrioritization == .speed) ? .speed : .balanced
        } else {
            settings.photoQualityPrioritization = .speed
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        captureLock.lock()
        let inFlight = self.isBurstInFlight
        let cancelled = self.isCancelled
        let currentIndex = self.capturedFrames.count
        let total = self.targetBurstCount
        captureLock.unlock()

        guard inFlight && !cancelled else { return }

        if let error = error {
            CameraLogger.error("UltraSharpCaptureController: Lỗi chụp frame index \(currentIndex): \(error.localizedDescription)", category: .capture)
            // Nếu có ít nhất 4 frame thì kết thúc thành công với số frame hiện có
            captureLock.lock()
            let count = self.capturedFrames.count
            let current = self.capturedFrames
            captureLock.unlock()

            if count >= 4 {
                finishBurst(with: .success(current))
            } else {
                finishBurst(with: .failure(error))
            }
            return
        }

        guard let pixelBuffer: CVPixelBuffer = autoreleasepool(invoking: {
            self.decodePixelBuffer(from: photo)
        }) else {
            CameraLogger.warning("UltraSharpCaptureController: Không trích xuất được pixelBuffer cho frame \(currentIndex)", category: .capture)
            captureLock.lock()
            let count = self.capturedFrames.count
            let current = self.capturedFrames
            captureLock.unlock()
            if count >= 3 {
                finishBurst(with: .success(current))
            } else {
                finishBurst(with: .failure(CameraServiceError.photoProcessingFailed))
            }
            return
        }

        let iso = photo.metadata[kCGImagePropertyExifDictionary as String].flatMap { ($0 as? [String: Any])?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] }?.first?.floatValue ?? 100.0
        let duration = photo.timestamp

        let ultraFrame = UltraSharpFrame(
            index: currentIndex,
            pixelBuffer: pixelBuffer,
            timestamp: duration,
            iso: iso,
            exposureDuration: duration,
            sharpnessScore: 0.0,
            metadata: photo.metadata
        )

        captureLock.lock()
        self.capturedFrames.append(ultraFrame)
        let newCount = self.capturedFrames.count
        let callback = self.onFrameReceived
        let service = self.currentCameraService
        captureLock.unlock()

        // Phát tín hiệu streaming frame ra ngoài ngay lập tức
        callback?(ultraFrame, newCount, total)

        // Bắn phát chụp tiếp theo trên sessionQueue của CameraService
        guard let cameraService = service else { return }
        cameraService.sessionQueue.async { [weak self] in
            self?.triggerNextPhotoShot(cameraService: cameraService, shotIndex: newCount)
        }
    }

    private func decodePixelBuffer(from photo: AVCapturePhoto) -> CVPixelBuffer? {
        guard let data = photo.fileDataRepresentation(),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4032
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) ??
                            CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

            if let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        return buffer
    }

    public func cancelBurst() {
        captureLock.lock()
        guard isBurstInFlight else {
            captureLock.unlock()
            return
        }
        isCancelled = true
        captureLock.unlock()

        finishBurst(with: .failure(CameraServiceError.captureTimedOut))
    }

    private func finishBurst(with result: Result<[UltraSharpFrame], Error>) {
        captureLock.lock()
        let completion = self.onBurstFinished
        let service = self.currentCameraService
        self.isBurstInFlight = false
        self.capturedFrames.removeAll(keepingCapacity: false)
        self.onFrameReceived = nil
        self.onBurstFinished = nil
        self.currentCameraService = nil
        captureLock.unlock()

        // Hoàn nguyên trạng thái camera trên luồng session của CameraService
        let targetQueue = service?.sessionQueue ?? sessionQueue
        targetQueue.async { [weak self] in
            self?.restoreCameraConfiguration()
        }

        completion?(result)
    }
}
