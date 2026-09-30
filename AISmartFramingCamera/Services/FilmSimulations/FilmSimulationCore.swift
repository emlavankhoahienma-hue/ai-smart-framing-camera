import Foundation
import CoreImage
import CoreGraphics

/// Bo khung thuat toan quang hoc Metal va CoreImage phuc vu gia lap phim va cam bien may anh chuyen sau.
/// Tich hop day du: Color Matrix, Photochemical S-Curve, Organic Halide Grain, Digital CCD Noise,
/// Highlight Halation Glow, CCD Sensor Bloom, Lens Diffusion, Chroma Bleed, Light Leak, va LCD Dither.
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

    // MARK: - Film S-Curve (Duong cong phan hoi quang hoa D-min Toe va D-max Shoulder)
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

    // MARK: - 1. Organic Film Grain (Hat phim bac huu co Silver Halide)
    public static func applyOrganicGrain(_ input: CIImage, intensity: Float, grainSize: Float = 1.4) -> CIImage {
        guard intensity > 0.01 else { return input }
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }

        let extent = input.extent
        let croppedNoise = random.cropped(to: extent)

        // Chuyen doi nhieu ngau nhien thanh don sac xam
        guard let monoFilter = CIFilter(name: "CIColorControls") else { return input }
        monoFilter.setValue(croppedNoise, forKey: kCIInputImageKey)
        monoFilter.setValue(0.0, forKey: kCIInputSaturationKey)
        monoFilter.setValue(1.15, forKey: kCIInputContrastKey)
        guard let monoNoise = monoFilter.outputImage else { return input }

        // Lam mo nhe de tao hinh khoi hat bac huu co
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return input }
        blurFilter.setValue(monoNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(grainSize, forKey: kCIInputRadiusKey)
        guard let blurredNoise = blurFilter.outputImage?.cropped(to: extent) else { return input }

        // Dieu tiet do trong suot cua lop hat
        guard let opacityFilter = CIFilter(name: "CIColorMatrix") else { return input }
        opacityFilter.setValue(blurredNoise, forKey: kCIInputImageKey)
        opacityFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        opacityFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        opacityFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        opacityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(0.38, intensity * 0.30))), forKey: "inputAVector")
        guard let controlledNoise = opacityFilter.outputImage else { return input }

        guard let blend = CIFilter(name: "CISoftLightBlendMode") else { return input }
        blend.setValue(controlledNoise, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 2. Digital CCD Sensor Noise (Nhieu hat cam bien dien tu Digicam Y2K)
    public static func applyDigitalCCDNoise(_ input: CIImage, intensity: Float) -> CIImage {
        guard intensity > 0.01 else { return input }
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        let extent = input.extent
        let cropped = random.cropped(to: extent)

        // Nhieu cam bien ky thuat so CCD co hat min, chua mot phan sac mau chroma noise nhe
        guard let noiseControls = CIFilter(name: "CIColorControls") else { return input }
        noiseControls.setValue(cropped, forKey: kCIInputImageKey)
        noiseControls.setValue(0.20, forKey: kCIInputSaturationKey)
        noiseControls.setValue(1.25, forKey: kCIInputContrastKey)
        guard let coloredNoise = noiseControls.outputImage else { return input }

        guard let opacity = CIFilter(name: "CIColorMatrix") else { return input }
        opacity.setValue(coloredNoise, forKey: kCIInputImageKey)
        opacity.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        opacity.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        opacity.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        opacity.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(0.25, intensity * 0.20))), forKey: "inputAVector")
        guard let controlled = opacity.outputImage else { return input }

        guard let blend = CIFilter(name: "CIOverlayBlendMode") else { return input }
        blend.setValue(controlled, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 3. Highlight Halation & Red Glow (Quang do bop nguon sang dac trung CineStill 800T)
    public static func applyHalationGlow(
        _ input: CIImage,
        intensity: Float = 0.32,
        radius: Float = 14.0
    ) -> CIImage {
        guard intensity > 0.01 else { return input }
        let extent = input.extent

        // Trich xuat vung sang cao (Highlights thresholding)
        guard let threshold = CIFilter(name: "CIColorMatrix") else { return input }
        threshold.setValue(input, forKey: kCIInputImageKey)
        threshold.setValue(CIVector(x: 2.4, y: 0, z: 0, w: 0), forKey: "inputRVector")
        threshold.setValue(CIVector(x: 0, y: 1.1, z: 0, w: 0), forKey: "inputGVector")
        threshold.setValue(CIVector(x: 0, y: 0, z: 0.3, w: 0), forKey: "inputBVector")
        threshold.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        threshold.setValue(CIVector(x: -0.88, y: -0.88, z: -0.88, w: 0), forKey: "inputBiasVector")
        guard let brightHighlights = threshold.outputImage else { return input }

        // Lam mo quang hoc quang do
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return input }
        blur.setValue(brightHighlights, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurredHalation = blur.outputImage?.cropped(to: extent) else { return input }

        // Nhuom do cam ruc ro dac trung lop than Remjet bi boc tren phim nhua chieu bong
        guard let tint = CIFilter(name: "CIColorMatrix") else { return input }
        tint.setValue(blurredHalation, forKey: kCIInputImageKey)
        tint.setValue(CIVector(x: CGFloat(intensity * 1.8), y: 0, z: 0, w: 0), forKey: "inputRVector")
        tint.setValue(CIVector(x: 0, y: CGFloat(intensity * 0.40), z: 0, w: 0), forKey: "inputGVector")
        tint.setValue(CIVector(x: 0, y: 0, z: CGFloat(intensity * 0.10), w: 0), forKey: "inputBVector")
        guard let tintedGlow = tint.outputImage else { return input }

        // Cong quang hoc vao anh goc
        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return input }
        screen.setValue(tintedGlow, forKey: kCIInputImageKey)
        screen.setValue(input, forKey: kCIInputBackgroundImageKey)
        return screen.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 4. CCD Sensor Bloom (Hien tuong tran sang mem dac trung cam bien CCD Y2K khi danh flash)
    public static func applyCCDBloom(
        _ input: CIImage,
        intensity: Float = 0.22,
        radius: Float = 9.0
    ) -> CIImage {
        guard intensity > 0.01 else { return input }
        let extent = input.extent

        guard let bloomFilter = CIFilter(name: "CIBloom") else { return input }
        bloomFilter.setValue(input, forKey: kCIInputImageKey)
        bloomFilter.setValue(intensity, forKey: kCIInputIntensityKey)
        bloomFilter.setValue(radius, forKey: kCIInputRadiusKey)
        return bloomFilter.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 5. Lens Diffusion Mist (Suong mo thau kinh co dien khong trang phu)
    public static func applyLensDiffusion(
        _ input: CIImage,
        intensity: Float = 0.18,
        radius: Float = 10.0
    ) -> CIImage {
        guard intensity > 0.01 else { return input }
        let extent = input.extent

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return input }
        blur.setValue(input, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return input }

        guard let opacity = CIFilter(name: "CIColorMatrix") else { return input }
        opacity.setValue(blurred, forKey: kCIInputImageKey)
        opacity.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        opacity.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        opacity.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        opacity.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(0.40, intensity))), forKey: "inputAVector")
        guard let diffuseLayer = opacity.outputImage else { return input }

        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return input }
        screen.setValue(diffuseLayer, forKey: kCIInputImageKey)
        screen.setValue(input, forKey: kCIInputBackgroundImageKey)
        return screen.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 6. Chroma Bleed (Lech pha mau ngang dac trung giai ma bang tu MiniDV / VHS)
    public static func applyChromaBleed(_ input: CIImage, shiftX: CGFloat = 2.5) -> CIImage {
        guard abs(shiftX) > 0.5 else { return input }
        let extent = input.extent
        let transform = CGAffineTransform(translationX: shiftX, y: 0)
        let shifted = input.transformed(by: transform).cropped(to: extent)

        guard let blend = CIFilter(name: "CILightenBlendMode") else { return input }
        blend.setValue(shifted, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 7. Corner Light Leak (Vet ro sang quang hoc o goc cua may co / do choi)
    public static func applyLightLeak(_ input: CIImage, intensity: Float = 0.25) -> CIImage {
        guard intensity > 0.01 else { return input }
        let extent = input.extent
        let center = CIVector(x: extent.origin.x + extent.width * 0.10, y: extent.origin.y + extent.height * 0.90)

        guard let radGrad = CIFilter(name: "CIRadialGradient") else { return input }
        radGrad.setValue(center, forKey: "inputCenter")
        radGrad.setValue(0.0, forKey: "inputRadius0")
        radGrad.setValue(max(extent.width, extent.height) * 0.60, forKey: "inputRadius1")
        radGrad.setValue(CIColor(red: 1.0, green: 0.42, blue: 0.12, alpha: CGFloat(intensity * 0.32)), forKey: "inputColor0")
        radGrad.setValue(CIColor(red: 0.90, green: 0.18, blue: 0.05, alpha: 0.0), forKey: "inputColor1")
        guard let leakGrad = radGrad.outputImage?.cropped(to: extent) else { return input }

        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return input }
        screen.setValue(leakGrad, forKey: kCIInputImageKey)
        screen.setValue(input, forKey: kCIInputBackgroundImageKey)
        return screen.outputImage?.cropped(to: extent) ?? input
    }

    // MARK: - 8. Nokia 3310 LCD Matrix Dither (Don sac xanh luc LCD 84x48)
    public static func applyDitherLCD(_ input: CIImage) -> CIImage {
        guard let mono = CIFilter(name: "CIColorControls") else { return input }
        mono.setValue(input, forKey: kCIInputImageKey)
        mono.setValue(0.0, forKey: kCIInputSaturationKey)
        mono.setValue(1.50, forKey: kCIInputContrastKey)
        guard let monoImage = mono.outputImage else { return input }

        guard let matrix = CIFilter(name: "CIColorMatrix") else { return monoImage }
        matrix.setValue(monoImage, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0.40, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 0.56, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0.20, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0.14, y: 0.24, z: 0.08, w: 0), forKey: "inputBiasVector")
        return matrix.outputImage?.cropped(to: input.extent) ?? monoImage
    }

    // MARK: - 9. Intensity Blend (Hoa tron anh goc va anh gia lap theo cuong do)
    public static func applyIntensityBlend(original: CIImage, filtered: CIImage, intensity: Float) -> CIImage {
        guard intensity < 0.999 else { return filtered }
        guard intensity > 0.001 else { return original }

        let alpha = CGFloat(max(0.0, min(1.0, intensity)))
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha)).cropped(to: original.extent)

        guard let blend = CIFilter(name: "CIBlendWithAlphaMask") else { return filtered }
        blend.setValue(filtered, forKey: kCIInputImageKey)
        blend.setValue(original, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: original.extent) ?? filtered
    }
}
