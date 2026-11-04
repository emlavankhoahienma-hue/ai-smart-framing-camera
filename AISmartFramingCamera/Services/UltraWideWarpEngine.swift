import Foundation
import CoreImage
import CoreGraphics
import Metal
import CoreVideo

/// Động cơ Giả lập Quang học Góc Siêu rộng Full-Frame (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Phiên bản nâng cấp SuperView Anamorphic Warp + Độ cong quang học thấu kính 13mm (Subtle Optical Barrel Curvature)
/// Tràn viền 100% không viền đen, không viền mờ nhân tạo, bảo toàn hình thái người và khuôn mặt tự nhiên.
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()
    public static var live: UltraWideWarpEngine { shared }
    public static var photo: UltraWideWarpEngine { shared }

    /// Cờ tuỳ chọn cho phép chuyển đổi chế độ (mặc định là false dùng SuperView quang học tràn viền)
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

    public struct SuperViewParams {
        public var beta_x: Float
        public var beta_y: Float
        public var barrel_k: Float
        public var edge_clarity: Float

        public init(beta_x: Float, beta_y: Float, barrel_k: Float, edge_clarity: Float) {
            self.beta_x = beta_x
            self.beta_y = beta_y
            self.barrel_k = barrel_k
            self.edge_clarity = edge_clarity
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

    // MARK: - Core Processing for CIImage
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
        guard factor < 0.999 else { return image }

        let width = Int(extent.width)
        let height = Int(extent.height)

        let progress = Float(min(max((1.0 - factor) / 0.5, 0.0), 1.0))
        // Thông số SuperView nâng cấp quang học:
        // betaX dãn ngang mạnh mẽ mở rộng tầm nhìn, betaY dãn nhẹ để mặt và người không bị kéo dài méo mó
        let betaX: Float = 0.22 * progress
        let betaY: Float = 0.08 * progress
        let barrelK: Float = 0.035 * progress
        let edgeClarity: Float = 0.12 * progress

        guard let dev = device,
              let cmdQueue = commandQueue,
              let pState = pipelineState else {
            return image
        }

        textureLock.lock()
        defer { textureLock.unlock() }

        // Kiểm tra và tái sử dụng bộ texture ping-pong
        let inTex: MTLTexture
        let outTex: MTLTexture

        if usePingSlot {
            if let pIn = pingInTex, let pOut = pingOutTex,
               pIn.width == width, pIn.height == height {
                inTex = pIn
                outTex = pOut
            } else {
                guard let (newIn, newOut) = makeTexturePair(device: dev, width: width, height: height) else {
                    return image
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
                    return image
                }
                pongInTex = newIn
                pongOutTex = newOut
                inTex = newIn
                outTex = newOut
            }
        }
        usePingSlot.toggle()

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        ciContext.render(
            image,
            to: inTex,
            commandBuffer: nil,
            bounds: extent,
            colorSpace: colorSpace
        )

        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pState)
        encoder.setTexture(inTex, index: 0)
        encoder.setTexture(outTex, index: 1)

        var params = SuperViewParams(
            beta_x: betaX,
            beta_y: betaY,
            barrel_k: barrelK,
            edge_clarity: edgeClarity
        )
        encoder.setBytes(&params, length: MemoryLayout<SuperViewParams>.stride, index: 0)

        let w = pState.threadExecutionWidth
        let h = pState.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: max(1, w), height: max(1, h), depth: 1)
        let numGroups = MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        cmdBuffer.commit()

        return CIImage(mtlTexture: outTex, options: [.colorSpace: colorSpace]) ?? image
    }

    // MARK: - CGImage Overload for Still Photo Capture
    public func applySimulatedUltraWide(
        to cgImage: CGImage,
        factor: CGFloat = 0.5,
        horizonRollAngle: Float = 0.0,
        horizonZoomScale: Float = 1.0,
        horizonShakeX: Float = 0.0,
        horizonShakeY: Float = 0.0
    ) -> CGImage? {
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: colorSpace])
        let extent = ciImage.extent
        if abs(horizonRollAngle) > 0.0005 || horizonZoomScale > 1.001 {
            let roll = CGFloat(-horizonRollAngle)
            let zoom = CGFloat(horizonZoomScale)
            let shakeX = CGFloat(horizonShakeX) * extent.width
            let shakeY = CGFloat(horizonShakeY) * extent.height
            let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(rotationAngle: roll))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: extent.midX + shakeX, y: extent.midY + shakeY))
            let bgBlack = CIImage(color: .black).cropped(to: extent)
            ciImage = ciImage.transformed(by: t).composited(over: bgBlack).cropped(to: extent)
        }
        let warpedCI = (factor < 0.999) ? applySimulatedUltraWide(to: ciImage, factor: factor) : ciImage
        return ciContext.createCGImage(
            warpedCI,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
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
