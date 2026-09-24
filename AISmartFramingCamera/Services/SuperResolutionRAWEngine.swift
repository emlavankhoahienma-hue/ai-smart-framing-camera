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

/// Động cơ Siêu Phân Giải Đa Khung RAW 14-bit (Handheld Super-Resolution Multi-Frame Fusion)
/// Thực thi toàn bộ chuỗi thuật toán 6 tầng hoàn toàn trên Apple Metal GPU:
/// 1. Tầng Thu Nhận & Giải Mã (Ingress & ISP Decode): Nạp chuỗi burst 8 frame RAW, giải mã trực tiếp bằng phần cứng Apple ISP sang Display P3.
/// 2. Tầng Khung Neo (Anchor Selection): Luminance Gradient Energy để chọn frame nét nhất làm tham chiếu chuẩn.
/// 3. Tầng Căn Chỉnh Vi Mô & De-ghosting (Sub-Pixel Align & Motion Weighting): So khớp theo IMU Prior + loại bỏ bóng ma chuyển động.
/// 4. Tầng Tích Tụ Siêu Phân Giải (High-Resolution Fusion Gather): Tích lũy photon thật từ đa khung hình vào lưới siêu phân giải 27MP - 48MP.
/// 5. Tầng Bảo Toàn Sắc Thái & Chuẩn Hóa (Normalize & Tone Preservation): Chuẩn hóa trọng số, bảo toàn 100% màu sắc Apple P3 chuẩn mực.
/// 6. Tầng Tối Ưu Chi Tiết Vi Mô (Zero-Mushiness Micro-Contrast): Khuếch đại vi tương phản tần số cao, triệt tiêu bệt nhòe.
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
            // 1. Thử decode qua CoreImage Camera RAW Engine (chuẩn màu Apple Display P3)
            if let ci = CIImage(data: data) {
                let orientedCI = ci.oriented(frame.orientation)
                if let cg = ciContext.createCGImage(orientedCI, from: orientedCI.extent) {
                    return cg
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
            // 3. Fallback UIImage cho JPEG/HEIC
            if let ui = UIImage(data: data), let cg = ui.cgImage {
                return cg
            }
        }
        return nil
    }

    /// Xử lý danh sách frame RAW và trả về ảnh siêu nét 27MP / 48MP Display P3
    public func processBurst(
        frames: [SuperResolutionInputFrame],
        progress: @escaping (Float, String) -> Void
    ) async throws -> CGImage {
        guard !frames.isEmpty else {
            throw NSError(domain: "SuperResolutionRAWEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không có frame RAW đầu vào"])
        }

        // Nếu chỉ có 1 frame hoặc không có Metal, fallback giải mã ngay frame 0
        guard frames.count > 1, let device = self.device, let commandQueue = self.commandQueue else {
            CameraLogger.warning("Super-Res: Frame count < 2 hoặc Metal không khả dụng, dùng fallback frame 0", category: .ai)
            return try extractCGImage(from: frames[0])
        }

        progress(0.10, "Đang nạp dữ liệu cảm biến...")

        // TẦNG 1: Chuyển đổi Frame sang Metal Texture với chuẩn màu Apple Display P3
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

        // Kiểm tra dung lượng RAM thiết bị để tối ưu kích thước lưới
        // iPhone 15 Pro / 16 Pro (8GB RAM): scale 2.0x (48.8MP)
        // iPhone 12 / 13 / 14 / 15 thường (4GB - 6GB RAM): scale 1.5x (27.4MP, chi tiết gấp đôi 12MP, an toàn tuyệt đối)
        // iPhone cũ <= 3GB RAM: scale 1.25x (19.0MP)
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let scale: Float
        if totalRAM >= 7_000_000_000 {
            scale = 2.0 // 48.7 MP
        } else if totalRAM >= 3_500_000_000 {
            scale = 1.5 // 27.4 MP
        } else {
            scale = 1.25 // 19.0 MP
        }
        let targetWidth = Int(Float(baseWidth) * scale)
        let targetHeight = Int(Float(baseHeight) * scale)

        progress(0.25, "Đang chọn Khung Neo nét nhất...")

        // TẦNG 2: Chọn Khung Neo (Anchor Selection) dựa trên Luminance Gradient Energy
        let anchorIndex = await selectAnchorFrame(textures: textures, device: device, commandQueue: commandQueue)
        let anchorTexture = textures[anchorIndex]
        let anchorFrame = frames[min(anchorIndex, frames.count - 1)]

        CameraLogger.info("Super-Res: Đã chọn Khung Neo #\(anchorIndex) (Độ phân giải đích: \(targetWidth)x\(targetHeight), Scale: \(scale)x)", category: .ai)

        progress(0.40, "Đang căn chỉnh vi mô & khử bóng ma...")

        // TẦNG 3 & 4: Khởi tạo Texture tích tụ nửa độ chính xác .rgba16Float (RGB trong .rgb, trọng số trong .a)
        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        accumDesc.usage = [.shaderRead, .shaderWrite]
        accumDesc.storageMode = .private

        guard var accumTextureA = device.makeTexture(descriptor: accumDesc),
              var accumTextureB = device.makeTexture(descriptor: accumDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        // Texture trung gian cho Motion Vectors & Deghost Weights (kích thước baseWidth x baseHeight)
        let mvDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: baseWidth,
            height: baseHeight,
            mipmapped: false
        )
        mvDesc.usage = [.shaderRead, .shaderWrite]
        mvDesc.storageMode = .private
        guard let motionVectorTex = device.makeTexture(descriptor: mvDesc),
              let deghostWeightTex = device.makeTexture(descriptor: mvDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        // Tích tụ từng frame vào lưới siêu phân giải (bắt đầu từ Khung Neo để đảm bảo 100% điểm ảnh có mẫu gốc)
        var orderedIndices = [anchorIndex]
        for i in 0..<textures.count {
            if i != anchorIndex { orderedIndices.append(i) }
        }

        let totalCount = orderedIndices.count
        for (step, idx) in orderedIndices.enumerated() {
            let candidateTex = textures[idx]
            let candidateFrame = frames[min(idx, frames.count - 1)]
            let isAnchor = (step == 0)

            // Tính toán IMU Prior Offset giữa Anchor Frame và Candidate Frame
            let imuPrior = computeIMUPriorOffset(
                anchor: anchorFrame.imuPose,
                candidate: candidateFrame.imuPose,
                sensorWidth: baseWidth
            )

            guard let cmdBuffer = commandQueue.makeCommandBuffer() else { continue }

            if !isAnchor {
                // 3a. Sub-pixel Alignment theo Luminance
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
            }

            // 4. Super-Resolution Fusion Gather
            if let gatherPipeline = shaders.fusionGatherPipeline,
               let encoder = cmdBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(gatherPipeline)
                encoder.setTexture(anchorTexture, index: 0)
                encoder.setTexture(candidateTex, index: 1)
                encoder.setTexture(motionVectorTex, index: 2)
                encoder.setTexture(deghostWeightTex, index: 3)
                encoder.setTexture(accumTextureA, index: 4)
                encoder.setTexture(accumTextureB, index: 5)
                var isAnchorFlag: Int32 = isAnchor ? 1 : 0
                encoder.setBytes(&isAnchorFlag, length: MemoryLayout<Int32>.stride, index: 0)

                let w = gatherPipeline.threadExecutionWidth
                let h = gatherPipeline.maxTotalThreadsPerThreadgroup / w
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

            let p = 0.40 + Float(step + 1) / Float(totalCount) * 0.35
            progress(p, "Đang tích tụ hạt photon \(step + 1)/\(totalCount)...")
        }

        progress(0.80, "Đang bảo toàn sắc thái Apple Display P3...")

        // TẦNG 5: Super-Resolution Normalize & Tone Preservation
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .shared

        guard let p3Texture = device.makeTexture(descriptor: outDesc),
              let finalTexture = device.makeTexture(descriptor: outDesc) else {
            return try extractCGImage(from: anchorFrame)
        }

        guard let postCmd = commandQueue.makeCommandBuffer() else {
            return try extractCGImage(from: anchorFrame)
        }

        if let normPipeline = shaders.normalizeTonePipeline,
           let encoder = postCmd.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(normPipeline)
            encoder.setTexture(accumTextureA, index: 0)
            encoder.setTexture(anchorTexture, index: 1)
            encoder.setTexture(p3Texture, index: 2)

            let w = normPipeline.threadExecutionWidth
            let h = normPipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
            let threadsPerGrid = MTLSize(width: targetWidth, height: targetHeight, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        progress(0.92, "Đang tối ưu độ sắc nét vi mô (Zero-Mushiness)...")

        // TẦNG 6: Zero-Mushiness Micro-Contrast Enhancement
        if let microPipeline = shaders.microContrastPipeline,
           let encoder = postCmd.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(microPipeline)
            encoder.setTexture(p3Texture, index: 0)
            encoder.setTexture(finalTexture, index: 1)
            var factor: Float = 0.20
            encoder.setBytes(&factor, length: MemoryLayout<Float>.stride, index: 0)

            let w = microPipeline.threadExecutionWidth
            let h = microPipeline.maxTotalThreadsPerThreadgroup / w
            let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
            let threadsPerGrid = MTLSize(width: targetWidth, height: targetHeight, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        await withCheckedContinuation { continuation in
            postCmd.addCompletedHandler { _ in
                continuation.resume()
            }
            postCmd.commit()
        }

        let resolutionLabel = scale >= 1.9 ? "48MP" : (scale >= 1.4 ? "27MP" : "19MP")
        progress(0.98, "Đang tạo ảnh thành phẩm \(resolutionLabel)...")

        // Xuất CGImage Display P3
        let resultCG = makeCGImage(from: finalTexture)
        progress(1.0, "Hoàn tất")
        if let resultCG = resultCG {
            return resultCG
        }
        return try extractCGImage(from: anchorFrame)
    }

    // MARK: - Private Helpers

    /// Chọn Frame nét nhất dựa trên tổng năng lượng độ dốc Luminance
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

    /// Chuyển đổi SuperResolutionInputFrame sang MTLTexture Display P3 thông qua CoreImage / ImageIO
    private func makeTexture(from frame: SuperResolutionInputFrame, device: MTLDevice) -> MTLTexture? {
        if let pb = frame.pixelBuffer {
            let ci = CIImage(cvPixelBuffer: pb).oriented(frame.orientation)
            return renderCIImageToTexture(ci, device: device)
        }

        if let data = frame.rawData {
            // Giải mã DNG RAW hoặc ảnh nén trực tiếp qua CoreImage Camera RAW Engine
            if let ci = CIImage(data: data) {
                let orientedCI = ci.oriented(frame.orientation)
                if let tex = renderCIImageToTexture(orientedCI, device: device) {
                    return tex
                }
            }

            // Giải mã qua ImageIO
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
        }

        return nil
    }

    /// Render CIImage trực tiếp vào MTLTexture Display P3 trên GPU
    private func renderCIImageToTexture(_ ciImage: CIImage, device: MTLDevice) -> MTLTexture? {
        let extent = ciImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

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
        ciContext.render(ciImage, to: texture, commandBuffer: nil, bounds: extent, colorSpace: colorSpace)
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
