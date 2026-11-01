import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Động cơ Giả lập Quang học Góc Siêu rộng (Simulated Ultra-Wide 0.5x Full Frame Engine)
/// Sử dụng CIFilter CIBumpDistortion nguyên bản của Apple (100% GPU Metal, không warning, không viền đen).
public final class UltraWideWarpEngine: @unchecked Sendable {
    public static let shared = UltraWideWarpEngine()

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
    }

    public func applySimulatedUltraWide(to image: CIImage, factor: CGFloat = 0.5) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let center = CIVector(x: extent.midX, y: extent.midY)
        let radius = hypot(extent.width, extent.height) * 0.54
        let clamped = image.clampedToExtent()
        guard let filter = CIFilter(name: "CIBumpDistortion") else { return image }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(center, forKey: kCIInputCenterKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        // inputScale âm (-0.48) thu nhỏ chủ thể ở tâm lùi xa ra như ống kính 0.5x và kéo giãn mượt vùng rìa tràn khít 100% khung hình:
        let intensity = Float(min(max((1.0 - factor) * 0.95, 0.25), 0.55))
        filter.setValue(-intensity, forKey: kCIInputScaleKey)
        return (filter.outputImage ?? image).cropped(to: extent)
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
