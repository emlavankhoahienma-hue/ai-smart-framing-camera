import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import CoreGraphics

public final class FilmFilterEngine {
    public static let shared = FilmFilterEngine()
    
    private let context: CIContext
    
    public init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            self.context = CIContext(options: [.useSoftwareRenderer: false])
        }
    }
    
    // MARK: - Manual Preset
    public func applyPreset(to image: CGImage, preset: FilmPreset) -> CGImage? {
        guard preset != .aiFullAuto else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset) else { return image }
        return context.createCGImage(filteredCI, from: filteredCI.extent)
    }
    
    public func applyPreset(to inputImage: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .standard, .aiFullAuto: return inputImage
        case .fujiPro400H: return applyFujiPro400H(inputImage)
        case .kodakPortra400: return applyKodakPortra400(inputImage)
        case .cinemaTealOrange: return applyCinemaTealOrange(inputImage)
        case .sunsetGlow: return applySunsetGlow(inputImage)
        case .monochromeNoir: return applyMonochromeNoir(inputImage)
        case .vintageWarm: return applyVintageWarm(inputImage)
        case .streetClassic: return applyStreetClassic(inputImage)
        }
    }
    
    // MARK: - AI Full Color Mode (Neural Engine driven parameters)
    public func applyAIColorParameters(to image: CGImage, params: AIColorParameters) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let result = applyAIColorParameters(to: ciImage, params: params) else { return image }
        return context.createCGImage(result, from: result.extent)
    }
    
    public func applyAIColorParameters(to inputImage: CIImage, params: AIColorParameters) -> CIImage? {
        var output = inputImage
        
        // Step 1: Temperature & Tint (warmth shift)
        if abs(params.warmthShift) > 0.01 {
            if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
                tempFilter.setValue(output, forKey: kCIInputImageKey)
                let neutralTemp: CGFloat = 6500
                let targetTemp = neutralTemp + params.warmthShift * 3000 // ±3000K range
                tempFilter.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
                tempFilter.setValue(CIVector(x: targetTemp, y: params.warmthShift * 10), forKey: "inputTargetNeutral")
                output = tempFilter.outputImage ?? output
            }
        }
        
        // Step 2: Saturation & Contrast
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(params.contrastCurve, forKey: kCIInputContrastKey)
            colorControls.setValue(params.saturationBoost, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        
        // Step 3: Tone Curve — Shadow lift & Highlight roll
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(output, forKey: kCIInputImageKey)
            let shadowLift = params.shadowLift
            let highlightRoll = params.highlightRoll
            curve.setValue(CIVector(x: 0.0, y: shadowLift), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.25 + shadowLift * 0.5), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.75 * highlightRoll), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: highlightRoll), forKey: "inputPoint4")
            output = curve.outputImage ?? output
        }
        
        // Step 4: Color Grade overlay (scene-specific color shift)
        output = applyColorGrade(output, grade: params.colorGrade)
        
        // Step 5: Film Grain
        if params.filmGrain > 0.02 {
            if let noiseReduction = CIFilter(name: "CIRandomGenerator") {
                if let noiseImage = noiseReduction.outputImage {
                    let croppedNoise = noiseImage.cropped(to: output.extent)
                    if let blendFilter = CIFilter(name: "CIBlendWithMask") {
                        _ = blendFilter // grain via color matrix instead
                    }
                    // Use soft light blending for grain
                    if let grainFilter = CIFilter(name: "CIColorMatrix") {
                        let grainScale = params.filmGrain * 0.04
                        grainFilter.setValue(croppedNoise, forKey: kCIInputImageKey)
                        grainFilter.setValue(CIVector(x: grainScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
                        grainFilter.setValue(CIVector(x: 0, y: grainScale, z: 0, w: 0), forKey: "inputGVector")
                        grainFilter.setValue(CIVector(x: 0, y: 0, z: grainScale, w: 0), forKey: "inputBVector")
                        grainFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: params.filmGrain * 0.15), forKey: "inputAVector")
                        if let grainImage = grainFilter.outputImage,
                           let composite = CIFilter(name: "CIAdditionCompositing") {
                            composite.setValue(output, forKey: kCIInputImageKey)
                            composite.setValue(grainImage, forKey: kCIInputBackgroundImageKey)
                            output = composite.outputImage ?? output
                        }
                    }
                }
            }
        }
        
        // Step 6: Vignette
        if params.vignetteAmount > 0.05 {
            if let vignette = CIFilter(name: "CIVignette") {
                vignette.setValue(output, forKey: kCIInputImageKey)
                vignette.setValue(params.vignetteAmount, forKey: kCIInputIntensityKey)
                vignette.setValue(1.8, forKey: kCIInputRadiusKey)
                output = vignette.outputImage ?? output
            }
        }
        
        return output
    }
    
    private func applyColorGrade(_ input: CIImage, grade: AIColorGrade) -> CIImage {
        var output = input
        
        switch grade {
        case .softwarm:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 1.04, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: 1.00, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0.96, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
            
        case .tealOrange:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 1.12, y: -0.04, z: -0.04, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: -0.02, y: 1.02, z: -0.02, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: -0.04, y: -0.04, z: 1.18, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
            
        case .golden:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 1.15, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: 1.04, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0.85, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
            
        case .coolnatural:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 0.97, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: 1.02, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 1.06, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
            
        case .moody:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: 0.95, y: -0.02, z: 0.02, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: 0.92, z: 0.02, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0.02, y: 0, z: 1.08, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
            
        case .vibrant:
            if let vibrance = CIFilter(name: "CIVibrance") {
                vibrance.setValue(output, forKey: kCIInputImageKey)
                vibrance.setValue(0.35, forKey: "inputAmount")
                output = vibrance.outputImage ?? output
            }
            
        case .classic:
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                // Luminosity weights R:0.299, G:0.587, B:0.114 → desaturate
                matrix.setValue(CIVector(x: 0.4, y: 0.35, z: 0.25, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0.4, y: 0.35, z: 0.25, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0.4, y: 0.35, z: 0.25, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
        }
        
        return output
    }
    
    // MARK: - Film Presets (unchanged)
    
    private func applyFujiPro400H(_ input: CIImage) -> CIImage {
        var output = input
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.04, forKey: kCIInputContrastKey)
            colorControls.setValue(0.96, forKey: kCIInputSaturationKey)
            colorControls.setValue(0.02, forKey: kCIInputBrightnessKey)
            output = colorControls.outputImage ?? output
        }
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6200, y: 15), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        if let hlShadow = CIFilter(name: "CIHighlightShadowAdjust") {
            hlShadow.setValue(output, forKey: kCIInputImageKey)
            hlShadow.setValue(0.9, forKey: "inputHighlightAmount")
            hlShadow.setValue(1.15, forKey: "inputShadowAmount")
            output = hlShadow.outputImage ?? output
        }
        return output
    }
    
    private func applyKodakPortra400(_ input: CIImage) -> CIImage {
        var output = input
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 5800, y: 10), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.08, forKey: kCIInputContrastKey)
            colorControls.setValue(1.12, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        if let curve = CIFilter(name: "CIToneCurve") {
            curve.setValue(output, forKey: kCIInputImageKey)
            curve.setValue(CIVector(x: 0.0, y: 0.02), forKey: "inputPoint0")
            curve.setValue(CIVector(x: 0.25, y: 0.23), forKey: "inputPoint1")
            curve.setValue(CIVector(x: 0.5, y: 0.52), forKey: "inputPoint2")
            curve.setValue(CIVector(x: 0.75, y: 0.77), forKey: "inputPoint3")
            curve.setValue(CIVector(x: 1.0, y: 0.98), forKey: "inputPoint4")
            output = curve.outputImage ?? output
        }
        return output
    }
    
    private func applyCinemaTealOrange(_ input: CIImage) -> CIImage {
        var output = input
        if let colorMatrix = CIFilter(name: "CIColorMatrix") {
            colorMatrix.setValue(output, forKey: kCIInputImageKey)
            colorMatrix.setValue(CIVector(x: 1.15, y: -0.05, z: -0.05, w: 0), forKey: "inputRVector")
            colorMatrix.setValue(CIVector(x: -0.02, y: 1.05, z: -0.02, w: 0), forKey: "inputGVector")
            colorMatrix.setValue(CIVector(x: -0.05, y: -0.05, z: 1.25, w: 0), forKey: "inputBVector")
            output = colorMatrix.outputImage ?? output
        }
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.22, forKey: kCIInputContrastKey)
            colorControls.setValue(1.15, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        if let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(output, forKey: kCIInputImageKey)
            vignette.setValue(0.65, forKey: kCIInputIntensityKey)
            vignette.setValue(1.8, forKey: kCIInputRadiusKey)
            output = vignette.outputImage ?? output
        }
        return output
    }
    
    private func applySunsetGlow(_ input: CIImage) -> CIImage {
        var output = input
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 4900, y: 25), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(output, forKey: kCIInputImageKey)
            vibrance.setValue(0.45, forKey: "inputAmount")
            output = vibrance.outputImage ?? output
        }
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.14, forKey: kCIInputContrastKey)
            output = colorControls.outputImage ?? output
        }
        return output
    }
    
    private func applyMonochromeNoir(_ input: CIImage) -> CIImage {
        var output = input
        if let noir = CIFilter(name: "CIPhotoEffectNoir") {
            noir.setValue(output, forKey: kCIInputImageKey)
            output = noir.outputImage ?? output
        }
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.30, forKey: kCIInputContrastKey)
            colorControls.setValue(-0.02, forKey: kCIInputBrightnessKey)
            output = colorControls.outputImage ?? output
        }
        return output
    }
    
    private func applyVintageWarm(_ input: CIImage) -> CIImage {
        var output = input
        if let instant = CIFilter(name: "CIPhotoEffectInstant") {
            instant.setValue(output, forKey: kCIInputImageKey)
            output = instant.outputImage ?? output
        }
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 5500, y: 15), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        return output
    }
    
    private func applyStreetClassic(_ input: CIImage) -> CIImage {
        var output = input
        if let process = CIFilter(name: "CIPhotoEffectProcess") {
            process.setValue(output, forKey: kCIInputImageKey)
            output = process.outputImage ?? output
        }
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(output, forKey: kCIInputImageKey)
            unsharp.setValue(0.5, forKey: kCIInputIntensityKey)
            unsharp.setValue(2.5, forKey: kCIInputRadiusKey)
            output = unsharp.outputImage ?? output
        }
        return output
    }
}
