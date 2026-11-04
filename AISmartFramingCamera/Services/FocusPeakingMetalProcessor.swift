//
//  FocusPeakingMetalProcessor.swift
//  AISmartFramingCamera
//
//  Bộ xử lý Focus Peaking Báo Nét Điện Ảnh Chuyên Nghiệp 60 FPS
//  Thuật toán: Rec.709 Luminance + Sobel Gradient + 3x3 Morphological Dilation + Noise Gate + Halo Contrast
//

import Foundation
import CoreImage
import CoreVideo
import Metal
import simd

public final class FocusPeakingMetalProcessor: @unchecked Sendable {
    public static let shared = FocusPeakingMetalProcessor()

    private let metalDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        self.metalDevice = device
        self.commandQueue = device?.makeCommandQueue()

        if let device = device {
            self.ciContext = CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false
            ])
        } else {
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    /// Áp dụng Focus Peaking sắc nét điện ảnh với kỹ thuật Halo Contrast & 3x3 Morphological Dilation
    public func processPeaking(
        inputImage: CIImage,
        color: FocusPeakingColor,
        threshold: Float = 0.16
    ) -> CIImage {
        let extent = inputImage.extent
        guard extent.width > 2, extent.height > 2 else { return inputImage }

        // BƯỚC 1: Chuyển sang Luminance chuẩn Rec.709 (Y = 0.2126*R + 0.7152*G + 0.0722*B)
        guard let luminanceFilter = CIFilter(name: "CIColorMatrix") else { return inputImage }
        luminanceFilter.setValue(inputImage, forKey: kCIInputImageKey)
        luminanceFilter.setValue(CIVector(x: 0.2126, y: 0.2126, z: 0.2126, w: 0), forKey: "inputRVector")
        luminanceFilter.setValue(CIVector(x: 0.7152, y: 0.7152, z: 0.7152, w: 0), forKey: "inputGVector")
        luminanceFilter.setValue(CIVector(x: 0.0722, y: 0.0722, z: 0.0722, w: 0), forKey: "inputBVector")
        luminanceFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        luminanceFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        guard let luminanceImage = luminanceFilter.outputImage?.cropped(to: extent) else { return inputImage }

        // Khử nhẹ nhiễu hạt cảm biến ISO (bán kính 0.5px) trước khi tính đạo hàm cạnh
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return inputImage }
        blurFilter.setValue(luminanceImage, forKey: kCIInputImageKey)
        blurFilter.setValue(0.5, forKey: kCIInputRadiusKey)
        guard let smoothedLuma = blurFilter.outputImage?.cropped(to: extent) else { return inputImage }

        // BƯỚC 2: Toán tử đạo hàm Sobel 3x3 trích xuất biên độ cạnh ngang và dọc
        // Gx = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
        guard let sobelXFilter = CIFilter(name: "CIConvolution3X3") else { return inputImage }
        sobelXFilter.setValue(smoothedLuma, forKey: kCIInputImageKey)
        let sobelXWeights: [CGFloat] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
        sobelXFilter.setValue(CIVector(values: sobelXWeights, count: 9), forKey: "inputWeights")
        sobelXFilter.setValue(0.0, forKey: "inputBias")
        let edgeX = sobelXFilter.outputImage?.cropped(to: extent)

        // Gy = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        guard let sobelYFilter = CIFilter(name: "CIConvolution3X3") else { return inputImage }
        sobelYFilter.setValue(smoothedLuma, forKey: kCIInputImageKey)
        let sobelYWeights: [CGFloat] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        sobelYFilter.setValue(CIVector(values: sobelYWeights, count: 9), forKey: "inputWeights")
        sobelYFilter.setValue(0.0, forKey: "inputBias")
        let edgeY = sobelYFilter.outputImage?.cropped(to: extent)

        // Hợp nhất gradient magnitude xấp xỉ (|Gx| + |Gy|) và khuếch đại
        let rawEdges: CIImage
        if let edgeX = edgeX, let edgeY = edgeY {
            guard let absFilterX = CIFilter(name: "CIColorMatrix") else { return inputImage }
            absFilterX.setValue(edgeX, forKey: kCIInputImageKey)
            absFilterX.setValue(CIVector(x: 2.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            absFilterX.setValue(CIVector(x: 0, y: 2.0, z: 0, w: 0), forKey: "inputGVector")
            absFilterX.setValue(CIVector(x: 0, y: 0, z: 2.0, w: 0), forKey: "inputBVector")
            absFilterX.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            let absX = absFilterX.outputImage ?? edgeX

            guard let absFilterY = CIFilter(name: "CIColorMatrix") else { return inputImage }
            absFilterY.setValue(edgeY, forKey: kCIInputImageKey)
            absFilterY.setValue(CIVector(x: 2.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            absFilterY.setValue(CIVector(x: 0, y: 2.0, z: 0, w: 0), forKey: "inputGVector")
            absFilterY.setValue(CIVector(x: 0, y: 0, z: 2.0, w: 0), forKey: "inputBVector")
            absFilterY.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            let absY = absFilterY.outputImage ?? edgeY

            guard let addEdges = CIFilter(name: "CIAdditionCompositing") else { return inputImage }
            addEdges.setValue(absX, forKey: kCIInputImageKey)
            addEdges.setValue(absY, forKey: kCIInputBackgroundImageKey)
            rawEdges = addEdges.outputImage?.cropped(to: extent) ?? inputImage
        } else {
            // Fallback sang CIEdges nếu hệ thống thiếu bộ lọc convolution
            guard let edgesFilter = CIFilter(name: "CIEdges") else { return inputImage }
            edgesFilter.setValue(smoothedLuma, forKey: kCIInputImageKey)
            edgesFilter.setValue(4.5, forKey: kCIInputIntensityKey)
            rawEdges = edgesFilter.outputImage?.cropped(to: extent) ?? inputImage
        }

        // BƯỚC 3: Làm dày đường viền lên 2.0px - 2.5px bằng 3x3 Neighborhood Maximum Dilation
        let dilatedEdges: CIImage
        if let morphologyFilter = CIFilter(name: "CIMorphologyMaximum") {
            morphologyFilter.setValue(rawEdges, forKey: kCIInputImageKey)
            morphologyFilter.setValue(1.8, forKey: kCIInputRadiusKey)
            dilatedEdges = morphologyFilter.outputImage?.cropped(to: extent) ?? rawEdges
        } else {
            dilatedEdges = rawEdges
        }

        // BƯỚC 4: Cổng chặn nhiễu thông minh (Noise Gate) triệt tiêu hoàn toàn hạt ISO vùng phẳng
        guard let gateFilter = CIFilter(name: "CIColorMatrix") else { return inputImage }
        let edgeGain: CGFloat = 5.2
        let edgeBias: CGFloat = -CGFloat(threshold) * edgeGain
        gateFilter.setValue(dilatedEdges, forKey: kCIInputImageKey)
        gateFilter.setValue(CIVector(x: edgeGain, y: 0, z: 0, w: 0), forKey: "inputRVector")
        gateFilter.setValue(CIVector(x: 0, y: edgeGain, z: 0, w: 0), forKey: "inputGVector")
        gateFilter.setValue(CIVector(x: 0, y: 0, z: edgeGain, w: 0), forKey: "inputBVector")
        gateFilter.setValue(CIVector(x: edgeGain, y: 0, z: 0, w: 0), forKey: "inputAVector")
        gateFilter.setValue(CIVector(x: edgeBias, y: edgeBias, z: edgeBias, w: edgeBias), forKey: "inputBiasVector")
        guard let gatedOutput = gateFilter.outputImage else { return inputImage }

        // Kẹp dải giá trị về [0.0, 1.0]
        guard let clampFilter = CIFilter(name: "CIColorClamp") else { return inputImage }
        clampFilter.setValue(gatedOutput, forKey: kCIInputImageKey)
        clampFilter.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0), forKey: "inputMinComponents")
        clampFilter.setValue(CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1.0), forKey: "inputMaxComponents")
        guard let cleanEdgeMask = clampFilter.outputImage?.cropped(to: extent) else { return inputImage }

        // BƯỚC 5: Kỹ thuật Halo Contrast - Làm tối nền ảnh gốc 35% tại vùng có cạnh nét để tôn màu Neon
        guard let darkenFilter = CIFilter(name: "CIColorMatrix") else { return inputImage }
        darkenFilter.setValue(inputImage, forKey: kCIInputImageKey)
        darkenFilter.setValue(CIVector(x: 0.65, y: 0, z: 0, w: 0), forKey: "inputRVector")
        darkenFilter.setValue(CIVector(x: 0, y: 0.65, z: 0, w: 0), forKey: "inputGVector")
        darkenFilter.setValue(CIVector(x: 0, y: 0, z: 0.65, w: 0), forKey: "inputBVector")
        darkenFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        let darkenedBg = darkenFilter.outputImage?.cropped(to: extent) ?? inputImage

        // Trộn nền làm tối với nền gốc dựa trên mặt nạ cạnh (Halo Mask)
        guard let haloBlend = CIFilter(name: "CIBlendWithMask") else { return inputImage }
        haloBlend.setValue(darkenedBg, forKey: kCIInputImageKey)
        haloBlend.setValue(inputImage, forKey: kCIInputBackgroundImageKey)
        haloBlend.setValue(cleanEdgeMask, forKey: kCIInputMaskImageKey)
        let haloEnhancedBg = haloBlend.outputImage?.cropped(to: extent) ?? inputImage

        // BƯỚC 6: Phủ màu Neon rực rỡ với hệ số khuếch đại 1.35x
        let neonSIMD = color.neonVector
        guard let tintFilter = CIFilter(name: "CIColorMatrix") else { return inputImage }
        let boost: CGFloat = 1.35
        tintFilter.setValue(cleanEdgeMask, forKey: kCIInputImageKey)
        tintFilter.setValue(CIVector(x: CGFloat(neonSIMD.x) * boost, y: 0, z: 0, w: 0), forKey: "inputRVector")
        tintFilter.setValue(CIVector(x: 0, y: CGFloat(neonSIMD.y) * boost, z: 0, w: 0), forKey: "inputGVector")
        tintFilter.setValue(CIVector(x: 0, y: 0, z: CGFloat(neonSIMD.z) * boost, w: 0), forKey: "inputBVector")
        tintFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1.0), forKey: "inputAVector")
        guard let neonLaserEdges = tintFilter.outputImage?.cropped(to: extent) else { return inputImage }

        // BƯỚC 7: Cộng tia Laser phát sáng lên nền đã có Halo Contrast
        guard let finalAdd = CIFilter(name: "CIAdditionCompositing") else { return inputImage }
        finalAdd.setValue(neonLaserEdges, forKey: kCIInputImageKey)
        finalAdd.setValue(haloEnhancedBg, forKey: kCIInputBackgroundImageKey)
        return finalAdd.outputImage?.cropped(to: extent) ?? inputImage
    }
}

extension FocusPeakingColor {
    /// Vector màu sắc Neon chuẩn SIMD3<Float>
    public var neonVector: SIMD3<Float> {
        switch self {
        case .cyan:
            return SIMD3<Float>(0.0, 1.0, 1.0)       // Electric Cyan
        case .red:
            return SIMD3<Float>(1.0, 0.12, 0.28)     // Neon Red
        case .yellow:
            return SIMD3<Float>(1.0, 0.88, 0.0)      // Cyber Yellow
        case .green:
            return SIMD3<Float>(0.15, 1.0, 0.35)     // Matrix Green
        }
    }
}
