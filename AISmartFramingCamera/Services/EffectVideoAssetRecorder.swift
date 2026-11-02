import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import QuartzCore
import UIKit

// MARK: - Effect Video Asset Recorder (Horizon Lock 360°, Simulated Ultra-Wide 0.5x, Film Presets)
public final class EffectVideoAssetRecorder: @unchecked Sendable {
    public static let shared = EffectVideoAssetRecorder()

    private let recordQueue = DispatchQueue(label: "com.alignai.camera.effectRecordQueue", qos: .userInitiated)
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
    public var isHorizonLock: Bool = false
    public var isSimulatedUW: Bool = false
    public var simulatedFactor: CGFloat = 0.5
    public var filmPreset: FilmPreset? = nil
    public var filmIntensity: Float = 1.0
    public var aiColorParams: FilmSimulationAIColorParameters? = nil

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
        fps: Double = 30.0,
        codec: VideoCodec = .hevc,
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
            self.sessionStartTime = nil
            self.lastVideoPTS = nil
            self.currentOutputURL = outputURL
            self.stateLock.unlock()

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }

            do {
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let width = Int(dimensions.width)
                let height = Int(dimensions.height)

                let canHEVC = writer.canApply(outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc], forMediaType: .video)
                let videoCodecType: AVVideoCodecType = (codec == .hevc && canHEVC) ? .hevc : .h264
                let bitrate = (width >= 2160 || height >= 2160) ? 35_000_000 : 16_000_000
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: videoCodecType,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoExpectedSourceFrameRateKey: Int(fps),
                        AVVideoMaxKeyFrameIntervalKey: Int(fps)
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
                    CameraLogger.error("EffectVideoAssetRecorder: Khong the add video input", category: .capture)
                    completion(false)
                    return
                }
                writer.add(vInput)

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
                    CameraLogger.error("EffectVideoAssetRecorder: startWriting that bai: \(String(describing: writer.error))", category: .capture)
                    completion(false)
                    return
                }

                self.assetWriter = writer
                self.videoInput = vInput
                self.videoAdaptor = adaptor

                self.stateLock.lock()
                self.isRecordingInternal = true
                self.stateLock.unlock()

                CameraLogger.success("EffectVideoAssetRecorder: Da bat dau ghi video Effect tai \(outputURL.lastPathComponent)", category: .capture)
                completion(true)
            } catch {
                CameraLogger.error("EffectVideoAssetRecorder: Khoi tao AVAssetWriter that bai", error: error, category: .capture)
                completion(false)
            }
        }
    }

    // MARK: - Append Video Pixel Buffer
    public func appendVideoPixelBuffer(_ videoBuffer: CVPixelBuffer, pts: CMTime) {
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
            let isHL = self.isHorizonLock
            let simUW = self.isSimulatedUW
            let simFactor = self.simulatedFactor
            let preset = self.filmPreset
            let intensity = self.filmIntensity
            let aiParams = self.aiColorParams
            self.stateLock.unlock()

            var targetBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool ?? self.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &targetBuffer)
            }
            let inWidth = CVPixelBufferGetWidth(videoBuffer)
            let inHeight = CVPixelBufferGetHeight(videoBuffer)
            guard inWidth > 0, inHeight > 0 else { return }

            if targetBuffer == nil {
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey: inWidth,
                    kCVPixelBufferHeightKey: inHeight,
                    kCVPixelFormatOpenGLESCompatibility: true
                ]
                CVPixelBufferCreate(kCFAllocatorDefault, inWidth, inHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &targetBuffer)
            }
            guard let outBuffer = targetBuffer else { return }
            let outWidth = CVPixelBufferGetWidth(outBuffer)
            let outHeight = CVPixelBufferGetHeight(outBuffer)
            guard outWidth > 0, outHeight > 0 else { return }

            let rawCI = CIImage(cvPixelBuffer: videoBuffer)
            let bExt = rawCI.extent
            guard bExt.width > 0, bExt.height > 0 else { return }

            let targetSize = CGSize(width: CGFloat(outWidth), height: CGFloat(outHeight))
            let sx = targetSize.width / bExt.width
            let sy = targetSize.height / bExt.height
            let scale = max(sx, sy)

            var frameCI: CIImage
            if isHL {
                let motionParams = DeviceMotionService.shared.currentHorizonParams()
                let rollAngle = CGFloat(-motionParams.roll)
                let zoomFactor = CGFloat(motionParams.zoom)
                let totalScale = scale * zoomFactor
                let shakeOffsetX = CGFloat(motionParams.shakeX) * targetSize.width
                let shakeOffsetY = CGFloat(motionParams.shakeY) * targetSize.height

                let horizonTransform = CGAffineTransform(translationX: -bExt.midX, y: -bExt.midY)
                    .concatenating(CGAffineTransform(rotationAngle: rollAngle))
                    .concatenating(CGAffineTransform(scaleX: totalScale, y: totalScale))
                    .concatenating(CGAffineTransform(translationX: (targetSize.width / 2.0) + shakeOffsetX,
                                                     y: (targetSize.height / 2.0) + shakeOffsetY))
                let transformed = rawCI.transformed(by: horizonTransform)
                let bgBlack = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: targetSize))
                frameCI = transformed.composited(over: bgBlack).cropped(to: CGRect(origin: .zero, size: targetSize))
            } else {
                let ox = (targetSize.width - bExt.width * scale) / 2.0
                let oy = (targetSize.height - bExt.height * scale) / 2.0
                let transform = CGAffineTransform(translationX: -bExt.minX, y: -bExt.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: ox, y: oy))
                frameCI = rawCI.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: targetSize))
            }

            if simUW {
                frameCI = UltraWideWarpEngine.shared.applySimulatedUltraWide(to: frameCI, factor: simFactor)
            }

            if let p = preset, p != .standard {
                var filtered = FilmFilterEngine.shared.applyPreset(to: frameCI, preset: p, intensity: intensity, isRealtimePreview: false) ?? frameCI
                if let ai = aiParams {
                    filtered = FilmFilterEngine.shared.applyAIColorParameters(to: filtered, params: ai) ?? filtered
                }
                frameCI = filtered
            }

            self.ciContext.render(frameCI, to: outBuffer)
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
                    CameraLogger.error("EffectVideoAssetRecorder: Ghi video that bai: \(String(describing: writer.error))", category: .capture)
                    completion(nil, writer.error)
                } else {
                    CameraLogger.success("EffectVideoAssetRecorder: Da xuat video Effect hoan chinh: \(outURL?.path ?? "")", category: .capture)
                    completion(outURL, nil)
                }
            }
        }
    }
}
