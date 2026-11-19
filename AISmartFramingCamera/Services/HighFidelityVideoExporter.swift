import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UIKit

/// Bộ xuất Video chất lượng cao (AVAssetReader + AVAssetWriter + Metal GPU CIContext + Audio Passthrough)
/// - Ghép Khung Master (mở rộng chiều cao canvas H + barHeight, KHÔNG cắt xén 1 pixel nào của video gốc)
/// - Bảo toàn độ phân giải gốc (4K / 1080p), đúng FPS (30/60fps), đúng Codec (HEVC / H.264), bitrate >= 115% bản gốc
/// - Audio Track Passthrough (`outputSettings: nil`): sao chép bit-for-bit âm thanh gốc không giải mã/nén lại
public final class HighFidelityVideoExporter: @unchecked Sendable {
    public struct MasterFrameConfig: @unchecked Sendable {
        public let deviceName: String
        public let theme: WatermarkTheme
        public let logoStyle: WatermarkLogoStyle
        public let customLogo: UIImage?
        public let specs: PhotoWatermarkSpecs
        public let videoTag: String

        public init(
            deviceName: String,
            theme: WatermarkTheme,
            logoStyle: WatermarkLogoStyle,
            customLogo: UIImage?,
            specs: PhotoWatermarkSpecs,
            videoTag: String
        ) {
            self.deviceName = deviceName
            self.theme = theme
            self.logoStyle = logoStyle
            self.customLogo = customLogo
            self.specs = specs
            self.videoTag = videoTag
        }
    }

    public struct ExportOptions: @unchecked Sendable {
        public let sourceURL: URL
        public let preferredCodec: VideoCodec
        public let applyWindowCrop: Bool
        public let windowAspect: WindowedZoomAspectRatio
        public let recordedKeyframes: [WindowedZoomKeyframe]
        public let fallbackKeyframe: WindowedZoomKeyframe
        public let applyColorGrading: Bool
        public let filterPreset: FilmPreset
        public let aiColorParams: AIColorParameters?
        public let infoFrameStyle: VideoInfoFrameStyle
        public let masterFrameConfig: MasterFrameConfig
        public let liveAperture: String
        public let liveShutterText: String
        public let liveISOValue: Int
        public let fallbackFPS: Int

        public init(
            sourceURL: URL,
            preferredCodec: VideoCodec,
            applyWindowCrop: Bool,
            windowAspect: WindowedZoomAspectRatio,
            recordedKeyframes: [WindowedZoomKeyframe],
            fallbackKeyframe: WindowedZoomKeyframe,
            applyColorGrading: Bool,
            filterPreset: FilmPreset,
            aiColorParams: AIColorParameters?,
            infoFrameStyle: VideoInfoFrameStyle,
            masterFrameConfig: MasterFrameConfig,
            liveAperture: String,
            liveShutterText: String,
            liveISOValue: Int,
            fallbackFPS: Int
        ) {
            self.sourceURL = sourceURL
            self.preferredCodec = preferredCodec
            self.applyWindowCrop = applyWindowCrop
            self.windowAspect = windowAspect
            self.recordedKeyframes = recordedKeyframes
            self.fallbackKeyframe = fallbackKeyframe
            self.applyColorGrading = applyColorGrading
            self.filterPreset = filterPreset
            self.aiColorParams = aiColorParams
            self.infoFrameStyle = infoFrameStyle
            self.masterFrameConfig = masterFrameConfig
            self.liveAperture = liveAperture
            self.liveShutterText = liveShutterText
            self.liveISOValue = liveISOValue
            self.fallbackFPS = fallbackFPS
        }
    }

