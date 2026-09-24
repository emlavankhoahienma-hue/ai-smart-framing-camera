import Foundation
import Metal
import CoreGraphics
import CoreVideo
import ImageIO
import simd
import UIKit

/// Cấu trúc chứa dữ liệu một khung hình RAW 14-bit kèm con quay hồi chuyển CoreMotion
public struct SuperResolutionInputFrame: @unchecked Sendable {
    public let index: Int
    public let timestamp: TimeInterval
    public let pixelBuffer: CVPixelBuffer?
    public let rawData: Data?
    public let orientation: CGImagePropertyOrientation
    public let imuPose: simd_quatd?
    public let iso: Float
    public let shutterSpeed: Double
    public let metadata: [String: Any]?

    public init(
        index: Int,
        timestamp: TimeInterval,
        pixelBuffer: CVPixelBuffer?,
        rawData: Data?,
        orientation: CGImagePropertyOrientation = .up,
        imuPose: simd_quatd?,
        iso: Float = 100,
        shutterSpeed: Double = 1.0 / 125.0,
        metadata: [String: Any]? = nil
    ) {
        self.index = index
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
        self.rawData = rawData
        self.orientation = orientation
        self.imuPose = imuPose
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.metadata = metadata
    }
}

/// Tham số cân chỉnh màu sắc và dải động cho cảm biến Apple Display P3
public struct CameraCalibrationParams {
    public var asShotNeutral: SIMD4<Float>
    public var levelsAndFactor: SIMD4<Float>
    public var colorMatrixP3: simd_float4x4

    public init(
        asShotNeutral: SIMD4<Float>,
        levelsAndFactor: SIMD4<Float>,
        colorMatrixP3: simd_float4x4
    ) {
        self.asShotNeutral = asShotNeutral
        self.levelsAndFactor = levelsAndFactor
        self.colorMatrixP3 = colorMatrixP3
    }

    public init(
        asShotNeutral: SIMD4<Float> = SIMD4<Float>(2.08, 1.0, 1.61, 1.0),
        blackLevel: Float = 512.0 / 16383.0,
        whiteLevel: Float = 1.0,
        microContrastFactor: Float = 0.22,
        colorMatrixP3: simd_float4x4 = simd_float4x4(
            SIMD4<Float>( 1.654, -0.582, -0.072, 0.0),
            SIMD4<Float>(-0.210,  1.325, -0.115, 0.0),
            SIMD4<Float>( 0.035, -0.320,  1.285, 0.0),
            SIMD4<Float>( 0.0,    0.0,    0.0,   1.0)
        )
    ) {
        self.asShotNeutral = asShotNeutral
        self.levelsAndFactor = SIMD4<Float>(blackLevel, whiteLevel, microContrastFactor, 0.0)
        self.colorMatrixP3 = colorMatrixP3
    }
}

/// Multi-frame reconstruction from RAW frames rendered by Core Image into
/// Display P3. Metal registers, rejects moving regions and gathers their
/// distinct subpixel samples. Actual detail depends on motion diversity,
/// lens resolution and the device's available memory.
public final class SuperResolutionRAWEngine: @unchecked Sendable {
    public static let shared = SuperResolutionRAWEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let shaders = SuperResolutionMetalShaders.shared
    public let ciContext: CIContext

