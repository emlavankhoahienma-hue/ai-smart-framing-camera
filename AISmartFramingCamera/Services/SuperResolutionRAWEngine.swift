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

/// Động cơ Siêu Phân Giải Đa Khung RAW 14-bit (Handheld Super-Resolution Multi-Frame RAW Fusion)
/// Thực thi toàn bộ chuỗi thuật toán 6 tầng hoàn toàn trên Apple Metal GPU:
/// 1. Tầng Thu Nhận (Ingress): Burst 8-12 frame RAW + IMU CoreMotion 60Hz.
/// 2. Tầng Khung Neo (Anchor Selection): Gradient Energy trên kênh Green để chọn frame nét nhất.
/// 3. Tầng Căn Chỉnh Vi Mô & De-ghosting: So khớp phân cấp dưới pixel (0.1px) + triệt tiêu bóng ma chuyển động.
/// 4. Tầng Tích Tụ Hạt Nhân (Kernel Splatting / Drizzle 2x): Tích lũy photon thật vào lưới 48MP không đoán mò.
/// 5. Tầng Bảo Toàn Màu Sắc Apple: Chuẩn hóa ISP AsShotNeutral & ColorMatrix sang Apple Display P3.
/// 6. Tầng Tối Ưu Chi Tiết (Zero-Mushiness): Khuếch đại vi tương phản cục bộ, triệt tiêu bệt màu nước.
public final class SuperResolutionRAWEngine: @unchecked Sendable {
    public static let shared = SuperResolutionRAWEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let shaders = SuperResolutionMetalShaders.shared
    private let ciContext: CIContext

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

    /// Xử lý danh sách frame RAW và trả về ảnh siêu nét 48MP Display P3
    public func processBurst(
        frames: [SuperResolutionInputFrame],
        progress: @escaping (Float, String) -> Void
    ) async throws -> CGImage {
        guard !frames.isEmpty else {
            throw NSError(domain: "SuperResolutionRAWEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không có frame RAW đầu vào"])
        }

        // Nếu chỉ có 1 frame hoặc phần cứng không hỗ trợ Metal, fallback hiển thị trực tiếp
        guard frames.count > 1, let device = self.device, let commandQueue = self.commandQueue else {
            CameraLogger.warning("Super-Res: Frame count < 2 hoặc Metal không khả dụng, dùng fallback frame 0", category: .ai)
            return try extractCGImage(from: frames[0])
        }

        progress(0.10, "Đang nạp dữ liệu cảm biến...")

        // TẦNG 1: Chuyển đổi Frame sang Metal Texture
        var textures: [MTLTexture] = []
        for frame in frames {
            if let tex = makeTexture(from: frame, device: device) {
                textures.append(tex)
            }
        }

        guard textures.count >= 2 else {
            CameraLogger.warning("Không thể tạo đủ texture từ các frame RAW, fallback frame 0", category: .ai)
            return try extractCGImage(from: frames[0])
        }

        let baseWidth = textures[0].width
        let baseHeight = textures[0].height

        // Kiểm tra dung lượng RAM thiết bị để tối ưu kích thước lưới (2x cho máy >= 4GB, 1.5x cho máy 2-3GB)
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let scale: Float = (totalRAM >= 3_500_000_000) ? 2.0 : 1.5
        let targetWidth = Int(Float(baseWidth) * scale)
        let targetHeight = Int(Float(baseHeight) * scale)

        progress(0.25, "Đang chọn Khung Neo nét nhất...")

        // TẦNG 2: Chọn Khung Neo (Anchor Selection) dựa trên Gradient Energy kênh Green
        let anchorIndex = await selectAnchorFrame(textures: textures, device: device, commandQueue: commandQueue)
        let anchorTexture = textures[anchorIndex]
        let anchorFrame = frames[min(anchorIndex, frames.count - 1)]

        CameraLogger.info("Super-Res: Đã chọn Khung Neo #\(anchorIndex) (Độ phân giải nguồn: \(baseWidth)x\(baseHeight))", category: .ai)

        progress(0.40, "Đang căn chỉnh vi mô & khử bóng ma...")

        // TẦNG 3 & 4: Khởi tạo Texture tích tụ 2x (Ping-Pong Accumulators)
        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        accumDesc.usage = [MTLTextureUsage.shaderRead, MTLTextureUsage.shaderWrite]
        accumDesc.storageMode = MTLStorageMode.private