    public enum ExportError: LocalizedError {
        case missingVideoTrack
        case cannotCreateReaderWriter(String)
        case writerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingVideoTrack: return "Không tìm thấy track hình ảnh trong video gốc"
            case .cannotCreateReaderWriter(let detail): return "Không khởi tạo được bộ ghi chất lượng cao: \(detail)"
            case .writerFailed(let detail): return "Xuất video thất bại: \(detail)"
            }
        }
    }

    private static let gpuContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false,
                .cacheIntermediates: false
            ])
        }
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .cacheIntermediates: false
        ])
    }()

    public static func export(
        options: ExportOptions,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: options.sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let estimatedBitrate = try await videoTrack.load(.estimatedDataRate)
        let durationCM = try await asset.load(.duration)
        let totalSeconds = max(0.05, durationCM.seconds.isFinite ? durationCM.seconds : 1.0)
        let exportFPS = nominalFPS > 0 ? max(1, Int(round(Double(nominalFPS)))) : max(1, options.fallbackFPS)

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let audioTrack = audioTracks.first
        let audioFormatHint: CMFormatDescription? = try? await audioTrack?.load(.formatDescriptions).first

        let orientation = cgImageOrientation(from: preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let uprightSourceSize = CGSize(
            width: max(2, CGFloat(Int(abs(transformedRect.width)) & ~1)),
            height: max(2, CGFloat(Int(abs(transformedRect.height)) & ~1))
        )

        // 1. Kích thước phần hình video (giữ 1:1 kích thước gốc nếu không crop Windowed Zoom)
        let videoContentSize: CGSize
        if options.applyWindowCrop {
            videoContentSize = computeTargetRenderSize(sourceSize: uprightSourceSize, aspect: options.windowAspect)
        } else {
            videoContentSize = uprightSourceSize
        }

        // 2. Nếu chọn Khung Master -> mở rộng thêm dải footer phía dưới (KHÔNG cắt video gốc!)
        let isMasterFrame = (options.infoFrameStyle == .masterFrame)
        let masterBarHeight: CGFloat = isMasterFrame
            ? MasterWatermarkRenderer.recommendedFooterHeight(width: videoContentSize.width, height: videoContentSize.height)
            : 0
        let finalOutputSize = CGSize(
            width: max(2, CGFloat(Int(videoContentSize.width) & ~1)),
            height: max(2, CGFloat(Int(videoContentSize.height + masterBarHeight) & ~1))
        )

        // Render sẵn Footer Bar Khung Master 1 lần duy nhất ra CIImage cache (tốc độ GPU tối đa)
        let cachedMasterFooterCI: CIImage?
        if isMasterFrame {
            let resLabel = max(videoContentSize.width, videoContentSize.height) >= 3600 ? "4K" : "1080p"
            let vTag = "\(resLabel) · \(exportFPS)fps"
            let footerCG = MasterWatermarkRenderer.shared.renderFooterBarImage(
                width: finalOutputSize.width,
                barHeight: masterBarHeight,
                deviceName: options.masterFrameConfig.deviceName,
                theme: options.masterFrameConfig.theme,
                logoStyle: options.masterFrameConfig.logoStyle,
                customLogo: options.masterFrameConfig.customLogo,
                specs: options.masterFrameConfig.specs,
                videoTag: vTag
            )
            cachedMasterFooterCI = footerCG.map { CIImage(cgImage: $0) }
        } else {
            cachedMasterFooterCI = nil
        }

        // 3. Xác định Codec & Bitrate chất lượng gốc (>= 115% bitrate gốc, có sàn tối thiểu chuẩn Pro)
        let useHEVC = (options.preferredCodec == .hevc)
        let pixels = Double(finalOutputSize.width * finalOutputSize.height)
        let is4K = pixels >= 6_000_000
        let floorBitrate: Double
        if is4K {
            floorBitrate = exportFPS >= 50 ? (useHEVC ? 48_000_000 : 68_000_000) : (useHEVC ? 32_000_000 : 48_000_000)
        } else {
            floorBitrate = exportFPS >= 50 ? (useHEVC ? 22_000_000 : 32_000_000) : (useHEVC ? 14_000_000 : 20_000_000)
        }
        let sourceBitrate = Double(estimatedBitrate)
        let targetBitrate = Int(max(floorBitrate, sourceBitrate * 1.15))

        // Đọc thông số dải màu nguồn (P3-D65 / Rec.709) để bảo toàn màu gốc chuẩn xác
        let colorProperties = await detectColorProperties(from: videoTrack)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignMaster_\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            return try await runReaderWriterPass(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                audioFormatHint: audioFormatHint,
                outputURL: outputURL,
                orientation: orientation,
                videoContentSize: videoContentSize,
                finalOutputSize: finalOutputSize,
                masterBarHeight: masterBarHeight,
                cachedMasterFooterCI: cachedMasterFooterCI,
                useHEVC: useHEVC,
                targetBitrate: targetBitrate,
                exportFPS: exportFPS,
                totalSeconds: totalSeconds,
                colorProperties: colorProperties,
                options: options,
                progressHandler: progressHandler
            )
        } catch {
            // Dự phòng an toàn nếu cấu hình P3/HEVC đặc biệt bị phần cứng từ chối -> thử H.264 Rec.709 cùng độ phân giải & bitrate cao
            CameraLogger.warning("HighFidelityVideoExporter: Thử lại với profile tương thích Rec.709 (\(error.localizedDescription))", category: .photoKit)
            try? FileManager.default.removeItem(at: outputURL)
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AlignMasterFB_\(UUID().uuidString).mov")
            return try await runReaderWriterPass(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                audioFormatHint: audioFormatHint,
                outputURL: fallbackURL,
                orientation: orientation,
                videoContentSize: videoContentSize,
                finalOutputSize: finalOutputSize,
                masterBarHeight: masterBarHeight,
                cachedMasterFooterCI: cachedMasterFooterCI,
                useHEVC: false,
                targetBitrate: targetBitrate,
                exportFPS: exportFPS,
                totalSeconds: totalSeconds,
                colorProperties: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                options: options,
                progressHandler: progressHandler
            )
        }
    }

    private static func runReaderWriterPass(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        audioFormatHint: CMFormatDescription?,
        outputURL: URL,
        orientation: CGImagePropertyOrientation,
        videoContentSize: CGSize,
        finalOutputSize: CGSize,
        masterBarHeight: CGFloat,
        cachedMasterFooterCI: CIImage?,
        useHEVC: Bool,
        targetBitrate: Int,
        exportFPS: Int,
        totalSeconds: Double,
        colorProperties: [String: Any],
        options: ExportOptions,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ExportError.cannotCreateReaderWriter(error.localizedDescription)
        }

        let readerVideoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotCreateReaderWriter("Không thể thêm AVAssetReaderTrackOutput video")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput? = nil
        var audioInput: AVAssetWriterInput? = nil
        if let aTrack = audioTrack {
            // Audio Passthrough 100% nguyên bản (không nén lại âm thanh!)
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            aOut.alwaysCopiesSampleData = false
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatHint)
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut) && writer.canAdd(aIn) {
                reader.add(aOut)
                writer.add(aIn)
                audioOutput = aOut
                audioInput = aIn
            }
        }

        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoExpectedSourceFrameRateKey: exportFPS,
            AVVideoMaxKeyFrameIntervalKey: exportFPS
        ]
        if !useHEVC {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(finalOutputSize.width),
            AVVideoHeightKey: Int(finalOutputSize.height),
            AVVideoCompressionPropertiesKey: compressionProps
        ]
        if !colorProperties.isEmpty {
            videoSettings[AVVideoColorPropertiesKey] = colorProperties
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.cannotCreateReaderWriter("Thiết bị từ chối cấu hình AVAssetWriterInput")
        }
        writer.add(videoInput)
        writer.shouldOptimizeForNetworkUse = true

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(finalOutputSize.width),
            kCVPixelBufferHeightKey as String: Int(finalOutputSize.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        guard reader.startReading() else {
            throw ExportError.writerFailed(reader.error?.localizedDescription ?? "Không đọc được file video")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Không khởi tạo được tiến trình ghi")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = Self.gpuContext
        let renderBounds = CGRect(origin: .zero, size: finalOutputSize)
        let colorSpace = (colorProperties[AVVideoColorPrimariesKey] as? String) == AVVideoColorPrimaries_P3_D65
            ? (CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB())
            : (CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB())

        // Chạy đồng thời 2 luồng video & audio trên serial queue riêng (không chặn MainActor)
        let videoQueue = DispatchQueue(label: "com.aismartframing.exporter.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.aismartframing.exporter.audio", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let errorLock = NSLock()
            var capturedError: Error? = nil

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    var shouldBreak = false
                    autoreleasepool {
                        guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                            videoInput.markAsFinished()
                            shouldBreak = true
                            group.leave()
                            return
                        }

                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        guard let srcPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                              let pool = adaptor.pixelBufferPool else {
                            return
                        }

                        var dstPixelBuffer: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstPixelBuffer)
                        guard status == kCVReturnSuccess, let outBuffer = dstPixelBuffer else {
                            return
                        }

                        let frameTime = max(0.0, pts.seconds.isFinite ? pts.seconds : 0.0)
                        let composedCI = Self.processFrame(
                            pixelBuffer: srcPixelBuffer,
                            orientation: orientation,
                            frameTime: frameTime,
                            videoContentSize: videoContentSize,
                            finalOutputSize: finalOutputSize,
                            masterBarHeight: masterBarHeight,
                            cachedMasterFooterCI: cachedMasterFooterCI,
                            exportFPS: exportFPS,
                            options: options
                        )

                        ciContext.render(
                            composedCI,
                            to: outBuffer,
                            bounds: renderBounds,
                            colorSpace: colorSpace
                        )

                        if !adaptor.append(outBuffer, withPresentationTime: pts) {
                            errorLock.lock()
                            if capturedError == nil {
                                capturedError = writer.error ?? ExportError.writerFailed("Không ghi được frame video")
                            }
                            errorLock.unlock()
                            videoInput.markAsFinished()
                            shouldBreak = true
                            group.leave()
                            return
                        }

                        let progress = min(0.98, max(0.02, frameTime / totalSeconds))
                        progressHandler(progress)
                    }
                    if shouldBreak { break }
                }
            }

            if let aOut = audioOutput, let aIn = audioInput {
                group.enter()
                aIn.requestMediaDataWhenReady(on: audioQueue) {
                    while aIn.isReadyForMoreMediaData {
                        guard let audioSample = aOut.copyNextSampleBuffer() else {
                            aIn.markAsFinished()
                            group.leave()
                            return
                        }
                        if !aIn.append(audioSample) {
                            aIn.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                errorLock.lock()
                let err = capturedError
                errorLock.unlock()

                if let err = err {
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(throwing: err)
                    return
                }

                if reader.status == .failed {
                    writer.cancelWriting()
                    continuation.resume(throwing: ExportError.writerFailed(reader.error?.localizedDescription ?? "Lỗi đọc video"))
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        progressHandler(1.0)
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ExportError.writerFailed(writer.error?.localizedDescription ?? "Lỗi hoàn tất file video"))
                    }
                }
            }
        }

        return outputURL
    }

    private static func processFrame(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        frameTime: Double,
        videoContentSize: CGSize,
        finalOutputSize: CGSize,
        masterBarHeight: CGFloat,
        cachedMasterFooterCI: CIImage?,
        exportFPS: Int,
        options: ExportOptions
    ) -> CIImage {
        let rawOriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let origExtent = rawOriented.extent
        let normalizedSource = rawOriented
            .transformed(by: CGAffineTransform(translationX: -origExtent.origin.x, y: -origExtent.origin.y))
        let clampedSource = normalizedSource.clampedToExtent()

        var contentImage: CIImage

        // 1. Cắt Windowed Zoom mượt mà theo Hermite Keyframes (nếu có)
        if options.applyWindowCrop {
            let state = CameraViewModel.interpolateKeyframe(
                at: frameTime,
                keyframes: options.recordedKeyframes,
                fallback: options.fallbackKeyframe
            )
            let fractions = state.aspectRatio.windowFractions(
                focalLength: state.focalLength,
                baseOpticalZoom: state.baseOpticalZoom,
                containerAspect: origExtent.width / max(1.0, origExtent.height)
            )
            let cropW = max(2.0, origExtent.width * fractions.widthFraction)
            let cropH = max(2.0, origExtent.height * fractions.heightFraction)
            let normCenter = state.normalizedCenter

            let ciCenterX = origExtent.width * normCenter.x
            let ciCenterY = origExtent.height * (1.0 - normCenter.y)
            let minCIX = cropW / 2.0
            let maxCIX = origExtent.width - cropW / 2.0
            let minCIY = cropH / 2.0
            let maxCIY = origExtent.height - cropH / 2.0
            let cropX = max(minCIX, min(ciCenterX, maxCIX)) - cropW / 2.0
            let cropY = max(minCIY, min(ciCenterY, maxCIY)) - cropH / 2.0

            let cropped = clampedSource.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
            let translated = cropped.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

            let uniformScale = max(videoContentSize.width / max(1.0, cropW), videoContentSize.height / max(1.0, cropH))
            let scaled = translated.transformed(by: CGAffineTransform(scaleX: uniformScale, y: uniformScale))
            let offsetX = (videoContentSize.width - cropW * uniformScale) / 2.0
            let offsetY = (videoContentSize.height - cropH * uniformScale) / 2.0

            contentImage = scaled
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: CGRect(origin: .zero, size: videoContentSize))

            if uniformScale > 1.02, let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(contentImage, forKey: kCIInputImageKey)
                sharpen.setValue(min(0.35, 0.14 + Float(uniformScale - 1.0) * 0.08), forKey: kCIInputSharpnessKey)
                if let sharpened = sharpen.outputImage {
                    contentImage = sharpened.cropped(to: CGRect(origin: .zero, size: videoContentSize))
                }
            }
        } else {
            contentImage = normalizedSource.cropped(to: CGRect(origin: .zero, size: videoContentSize))
        }

        // 2. Áp bộ lọc màu Film / AI (chỉ khi người dùng bấm Chỉnh màu)
        if options.applyColorGrading {
            if options.filterPreset != .standard,
               let filtered = FilmFilterEngine.shared.applyPreset(to: contentImage, preset: options.filterPreset) {
                contentImage = filtered.cropped(to: CGRect(origin: .zero, size: videoContentSize))
            }
            if let aiParams = options.aiColorParams,
               let aiFiltered = FilmFilterEngine.shared.applyAIColorParameters(to: contentImage, params: aiParams) {
                contentImage = aiFiltered.cropped(to: CGRect(origin: .zero, size: videoContentSize))
            }
        }

        // 3. Ghép Khung Master (mở rộng phía dưới KHÔNG cắt xén 1 pixel gốc) hoặc Cinema Frame
        if options.infoFrameStyle == .masterFrame, let footerCI = cachedMasterFooterCI {
            // CoreImage có gốc Y ở cạnh dưới: footer nằm ở y = 0...masterBarHeight, video nằm ở y = masterBarHeight...H+masterBarHeight
            let liftedVideo = contentImage.transformed(by: CGAffineTransform(translationX: 0, y: masterBarHeight))
            return liftedVideo
                .composited(over: footerCI)
                .cropped(to: CGRect(origin: .zero, size: finalOutputSize))
        } else if options.infoFrameStyle != .off && options.infoFrameStyle != .masterFrame {
            let totalFrames = Int(frameTime * Double(exportFPS))
            let tcSec = Int(frameTime) % 60
            let tcMin = (Int(frameTime) / 60) % 60
            let tcHour = Int(frameTime) / 3600
            let subFrame = totalFrames % max(1, exportFPS)
            let timecode = String(format: "%02d:%02d:%02d:%02d", tcHour, tcMin, tcSec, subFrame)

            let currentFocal = options.applyWindowCrop
                ? Int(CameraViewModel.interpolateKeyframe(
                    at: frameTime,
                    keyframes: options.recordedKeyframes,
                    fallback: options.fallbackKeyframe
                ).focalLength)
                : 24
            let metadata = VideoFrameMetadata(
                deviceName: options.masterFrameConfig.deviceName,
                lensDescription: "\(currentFocal)mm OPTICAL",
                focalLengthMM: currentFocal,
                aperture: options.liveAperture,
                shutterSpeed: options.liveShutterText,
                iso: options.liveISOValue,
                fps: exportFPS,
                resolutionTag: "\(Int(videoContentSize.width))x\(Int(videoContentSize.height))",
                lutName: options.filterPreset.rawValue.uppercased(),
                dateString: "",
                timecode: timecode
            )
            return VideoInfoFrameCompositor.shared.composite(
                frame: contentImage,
                metadata: metadata,
                style: options.infoFrameStyle
            ).cropped(to: CGRect(origin: .zero, size: finalOutputSize))
        }

        return contentImage.cropped(to: CGRect(origin: .zero, size: finalOutputSize))
    }

    private static func detectColorProperties(from track: AVAssetTrack) async -> [String: Any] {
        guard let desc = try? await track.load(.formatDescriptions).first else {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let primariesRaw = ext?[kCVImageBufferColorPrimariesKey as String] as? String
        if primariesRaw == (kCVImageBufferColorPrimaries_P3_D65 as String) {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    public static func cgImageOrientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a, b = t.b, c = t.c, d = t.d
        if a == 0 && b == 1 && c == -1 && d == 0 { return .right }
        if a == 0 && b == -1 && c == 1 && d == 0 { return .left }
        if a == -1 && b == 0 && c == 0 && d == -1 { return .down }
        if a == 1 && b == 0 && c == 0 && d == 1 { return .up }
        if a == 0 && b == 1 && c == 1 && d == 0 { return .rightMirrored }
        if a == 0 && b == -1 && c == -1 && d == 0 { return .leftMirrored }
        if a == -1 && b == 0 && c == 0 && d == 1 { return .upMirrored }
        if a == 1 && b == 0 && c == 0 && d == -1 { return .downMirrored }
        // Fallback bằng góc xoay liên tục
        let angle = atan2(b, a)
        let deg = angle * 180.0 / .pi
        if deg > 45 && deg <= 135 { return .right }
        if deg < -45 && deg >= -135 { return .left }
        if abs(deg) > 135 { return .down }
        return .up
    }

    public static func computeTargetRenderSize(sourceSize: CGSize, aspect: WindowedZoomAspectRatio) -> CGSize {
        let origW = sourceSize.width
        let origH = sourceSize.height
        let isPortrait = origW <= origH

        let targetW: CGFloat
        let targetH: CGFloat
        switch aspect {
        case .ratio1_1:
            let side = min(origW, origH)
            targetW = side
            targetH = side
        case .ratio3_4:
            if isPortrait {
                let h = origH
                let w = round(h * 3.0 / 4.0)
                if w <= origW { targetW = w; targetH = h }
                else { targetW = origW; targetH = round(origW * 4.0 / 3.0) }
            } else {
                let w = origW
                let h = round(w * 3.0 / 4.0)
                if h <= origH { targetW = w; targetH = h }
                else { targetH = origH; targetW = round(origH * 4.0 / 3.0) }
            }
        case .ratio16_9:
            if isPortrait {
                let h = origH
                let w = round(h * 9.0 / 16.0)
                if w <= origW { targetW = w; targetH = h }
                else { targetW = origW; targetH = round(origW * 16.0 / 9.0) }
            } else {
                let w = origW
                let h = round(w * 9.0 / 16.0)
                if h <= origH { targetW = w; targetH = h }
                else { targetH = origH; targetW = round(origH * 16.0 / 9.0) }
            }
        }
        let evenW = CGFloat(Int(targetW) & ~1)
        let evenH = CGFloat(Int(targetH) & ~1)
        return CGSize(width: max(2, evenW), height: max(2, evenH))
    }
}