    private init() {
        if let dev = MTLCreateSystemDefaultDevice() {
            self.device = dev
            self.commandQueue = dev.makeCommandQueue()
            self.ciContext = CIContext(mtlDevice: dev, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false
            ])
        } else {
            self.device = nil
            self.commandQueue = nil
            self.ciContext = CIContext(options: nil)
        }
        shaders.prepare()
    }

    /// Giải mã an toàn 1 frame bất kỳ sang CGImage chuẩn Apple Display P3
    public static func decodeFrameToCGImage(frame: SuperResolutionInputFrame, ciContext: CIContext) -> CGImage? {
        if let pb = frame.pixelBuffer {
            let ci = CIImage(cvPixelBuffer: pb).oriented(frame.orientation)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                return cg
            }
        }
        if let data = frame.rawData {
            // Decode with the camera's native RAW rendering and no extra EV gain.
            if let rawFilter = CIRAWFilter(imageData: data, identifierHint: nil) {
                // The RAW filter performs the camera profile, white balance and
                // its own tone rendering. Exposure is an extra adjustment in EV.
                rawFilter.exposure = 0
                if let outCI = rawFilter.outputImage {
                    let orientedCI = outCI.oriented(frame.orientation)
                    if let cg = ciContext.createCGImage(orientedCI, from: orientedCI.extent) {
                        return cg
                    }
                }
            }
            // 2. Thử decode qua ImageIO Camera RAW
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
                let thumbOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4032
                ] as CFDictionary
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) {
                    return cg
                }
            }
            // 3. Fallback CIImage trực tiếp
            if let ci = CIImage(data: data) {
                let orientedCI = ci.oriented(frame.orientation)
                if let cg = ciContext.createCGImage(orientedCI, from: orientedCI.extent) {
                    return cg
                }
            }
            // 4. Fallback UIImage cho JPEG/HEIC
            if let ui = UIImage(data: data), let cg = ui.cgImage {
                return cg
            }
        }
        return nil
    }

    /// Decode a burst with one candidate texture resident at a time. The
    /// decoded pixels use the camera's P3 rendering; Metal linearizes them
    /// before fusion and encodes them once on output.
    public func processBurst(
        frames: [SuperResolutionInputFrame],
        progress: @escaping (Float, String) -> Void
    ) async throws -> CGImage {
        guard let first = frames.first else {
            throw NSError(domain: "SuperResolutionRAWEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Không có frame RAW đầu vào"])
        }
        guard frames.count > 1, let device, let commandQueue,
              let alignPipeline = shaders.subpixelAlignPipeline,
              let gatherPipeline = shaders.fusionGatherPipeline,
              let normalizePipeline = shaders.normalizeTonePipeline else {
            return try extractCGImage(from: first)
        }

        progress(0.08, "Đang giải mã RAW và chọn khung neo...")
        var anchorIndex = 0
        var bestEnergy: Float = -.infinity
        var anchorTexture: MTLTexture?
        for (index, frame) in frames.enumerated() {
            guard let texture = makeTexture(from: frame, device: device) else { continue }
            if let old = anchorTexture,
               (texture.width != old.width || texture.height != old.height) {
                continue
            }
            let energy = await gradientEnergy(of: texture, device: device,
                                              commandQueue: commandQueue)
            if anchorTexture == nil || energy > bestEnergy {
                anchorIndex = index
                anchorTexture = texture
                bestEnergy = energy
            }
        }
        guard let anchorTexture else { return try extractCGImage(from: first) }
        let anchorFrame = frames[anchorIndex]
        let baseWidth = anchorTexture.width
        let baseHeight = anchorTexture.height
        let basePixels = baseWidth * baseHeight

        // The two 16-bit accumulators dominate memory. Include input, encoded
        // output, retained DNG data and a Core Image export allowance.
        let ram = ProcessInfo.processInfo.physicalMemory
        let ramScale: Double = ram >= 7_000_000_000 ? 2.0 :
                               (ram >= 5_000_000_000 ? 1.5 :
                               (ram >= 3_500_000_000 ? 1.25 : 1.0))
        let nativeLimit = sqrt(48_000_000.0 / Double(basePixels))
        var scale = max(1.0, min(ramScale, nativeLimit))
        let rawBytes = frames.reduce(0) { $0 + ($1.rawData?.count ?? 0) }
        let budget = min(Double(ram) * 0.20, 1_700_000_000)
        func predictedBytes(_ factor: Double) -> Double {
            let pixels = Double(basePixels) * factor * factor
            return pixels * 24 + Double(basePixels) * 12 +
                   Double(rawBytes) + 150_000_000
        }
        while scale > 1.0 && predictedBytes(scale) > budget {
            scale = scale > 1.5 ? 1.5 : (scale > 1.25 ? 1.25 : 1.0)
        }
        if predictedBytes(scale) > budget {
            CameraLogger.warning("Super-Res: insufficient memory budget; using decoded anchor", category: .ai)
            return try extractCGImage(from: anchorFrame)
        }
        let targetWidth = Int(Double(baseWidth) * scale)
        let targetHeight = Int(Double(baseHeight) * scale)
        guard targetWidth <= 8192, targetHeight <= 8192 else {
            return try extractCGImage(from: anchorFrame)
        }
        CameraLogger.info("Super-Res: anchor #\(anchorIndex), output \(targetWidth)x\(targetHeight), RAM estimate \(Int(predictedBytes(scale) / 1_000_000)) MB", category: .ai)

        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: targetWidth,
            height: targetHeight, mipmapped: false)
        accumDesc.usage = [.shaderRead, .shaderWrite]
        accumDesc.storageMode = .private
        guard var accumA = device.makeTexture(descriptor: accumDesc),
              var accumB = device.makeTexture(descriptor: accumDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        let blockSize = 16
        let gridWidth = (baseWidth + blockSize - 1) / blockSize
        let gridHeight = (baseHeight + blockSize - 1) / blockSize
        let motionDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: gridWidth,
            height: gridHeight, mipmapped: false)
        motionDesc.usage = [.shaderRead, .shaderWrite]
        motionDesc.storageMode = .private
        guard let motionTexture = device.makeTexture(descriptor: motionDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        var accepted = 0
        let order = [anchorIndex] + frames.indices.filter { $0 != anchorIndex }
        for index in order {
            let isAnchor = index == anchorIndex
            guard let candidate = isAnchor ? anchorTexture :
                    makeTexture(from: frames[index], device: device),
                  candidate.width == baseWidth, candidate.height == baseHeight,
                  let command = commandQueue.makeCommandBuffer() else { continue }

            if !isAnchor {
                guard let encoder = command.makeComputeCommandEncoder() else { continue }
                encoder.setComputePipelineState(alignPipeline)
                encoder.setTexture(anchorTexture, index: 0)
                encoder.setTexture(candidate, index: 1)
                encoder.setTexture(motionTexture, index: 2)
                var prior = computeIMUPriorOffset(
                    anchor: anchorFrame.imuPose,
                    candidate: frames[index].imuPose,
                    sensorWidth: baseWidth, sensorHeight: baseHeight)
                encoder.setBytes(&prior, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: gridWidth, height: gridHeight, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
            }
            guard let encoder = command.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(gatherPipeline)
            encoder.setTexture(anchorTexture, index: 0)
            encoder.setTexture(candidate, index: 1)
            encoder.setTexture(motionTexture, index: 2)
            encoder.setTexture(accumA, index: 3)
            encoder.setTexture(accumB, index: 4)
            var anchorFlag: Int32 = isAnchor ? 1 : 0
            encoder.setBytes(&anchorFlag, length: MemoryLayout<Int32>.stride, index: 0)
            let w = gatherPipeline.threadExecutionWidth
            let h = max(1, gatherPipeline.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreads(
                MTLSize(width: targetWidth, height: targetHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            encoder.endEncoding()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            if command.status != .completed {
                CameraLogger.warning("Super-Res: Metal fusion failed: \(String(describing: command.error))", category: .ai)
                return try extractCGImage(from: anchorFrame)
            }
            swap(&accumA, &accumB)
            accepted += 1
            progress(0.30 + Float(accepted) / Float(order.count) * 0.52,
                     "Đang ghép ảnh \(accepted)/\(order.count)...")
        }
        guard accepted > 0 else { return try extractCGImage(from: anchorFrame) }

        progress(0.86, "Đang hoàn tất màu Display P3...")
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: targetWidth,
            height: targetHeight, mipmapped: false)
        outputDesc.usage = [.shaderRead, .shaderWrite]
        outputDesc.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDesc),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            return try extractCGImage(from: anchorFrame)
        }
        encoder.setComputePipelineState(normalizePipeline)
        encoder.setTexture(accumA, index: 0)
        encoder.setTexture(anchorTexture, index: 1)
        encoder.setTexture(output, index: 2)
        let w = normalizePipeline.threadExecutionWidth
        let h = max(1, normalizePipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: targetWidth, height: targetHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        guard command.status == .completed,
              let result = makeCGImage(from: output) else {
            return try extractCGImage(from: anchorFrame)
        }
        progress(1.0, "Hoàn tất")
        return result
    }

    // MARK: - Private Helpers

    private func gradientEnergy(of texture: MTLTexture, device: MTLDevice,
                                commandQueue: MTLCommandQueue) async -> Float {
        guard let pipeline = shaders.gradientEnergyPipeline else { return 0 }
        let gx = (texture.width + 15) / 16
        let gy = (texture.height + 15) / 16
        let count = gx * gy
        guard let buffer = device.makeBuffer(
            length: count * MemoryLayout<Float>.stride, options: .storageModeShared),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return 0 }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: gx, height: gy, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        guard command.status == .completed else { return 0 }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: count)
        var energy: Float = 0
        for index in 0..<count where values[index].isFinite {
            energy += values[index]
        }
        return energy
    }

    /// The CoreMotion quaternion already fuses gyro and accelerometer data.
    /// Project the anchor's optical axis into the candidate camera to obtain
    /// a prior. Optical registration handles translation and residual drift.
    private func computeIMUPriorOffset(
        anchor: simd_quatd?, candidate: simd_quatd?,
        sensorWidth: Int, sensorHeight: Int
    ) -> SIMD2<Float> {
        guard let anchor, let candidate else { return .zero }
        let worldRay = anchor.act(SIMD3<Double>(0, 0, -1))
        let ray = candidate.inverse.act(worldRay)
        guard ray.z < -0.1, ray.x.isFinite, ray.y.isFinite else { return .zero }
        let aspect = Double(sensorWidth) / Double(sensorHeight)
        let k = TrackingCalibration.fallback(aspect: aspect)
        let x = k.fx * Double(sensorWidth) * ray.x / -ray.z
        let y = -k.fy * Double(sensorHeight) * ray.y / -ray.z
        guard x.isFinite, y.isFinite, abs(x) <= 64, abs(y) <= 64 else { return .zero }
        return SIMD2<Float>(Float(x), Float(y))
    }

    /// Chuyển đổi SuperResolutionInputFrame sang MTLTexture Display P3 thông qua CoreImage / ImageIO
    private func makeTexture(from frame: SuperResolutionInputFrame, device: MTLDevice) -> MTLTexture? {
        if let pb = frame.pixelBuffer {
            let ci = CIImage(cvPixelBuffer: pb).oriented(frame.orientation)
            return renderCIImageToTexture(ci, device: device)
        }

        if let data = frame.rawData {
            // Decode with the camera's native RAW rendering and no extra EV gain.
            if let rawFilter = CIRAWFilter(imageData: data, identifierHint: nil) {
                // The RAW filter performs the camera profile, white balance and
                // its own tone rendering. Exposure is an extra adjustment in EV.
                rawFilter.exposure = 0
                if let outCI = rawFilter.outputImage {
                    let orientedCI = outCI.oriented(frame.orientation)
                    if let tex = renderCIImageToTexture(orientedCI, device: device) {
                        return tex
                    }
                }
            }

            // 2. Thử giải mã qua CIImage trực tiếp
            if let ci = CIImage(data: data) {
                let orientedCI = ci.oriented(frame.orientation)
                if let tex = renderCIImageToTexture(orientedCI, device: device) {
                    return tex
                }
            }

            // 3. Thử giải mã qua ImageIO
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
                let thumbOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4032
                ] as CFDictionary
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) {
                    let ci = CIImage(cgImage: cg)
                    return renderCIImageToTexture(ci, device: device)
                }
            }

            // 4. Fallback UIImage cho JPEG/HEIC
            if let ui = UIImage(data: data), let cg = ui.cgImage {
                let ci = CIImage(cgImage: cg)
                return renderCIImageToTexture(ci, device: device)
            }
        }

        return nil
    }

    /// Render CIImage trực tiếp vào MTLTexture Display P3 trên GPU
    private func renderCIImageToTexture(_ ciImage: CIImage, device: MTLDevice) -> MTLTexture? {
        let extent = ciImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0, width <= 8192,
              height <= 8192 else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let normalized = ciImage.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y))
        ciContext.render(normalized, to: texture, commandBuffer: nil,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: colorSpace)
        return texture
    }

    /// Xuất MTLTexture thành CGImage có ColorSpace Display P3
    private func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Trích xuất CGImage từ frame gốc trong trường hợp fallback
    private func extractCGImage(from frame: SuperResolutionInputFrame) throws -> CGImage {
        if let cg = Self.decodeFrameToCGImage(frame: frame, ciContext: ciContext) {
            return cg
        }
        throw NSError(domain: "SuperResolutionRAWEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Không thể trích xuất CGImage từ frame"])
    }
}