        guard var accumTextureA = device.makeTexture(descriptor: accumDesc),
              var accumTextureB = device.makeTexture(descriptor: accumDesc),
              var weightTextureA = device.makeTexture(descriptor: accumDesc),
              var weightTextureB = device.makeTexture(descriptor: accumDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        // Texture trung gian cho Motion Vectors & Deghost Weights
        let mvDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: baseWidth,
            height: baseHeight,
            mipmapped: false
        )
        mvDesc.usage = [MTLTextureUsage.shaderRead, MTLTextureUsage.shaderWrite]
        mvDesc.storageMode = MTLStorageMode.private
        guard let motionVectorTex = device.makeTexture(descriptor: mvDesc),
              let deghostWeightTex = device.makeTexture(descriptor: mvDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        // Tích tụ từng frame vào lưới siêu phân giải
        let totalCount = textures.count
        for i in 0..<totalCount {
            let candidateTex = textures[i]
            let candidateFrame = frames[min(i, frames.count - 1)]

            // Tính toán IMU Prior Offset giữa Anchor Frame và Candidate Frame
            let imuPrior = computeIMUPriorOffset(
                anchor: anchorFrame.imuPose,
                candidate: candidateFrame.imuPose,
                sensorWidth: baseWidth
            )

            guard let cmdBuffer = commandQueue.makeCommandBuffer() else { continue }

            // 3a. Sub-pixel Alignment (0.1px precision)
            if let alignPipeline = shaders.subpixelAlignPipeline,
               let encoder = cmdBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(alignPipeline)
                encoder.setTexture(anchorTexture, index: 0)
                encoder.setTexture(candidateTex, index: 1)
                encoder.setTexture(motionVectorTex, index: 2)
                var prior = imuPrior
                encoder.setBytes(&prior, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)

                let w = alignPipeline.threadExecutionWidth
                let h = alignPipeline.maxTotalThreadsPerThreadgroup / w
                let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
                let threadsPerGrid = MTLSize(width: baseWidth, height: baseHeight, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // 3b. Motion De-Ghosting Weights (khử vùng chuyển động của ô tô, người đi bộ, lá cây)
            if let deghostPipeline = shaders.deghostWeightsPipeline,
               let encoder = cmdBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(deghostPipeline)
                encoder.setTexture(anchorTexture, index: 0)
                encoder.setTexture(candidateTex, index: 1)
                encoder.setTexture(motionVectorTex, index: 2)
                encoder.setTexture(deghostWeightTex, index: 3)

                let w = deghostPipeline.threadExecutionWidth
                let h = deghostPipeline.maxTotalThreadsPerThreadgroup / w
                let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
                let threadsPerGrid = MTLSize(width: baseWidth, height: baseHeight, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // 4. Kernel Splatting / Drizzle 2x Gather
            if let splatPipeline = shaders.kernelSplatting2xPipeline,
               let encoder = cmdBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(splatPipeline)
                encoder.setTexture(anchorTexture, index: 0)
                encoder.setTexture(candidateTex, index: 1)
                encoder.setTexture(motionVectorTex, index: 2)
                encoder.setTexture(deghostWeightTex, index: 3)
                encoder.setTexture(accumTextureA, index: 4)
                encoder.setTexture(weightTextureA, index: 5)
                encoder.setTexture(accumTextureB, index: 6)
                encoder.setTexture(weightTextureB, index: 7)

                let w = splatPipeline.threadExecutionWidth
                let h = splatPipeline.maxTotalThreadsPerThreadgroup / w
                let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
                let threadsPerGrid = MTLSize(width: targetWidth, height: targetHeight, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            await withCheckedContinuation { continuation in
                cmdBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                cmdBuffer.commit()
            }

            // Ping-pong hoán đổi textures
            swap(&accumTextureA, &accumTextureB)
            swap(&weightTextureA, &weightTextureB)

            let p = 0.40 + Float(i + 1) / Float(totalCount) * 0.35
            progress(p, "Đang tích tụ hạt photon \(i + 1)/\(totalCount)...")
        }

        progress(0.80, "Đang cân chỉnh màu Apple Display P3...")

        // TẦNG 5: Apple Color Calibration & Display P3 Transform
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        outDesc.usage = [MTLTextureUsage.shaderRead, MTLTextureUsage.shaderWrite]
        outDesc.storageMode = MTLStorageMode.shared

        guard let p3Texture = device.makeTexture(descriptor: outDesc),
              let finalTexture = device.makeTexture(descriptor: outDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        var calibParams = parseAppleCalibration(from: anchorFrame)

        guard let colorCmd = commandQueue.makeCommandBuffer() else {
            return try extractCGImage(from: anchorFrame)
        }

        if let p3Pipeline = shaders.appleP3ColorTransformPipeline,
           let encoder = colorCmd.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(p3Pipeline)
            encoder.setTexture(accumTextureA, index: 0)
            encoder.setTexture(weightTextureA, index: 1)
            encoder.setTexture(p3Texture, index: 2)
            encoder.setBytes(&calibParams, length: MemoryLayout<CameraCalibrationParams>.stride, index: 0)

            let w = p3Pipeline.threadExecutionWidth
            let h = p3Pipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
            let threadsPerGrid = MTLSize(width: targetWidth, height: targetHeight, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        progress(0.92, "Đang tối ưu độ sắc nét vi mô (Zero-Mushiness)...")

        // TẦNG 6: Zero-Mushiness Micro-Contrast Enhancement
        if let microPipeline = shaders.microContrastPipeline,
           let encoder = colorCmd.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(microPipeline)
            encoder.setTexture(p3Texture, index: 0)
            encoder.setTexture(finalTexture, index: 1)
            var factor: Float = 0.22
            encoder.setBytes(&factor, length: MemoryLayout<Float>.stride, index: 0)

            let w = microPipeline.threadExecutionWidth
            let h = microPipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
            let threadsPerGrid = MTLSize(width: targetWidth, height: targetHeight, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        await withCheckedContinuation { continuation in
            colorCmd.addCompletedHandler { _ in
                continuation.resume()
            }
            colorCmd.commit()
        }

        progress(0.98, "Đang tạo ảnh thành phẩm 48MP...")

        // Xuất CGImage Display P3
        let resultCG = makeCGImage(from: finalTexture, orientation: anchorFrame.orientation)
        progress(1.0, "Hoàn tất")
        return resultCG ?? (try extractCGImage(from: anchorFrame))
    }

    // MARK: - Private Helpers

    /// Chọn Frame nét nhất dựa trên tổng năng lượng độ dốc kênh Green
    private func selectAnchorFrame(
        textures: [MTLTexture],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) async -> Int {
        guard let pipeline = shaders.gradientEnergyPipeline else { return 0 }

        var bestIndex = 0
        var maxEnergy: Float = -1.0

        for (idx, tex) in textures.enumerated() {
            let width = tex.width
            let height = tex.height

            let w = 16
            let h = 16
            let numGroupsX = (width + w - 1) / w
            let numGroupsY = (height + h - 1) / h
            let totalGroups = numGroupsX * numGroupsY

            guard let energyBuffer = device.makeBuffer(length: totalGroups * MemoryLayout<Float>.stride, options: .storageModeShared),
                  let cmd = commandQueue.makeCommandBuffer(),
                  let encoder = cmd.makeComputeCommandEncoder() else {
                continue
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(tex, index: 0)
            encoder.setBuffer(energyBuffer, offset: 0, index: 0)

            let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(width: numGroupsX, height: numGroupsY, depth: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()

            await withCheckedContinuation { continuation in
                cmd.addCompletedHandler { _ in
                    continuation.resume()
                }
                cmd.commit()
            }

            let rawPtr = energyBuffer.contents().bindMemory(to: Float.self, capacity: totalGroups)
            var sum: Float = 0.0
            for i in 0..<totalGroups {
                let val = rawPtr[i]
                if val.isFinite { sum += val }
            }

            if sum > maxEnergy {
                maxEnergy = sum
                bestIndex = idx
            }
        }

        return bestIndex
    }

    /// Tính vector dịch chuyển dựa trên con quay hồi chuyển CoreMotion
    private func computeIMUPriorOffset(
        anchor: simd_quatd?,
        candidate: simd_quatd?,
        sensorWidth: Int
    ) -> SIMD2<Float> {
        guard let qAnchor = anchor, let qCand = candidate else {
            return SIMD2<Float>(0, 0)
        }

        let deltaQ = simd_mul(simd_inverse(qAnchor), qCand)
        let pitch = Float(2.0 * (deltaQ.real * deltaQ.imag.x - deltaQ.imag.y * deltaQ.imag.z))
        let yaw   = Float(2.0 * (deltaQ.real * deltaQ.imag.y + deltaQ.imag.z * deltaQ.imag.x))

        // Hệ số tiêu cự chuẩn cho cảm biến góc rộng iPhone (~3000px)
        let focal = Float(sensorWidth) * 0.75
        let dx = -yaw * focal
        let dy = pitch * focal

        // Giới hạn biên an toàn 12 pixel cho rung lắc tự nhiên của tay
        let clampedX = max(-12.0, min(12.0, dx))
        let clampedY = max(-12.0, min(12.0, dy))

        return SIMD2<Float>(clampedX, clampedY)
    }

    /// Trích xuất hoặc giải lập tham số màu sắc chuẩn Apple Display P3 từ ISP
    private func parseAppleCalibration(from frame: SuperResolutionInputFrame) -> CameraCalibrationParams {
        var asShot = SIMD4<Float>(2.08, 1.0, 1.61, 1.0)
        var blackLevel: Float = 0.0
        var whiteLevel: Float = 1.0

        if let meta = frame.metadata {
            if let dngDict = meta["{DNG}"] as? [String: Any] {
                if let neutral = dngDict["AsShotNeutral"] as? [Double], neutral.count >= 3 {
                    let r = Float(neutral[0] > 0 ? (1.0 / neutral[0]) : 2.08)
                    let g = Float(neutral[1] > 0 ? (1.0 / neutral[1]) : 1.0)
                    let b = Float(neutral[2] > 0 ? (1.0 / neutral[2]) : 1.61)
                    asShot = SIMD4<Float>(r, g, b, 1.0)
                }
                if let bl = dngDict["BlackLevel"] as? Double {
                    blackLevel = Float(bl / 16383.0)
                }
                if let wl = dngDict["WhiteLevel"] as? Double {
                    whiteLevel = Float(wl / 16383.0)
                }
            }
        }

        // Ma trận chuyển đổi màu cảm biến Apple Sensor RGB -> Display P3 (D65)
        let colorMatrix = simd_float4x4(
            SIMD4<Float>( 1.654, -0.582, -0.072, 0.0),
            SIMD4<Float>(-0.210,  1.325, -0.115, 0.0),
            SIMD4<Float>( 0.035, -0.320,  1.285, 0.0),
            SIMD4<Float>( 0.0,    0.0,    0.0,   1.0)
        )

        return CameraCalibrationParams(
            asShotNeutral: asShot,
            levelsAndFactor: SIMD4<Float>(blackLevel, max(whiteLevel, 0.1), 0.22, 0.0),
            colorMatrixP3: colorMatrix
        )
    }

    /// Chuyển đổi SuperResolutionInputFrame sang MTLTexture
    private func makeTexture(from frame: SuperResolutionInputFrame, device: MTLDevice) -> MTLTexture? {
        if let pb = frame.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

            let width = CVPixelBufferGetWidth(pb)
            let height = CVPixelBufferGetHeight(pb)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

            guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return nil }

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = MTLTextureUsage.shaderRead
            desc.storageMode = MTLStorageMode.shared

            guard let texture = device.makeTexture(descriptor: desc) else { return nil }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddr,
                bytesPerRow: bytesPerRow
            )
            return texture
        }

        if let data = frame.rawData, let img = UIImage(data: data)?.cgImage {
            let width = img.width
            let height = img.height

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = MTLTextureUsage.shaderRead
            desc.storageMode = MTLStorageMode.shared

            guard let texture = device.makeTexture(descriptor: desc) else { return nil }

            let colorSpace = CGColorSpaceCreateDeviceGray()
            var rawData = [UInt16](repeating: 0, count: width * height)
            if let ctx = CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 2,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: rawData,
                    bytesPerRow: width * 2
                )
                return texture
            }
        }

        return nil
    }

    /// Xuất MTLTexture thành CGImage có ColorSpace Display P3
    private func makeCGImage(from texture: MTLTexture, orientation: CGImagePropertyOrientation) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var rawBytes = [UInt8](repeating: 0, count: width * height * 4)

        texture.getBytes(
            &rawBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let ctx = CGContext(
            data: &rawBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cg = ctx.makeImage() else {
            return nil
        }

        return cg
    }

    /// Trích xuất CGImage từ frame gốc trong trường hợp fallback
    private func extractCGImage(from frame: SuperResolutionInputFrame) throws -> CGImage {
        if let pb = frame.pixelBuffer {
            let ci = CIImage(cvPixelBuffer: pb).oriented(frame.orientation)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                return cg
            }
        }
        if let data = frame.rawData, let uiImage = UIImage(data: data), let cg = uiImage.cgImage {
            return cg
        }
        throw NSError(domain: "SuperResolutionRAWEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Không thể trích xuất CGImage từ frame"])
    }
}
