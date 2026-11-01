import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Áp dụng thuật toán Radial Panini / Barrel-to-Rectilinear Ultra-Wide Warp:
/// u_src = u * (alpha + (1.0 - alpha) * pow(abs(u), k))
/// v_src = v * (alpha + (1.0 - alpha) * pow(abs(v), k))
/// Tuyệt đối bảo toàn biên: khi |u| = 1.0 thì u_src = ±1.0, tràn viền 100% không viền đen.
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()

    private let warpKernel: CIWarpKernel?
    private let ciContext: CIContext

    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }

        let kernelSource = """
        kernel vec2 ultraWideRadialPaniniWarp(vec2 extentOrigin, vec2 extentSize, float alpha, float k) {
            vec2 p = destCoord() - extentOrigin;
            vec2 uv = (p / extentSize - 0.5) * 2.0;
            float u = clamp(uv.x, -1.0, 1.0);
            float v = clamp(uv.y, -1.0, 1.0);
            float absU = abs(u);
            float absV = abs(v);
            float u_src = u * (alpha + (1.0 - alpha) * pow(absU, k));
            float v_src = v * (alpha + (1.0 - alpha) * pow(absV, k));
            return (vec2(u_src, v_src) * 0.5 + 0.5) * extentSize + extentOrigin;
        }
        """
        self.warpKernel = CIWarpKernel(source: kernelSource)
    }

    public func applySimulatedUltraWide(to image: CIImage, factor: CGFloat = 0.5) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // alpha ≈ 1.38 - 1.45 ở mức 0.5x, k ≈ 2.1
        let clampedFactor = max(0.40, min(1.0, factor))
        let t = Float((1.0 - clampedFactor) / 0.5)
        let alpha = 1.0 + t * 0.42
        let k: Float = 2.1

        guard let kernel = warpKernel else {
            let s = 1.0 / CGFloat(alpha)
            let tForm = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
            return image.transformed(by: tForm).cropped(to: extent)
        }

        let originVec = CIVector(x: extent.origin.x, y: extent.origin.y)
        let sizeVec = CIVector(x: extent.width, y: extent.height)

        let warped = kernel.apply(
            extent: extent,
            roiCallback: { _, _ in extent },
            image: image,
            arguments: [originVec, sizeVec, NSNumber(value: alpha), NSNumber(value: k)]
        )
        return warped ?? image
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
