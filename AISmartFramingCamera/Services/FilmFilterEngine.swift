import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

public final class FilmFilterEngine {
    public static let shared = FilmFilterEngine()
    
    private let context: CIContext
    
    public init() {
        // Create high-performance Metal-backed CIContext
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: metalDevice, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            self.context = CIContext(options: [.useSoftwareRenderer: false])
        }
    }
    
    // MARK: - Process CGImage with Film Recipe
    public func applyPreset(to image: CGImage, preset: FilmPreset) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filteredCI = applyPreset(to: ciImage, preset: preset) else { return image }
        return context.createCGImage(filteredCI, from: filteredCI.extent)
    }
    
    // MARK: - CoreImage Filter Graph
    public func applyPreset(to inputImage: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .standard:
            return inputImage
            
        case .fujiPro400H:
            return applyFujiPro400H(inputImage)
            
        case .kodakPortra400:
            return applyKodakPortra400(inputImage)
            
        case .cinemaTealOrange:
            return applyCinemaTealOrange(inputImage)
            
        case .sunsetGlow:
            return applySunsetGlow(inputImage)
            
        case .monochromeNoir:
            return applyMonochromeNoir(inputImage)
            
        case .vintageWarm:
            return applyVintageWarm(inputImage)
            
        case .streetClassic:
            return applyStreetClassic(inputImage)
        }
    }
    
    // MARK: - Specific Film Recipes
    
    private func applyFujiPro400H(_ input: CIImage) -> CIImage {
        // Soft pastel highlights, gentle cyan/green shift in shadows, glowing skin
        var output = input
        
        // 1. Color Controls: Slight desaturation, elevated brightness
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.04, forKey: kCIInputContrastKey)
            colorControls.setValue(0.96, forKey: kCIInputSaturationKey)
            colorControls.setValue(0.02, forKey: kCIInputBrightnessKey)
            output = colorControls.outputImage ?? output
        }
        
        // 2. Temperature & Tint (Cooler cyan-greenish)
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6200, y: 15), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        
        // 3. Highlight / Shadow adjustment
        if let hlShadow = CIFilter(name: "CIHighlightShadowAdjust") {
            hlShadow.setValue(output, forKey: kCIInputImageKey)
            hlShadow.setValue(0.9, forKey: "inputHighlightAmount")
            hlShadow.setValue(1.15, forKey: "inputShadowAmount")
            output = hlShadow.outputImage ?? output
        }
        
        return output
    }
    
    private func applyKodakPortra400(_ input: CIImage) -> CIImage {
        // Rich warm skin tones, golden yellow highlights, gentle contrast
        var output = input
        
        // 1. Warm Temperature Shift
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 5800, y: 10), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        
        // 2. Color Controls
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.08, forKey: kCIInputContrastKey)
            colorControls.setValue(1.12, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        
        // 3. Tone Curve
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
        
        // Color Matrix for Orange / Teal separation
        if let colorMatrix = CIFilter(name: "CIColorMatrix") {
            colorMatrix.setValue(output, forKey: kCIInputImageKey)
            colorMatrix.setValue(CIVector(x: 1.15, y: -0.05, z: -0.05, w: 0), forKey: "inputRVector")
            colorMatrix.setValue(CIVector(x: -0.02, y: 1.05, z: -0.02, w: 0), forKey: "inputGVector")
            colorMatrix.setValue(CIVector(x: -0.05, y: -0.05, z: 1.25, w: 0), forKey: "inputBVector")
            output = colorMatrix.outputImage ?? output
        }
        
        // High contrast S-Curve
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(output, forKey: kCIInputImageKey)
            colorControls.setValue(1.22, forKey: kCIInputContrastKey)
            colorControls.setValue(1.15, forKey: kCIInputSaturationKey)
            output = colorControls.outputImage ?? output
        }
        
        // Subtle Vignette for cinema feel
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
        
        // Golden hour warm enhancement
        if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(output, forKey: kCIInputImageKey)
            tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            tempFilter.setValue(CIVector(x: 4900, y: 25), forKey: "inputTargetNeutral")
            output = tempFilter.outputImage ?? output
        }
        
        // Vibrance boost
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
        
        // 1. Photo Effect Noir (Rich Black and White)
        if let noir = CIFilter(name: "CIPhotoEffectNoir") {
            noir.setValue(output, forKey: kCIInputImageKey)
            output = noir.outputImage ?? output
        }
        
        // 2. Punchy contrast boost
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
        
        // 1. Instant / Vintage look
        if let instant = CIFilter(name: "CIPhotoEffectInstant") {
            instant.setValue(output, forKey: kCIInputImageKey)
            output = instant.outputImage ?? output
        }
        
        // 2. Faded warm lift
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
        
        // 1. Photo Effect Process
        if let process = CIFilter(name: "CIPhotoEffectProcess") {
            process.setValue(output, forKey: kCIInputImageKey)
            output = process.outputImage ?? output
        }
        
        // 2. Clarity & Sharpening
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(output, forKey: kCIInputImageKey)
            unsharp.setValue(0.5, forKey: kCIInputIntensityKey)
            unsharp.setValue(2.5, forKey: kCIInputRadiusKey)
            output = unsharp.outputImage ?? output
        }
        
        return output
    }
}
