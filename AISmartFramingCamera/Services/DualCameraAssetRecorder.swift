import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import QuartzCore
import UIKit

// MARK: - Dual Camera PIP Corner
public enum DualCameraPIPCorner: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

// MARK: - Dual Camera PIP Video & Photo Compositor / Asset Recorder
public final class DualCameraAssetRecorder: @unchecked Sendable {
    public static let shared = DualCameraAssetRecorder()

    private let recordQueue = DispatchQueue(label: "com.alignai.camera.dualRecordQueue", qos: .userInitiated)
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var currentOutputURL: URL?
    private var isRecordingInternal = false
    private var sessionStartTime: CMTime?
    private var lastVideoPTS: CMTime?
    private var pixelBufferPool: CVPixelBufferPool?

    private let stateLock = NSLock()
    public var pipCorner: DualCameraPIPCorner = .topTrailing

    public var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRecordingInternal
    }

    public init() {}

    // MARK: - Start Recording
    public func startRecording(
        outputURL: URL,
        dimensions: CMVideoDimensions = CMVideoDimensions(width: 1080, height: 1920),
        codec: VideoCodec = .hevc,
        corner: DualCameraPIPCorner = .topTrailing,
        completion: @escaping (Bool) -> Void
    ) {
        recordQueue.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }

            self.stateLock.lock()
            if self.isRecordingInternal {
                self.stateLock.unlock()
                completion(false)
                return
            }
            self.pipCorner = corner
            self.sessionStartTime = nil
            self.lastVideoPTS = nil
            self.currentOutputURL = outputURL
            self.stateLock.unlock()

            // Xóa file cũ nếu tồn tại
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }

            do {
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let width = Int(dimensions.width)
                let height = Int(dimensions.height)

                // 1. Cấu hình Video Output (1080x1920 @ 30fps)
                let canHEVC = writer.canApply(outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc], forMediaType: .video)
                let videoCodecType: AVVideoCodecType = (codec == .hevc && canHEVC) ? .hevc : .h264
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: videoCodecType,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 14_000_000,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30
                    ]
                ]

                let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                vInput.expectsMediaDataInRealTime = true

                let sourcePixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelFormatOpenGLESCompatibility as String: true
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: vInput,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )

                guard writer.canAdd(vInput) else {
                    CameraLogger.error("DualCameraAssetRecorder: Không thể add video input", category: .capture)
                    completion(false)
                    return
                }
                writer.add(vInput)

                // 2. Cấu hình Audio Output (AAC 44.1kHz stereo)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100.0,
                    AVEncoderBitRateKey: 128000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true

                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    self.audioInput = aInput
                } else {
                    self.audioInput = nil
                }

                guard writer.startWriting() else {
                    CameraLogger.error("DualCameraAssetRecorder: startWriting thất bại: \(String(describing: writer.error))", category: .capture)
                    completion(false)
                    return
                }

                self.assetWriter = writer
                self.videoInput = vInput
                self.videoAdaptor = adaptor

                self.stateLock.lock()
                self.isRecordingInternal = true
                self.stateLock.unlock()

                CameraLogger.success("DualCameraAssetRecorder: Đã bắt đầu ghi video Dual Camera (PIP) tại \(outputURL.lastPathComponent)", category: .capture)
                completion(true)
            } catch {
                CameraLogger.error("DualCameraAssetRecorder: Khởi tạo AVAssetWriter thất bại", error: error, category: .capture)
                completion(false)
            }
        }
    }

    // MARK: - Append Video Pixel Buffer (Composited PIP)
    public func appendBackPixelBuffer(_ backBuffer: CVPixelBuffer, frontBuffer: CVPixelBuffer?, pts: CMTime) {
        guard isRecording else { return }

        recordQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, let vInput = self.videoInput, let adaptor = self.videoAdaptor else { return }
            guard writer.status == .writing, vInput.isReadyForMoreMediaData else { return }

            self.stateLock.lock()
            if self.sessionStartTime == nil {
                self.sessionStartTime = pts
                writer.startSession(atSourceTime: pts)
            }
            if let last = self.lastVideoPTS, pts <= last {
                self.stateLock.unlock()
                return
            }
            self.lastVideoPTS = pts
            let corner = self.pipCorner
            let scaleMultiplier = self.pipScale
            self.stateLock.unlock()

            let width = CVPixelBufferGetWidth(backBuffer)
            let height = CVPixelBufferGetHeight(backBuffer)
            guard width > 0, height > 0 else { return }

            let backCI = CIImage(cvPixelBuffer: backBuffer)
            let finalCI: CIImage

            if let frontBuffer {
                let frontCI = CIImage(cvPixelBuffer: frontBuffer)
                finalCI = Self.compositePIP(
                    frontCI: frontCI,
                    over: backCI,
                    canvasWidth: CGFloat(width),
                    canvasHeight: CGFloat(height),
                    corner: corner,
                    scaleMultiplier: scaleMultiplier
                )
            } else {
                finalCI = backCI
            }

            var targetBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool ?? self.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &targetBuffer)
            }
            if targetBuffer == nil {
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelFormatOpenGLESCompatibility: true
                ]
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &targetBuffer)
            }
            guard let outBuffer = targetBuffer else { return }

            self.ciContext.render(finalCI, to: outBuffer)
            adaptor.append(outBuffer, withPresentationTime: pts)
        }
    }

    // MARK: - Append Audio Buffer
    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }

        recordQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, let aInput = self.audioInput else { return }
            guard writer.status == .writing, aInput.isReadyForMoreMediaData else { return }

            self.stateLock.lock()
            let hasStarted = self.sessionStartTime != nil
            self.stateLock.unlock()

            guard hasStarted else { return }
            aInput.append(sampleBuffer)
        }
    }

    // MARK: - Stop Recording
    public func stopRecording(completion: @escaping (URL?, Error?) -> Void) {
        recordQueue.async { [weak self] in
            guard let self else {
                completion(nil, nil)
                return
            }

            self.stateLock.lock()
            guard self.isRecordingInternal, let writer = self.assetWriter else {
                self.stateLock.unlock()
                completion(nil, nil)
                return
            }
            self.isRecordingInternal = false
            let outURL = self.currentOutputURL
            let hasSessionStarted = self.sessionStartTime != nil
            self.stateLock.unlock()

            guard hasSessionStarted else {
                writer.cancelWriting()
                self.stateLock.lock()
                self.assetWriter = nil
                self.videoInput = nil
                self.videoAdaptor = nil
                self.audioInput = nil
                self.sessionStartTime = nil
                self.lastVideoPTS = nil
                self.currentOutputURL = nil
                self.stateLock.unlock()
                completion(nil, nil)
                return
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.assetWriter = nil
                self.videoInput = nil
                self.videoAdaptor = nil
                self.audioInput = nil
                self.sessionStartTime = nil
                self.lastVideoPTS = nil
                self.currentOutputURL = nil
                self.stateLock.unlock()

                if writer.status == .failed {
                    CameraLogger.error("DualCameraAssetRecorder: Ghi video thất bại: \(String(describing: writer.error))", category: .capture)
                    completion(nil, writer.error)
                } else {
                    CameraLogger.success("DualCameraAssetRecorder: Đã xuất video Dual Camera hoàn chỉnh: \(outURL?.path ?? "")", category: .capture)
                    completion(outURL, nil)
                }
            }
        }
    }

    // MARK: - PIP Static Compositor for Photos and Frames
    public static func compositePIP(
        frontCI: CIImage,
        over backCI: CIImage,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        corner: DualCameraPIPCorner,
        scaleMultiplier: CGFloat = 1.0
    ) -> CIImage {
        let fExtent = frontCI.extent
        guard fExtent.width > 0, fExtent.height > 0 else { return backCI }

        // Kích thước PIP: Chiếm 28% chiều rộng khung hình chính (nhân tỉ lệ scaleMultiplier), tỉ lệ 3:4 chuẩn chân dung
        let basePipWidth = round(canvasWidth * 0.28)
        let clampedScale = max(0.75, min(1.8, scaleMultiplier))
        let pipWidth = round(basePipWidth * clampedScale)
        let pipHeight = round(pipWidth * (4.0 / 3.0))
        let margin: CGFloat = round(canvasWidth * 0.035)

        // Tính tọa độ điểm neo theo góc người dùng đã chọn (CoreImage: gốc (0,0) ở góc dưới-trái)
        let targetX: CGFloat
        let targetY: CGFloat
        switch corner {
        case .topLeading:
            targetX = margin
            targetY = canvasHeight - margin - pipHeight
        case .topTrailing:
            targetX = canvasWidth - margin - pipWidth
            targetY = canvasHeight - margin - pipHeight
        case .bottomLeading:
            targetX = margin
            targetY = margin + round(canvasHeight * 0.07) // Cách đáy để tránh thanh điều khiển
        case .bottomTrailing:
            targetX = canvasWidth - margin - pipWidth
            targetY = margin + round(canvasHeight * 0.07)
        }

        // Scale và crop cam trước vừa khít khung PIP
        let scaleX = pipWidth / fExtent.width
        let scaleY = pipHeight / fExtent.height
        let scale = max(scaleX, scaleY)
        let scaledW = fExtent.width * scale
        let scaledH = fExtent.height * scale
        let offsetX = (pipWidth - scaledW) / 2.0
        let offsetY = (pipHeight - scaledH) / 2.0

        let scaledFront = frontCI
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY)))
            .cropped(to: CGRect(x: 0, y: 0, width: pipWidth, height: pipHeight))

        // Bo tròn góc PIP (Radius 16px) bằng Alpha Mask với nền trắng để giữ trọn vùng vẽ
        let cornerRadius: CGFloat = 16.0
        let maskRect = CGRect(x: 0, y: 0, width: pipWidth, height: pipHeight)
        let maskImage = createRoundedRectMask(size: maskRect.size, cornerRadius: cornerRadius)

        let maskedFront: CIImage
        if let mask = maskImage,
           let blendFilter = CIFilter(name: "CIBlendWithAlphaMask") {
            blendFilter.setValue(scaledFront, forKey: kCIInputImageKey)
            blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)
            maskedFront = blendFilter.outputImage ?? scaledFront
        } else {
            maskedFront = scaledFront
        }

        // Đặt PIP vào vị trí mong muốn trên canvas
        let positionedFront = maskedFront.transformed(by: CGAffineTransform(translationX: targetX, y: targetY))

        // Lồng ghép lên trên ảnh nền camera sau
        return positionedFront.composited(over: backCI)
    }

    private static func createRoundedRectMask(size: CGSize, cornerRadius: CGFloat) -> CIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius)
            path.fill()
        }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
