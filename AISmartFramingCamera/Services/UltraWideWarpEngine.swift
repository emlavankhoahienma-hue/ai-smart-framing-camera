import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Tích hợp Khóa Đường Chân Trời 360° (360° Horizon Lock) đẳng hướng 1-Pass trên GPU Metal
/// Kết hợp SuperView Anamorphic + Velocity-Adaptive Roll & Adaptive Dynamic Zoom
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext
    private let textureLock = NSLock()

    // Bộ đệm Texture tái sử dụng (Texture Pooling) chống cấp phát lặp lại ở 60 FPS
    private var pooledInTex: MTLTexture?
    private var pooledOutTex: MTLTexture?

    private struct SuperViewParams {
        var beta_x: Float
        var beta_y: Float
    }

    public init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()

        if let dev = dev {
            self.ciContext = CIContext(mtlDevice: dev, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
            // Tải Metal Shader Separable SuperView đã biên dịch sẵn trong app bundle
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

        let width = Int(extent.width)
        let height = Int(extent.height)

        let progress = Float(min(max((1.0 - factor) / 0.5, 0.0), 1.0))
        let betaX: Float = 0.20 * progress
        let betaY: Float = 0.14 * progress

        guard let dev = device,
              let cmdQueue = commandQueue,
              let pState = pipelineState else {
            return image
        }

        textureLock.lock()
        defer { textureLock.unlock() }

        let inTex: MTLTexture
        let outTex: MTLTexture

        if let pIn = pooledInTex, let pOut = pooledOutTex,
           pIn.width == width, pIn.height == height {
            inTex = pIn
            outTex = pOut
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]

            guard let newIn = dev.makeTexture(descriptor: desc),
                  let newOut = dev.makeTexture(descriptor: desc) else {
                return image
            }
            pooledInTex = newIn
            pooledOutTex = newOut
            inTex = newIn
            outTex = newOut
        }

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
            beta_y: betaY
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
        cmdBuffer.waitUntilCompleted()

        return CIImage(mtlTexture: outTex, options: [.colorSpace: colorSpace]) ?? image
    }

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
}
