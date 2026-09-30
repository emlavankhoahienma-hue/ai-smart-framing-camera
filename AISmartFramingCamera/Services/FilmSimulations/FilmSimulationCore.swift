import Foundation
import CoreImage
import CoreGraphics

/// Bo khung thuat toan quang hoc Metal va CoreImage phuc vu gia lap phim va cam bien may anh.
/// Ho tro Color Matrix, Film S-Curve, Organic Grain, Highlight Halation va CCD Bloom.
public enum FilmSimulationCore {

    // MARK: - Color Matrix Transformation (Pha tron pho mau quang hoc)
    public static func applyColorMatrix(
        _ input: CIImage,
        red: CIVector,
        green: CIVector,
        blue: CIVector,
        alpha: CIVector = CIVector(x: 0, y: 0, z: 0, w: 1),
        bias: CIVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    ) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(red, forKey: "inputRVector")
        filter.setValue(green, forKey: "inputGVector")
        filter.setValue(blue, forKey: "inputBVector")
        filter.setValue(alpha, forKey: "inputAVector")
        filter.setValue(bias, forKey: "inputBiasVector")
        return filter.outputImage ?? input
    }

    // MARK: - Film S-Curve (Duong cong phan hoi quang hoc D-min Toe va D-max Shoulder)
    public static func applyToneCurve(
        _ input: CIImage,
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint,
        p4: CGPoint
    ) -> CIImage {
        guard let filter = CIFilter(name: "CIToneCurve") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: p0.x, y: p0.y), forKey: "inputPoint0")
        filter.setValue(CIVector(x: p1.x, y: p1.y), forKey: "inputPoint1")
        filter.setValue(CIVector(x: p2.x, y: p2.y), forKey: "inputPoint2")
        filter.setValue(CIVector(x: p3.x, y: p3.y), forKey: "inputPoint3")
        filter.setValue(CIVector(x: p4.x, y: p4.y), forKey: "inputPoint4")
        return filter.outputImage ?? input
    }

    // MARK: - Temperature & Tint (Can bang trang analog)
    public static func applyTempTint(
        _ input: CIImage,
        neutralTemp: CGFloat = 6500,
        targetTemp: CGFloat,
        targetTint: CGFloat = 0
    ) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: targetTemp, y: targetTint), forKey: "inputTargetNeutral")
        return filter.outputImage ?? input
    }

    // MARK: - Color Controls & Dynamics
    public static func applyColorControls(
        _ input: CIImage,
        contrast: Float = 1.0,
        saturation: Float = 1.0,
        brightness: Float = 0.0
    ) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        return filter.outputImage ?? input
    }

    // MARK: - Vibrance
    public static func applyVibrance(_ input: CIImage, amount: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIVibrance") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: "inputAmount")
        return filter.outputImage ?? input
    }

    // MARK: - Optical Vignetting
    public static func applyVignette(_ input: CIImage, intensity: Float, radius: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIVignette") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(intensity, forKey: kCIInputIntensityKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage ?? input
    }

    // MARK: - Exposure
    public static func applyExposure(_ input: CIImage, ev: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(ev, forKey: kCIInputEVKey)
        return filter.outputImage ?? input
    }

    // MARK: - Organic Film Grain (Hat phim bac huu co chon loc vung toi va trung tinh)
    public static func applyOrganicGrain(_ input: CIImage, intensity: Float, grainSize: Float = 1.5) -> CIImage {
        guard intensity > 0.01 else { return input }
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }

        let croppedNoise = random.cropped(to: input.extent)

        // Bien doi nhieu thanh trang den va lam mo nhe de dieu chinh do min cua hat
        guard let monoFilter = CIFilter(name: "CIColorControls") else { return input }
        monoFilter.setValue(croppedNoise, forKey: kCIInputImageKey)
        monoFilter.setValue(0.0, forKey: kCIInputSaturationKey)
        monoFilter.setValue(1.1, forKey: kCIInputContrastKey)
        guard let monoNoise = monoFilter.outputImage else { return input }

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return input }
        blurFilter.setValue(monoNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(grainSize, forKey: kCIInputRadiusKey)
        guard let blurredNoise = blurFilter.outputImage?.cropped(to: input.extent) else { return input }

        // Dieu tiet cuong do hat
        guard let opacityFilter = CIFilter(name: "CIColorMatrix") else { return input }
        opacityFilter.setValue(blurredNoise, forKey: kCIInputImageKey)
        opacityFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        opacityFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        opacityFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        opacityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(0.40, intensity * 0.35))), forKey: "inputAVector")
        guard let controlledNoise = opacityFilter.outputImage else { return input }

        guard let blend = CIFilter(name: "CISoftLightBlendMode") else { return input }
        blend.setValue(controlledNoise, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: input.extent) ?? input
    }

    // MARK: - Highlight Halation & Red Glow (Quang do bọc nguon sang dac trung CineStill)
    public static func applyHalationGlow(
        _ input: CIImage,
        intensity: Float = 0.30,
        radius: Float = 14.0
    ) -> CIImage {
        guard intensity > 0.01 else { return input }

        // Trich xuat vung sang cao (Highlights extraction)
        guard let threshold = CIFilter(name: "CIColorMatrix") else { return input }
        threshold.setValue(input, forKey: kCIInputImageKey)
        threshold.setValue(CIVector(x: 2.2, y: 0, z: 0, w: 0), forKey: "inputRVector")
        threshold.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
        threshold.setValue(CIVector(x: 0, y: 0, z: 0.4, w: 0), forKey: "inputBVector")
        threshold.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        threshold.setValue(CIVector(x: -0.85, y: -0.85, z: -0.85, w: 0), forKey: "inputBiasVector")
        guard let brightHighlights = threshold.outputImage else { return input }

        // Lam mo quang hoc quang do (Red/Orange blur spread)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return input }
        blur.setValue(brightHighlights, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurredHalation = blur.outputImage?.cropped(to: input.extent) else { return input }

        // Nhuom do cam dac trung lop than remjet bi boc
        guard let tint = CIFilter(name: "CIColorMatrix") else { return input }
        tint.setValue(blurredHalation, forKey: kCIInputImageKey)
        tint.setValue(CIVector(x: CGFloat(intensity * 1.6), y: 0, z: 0, w: 0), forKey: "inputRVector")
        tint.setValue(CIVector(x: 0, y: CGFloat(intensity * 0.45), z: 0, w: 0), forKey: "inputGVector")
        tint.setValue(CIVector(x: 0, y: 0, z: CGFloat(intensity * 0.15), w: 0), forKey: "inputBVector")
        guard let tintedGlow = tint.outputImage else { return input }

        // Cong quang hoc vao anh goc
        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return input }
        screen.setValue(tintedGlow, forKey: kCIInputImageKey)
        screen.setValue(input, forKey: kCIInputBackgroundImageKey)
        return screen.outputImage?.cropped(to: input.extent) ?? input
    }

    // MARK: - CCD Sensor Bloom (Hien tuong tran sang mem dac trung cam bien CCD Y2K)
    public static func applyCCDBloom(
        _ input: CIImage,
        intensity: Float = 0.22,
        radius: Float = 8.0
    ) -> CIImage {
        guard intensity > 0.01 else { return input }

        guard let bloomFilter = CIFilter(name: "CIBloom") else { return input }
        bloomFilter.setValue(input, forKey: kCIInputImageKey)
        bloomFilter.setValue(intensity, forKey: kCIInputIntensityKey)
        bloomFilter.setValue(radius, forKey: kCIInputRadiusKey)
        return bloomFilter.outputImage?.cropped(to: input.extent) ?? input
    }
}
