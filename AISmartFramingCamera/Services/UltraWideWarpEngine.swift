import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Sử dụng Thuật toán Separable Anamorphic SuperView biên dịch trực tiếp qua Metal Compute Pipeline
/// u_src = (1.0 + beta_x) * u - beta_x * (u * u * u)
/// v_src = (1.0 + beta_y) * v - beta_y * (v * v * v)
/// Đạo hàm tại tâm (1 + beta) > 1.0 mở rộng góc nhìn trung tâm thật sự, không phóng to ngược,
/// bù độ nét vi mô vùng rìa (Edge Micro-Sharpening) để ảnh sắc nét từ tâm ra 4 góc,
/// bảo toàn chặt chẽ không gian màu sRGB/P3 không bị bệt trắng (Double Gamma Bleaching),
/// tái sử dụng bộ đệm Texture (Texture Pooling) chống nóng máy và tràn RAM ở 60 FPS.
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
        var edge_sharpen: Float
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

        // PHẦN 3: Nội suy mượt hệ số beta & edge_sharpen khi chuyển tiếp giữa 0.5x <-> 1.0x
        let progress = Float(min(max((1.0 - factor) / 0.5, 0.0), 1.0))
        let betaX: Float = 0.18 * progress
        let betaY: Float = 0.12 * progress
        let edgeSharpen: Float = 0.32 * progress

        guard let dev = device,
              let cmdQueue = commandQueue,
              let pState = pipelineState else {
            return image
        }

        // PHẦN 1: Tối ưu bộ đệm Texture tái sử dụng (Texture Pooling)
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

        // Bảo toàn chính xác không gian màu gốc, tránh CoreImage áp chồng 2 lần Gamma sRGB
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        ciContext.render(
            image,
            to: inTex,
            commandBuffer: nil,
            bounds: extent,
            colorSpace: colorSpace
        )

        // Thực thi Metal Compute Shader Separable SuperView kèm Edge Micro-Sharpening
        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pState)
        encoder.setTexture(inTex, index: 0)
        encoder.setTexture(outTex, index: 1)

        var params = SuperViewParams(beta_x: betaX, beta_y: betaY, edge_sharpen: edgeSharpen)
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

    public func applySimulatedUltraWide(to cgImage: CGImage, factor: CGFloat = 0.5) -> CGImage? {
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciImage = CIImage(cgImage: cgImage, options: [.colorSpace: colorSpace])
        let warpedCI = applySimulatedUltraWide(to: ciImage, factor: factor)
        return ciContext.createCGImage(
            warpedCI,
            from: warpedCI.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }
}
