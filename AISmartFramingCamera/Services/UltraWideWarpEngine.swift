import Foundation
import CoreImage
import CoreGraphics
import Metal
import Accelerate

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Sử dụng Thuật toán Separable Anamorphic SuperView biên dịch trực tiếp qua Metal Compute Pipeline
/// u_src = (1.0 - beta_x) * u + beta_x * (u * u * u)
/// v_src = (1.0 - beta_y) * v + beta_y * (v * v * v)
/// Bảo toàn 100% đường thẳng trục ngang / trục dọc, không méo cong đồng hồ cát ở chế độ Video,
/// bảo toàn chặt chẽ biên [-1.0, 1.0] -> [-1.0, 1.0], không sinh sọc mã vạch ở 4 cạnh.
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let ciContext: CIContext
    private let textureLock = NSLock()

    // Texture cache tránh cấp phát lặp lại ở 60 FPS
    private var cachedInTexture: MTLTexture?
    private var cachedOutTexture: MTLTexture?
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0

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

    public func applySimulatedUltraWide(to image: CIImage, factor: CGFloat = 0.5) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        let width = Int(extent.width)
        let height = Int(extent.height)

        // Tính toán tham số beta theo tỷ lệ zoom 0.5x (beta_x = 0.34, beta_y = 0.26)
        let clampedFactor = max(0.35, min(1.0, factor))
        let t = Float((1.0 - clampedFactor) / 0.5)
        let betaX = max(0.0, min(0.45, t * 0.34))
        let betaY = max(0.0, min(0.38, t * 0.26))

        guard let dev = device,
              let cmdQueue = commandQueue,
              let pState = pipelineState else {
            return image
        }

        textureLock.lock()
        defer { textureLock.unlock() }

        let inTex: MTLTexture
        let outTex: MTLTexture

        if let cachedIn = cachedInTexture, let cachedOut = cachedOutTexture,
           cachedWidth == width, cachedHeight == height {
            inTex = cachedIn
            outTex = cachedOut
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
            cachedInTexture = newIn
            cachedOutTexture = newOut
            cachedWidth = width
            cachedHeight = height
            inTex = newIn
            outTex = newOut
        }

        // Render CIImage vào inTexture
        ciContext.render(
            image,
            to: inTex,
            commandBuffer: nil,
            bounds: extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Thực thi Metal Compute Shader Separable SuperView
        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pState)
        encoder.setTexture(inTex, index: 0)
        encoder.setTexture(outTex, index: 1)

        var params = SuperViewParams(beta_x: betaX, beta_y: betaY)
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

        return CIImage(mtlTexture: outTex, options: nil) ?? image
    }

    public func applySimulatedUltraWide(to cgImage: CGImage, factor: CGFloat = 0.5) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let warpedCI = applySimulatedUltraWide(to: ciImage, factor: factor)
        return ciContext.createCGImage(
            warpedCI,
            from: warpedCI.extent,
            format: .RGBA8,
            colorSpace: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        )
    }
}
