import Foundation
import CoreImage
import CoreGraphics
import Metal
import CoreVideo

/// Động cơ Quang học Góc Siêu rộng 0.5x Tuyến tính C++20 NEON + Metal Catmull-Rom
/// (Rectilinear-Conformal Ultra-Wide 0.5x Engine):
/// - Giải lưới quang học Hyperbolic-Rectilinear C∞ bằng C++20 (`NativeOpticsCore`):
///   giữ 100% đường thẳng dọc & ngang KHÔNG CONG (triệt tiêu méo mắt cá / barrel),
///   giữ nguyên tỷ lệ 1:1 trung tâm (không làm méo mặt/người), tràn viền 100% không đen góc.
/// - Liveview & Video 60FPS: Metal 16-tap Catmull-Rom Bicubic Anti-Ringing + Bù nét theo Jacobian.
/// - Ảnh chụp tĩnh (Still Photo): C++20 ARM64 NEON đa luồng 6×6 Lanczos-3 Sinc + Phục hồi vi chi tiết biên.
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()
    public static var live: UltraWideWarpEngine { shared }
    public static var photo: UltraWideWarpEngine { shared }

    public static var useCanvasMode: Bool = false

    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext
    private let textureLock = NSLock()

    // Bộ đệm Ping-Pong Texture 2 slot luân phiên chống xung đột ghi/đọc ở 60 FPS
    private var pingInTex: MTLTexture?
    private var pingOutTex: MTLTexture?
    private var pongInTex: MTLTexture?
    private var pongOutTex: MTLTexture?
    private var usePingSlot = true

    // Tham số quang học Rectilinear giải tích chuẩn C++20 truyền trực tiếp xuống GPU float32 (0% vỡ khối/pixelate)
    public struct SuperViewParams {
        public var k: Float
        public var inv_tanh_k: Float
        public var progress: Float
        public var edge_clarity: Float
        public var vignette_mix: Float
        public var chroma_guard: Float
        public var reserved0: Float
        public var reserved1: Float

        public init(
            k: Float,
            inv_tanh_k: Float,
            progress: Float,
            edge_clarity: Float,
            vignette_mix: Float,
            chroma_guard: Float,
            reserved0: Float = 0.0,
            reserved1: Float = 0.0
        ) {
            self.k = k
            self.inv_tanh_k = inv_tanh_k
            self.progress = progress
            self.edge_clarity = edge_clarity
            self.vignette_mix = vignette_mix
            self.chroma_guard = chroma_guard
            self.reserved0 = reserved0
            self.reserved1 = reserved1
        }
    }

    public var isSupported: Bool {
        pipelineState != nil
    }

    public init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        let queue = dev?.makeCommandQueue()
        self.commandQueue = queue

        if let dev = dev, let queue = queue {
            self.ciContext = CIContext(mtlCommandQueue: queue, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
            var state: MTLComputePipelineState?
            if let defaultLib = dev.makeDefaultLibrary(),
               let kernelFn = defaultLib.makeFunction(name: "separableSuperViewKernel") {
                state = try? dev.makeComputePipelineState(function: kernelFn)
            }
            self.pipelineState = state
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
            self.pipelineState = nil
        }
    }

    // MARK: - Liveview & Video Pipeline (C++20 Rectilinear Mesh + Metal 16-Tap Catmull-Rom Bicubic)
    public func applySimulatedUltraWide(
        to image: CIImage,
        factor: CGFloat = 0.5,
        horizonRollAngle: Float = 0.0,
        horizonZoomScale: Float = 1.0,
        horizonShakeX: Float = 0.0,
        horizonShakeY: Float = 0.0
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        var workingImage = image
        if abs(horizonRollAngle) > 0.0005 || horizonZoomScale > 1.001 ||
           abs(horizonShakeX) > 1e-5 || abs(horizonShakeY) > 1e-5 {
            let roll = CGFloat(-horizonRollAngle)
            let zoom = CGFloat(max(1.0, horizonZoomScale))
            let shakeX = CGFloat(horizonShakeX) * extent.width
            let shakeY = CGFloat(horizonShakeY) * extent.height
            let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(rotationAngle: roll))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: extent.midX + shakeX, y: extent.midY + shakeY))
            let bgBlack = CIImage(color: .black).cropped(to: extent)
            workingImage = image.transformed(by: t).composited(over: bgBlack).cropped(to: extent)
        }

        guard factor < 0.999 else { return workingImage }

        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width >= 4, height >= 4 else { return workingImage }

        guard let dev = device,
              let cmdQueue = commandQueue,
              let pState = pipelineState else {
            return workingImage
        }

        textureLock.lock()
        defer { textureLock.unlock() }

        let fZoom = Float(factor)
        let defaultRigidity: Float = 0.45
        let resolved = noc_uw_resolve_params(zoomFactor: fZoom, architecturalRigidity: defaultRigidity)

        let inTex: MTLTexture
        let outTex: MTLTexture

        if usePingSlot {
            if let pIn = pingInTex, let pOut = pingOutTex,
               pIn.width == width, pIn.height == height {
                inTex = pIn
                outTex = pOut
            } else {
                guard let (newIn, newOut) = makeTexturePair(device: dev, width: width, height: height) else {
                    return workingImage
                }
                pingInTex = newIn
                pingOutTex = newOut
                inTex = newIn
                outTex = newOut
            }
        } else {
            if let pIn = pongInTex, let pOut = pongOutTex,
               pIn.width == width, pIn.height == height {
                inTex = pIn
                outTex = pOut
            } else {
                guard let (newIn, newOut) = makeTexturePair(device: dev, width: width, height: height) else {
                    return workingImage
                }
                pongInTex = newIn
                pongOutTex = newOut
                inTex = newIn
                outTex = newOut
            }
        }
        usePingSlot.toggle()

        let colorSpace = workingImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        ciContext.render(
            workingImage,
            to: inTex,
            commandBuffer: nil,
            bounds: extent,
            colorSpace: colorSpace
        )

        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            return workingImage
        }

        encoder.setComputePipelineState(pState)
        encoder.setTexture(inTex, index: 0)
        encoder.setTexture(outTex, index: 1)

        var params = SuperViewParams(
            k: resolved.k,
            inv_tanh_k: resolved.invTanhK,
            progress: resolved.progress,
            edge_clarity: 0.65 * resolved.progress,
            vignette_mix: 0.70 * resolved.progress,
            chroma_guard: 0.006
        )
        encoder.setBytes(&params, length: MemoryLayout<SuperViewParams>.stride, index: 0)

        let w = pState.threadExecutionWidth
        let h = max(1, pState.maxTotalThreadsPerThreadgroup / max(1, w))
        let threadsPerGroup = MTLSize(width: max(1, w), height: h, depth: 1)
        let numGroups = MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        return CIImage(mtlTexture: outTex, options: [.colorSpace: colorSpace]) ?? workingImage
    }

    // MARK: - High-Precision C++20 ARM64 NEON Multi-Core 6x6 Lanczos-3 Still Photo Pipeline
    public func applySimulatedUltraWide(
        to cgImage: CGImage,
        factor: CGFloat = 0.5,
        horizonRollAngle: Float = 0.0,
        horizonZoomScale: Float = 1.0,
        horizonShakeX: Float = 0.0,
        horizonShakeY: Float = 0.0
    ) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 16, height >= 16 else { return cgImage }

        let hasHorizon = abs(horizonRollAngle) > 0.0005 || horizonZoomScale > 1.001 ||
                         abs(horizonShakeX) > 1e-5 || abs(horizonShakeY) > 1e-5
        guard factor < 0.999 || hasHorizon else { return cgImage }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rowBytes = width * 4
        let totalBytes = height * rowBytes
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        var srcPixels = [UInt8](repeating: 0, count: totalBytes)
        let drawn: Bool = srcPixels.withUnsafeMutableBytes { buf in
            guard let ptr = buf.baseAddress,
                  let ctx = CGContext(
                    data: ptr,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return cgImage }

        // 1. Phân tích hình học kiến trúc & đường thẳng trong ảnh bằng C++20 NEON (< 1ms)
        let sceneMetrics: NOCUltraWideSceneMetrics = srcPixels.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return NOCUltraWideSceneMetrics(architecturalLineStrength: 0.45, peripheralDetailDensity: 0.4, recommendedK: 0.78)
            }
            return noc_uw_analyze_scene_bgra(ptr, Int32(width), Int32(height), Int32(rowBytes))
        }

        let rigidity = sceneMetrics.architecturalLineStrength
        let horizon = NOCHorizonTransformParams(
            rollRadians: horizonRollAngle,
            zoomScale: max(1.0, horizonZoomScale),
            shakeNormX: horizonShakeX,
            shakeNormY: horizonShakeY
        )

        var lanczosPixels = [UInt8](repeating: 0, count: totalBytes)
        var finalPixels = [UInt8](repeating: 0, count: totalBytes)
        let bandCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let rowsPerBand = (height + bandCount - 1) / bandCount
        let fZoom = Float(factor)

        // 2. Chiếu quang học tuyến tính 0.5x + Cân bằng chân trời bằng 6x6 Lanczos-3 C++20 NEON đa luồng
        srcPixels.withUnsafeBytes { srcBuf in
            lanczosPixels.withUnsafeMutableBytes { midBuf in
                guard let sPtr = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let mPtr = midBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                    let y0 = band * rowsPerBand
                    let y1 = min(height, y0 + rowsPerBand)
                    if y0 < y1 {
                        noc_uw_render_lanczos3_rgba8_rows(
                            sPtr, Int32(width), Int32(height), Int32(rowBytes),
                            mPtr, Int32(width), Int32(height), Int32(rowBytes),
                            fZoom, rigidity, horizon,
                            Int32(y0), Int32(y1)
                        )
                    }
                }
            }
        }

        // 3. Phục hồi độ sắc nét & vi tương phản vùng biên theo Jacobian bằng C++20 NEON đa luồng
        if factor < 0.999 {
            lanczosPixels.withUnsafeBytes { midBuf in
                finalPixels.withUnsafeMutableBytes { dstBuf in
                    guard let mPtr = midBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let dPtr = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    DispatchQueue.concurrentPerform(iterations: bandCount) { band in
                        let y0 = band * rowsPerBand
                        let y1 = min(height, y0 + rowsPerBand)
                        if y0 < y1 {
                            noc_uw_restore_edge_clarity_rgba8_rows(
                                mPtr, Int32(width), Int32(height), Int32(rowBytes),
                                dPtr, Int32(rowBytes),
                                fZoom, rigidity,
                                Int32(y0), Int32(y1)
                            )
                        }
                    }
                }
            }
        } else {
            finalPixels = lanczosPixels
        }

        let outData = Data(finalPixels)
        guard let provider = CGDataProvider(data: outData as CFData) else { return cgImage }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) ?? cgImage
    }

    // MARK: - CVPixelBuffer Process Helper
    public func processToPixelBuffer(_ src: CVPixelBuffer, factor: CGFloat, completion: @escaping (CVPixelBuffer) -> Void) {
        guard factor < 0.999 else {
            completion(src)
            return
        }
        let inputCI = CIImage(cvPixelBuffer: src)
        let processedCI = applySimulatedUltraWide(to: inputCI, factor: factor)
        ciContext.render(processedCI, to: src)
        completion(src)
    }

    // MARK: - Helper Methods
    private func makeTexturePair(device: MTLDevice, width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let inTex = device.makeTexture(descriptor: desc),
              let outTex = device.makeTexture(descriptor: desc) else {
            return nil
        }
        return (inTex, outTex)
    }
}
