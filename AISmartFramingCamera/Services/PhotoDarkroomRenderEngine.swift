import Foundation
import CoreImage
import CoreGraphics
import Metal
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Compact Real-Time Luminance + RGB Histogram Snapshot
public struct PhotoDarkroomHistogram: Sendable, Equatable {
    public let lumaBins: [Double]
    public let redBins: [Double]
    public let greenBins: [Double]
    public let blueBins: [Double]
    public let meanLuminance: Double
    public let shadowClipPercent: Double
    public let highlightClipPercent: Double

    public static let empty = PhotoDarkroomHistogram(
        lumaBins: Array(repeating: 0.05, count: 48),
        redBins: Array(repeating: 0.05, count: 48),
        greenBins: Array(repeating: 0.05, count: 48),
        blueBins: Array(repeating: 0.05, count: 48),
        meanLuminance: 0.5,
        shadowClipPercent: 0.0,
        highlightClipPercent: 0.0
    )

    public init(
        lumaBins: [Double],
        redBins: [Double],
        greenBins: [Double],
        blueBins: [Double],
        meanLuminance: Double,
        shadowClipPercent: Double,
        highlightClipPercent: Double
    ) {
        self.lumaBins = lumaBins
        self.redBins = redBins
        self.greenBins = greenBins
        self.blueBins = blueBins
        self.meanLuminance = meanLuminance
        self.shadowClipPercent = shadowClipPercent
        self.highlightClipPercent = highlightClipPercent
    }

    public static func compute(from cgImage: CGImage, binCount: Int = 48, maxSampleSide: Int = 160) -> PhotoDarkroomHistogram {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0, binCount >= 8 else { return .empty }
        let longest = max(srcW, srcH)
        let scale = min(1.0, Double(maxSampleSide) / Double(longest))
        let sampleW = max(16, Int(round(Double(srcW) * scale)))
        let sampleH = max(16, Int(round(Double(srcH) * scale)))
        let bytesPerRow = sampleW * 4
        var raw = [UInt8](repeating: 0, count: sampleH * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: &raw,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .empty
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var lHist = [Double](repeating: 0, count: binCount)
        var rHist = [Double](repeating: 0, count: binCount)
        var gHist = [Double](repeating: 0, count: binCount)
        var bHist = [Double](repeating: 0, count: binCount)

        let totalPixels = sampleW * sampleH
        guard totalPixels > 0 else { return .empty }
        var lumaSum = 0.0
        var shadowClip = 0
        var highlightClip = 0
        let binScale = Double(binCount - 1) / 255.0

        for i in 0..<totalPixels {
            let off = i * 4
            let r = Double(raw[off])
            let g = Double(raw[off + 1])
            let b = Double(raw[off + 2])
            let y = 0.2126 * r + 0.7152 * g + 0.722e-1 * b

            lumaSum += y / 255.0
            if y <= 4.0 { shadowClip += 1 }
            if y >= 251.0 { highlightClip += 1 }

            rHist[max(0, min(binCount - 1, Int((r * binScale).rounded())))] += 1
            gHist[max(0, min(binCount - 1, Int((g * binScale).rounded())))] += 1
            bHist[max(0, min(binCount - 1, Int((b * binScale).rounded())))] += 1
            lHist[max(0, min(binCount - 1, Int((y * binScale).rounded())))] += 1
        }

        func normalize(_ arr: [Double]) -> [Double] {
            let interiorMax = arr.dropFirst().dropLast().max() ?? 1.0
            let peak = max(1.0, max(interiorMax, (arr.max() ?? 1.0) * 0.65))
            return arr.map { min(1.0, max(0.03, pow($0 / peak, 0.72))) }
        }

        return PhotoDarkroomHistogram(
            lumaBins: normalize(lHist),
            redBins: normalize(rHist),
            greenBins: normalize(gHist),
            blueBins: normalize(bHist),
            meanLuminance: lumaSum / Double(totalPixels),
            shadowClipPercent: (Double(shadowClip) / Double(totalPixels)) * 100.0,
            highlightClipPercent: (Double(highlightClip) / Double(totalPixels)) * 100.0
        )
    }
}

// MARK: - Frame Metadata Passed to Render Engine
public struct PhotoDarkroomRenderMetadata: Sendable {
    public var timestamp: Date
    public var iso: Float
    public var shutterSpeed: Double
    public var focalLengthMM: Double
    public var aperture: Float
    public var deviceName: String

    public init(
        timestamp: Date = Date(),
        iso: Float = 100,
        shutterSpeed: Double = 1.0 / 120.0,
        focalLengthMM: Double = 24.0,
        aperture: Float = 1.8,
        deviceName: String = "ALIGN STUDIO OPTICAL"
    ) {
        self.timestamp = timestamp
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.focalLengthMM = focalLengthMM
        self.aperture = aperture
        self.deviceName = deviceName
    }
}

// MARK: - Deterministic SplitMix64 PRNG (Resolution-Independent Film Dust Textures)
private struct DarkroomSplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnitDouble() -> Double {
        Double(nextUInt64() >> 11) / Double(1 << 53)
    }
}

// MARK: - Core GPU Darkroom Rendering Engine (Shared by 128px Thumbnails, 1440px Live Proxy & Full-Res 48MP Export)
public final class PhotoDarkroomRenderEngine: @unchecked Sendable {
    public static let shared = PhotoDarkroomRenderEngine()

    public let ciContext: CIContext
    private let srgbColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Bounded caches for expensive procedural assets (3D HSL/Curves LUTs & film dust overlays)
    private struct ColorCubeCacheKey: Hashable {
        let hsl: PhotoHSLState
        let curves: PhotoCurvesState
    }
    private let cacheLock = NSLock()
    private var cubeCache: [ColorCubeCacheKey: Data] = [:]
    private var cubeCacheOrder: [ColorCubeCacheKey] = []
    private var dustTextureCache: [Int: CIImage] = [:]

    private init() {
        let linearCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true,
            .cacheIntermediates: false,
            .workingColorSpace: linearCS,
            .workingFormat: CIFormat.RGBAh
        ]
        if let mtl = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: mtl, options: options)
        } else {
            self.ciContext = CIContext(options: options)
        }
    }

    public func clearCaches() {
        ciContext.clearCaches()
        cacheLock.lock()
        cubeCache.removeAll()
        cubeCacheOrder.removeAll()
        dustTextureCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Complete Render Entrypoint (CGImage -> CGImage)
    public struct RenderExtras: @unchecked Sendable {
        #if canImport(UIKit)
        public var aiColorParams: AIColorParameters?
        public var customWatermarkLogo: UIImage?
        public init(aiColorParams: AIColorParameters? = nil, customWatermarkLogo: UIImage? = nil) {
            self.aiColorParams = aiColorParams
            self.customWatermarkLogo = customWatermarkLogo
        }
        #else
        public init() {}
        #endif
    }

    #if canImport(UIKit)
    public func render(
        cgImage: CGImage,
        state: PhotoDarkroomEditState,
        metadata: PhotoDarkroomRenderMetadata = PhotoDarkroomRenderMetadata(),
        isInteractiveProxy: Bool = false,
        applyGeometryCrop: Bool = true,
        applyFramesAndDate: Bool = true,
        aiColorParams: AIColorParameters? = nil,
        customWatermarkLogo: UIImage? = nil
    ) -> CGImage {
        render(
            cgImage: cgImage,
            state: state,
            metadata: metadata,
            isInteractiveProxy: isInteractiveProxy,
            applyGeometryCrop: applyGeometryCrop,
            applyFramesAndDate: applyFramesAndDate,
            extras: RenderExtras(aiColorParams: aiColorParams, customWatermarkLogo: customWatermarkLogo)
        )
    }
    #endif

    public func render(
        cgImage: CGImage,
        state: PhotoDarkroomEditState,
        metadata: PhotoDarkroomRenderMetadata = PhotoDarkroomRenderMetadata(),
        isInteractiveProxy: Bool = false,
        applyGeometryCrop: Bool = true,
        applyFramesAndDate: Bool = true,
        extras: RenderExtras = RenderExtras()
    ) -> CGImage {
        autoreleasepool {
            let srcExtent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            guard srcExtent.width >= 2, srcExtent.height >= 2 else { return cgImage }

            var working = CIImage(cgImage: cgImage)

            // 1. Geometry Stage (Rotate 90°, Flip Horizontal, Inscribed Straighten, Normalized Crop)
            if applyGeometryCrop && !state.tools.crop.isIdentity {
                working = applyCropAndGeometry(to: working, crop: state.tools.crop)
            }

            // 2. Film Preset + Optional AI Scene Color Balance (iOS FilmFilterEngine integration)
            #if canImport(UIKit)
            if let preset = FilmPreset(rawValue: state.presetRawValue),
               preset != .standard, preset != .aiFullAuto, preset != .proColorGrade,
               state.filmIntensity > 0.004 {
                if let styled = FilmFilterEngine.shared.applyPreset(
                    to: working,
                    preset: preset,
                    intensity: Float(state.filmIntensity),
                    isRealtimePreview: false,
                    applyUserGrade: false
                ) {
                    working = styled
                }
            }
            if state.isAIEnhanced, let aiColorParams = extras.aiColorParams {
                if let aiOut = FilmFilterEngine.shared.applyAIColorParameters(to: working, params: aiColorParams) {
                    working = aiOut
                }
            }
            #endif

            // 3. Tools Tone, White Balance, Selective 8-Band HSL, 4-Channel Curves & Detail
            working = applyToolsGraph(to: working, tools: state.tools)

            // 4. Optical & Analog Effects (12 GPU CIImage Effects)
            working = applyEffectsGraph(to: working, effects: state.effects, isInteractiveProxy: isInteractiveProxy)

            // Materialize GPU graph once into CGImage
            let finalExtent = working.extent.integral
            guard finalExtent.width >= 2, finalExtent.height >= 2 else { return cgImage }
            let outputCS = cgImage.colorSpace ?? srgbColorSpace
            guard var outputCG = ciContext.createCGImage(
                working,
                from: finalExtent,
                format: .RGBA8,
                colorSpace: outputCS
            ) else {
                return cgImage
            }

            // 5. Crisp Vector Imprints (Quartz Date Stamp & Gallery/Master Watermark Frames)
            if applyFramesAndDate {
                if state.effects.dateStamp.isEnabled {
                    outputCG = applyDateStamp(to: outputCG, mode: state.effects.dateStamp, date: metadata.timestamp)
                }
                if state.effects.frameStyle.isEnabled {
                    #if canImport(UIKit)
                    outputCG = applyFrame(
                        to: outputCG,
                        style: state.effects.frameStyle,
                        logo: state.effects.frameLogo,
                        metadata: metadata,
                        customLogo: extras.customWatermarkLogo
                    )
                    #else
                    outputCG = applyFrame(
                        to: outputCG,
                        style: state.effects.frameStyle,
                        logo: state.effects.frameLogo,
                        metadata: metadata
                    )
                    #endif
                }
            }

            return outputCG
        }
    }

    // MARK: - Stage 1: Geometry (Rotate 90°, Flip, Inscribed Straighten, Crop)
    public func applyCropAndGeometry(to input: CIImage, crop: PhotoCropState) -> CIImage {
        var img = normalizeOrigin(input)
        var ext = img.extent

        // 1a. Clockwise 90-degree turns
        let turns = ((crop.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let angle = -CGFloat(turns) * (.pi * 0.5)
            img = img.transformed(by: CGAffineTransform(rotationAngle: angle))
            img = normalizeOrigin(img)
            ext = img.extent
        }

        // 1b. Horizontal flip
        if crop.flipHorizontal {
            let flip = CGAffineTransform(scaleX: -1.0, y: 1.0).translatedBy(x: -ext.width, y: 0)
            img = img.transformed(by: flip)
            img = normalizeOrigin(img)
            ext = img.extent
        }

        // 1c. Fine straighten rotation with exact inscribed auto-zoom (zero black corner triangles!)
        if abs(crop.straightenDegrees) >= 0.05 {
            let scale = CGFloat(PhotoCropState.inscribedScaleFactor(
                degrees: crop.straightenDegrees,
                width: Double(ext.width),
                height: Double(ext.height)
            ))
            let rad = -CGFloat(crop.straightenDegrees) * .pi / 180.0
            let cx = ext.midX
            let cy = ext.midY
            var xform = CGAffineTransform.identity
            xform = xform.translatedBy(x: cx, y: cy)
            xform = xform.rotated(by: rad)
            xform = xform.scaledBy(x: scale, y: scale)
            xform = xform.translatedBy(x: -cx, y: -cy)
            img = img.clampedToExtent().transformed(by: xform).cropped(to: ext)
            img = normalizeOrigin(img)
            ext = img.extent
        }

        // 1d. Normalized crop rect (converted from top-left UI coordinates to bottom-left CIImage coordinates)
        let nr = crop.normalizedRect
        if abs(nr.origin.x) >= 0.001 || abs(nr.origin.y) >= 0.001 ||
           abs(nr.width - 1.0) >= 0.001 || abs(nr.height - 1.0) >= 0.001 {
            let ciX = floor(ext.minX + nr.origin.x * ext.width)
            let ciY = floor(ext.minY + (1.0 - nr.origin.y - nr.height) * ext.height)
            let ciW = max(8.0, floor(nr.width * ext.width))
            let ciH = max(8.0, floor(nr.height * ext.height))
            let cropRect = CGRect(x: ciX, y: ciY, width: ciW, height: ciH).intersection(ext)
            if !cropRect.isNull, cropRect.width >= 8, cropRect.height >= 8 {
                img = img.cropped(to: cropRect)
                img = normalizeOrigin(img)
            }
        }
        return img
    }

    // MARK: - Stage 3: Tools GPU Graph (Push/Pull, WB, Contrast, H/S, Sat, Vib, 3D HSL+Curves Cube, Detail)
    public func applyToolsGraph(to input: CIImage, tools: PhotoToolsState) -> CIImage {
        var output = normalizeOrigin(input)
        let extent = output.extent

        // 3a. Push / Pull Exposure EV (-2.0 ... +2.0)
        if abs(tools.exposureEV) >= 0.015 {
            if let expFilter = CIFilter(name: "CIExposureAdjust") {
                expFilter.setValue(output, forKey: kCIInputImageKey)
                // Gentle highlight-preserving scale on positive EV to prevent sudden harsh clipping
                let effectiveEV = tools.exposureEV > 0 ? tools.exposureEV * 0.90 : tools.exposureEV
                expFilter.setValue(Float(effectiveEV), forKey: kCIInputEVKey)
                output = expFilter.outputImage ?? output
            }
            if tools.exposureEV > 0.35 {
                // Soft highlight roll-off compression when pushing exposure significantly
                let roll = Float(min(0.32, (tools.exposureEV - 0.35) * 0.22))
                output = applyHighlightShadowAdjustment(to: output, highlights: -roll, shadows: 0.0)
            }
        }

        // 3b. Warmth (-1...1) & Tint (-1...1)
        if abs(tools.warmth) >= 0.008 || abs(tools.tint) >= 0.008 {
            let shiftedTemp = CGFloat(6500.0 + tools.warmth * 2600.0)
            let shiftedTint = CGFloat(tools.tint * 65.0)
            if let wb = CIFilter(name: "CITemperatureAndTint") {
                wb.setValue(output, forKey: kCIInputImageKey)
                wb.setValue(CIVector(x: shiftedTemp, y: shiftedTint), forKey: "inputNeutral")
                wb.setValue(CIVector(x: 6500.0, y: 0.0), forKey: "inputTargetNeutral")
                output = wb.outputImage ?? output
            }
        }

        // 3c. Contrast (-1...1) & Saturation (-1...1; -1.0 reaches exact 0.0 monochrome)
        if abs(tools.contrast) >= 0.008 || abs(tools.saturation) >= 0.008 {
            let contrastVal = max(0.55, min(1.50, 1.0 + tools.contrast * 0.45))
            let satVal = tools.saturation < 0
                ? max(0.0, 1.0 + tools.saturation)
                : min(1.80, 1.0 + tools.saturation * 0.80)
            if let cc = CIFilter(name: "CIColorControls") {
                cc.setValue(output, forKey: kCIInputImageKey)
                cc.setValue(Float(contrastVal), forKey: kCIInputContrastKey)
                cc.setValue(Float(satVal), forKey: kCIInputSaturationKey)
                output = cc.outputImage ?? output
            }
        }

        // 3d. Highlights (-1...1) & Shadows (-1...1)
        if abs(tools.highlights) >= 0.008 || abs(tools.shadows) >= 0.008 {
            output = applyHighlightShadowAdjustment(
                to: output,
                highlights: Float(tools.highlights),
                shadows: Float(tools.shadows)
            )
        }

        // 3e. Vibrance (-1...1)
        if abs(tools.vibrance) >= 0.008 {
            if let vib = CIFilter(name: "CIVibrance") {
                vib.setValue(output, forKey: kCIInputImageKey)
                vib.setValue(Float(tools.vibrance * 0.90), forKey: "inputAmount")
                output = vib.outputImage ?? output
            }
        }

        // 3f. Fused 8-Band Selective HSL + 4-Channel Monotone Cubic Curves via Single 25x25x25 3D Color Cube
        if !tools.hsl.isIdentity || !tools.curves.isIdentity {
            let cubeData = cachedHSLAndCurvesCubeData(hsl: tools.hsl, curves: tools.curves, dimension: 25)
            // Clamp to [0, 1] safely before sRGB 3D LUT sampling so negative extended-sRGB values never wrap
            let clamped = clampToUnitRange(output)
            if let cube = CIFilter(name: "CIColorCubeWithColorSpace") {
                cube.setValue(clamped, forKey: kCIInputImageKey)
                cube.setValue(25, forKey: "inputCubeDimension")
                cube.setValue(cubeData, forKey: "inputCubeData")
                cube.setValue(srgbColorSpace, forKey: "inputColorSpace")
                output = cube.outputImage?.cropped(to: extent) ?? output
            }
        }

        // 3g. Detail: Sharpness + Micro-Contrast Clarity
        if tools.sharpness >= 0.008 || tools.clarity >= 0.008 {
            let dim = max(extent.width, extent.height)
            let resScale = max(0.5, min(2.4, dim / 1400.0))
            if tools.sharpness >= 0.008 {
                if let unsharp = CIFilter(name: "CIUnsharpMask") {
                    unsharp.setValue(output, forKey: kCIInputImageKey)
                    unsharp.setValue(Float(1.15 * resScale), forKey: kCIInputRadiusKey)
                    unsharp.setValue(Float(tools.sharpness * 0.72), forKey: kCIInputIntensityKey)
                    output = unsharp.outputImage?.cropped(to: extent) ?? output
                }
                if let lumSharp = CIFilter(name: "CISharpenLuminance") {
                    lumSharp.setValue(output, forKey: kCIInputImageKey)
                    lumSharp.setValue(Float(tools.sharpness * 0.46), forKey: kCIInputSharpnessKey)
                    output = lumSharp.outputImage?.cropped(to: extent) ?? output
                }
            }
            if tools.clarity >= 0.008 {
                // Local midtone micro-contrast (wide-radius unsharp mask + subtle contrast punch)
                if let localUnsharp = CIFilter(name: "CIUnsharpMask") {
                    localUnsharp.setValue(output, forKey: kCIInputImageKey)
                    localUnsharp.setValue(Float(9.5 * resScale), forKey: kCIInputRadiusKey)
                    localUnsharp.setValue(Float(tools.clarity * 0.42), forKey: kCIInputIntensityKey)
                    output = localUnsharp.outputImage?.cropped(to: extent) ?? output
                }
            }
        }

        return output.cropped(to: extent)
    }

    // MARK: - Stage 4: 12 GPU Optical & Analog Effects (Date & Frame Applied Crisp on CGImage in Stage 5)
    public func applyEffectsGraph(to input: CIImage, effects: PhotoEffectsState, isInteractiveProxy: Bool) -> CIImage {
        guard !effects.isIdentity else { return input }
        var output = normalizeOrigin(input)
        let extent = output.extent

        // 1. EXPIRED (Emulsion color cross-shift, lifted faded blacks, slight desat + extra grain)
        if effects.expired >= 0.01 {
            output = applyExpiredFilmEffect(to: output, intensity: Float(effects.expired))
        }

        // 2. FADE (Classic matte film black-point toe lift)
        if effects.fade >= 0.01 {
            output = applyMatteFadeEffect(to: output, intensity: Float(effects.fade))
        }

        // 3. HALATION (Remjet red-orange highlight scatter at 1/4 res)
        if effects.halation >= 0.01 {
            output = applyHalationEffect(to: output, intensity: Float(effects.halation))
        }

        // 4. BLOOM (Black Pro-Mist soft highlight bloom at 1/4 res)
        if effects.bloom >= 0.01 {
            output = applyOpticalBloomEffect(to: output, intensity: Float(effects.bloom), radius: Float(effects.bloomRadius))
        }

        // 5. STAR (4-point or 6-point cross-screen specular diffraction starburst)
        if effects.star >= 0.01 {
            output = applyStarburstEffect(to: output, intensity: Float(effects.star), points: effects.starPoints)
        }

        // 6. PRISM (Edge-masked optical glass chromatic dispersion + soft refraction ghost)
        if effects.prism >= 0.01 {
            output = applyPrismRefractionEffect(to: output, intensity: Float(effects.prism), axis: effects.prismAxis)
        }

        // 7. FLARE (Optical sun flare + chromatic bokeh ghost rings / anamorphic streak)
        if effects.flare >= 0.01 {
            output = applyLensFlareEffect(to: output, intensity: Float(effects.flare), style: effects.flareStyle)
        }

        // 8. LEAK (8 distinct organic analog film light leak washes)
        if effects.leak >= 0.01 {
            output = applyLightLeakEffect(to: output, intensity: Float(effects.leak), patternIndex: effects.leakPattern)
        }

        // 9. BURN (35mm end-of-roll fiery overexposure edge burn)
        if effects.burn >= 0.01 {
            output = applyFilmEdgeBurnEffect(to: output, intensity: Float(effects.burn), edge: effects.burnEdge)
        }

        // 10. VIGNETTE (Optical lens corner falloff)
        if effects.vignette >= 0.01 {
            if let vig = CIFilter(name: "CIVignette") {
                vig.setValue(output, forKey: kCIInputImageKey)
                vig.setValue(Float(effects.vignette * 1.65), forKey: kCIInputIntensityKey)
                vig.setValue(Float(effects.vignetteRadius), forKey: kCIInputRadiusKey)
                output = vig.outputImage?.cropped(to: extent) ?? output
            }
        }

        // 11. GRAIN (Resolution-normalized organic silver halide film grain)
        let effectiveGrain = min(1.0, effects.grain + effects.expired * 0.28)
        if effectiveGrain >= 0.01 {
            output = applyOrganicGrainEffect(
                to: output,
                intensity: Float(effectiveGrain),
                grainSize: Float(effects.grainSize)
            )
        }

        // 12. DUST (Cached deterministic procedural analog dust & fine hairs)
        if effects.dust >= 0.01 {
            output = applyFilmDustEffect(to: output, intensity: Float(effects.dust), seed: effects.dustSeed)
        }

        _ = isInteractiveProxy
        return output.cropped(to: extent)
    }

    // MARK: - Fused 8-Band HSL + 4-Channel Curves 3D LUT Generator (Pure Math, Deterministic, Cached)
    public func buildHSLAndCurvesCubeData(hsl: PhotoHSLState, curves: PhotoCurvesState, dimension: Int = 25) -> Data {
        let dim = max(9, min(33, dimension))
        let totalFloats = dim * dim * dim * 4
        var floats = [Float32](repeating: 0, count: totalFloats)

        let applyHSL = !hsl.isIdentity
        let applyCurves = !curves.isIdentity
        let rgbLUT = applyCurves ? curves.rgb.buildLUT(samples: 256) : []
        let rLUT = applyCurves ? curves.red.buildLUT(samples: 256) : []
        let gLUT = applyCurves ? curves.green.buildLUT(samples: 256) : []
        let bLUT = applyCurves ? curves.blue.buildLUT(samples: 256) : []

        let bands: [(center: Double, halfW: Double, val: PhotoHSLBandValue)] = PhotoHSLColorChannel.allCases.compactMap { ch in
            let v = hsl[ch]
            return v.isIdentity ? nil : (ch.centerHueDegrees, ch.halfWidthDegrees, v)
        }

        @inline(__always)
        func sampleLUT(_ lut: [Double], _ x: Double) -> Double {
            let clamped = max(0.0, min(1.0, x))
            let pos = clamped * 255.0
            let i0 = Int(pos)
            let i1 = min(255, i0 + 1)
            let frac = pos - Double(i0)
            return lut[i0] * (1.0 - frac) + lut[i1] * frac
        }

        let invMax = 1.0 / Double(dim - 1)
        var offset = 0
        for bIdx in 0..<dim {
            let bIn = Double(bIdx) * invMax
            for gIdx in 0..<dim {
                let gIn = Double(gIdx) * invMax
                for rIdx in 0..<dim {
                    var r = Double(rIdx) * invMax
                    var g = gIn
                    var b = bIn

                    if applyHSL && !bands.isEmpty {
                        (r, g, b) = Self.transformPixelHSL(r: r, g: g, b: b, activeBands: bands)
                    }

                    if applyCurves {
                        r = sampleLUT(rLUT, sampleLUT(rgbLUT, r))
                        g = sampleLUT(gLUT, sampleLUT(rgbLUT, g))
                        b = sampleLUT(bLUT, sampleLUT(rgbLUT, b))
                    }

                    floats[offset] = Float32(max(0.0, min(1.0, r)))
                    floats[offset + 1] = Float32(max(0.0, min(1.0, g)))
                    floats[offset + 2] = Float32(max(0.0, min(1.0, b)))
                    floats[offset + 3] = 1.0
                    offset += 4
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func cachedHSLAndCurvesCubeData(hsl: PhotoHSLState, curves: PhotoCurvesState, dimension: Int = 25) -> Data {
        let key = ColorCubeCacheKey(hsl: hsl, curves: curves)
        cacheLock.lock()
        if let hit = cubeCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let built = buildHSLAndCurvesCubeData(hsl: hsl, curves: curves, dimension: dimension)
        cacheLock.lock()
        cubeCache[key] = built
        cubeCacheOrder.append(key)
        if cubeCacheOrder.count > 12 {
            let oldest = cubeCacheOrder.removeFirst()
            cubeCache.removeValue(forKey: oldest)
        }
        cacheLock.unlock()
        return built
    }

    public static func transformPixelHSL(
        r: Double,
        g: Double,
        b: Double,
        activeBands: [(center: Double, halfW: Double, val: PhotoHSLBandValue)]
    ) -> (Double, Double, Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let l = 0.5 * (maxC + minC)
        guard delta > 1e-5 else { return (r, g, b) }

        let s = delta / max(1e-5, 1.0 - abs(2.0 * l - 1.0))
        var h: Double
        if maxC == r {
            h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == g {
            h = 60.0 * (((b - r) / delta) + 2.0)
        } else {
            h = 60.0 * (((r - g) / delta) + 4.0)
        }
        if h < 0 { h += 360.0 }

        let satMask = min(1.0, s / 0.12)
        var dHue = 0.0
        var dSat = 0.0
        var dLum = 0.0
        for band in activeBands {
            var diff = abs(h - band.center)
            if diff > 180.0 { diff = 360.0 - diff }
            if diff < band.halfW {
                let w = 0.5 * (1.0 + cos(.pi * diff / band.halfW))
                dHue += w * band.val.hue * 30.0
                dSat += w * band.val.saturation
                dLum += w * band.val.luminance
            }
        }
        if abs(dHue) < 1e-5 && abs(dSat) < 1e-5 && abs(dLum) < 1e-5 {
            return (r, g, b)
        }

        var hOut = (h + dHue).truncatingRemainder(dividingBy: 360.0)
        if hOut < 0 { hOut += 360.0 }
        let sOut = max(0.0, min(1.0, s * max(0.0, 1.0 + dSat * 0.90)))
        let bell = max(0.0, 1.0 - abs(2.0 * l - 1.0))
        let lOut = max(0.0, min(1.0, l + dLum * 0.28 * bell * satMask))

        // HSL -> RGB
        let c = (1.0 - abs(2.0 * lOut - 1.0)) * sOut
        let x = c * (1.0 - abs((hOut / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = lOut - c * 0.5
        let (r1, g1, b1): (Double, Double, Double)
        switch hOut {
        case 0..<60: (r1, g1, b1) = (c, x, 0)
        case 60..<120: (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (
            max(0.0, min(1.0, r1 + m)),
            max(0.0, min(1.0, g1 + m)),
            max(0.0, min(1.0, b1 + m))
        )
    }

    // MARK: - Individual GPU Effect Implementations
    private func applyHighlightShadowAdjustment(to input: CIImage, highlights: Float, shadows: Float) -> CIImage {
        #if canImport(UIKit)
        return FilmSimulationCore.applyLocalShadowHighlight(
            input,
            shadows: max(-1.0, min(1.0, shadows)) * 0.58,
            highlights: max(-1.0, min(1.0, highlights)) * 0.58
        )
        #else
        var output = input
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(output, forKey: kCIInputImageKey)
            // CoreImage defaults: inputHighlightAmount = 1.0 (lower recovers highlights), inputShadowAmount = 0.0
            let hiVal = max(0.25, min(1.65, 1.0 + highlights * 0.55))
            let shVal = max(-0.65, min(0.85, shadows * 0.65))
            hs.setValue(hiVal, forKey: "inputHighlightAmount")
            hs.setValue(shVal, forKey: "inputShadowAmount")
            output = hs.outputImage ?? output
        }
        return output
        #endif
    }

    private func applyExpiredFilmEffect(to input: CIImage, intensity: Float) -> CIImage {
        let t = CGFloat(max(0.0, min(1.0, intensity)))
        var output = input
        // Authentic expired film emulsion shift: greenish-cyan shadows, slightly warm magenta mids, reduced contrast
        if let cm = CIFilter(name: "CIColorMatrix") {
            cm.setValue(output, forKey: kCIInputImageKey)
            cm.setValue(CIVector(x: 1.0 - 0.06 * t, y: 0.05 * t, z: 0.02 * t, w: 0), forKey: "inputRVector")
            cm.setValue(CIVector(x: 0.02 * t, y: 1.0 + 0.04 * t, z: -0.02 * t, w: 0), forKey: "inputGVector")
            cm.setValue(CIVector(x: 0.04 * t, y: 0.03 * t, z: 1.0 - 0.10 * t, w: 0), forKey: "inputBVector")
            cm.setValue(CIVector(x: 0.025 * t, y: 0.055 * t, z: 0.035 * t, w: 0), forKey: "inputBiasVector")
            output = cm.outputImage ?? output
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(output, forKey: kCIInputImageKey)
            cc.setValue(Float(1.0 - 0.14 * t), forKey: kCIInputContrastKey)
            cc.setValue(Float(1.0 - 0.18 * t), forKey: kCIInputSaturationKey)
            output = cc.outputImage ?? output
        }
        return output.cropped(to: input.extent)
    }

    private func applyMatteFadeEffect(to input: CIImage, intensity: Float) -> CIImage {
        let t = CGFloat(max(0.0, min(1.0, intensity)))
        let toe = 0.145 * t
        let shoulder = 1.0 - 0.04 * t
        guard let curve = CIFilter(name: "CIToneCurve") else { return input }
        curve.setValue(input, forKey: kCIInputImageKey)
        curve.setValue(CIVector(x: 0.00, y: toe), forKey: "inputPoint0")
        curve.setValue(CIVector(x: 0.25, y: 0.25 + toe * 0.55), forKey: "inputPoint1")
        curve.setValue(CIVector(x: 0.50, y: 0.50 + toe * 0.18), forKey: "inputPoint2")
        curve.setValue(CIVector(x: 0.75, y: 0.75 - 0.015 * t), forKey: "inputPoint3")
        curve.setValue(CIVector(x: 1.00, y: shoulder), forKey: "inputPoint4")
        return curve.outputImage?.cropped(to: input.extent) ?? input
    }

    private func applyHalationEffect(to input: CIImage, intensity: Float) -> CIImage {
        let extent = input.extent
        let dim = max(extent.width, extent.height)
        guard dim > 8 else { return input }
        let downScale: CGFloat = dim > 480 ? 0.25 : 0.5
        let smallExt = CGRect(
            x: 0,
            y: 0,
            width: max(4, ceil(extent.width * downScale)),
            height: max(4, ceil(extent.height * downScale))
        )
        let small = input.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downScale, y: downScale))
            .cropped(to: smallExt)

        // Calibrated for extendedLinearSRGB working space so highlights above ~0.72 sRGB (~0.48 linear)
        // produce a lush, authentic Remjet red-orange scatter halo without tinting normal midtones.
        guard let thresh = CIFilter(name: "CIColorMatrix") else { return input }
        thresh.setValue(small, forKey: kCIInputImageKey)
        thresh.setValue(CIVector(x: 1.65, y: 0.62, z: 0.25, w: 0), forKey: "inputRVector")
        thresh.setValue(CIVector(x: 0.45, y: 1.45, z: 0.40, w: 0), forKey: "inputGVector")
        thresh.setValue(CIVector(x: 0.25, y: 0.40, z: 1.25, w: 0), forKey: "inputBVector")
        thresh.setValue(CIVector(x: -1.16, y: -1.16, z: -1.16, w: 0), forKey: "inputBiasVector")
        guard let rawHi = thresh.outputImage else { return input }
        let bright = clampPositive(rawHi).cropped(to: smallExt)

        let effectiveRadius = max(2.0, 18.0 * Float(max(0.25, min(8.0, dim / 1000.0)) * downScale))
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return input }
        blur.setValue(bright.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(effectiveRadius, forKey: kCIInputRadiusKey)
        guard let blurredSmall = blur.outputImage?.cropped(to: smallExt) else { return input }

        let inv = 1.0 / downScale
        let blurred = blurredSmall.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: inv, y: inv))
            .cropped(to: extent)

        guard let tint = CIFilter(name: "CIColorMatrix") else { return input }
        tint.setValue(blurred, forKey: kCIInputImageKey)
        tint.setValue(CIVector(x: CGFloat(intensity * 1.78), y: 0, z: 0, w: 0), forKey: "inputRVector")
        tint.setValue(CIVector(x: 0, y: CGFloat(intensity * 0.44), z: 0, w: 0), forKey: "inputGVector")
        tint.setValue(CIVector(x: 0, y: 0, z: CGFloat(intensity * 0.10), w: 0), forKey: "inputBVector")
        guard let glow = tint.outputImage else { return input }
        return screenBlend(top: glow, bottom: input, extent: extent)
    }

    private func applyOpticalBloomEffect(to input: CIImage, intensity: Float, radius: Float) -> CIImage {
        let extent = input.extent
        let dim = max(extent.width, extent.height)
        guard dim > 8 else { return input }
        let downScale: CGFloat = dim > 480 ? 0.25 : 0.5
        let smallExt = CGRect(
            x: 0,
            y: 0,
            width: max(4, ceil(extent.width * downScale)),
            height: max(4, ceil(extent.height * downScale))
        )
        let small = input.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downScale, y: downScale))
            .cropped(to: smallExt)

        // Extract upper-mid to highlight glow smoothly (Black Pro-Mist halation/bloom)
        guard let thresh = CIFilter(name: "CIColorMatrix") else { return input }
        thresh.setValue(small, forKey: kCIInputImageKey)
        thresh.setValue(CIVector(x: 1.45, y: 0, z: 0, w: 0), forKey: "inputRVector")
        thresh.setValue(CIVector(x: 0, y: 1.45, z: 0, w: 0), forKey: "inputGVector")
        thresh.setValue(CIVector(x: 0, y: 0, z: 1.45, w: 0), forKey: "inputBVector")
        thresh.setValue(CIVector(x: -0.78, y: -0.78, z: -0.78, w: 0), forKey: "inputBiasVector")
        guard let rawHi = thresh.outputImage else { return input }
        let bright = clampPositive(rawHi).cropped(to: smallExt)

        let effectiveRadius = max(1.5, radius * Float(max(0.25, min(8.0, dim / 1000.0)) * downScale))
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return input }
        blur.setValue(bright.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(effectiveRadius, forKey: kCIInputRadiusKey)
        guard let blurredSmall = blur.outputImage?.cropped(to: smallExt) else { return input }

        let inv = 1.0 / downScale
        let blurred = blurredSmall.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: inv, y: inv))
            .cropped(to: extent)

        guard let scaleFilter = CIFilter(name: "CIColorMatrix") else { return input }
        scaleFilter.setValue(blurred, forKey: kCIInputImageKey)
        let k = CGFloat(intensity * 0.68)
        scaleFilter.setValue(CIVector(x: k * 1.04, y: 0, z: 0, w: 0), forKey: "inputRVector")
        scaleFilter.setValue(CIVector(x: 0, y: k * 1.01, z: 0, w: 0), forKey: "inputGVector")
        scaleFilter.setValue(CIVector(x: 0, y: 0, z: k * 0.96, w: 0), forKey: "inputBVector")
        guard let bloomLayer = scaleFilter.outputImage else { return input }
        return screenBlend(top: bloomLayer, bottom: input, extent: extent)
    }

    private func applyStarburstEffect(to input: CIImage, intensity: Float, points: PhotoStarPoints) -> CIImage {
        let extent = input.extent
        let dim = max(extent.width, extent.height)
        guard dim > 8 else { return input }
        let downScale: CGFloat = dim > 480 ? 0.25 : 0.5
        let smallExt = CGRect(
            x: 0,
            y: 0,
            width: max(4, ceil(extent.width * downScale)),
            height: max(4, ceil(extent.height * downScale))
        )
        let small = input.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downScale, y: downScale))
            .cropped(to: smallExt)

        // Isolate specular bright points
        guard let thresh = CIFilter(name: "CIColorMatrix") else { return input }
        thresh.setValue(small, forKey: kCIInputImageKey)
        thresh.setValue(CIVector(x: 3.2, y: 0, z: 0, w: 0), forKey: "inputRVector")
        thresh.setValue(CIVector(x: 0, y: 3.2, z: 0, w: 0), forKey: "inputGVector")
        thresh.setValue(CIVector(x: 0, y: 0, z: 3.2, w: 0), forKey: "inputBVector")
        thresh.setValue(CIVector(x: -2.42, y: -2.42, z: -2.42, w: 0), forKey: "inputBiasVector")
        guard let rawSpec = thresh.outputImage else { return input }
        let spec = clampPositive(rawSpec).cropped(to: smallExt)

        let rayRadius = Float(max(4.0, min(42.0, max(smallExt.width, smallExt.height) * 0.14)))
        let angles: [Float] = (points == .six)
            ? [0.0, Float.pi / 3.0, 2.0 * Float.pi / 3.0]
            : [Float.pi / 4.0, 3.0 * Float.pi / 4.0]

        var combinedRays: CIImage? = nil
        for angle in angles {
            guard let mb = CIFilter(name: "CIMotionBlur") else { continue }
            mb.setValue(spec.clampedToExtent(), forKey: kCIInputImageKey)
            mb.setValue(rayRadius, forKey: kCIInputRadiusKey)
            mb.setValue(angle, forKey: kCIInputAngleKey)
            guard let ray = mb.outputImage?.cropped(to: smallExt) else { continue }
            if let existing = combinedRays, let add = CIFilter(name: "CIAdditionCompositing") {
                add.setValue(ray, forKey: kCIInputImageKey)
                add.setValue(existing, forKey: kCIInputBackgroundImageKey)
                combinedRays = add.outputImage?.cropped(to: smallExt) ?? existing
            } else {
                combinedRays = ray
            }
        }
        guard let raysSmall = combinedRays else { return input }
        let inv = 1.0 / downScale
        let raysFull = raysSmall.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: inv, y: inv))
            .cropped(to: extent)

        guard let amp = CIFilter(name: "CIColorMatrix") else { return input }
        amp.setValue(raysFull, forKey: kCIInputImageKey)
        let k = CGFloat(intensity * 0.95)
        amp.setValue(CIVector(x: k, y: 0, z: 0, w: 0), forKey: "inputRVector")
        amp.setValue(CIVector(x: 0, y: k * 0.98, z: 0, w: 0), forKey: "inputGVector")
        amp.setValue(CIVector(x: 0, y: 0, z: k * 0.92, w: 0), forKey: "inputBVector")
        guard let starLayer = amp.outputImage else { return input }
        return screenBlend(top: starLayer, bottom: input, extent: extent)
    }

    private func applyPrismRefractionEffect(to input: CIImage, intensity: Float, axis: PhotoPrismAxis) -> CIImage {
        let extent = input.extent
        let dim = max(extent.width, extent.height)
        guard dim > 8 else { return input }
        let shiftMag = dim * CGFloat(0.012 * Double(intensity))
        let ghostMag = dim * CGFloat(0.045 * Double(intensity))
        let (dx, dy): (CGFloat, CGFloat)
        switch axis {
        case .horizontal: (dx, dy) = (shiftMag, 0)
        case .vertical: (dx, dy) = (0, shiftMag)
        case .diagonal: (dx, dy) = (shiftMag * 0.72, shiftMag * 0.72)
        }

        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, tx: CGFloat, ty: CGFloat) -> CIImage? {
            guard let cm = CIFilter(name: "CIColorMatrix") else { return nil }
            cm.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            cm.setValue(CIVector(x: r, y: 0, z: 0, w: 0), forKey: "inputRVector")
            cm.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
            cm.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
            return cm.outputImage?.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: extent)
        }

        guard let rCh = channel(1, 0, 0, tx: dx, ty: dy),
              let gCh = channel(0, 1, 0, tx: 0, ty: 0),
              let bCh = channel(0, 0, 1, tx: -dx, ty: -dy),
              let add1 = CIFilter(name: "CIAdditionCompositing"),
              let add2 = CIFilter(name: "CIAdditionCompositing") else { return input }

        add1.setValue(rCh, forKey: kCIInputImageKey)
        add1.setValue(gCh, forKey: kCIInputBackgroundImageKey)
        guard let rg = add1.outputImage else { return input }
        add2.setValue(bCh, forKey: kCIInputImageKey)
        add2.setValue(rg, forKey: kCIInputBackgroundImageKey)
        guard var refracted = add2.outputImage?.cropped(to: extent) else { return input }

        // Soft secondary glass-edge reflection ghost
        let ghostShift = CGAffineTransform(translationX: axis == .vertical ? 0 : ghostMag, y: axis == .horizontal ? 0 : ghostMag)
        let ghost = input.clampedToExtent().transformed(by: ghostShift).cropped(to: extent)
        if let ghostTint = CIFilter(name: "CIColorMatrix") {
            ghostTint.setValue(ghost, forKey: kCIInputImageKey)
            let a = CGFloat(0.28 * intensity)
            ghostTint.setValue(CIVector(x: a * 1.1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            ghostTint.setValue(CIVector(x: 0, y: a * 0.98, z: 0, w: 0), forKey: "inputGVector")
            ghostTint.setValue(CIVector(x: 0, y: 0, z: a * 1.15, w: 0), forKey: "inputBVector")
            if let gLayer = ghostTint.outputImage {
                refracted = screenBlend(top: gLayer, bottom: refracted, extent: extent)
            }
        }

        // Edge-only radial mask keeps subject center sharp while edges shimmer with prism dispersion
        guard let rad = CIFilter(name: "CIRadialGradient"),
              let blendMask = CIFilter(name: "CIBlendWithMask") else { return refracted }
        rad.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        rad.setValue(dim * 0.22, forKey: "inputRadius0")
        rad.setValue(dim * 0.62, forKey: "inputRadius1")
        rad.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor0")
        rad.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
        guard let mask = rad.outputImage?.cropped(to: extent) else { return refracted }

        blendMask.setValue(refracted, forKey: kCIInputImageKey)
        blendMask.setValue(input, forKey: kCIInputBackgroundImageKey)
        blendMask.setValue(mask, forKey: kCIInputMaskImageKey)
        return blendMask.outputImage?.cropped(to: extent) ?? input
    }

    private func applyLensFlareEffect(to input: CIImage, intensity: Float, style: PhotoFlareStyle) -> CIImage {
        let extent = input.extent
        let w = extent.width
        let h = extent.height
        let dim = max(w, h)
        let t = CGFloat(max(0.0, min(1.0, intensity)))
        var output = input

        func radialGlow(cx: CGFloat, cy: CGFloat, r0: CGFloat, r1: CGFloat, color: CIColor) -> CIImage? {
            guard let g = CIFilter(name: "CIRadialGradient") else { return nil }
            g.setValue(CIVector(x: cx, y: cy), forKey: "inputCenter")
            g.setValue(r0, forKey: "inputRadius0")
            g.setValue(r1, forKey: "inputRadius1")
            g.setValue(color, forKey: "inputColor0")
            g.setValue(CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0), forKey: "inputColor1")
            return g.outputImage?.cropped(to: extent)
        }

        switch style {
        case .topLeftSun, .topRightSun:
            let sx: CGFloat = (style == .topLeftSun) ? w * 0.14 : w * 0.86
            let sy: CGFloat = h * 0.86
            let dx = w * 0.5 - sx
            let dy = h * 0.5 - sy
            // Main warm sun glow
            if let core = radialGlow(cx: sx, cy: sy, r0: 0, r1: dim * 0.42,
                                     color: CIColor(red: 1.0, green: 0.84, blue: 0.54, alpha: 0.52 * t)) {
                output = screenBlend(top: core, bottom: output, extent: extent)
            }
            // Secondary chromatic lens ghost discs along optical axis
            let ghosts: [(pos: CGFloat, rad: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = [
                (0.55, 0.12, 1.0, 0.65, 0.30, 0.24),
                (1.18, 0.08, 0.35, 0.82, 0.96, 0.22),
                (1.55, 0.16, 0.92, 0.42, 0.72, 0.18)
            ]
            for ghost in ghosts {
                if let gImg = radialGlow(
                    cx: sx + dx * ghost.pos,
                    cy: sy + dy * ghost.pos,
                    r0: dim * ghost.rad * 0.15,
                    r1: dim * ghost.rad,
                    color: CIColor(red: ghost.r, green: ghost.g, blue: ghost.b, alpha: ghost.a * t)
                ) {
                    output = screenBlend(top: gImg, bottom: output, extent: extent)
                }
            }

        case .anamorphicStreak:
            // Classic cinema horizontal cyan-amber optical streak across upper third
            let streakY = h * 0.62
            if let base = radialGlow(cx: w * 0.5, cy: streakY, r0: 0, r1: w * 0.48,
                                     color: CIColor(red: 0.32, green: 0.78, blue: 1.0, alpha: 0.45 * t)) {
                let squashed = base
                    .transformed(by: CGAffineTransform(translationX: 0, y: -streakY))
                    .transformed(by: CGAffineTransform(scaleX: 1.35, y: 0.10))
                    .transformed(by: CGAffineTransform(translationX: -w * 0.175, y: streakY))
                    .cropped(to: extent)
                output = screenBlend(top: squashed, bottom: output, extent: extent)
            }
            if let hotCore = radialGlow(cx: w * 0.5, cy: streakY, r0: 0, r1: dim * 0.18,
                                        color: CIColor(red: 1.0, green: 0.92, blue: 0.78, alpha: 0.36 * t)) {
                output = screenBlend(top: hotCore, bottom: output, extent: extent)
            }

        case .opticalHalo:
            // Warm circular vintage coating rainbow halo ring
            if let outer = radialGlow(cx: w * 0.5, cy: h * 0.5, r0: dim * 0.26, r1: dim * 0.44,
                                      color: CIColor(red: 1.0, green: 0.68, blue: 0.34, alpha: 0.32 * t)) {
                output = screenBlend(top: outer, bottom: output, extent: extent)
            }
            if let innerCut = radialGlow(cx: w * 0.5, cy: h * 0.5, r0: 0, r1: dim * 0.28,
                                         color: CIColor(red: 0.42, green: 0.72, blue: 0.98, alpha: 0.18 * t)) {
                output = screenBlend(top: innerCut, bottom: output, extent: extent)
            }
        }
        return output.cropped(to: extent)
    }

    private func applyLightLeakEffect(to input: CIImage, intensity: Float, patternIndex: Int) -> CIImage {
        let extent = input.extent
        let w = extent.width
        let h = extent.height
        let dim = max(w, h)
        let t = CGFloat(max(0.0, min(1.0, intensity)))
        let p = ((patternIndex % 8) + 8) % 8

        struct LeakLobe {
            let nx: CGFloat; let ny: CGFloat; let radius: CGFloat
            let r: CGFloat; let g: CGFloat; let b: CGFloat; let a: CGFloat
        }

        let lobes: [LeakLobe]
        switch p {
        case 0:
            lobes = [
                LeakLobe(nx: 0.06, ny: 0.84, radius: 0.58, r: 1.00, g: 0.44, b: 0.12, a: 0.55),
                LeakLobe(nx: 0.18, ny: 0.62, radius: 0.42, r: 1.00, g: 0.72, b: 0.20, a: 0.34)
            ]
        case 1:
            lobes = [
                LeakLobe(nx: 0.94, ny: 0.78, radius: 0.60, r: 0.98, g: 0.26, b: 0.16, a: 0.54),
                LeakLobe(nx: 0.80, ny: 0.50, radius: 0.44, r: 1.00, g: 0.58, b: 0.18, a: 0.34)
            ]
        case 2:
            lobes = [
                LeakLobe(nx: 0.08, ny: 0.18, radius: 0.56, r: 1.00, g: 0.30, b: 0.36, a: 0.52),
                LeakLobe(nx: 0.25, ny: 0.12, radius: 0.40, r: 1.00, g: 0.64, b: 0.14, a: 0.36)
            ]
        case 3:
            lobes = [
                LeakLobe(nx: 0.92, ny: 0.16, radius: 0.58, r: 0.96, g: 0.28, b: 0.64, a: 0.48),
                LeakLobe(nx: 0.76, ny: 0.26, radius: 0.42, r: 1.00, g: 0.46, b: 0.18, a: 0.36)
            ]
        case 4:
            lobes = [
                LeakLobe(nx: 0.50, ny: 0.96, radius: 0.55, r: 1.00, g: 0.56, b: 0.16, a: 0.50),
                LeakLobe(nx: 0.35, ny: 0.86, radius: 0.38, r: 0.96, g: 0.22, b: 0.12, a: 0.32)
            ]
        case 5:
            lobes = [
                LeakLobe(nx: 0.04, ny: 0.50, radius: 0.52, r: 1.00, g: 0.34, b: 0.10, a: 0.54),
                LeakLobe(nx: 0.96, ny: 0.50, radius: 0.46, r: 0.98, g: 0.66, b: 0.24, a: 0.38)
            ]
        case 6:
            lobes = [
                LeakLobe(nx: 0.88, ny: 0.90, radius: 0.54, r: 0.98, g: 0.74, b: 0.26, a: 0.48),
                LeakLobe(nx: 0.14, ny: 0.16, radius: 0.46, r: 0.94, g: 0.22, b: 0.38, a: 0.38)
            ]
        default:
            lobes = [
                LeakLobe(nx: 0.50, ny: 0.04, radius: 0.56, r: 1.00, g: 0.38, b: 0.12, a: 0.52),
                LeakLobe(nx: 0.66, ny: 0.18, radius: 0.40, r: 1.00, g: 0.74, b: 0.30, a: 0.34)
            ]
        }

        var output = input
        for lobe in lobes {
            guard let rad = CIFilter(name: "CIRadialGradient") else { continue }
            rad.setValue(CIVector(x: w * lobe.nx, y: h * lobe.ny), forKey: "inputCenter")
            rad.setValue(0.0, forKey: "inputRadius0")
            rad.setValue(dim * lobe.radius, forKey: "inputRadius1")
            rad.setValue(CIColor(red: lobe.r, green: lobe.g, blue: lobe.b, alpha: lobe.a * t), forKey: "inputColor0")
            rad.setValue(CIColor(red: lobe.r * 0.7, green: lobe.g * 0.4, blue: lobe.b * 0.3, alpha: 0), forKey: "inputColor1")
            if let wash = rad.outputImage?.cropped(to: extent) {
                output = screenBlend(top: wash, bottom: output, extent: extent)
            }
        }
        return output.cropped(to: extent)
    }

    private func applyFilmEdgeBurnEffect(to input: CIImage, intensity: Float, edge: PhotoBurnEdge) -> CIImage {
        let extent = input.extent
        let w = extent.width
        let h = extent.height
        let t = CGFloat(max(0.0, min(1.0, intensity)))
        let depth = CGFloat(0.16 + 0.22 * Double(intensity))

        let p0: CIVector
        let p1: CIVector
        let pMid: CIVector
        switch edge {
        case .left:
            p0 = CIVector(x: 0, y: h * 0.5)
            pMid = CIVector(x: w * depth * 0.42, y: h * 0.5)
            p1 = CIVector(x: w * depth, y: h * 0.5)
        case .right:
            p0 = CIVector(x: w, y: h * 0.5)
            pMid = CIVector(x: w * (1.0 - depth * 0.42), y: h * 0.5)
            p1 = CIVector(x: w * (1.0 - depth), y: h * 0.5)
        case .top:
            p0 = CIVector(x: w * 0.5, y: h)
            pMid = CIVector(x: w * 0.5, y: h * (1.0 - depth * 0.42))
            p1 = CIVector(x: w * 0.5, y: h * (1.0 - depth))
        case .bottom:
            p0 = CIVector(x: w * 0.5, y: 0)
            pMid = CIVector(x: w * 0.5, y: h * depth * 0.42)
            p1 = CIVector(x: w * 0.5, y: h * depth)
        }

        var output = input
        // Outer fiery crimson-orange film burn gradient
        if let outerGrad = CIFilter(name: "CILinearGradient") {
            outerGrad.setValue(p0, forKey: "inputPoint0")
            outerGrad.setValue(p1, forKey: "inputPoint1")
            outerGrad.setValue(CIColor(red: 1.00, green: 0.34, blue: 0.06, alpha: 0.82 * t), forKey: "inputColor0")
            outerGrad.setValue(CIColor(red: 0.72, green: 0.10, blue: 0.02, alpha: 0.0), forKey: "inputColor1")
            if let layer = outerGrad.outputImage?.cropped(to: extent) {
                output = screenBlend(top: layer, bottom: output, extent: extent)
            }
        }
        // Hot incandescent white-yellow core along the exposed film edge
        if let hotCore = CIFilter(name: "CILinearGradient") {
            hotCore.setValue(p0, forKey: "inputPoint0")
            hotCore.setValue(pMid, forKey: "inputPoint1")
            hotCore.setValue(CIColor(red: 1.00, green: 0.92, blue: 0.68, alpha: 0.78 * t), forKey: "inputColor0")
            hotCore.setValue(CIColor(red: 1.00, green: 0.52, blue: 0.12, alpha: 0.0), forKey: "inputColor1")
            if let layer = hotCore.outputImage?.cropped(to: extent) {
                output = screenBlend(top: layer, bottom: output, extent: extent)
            }
        }
        return output.cropped(to: extent)
    }

    private func applyOrganicGrainEffect(to input: CIImage, intensity: Float, grainSize: Float) -> CIImage {
        let extent = input.extent
        let maxDim = max(extent.width, extent.height)
        guard maxDim > 4, let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        let physicalScale = max(1.0, (maxDim / 1100.0) * CGFloat(max(0.6, min(2.4, grainSize))))
        let scaled = random
            .transformed(by: CGAffineTransform(scaleX: physicalScale, y: physicalScale))
            .cropped(to: extent)

        guard let mono = CIFilter(name: "CIColorControls") else { return input }
        mono.setValue(scaled, forKey: kCIInputImageKey)
        mono.setValue(0.0, forKey: kCIInputSaturationKey)
        mono.setValue(1.22, forKey: kCIInputContrastKey)
        guard let monoNoise = mono.outputImage else { return input }

        guard let alphaMat = CIFilter(name: "CIColorMatrix") else { return input }
        alphaMat.setValue(monoNoise, forKey: kCIInputImageKey)
        alphaMat.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        alphaMat.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        alphaMat.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        alphaMat.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(0.42, intensity * 0.34))), forKey: "inputAVector")
        guard let controlled = alphaMat.outputImage else { return input }

        guard let blend = CIFilter(name: "CISoftLightBlendMode") else { return input }
        blend.setValue(controlled, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        return blend.outputImage?.cropped(to: extent) ?? input
    }

    private func applyFilmDustEffect(to input: CIImage, intensity: Float, seed: Int) -> CIImage {
        let extent = input.extent
        guard extent.width > 8, extent.height > 8 else { return input }
        let s = ((seed % 5) + 5) % 5
        let baseTexture = cachedDustTexture(seed: s)
        let texExt = baseTexture.extent
        guard texExt.width > 1, texExt.height > 1 else { return input }

        let sx = extent.width / texExt.width
        let sy = extent.height / texExt.height
        let scaledDust = baseTexture
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: extent)

        guard let opacity = CIFilter(name: "CIColorMatrix") else { return input }
        opacity.setValue(scaledDust, forKey: kCIInputImageKey)
        let k = CGFloat(max(0.0, min(1.0, intensity)) * 0.85)
        opacity.setValue(CIVector(x: k, y: 0, z: 0, w: 0), forKey: "inputRVector")
        opacity.setValue(CIVector(x: 0, y: k, z: 0, w: 0), forKey: "inputGVector")
        opacity.setValue(CIVector(x: 0, y: 0, z: k, w: 0), forKey: "inputBVector")
        guard let dustLayer = opacity.outputImage else { return input }
        return screenBlend(top: dustLayer, bottom: input, extent: extent)
    }

    private func cachedDustTexture(seed: Int) -> CIImage {
        cacheLock.lock()
        if let hit = dustTextureCache[seed] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let size = 768
        let cs = srgbColorSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        }

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        var rng = DarkroomSplitMix64(seed: UInt64(seed &* 7919 + 4211))

        // Fine white & warm-cream analog film dust specks & soft emulsion flecks
        for _ in 0..<320 {
            let x = CGFloat(rng.nextUnitDouble()) * CGFloat(size)
            let y = CGFloat(rng.nextUnitDouble()) * CGFloat(size)
            let r = CGFloat(1.1 + pow(rng.nextUnitDouble(), 1.9) * 3.8)
            let alpha = CGFloat(0.45 + rng.nextUnitDouble() * 0.55)
            let warm = CGFloat(rng.nextUnitDouble() * 0.14)
            ctx.setFillColor(red: 1.0, green: 0.96 - warm * 0.3, blue: 0.90 - warm, alpha: alpha)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }

        // Delicate micro fiber hairs & subtle vertical film emulsion scratches
        for i in 0..<32 {
            let x0 = CGFloat(rng.nextUnitDouble()) * CGFloat(size)
            let y0 = CGFloat(rng.nextUnitDouble()) * CGFloat(size)
            let len = CGFloat(18.0 + rng.nextUnitDouble() * (i < 7 ? 160.0 : 42.0))
            let angle = (i < 7) ? CGFloat.pi * 0.5 + CGFloat((rng.nextUnitDouble() - 0.5) * 0.05) : CGFloat(rng.nextUnitDouble() * .pi * 2.0)
            let x1 = x0 + cos(angle) * len
            let y1 = y0 + sin(angle) * len
            let cx = (x0 + x1) * 0.5 + CGFloat((rng.nextUnitDouble() - 0.5) * 18.0)
            let cy = (y0 + y1) * 0.5 + CGFloat((rng.nextUnitDouble() - 0.5) * 18.0)
            ctx.setStrokeColor(red: 1.0, green: 0.96, blue: 0.90, alpha: CGFloat(0.40 + rng.nextUnitDouble() * 0.52))
            ctx.setLineWidth(CGFloat(1.0 + rng.nextUnitDouble() * 1.1))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x0, y: y0))
            ctx.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy))
            ctx.strokePath()
        }

        let built = ctx.makeImage().map { CIImage(cgImage: $0) }
            ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))

        cacheLock.lock()
        dustTextureCache[seed] = built
        cacheLock.unlock()
        return built
    }

    // MARK: - Stage 5a: Retro Quartz Date Stamp
    private func applyDateStamp(to cgImage: CGImage, mode: PhotoDateStampMode, date: Date) -> CGImage {
        guard mode.isEnabled else { return cgImage }
        #if canImport(UIKit)
        let style: VintageDateStampStyle
        switch mode {
        case .off: return cgImage
        case .classicQuartz: style = .classicQuartz
        case .retroLED: style = .retroLED
        case .compactSlanted: style = .compactSlanted
        }
        return VintageDateStampRenderer.imprint(on: cgImage, style: style, date: date) ?? cgImage
        #else
        // Pure CoreGraphics glowing amber quartz block imprint for macOS regression verification
        let w = cgImage.width
        let h = cgImage.height
        guard w > 32, h > 32 else { return cgImage }
        let cs = cgImage.colorSpace ?? srgbColorSpace
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bw = CGFloat(w) * 0.18
        let bh = CGFloat(h) * 0.045
        let rect = CGRect(x: CGFloat(w) * 0.95 - bw, y: CGFloat(h) * 0.045, width: bw, height: bh)
        ctx.setFillColor(red: 1.0, green: 0.34, blue: 0.10, alpha: 0.95)
        ctx.fill(rect)
        return ctx.makeImage() ?? cgImage
        #endif
    }

    // MARK: - Stage 5b: Gallery, Polaroid & Master Watermark Frames
    #if canImport(UIKit)
    private func applyFrame(
        to cgImage: CGImage,
        style: PhotoFrameStyle,
        logo: PhotoFrameLogoOption,
        metadata: PhotoDarkroomRenderMetadata,
        customLogo: UIImage?
    ) -> CGImage {
        guard style.isEnabled else { return cgImage }
        switch style {
        case .off:
            return cgImage
        case .leicaWhite, .studioBlack:
            let theme: WatermarkTheme = (style == .leicaWhite) ? .white : .black
            let logoStyle: WatermarkLogoStyle
            switch logo {
            case .alignStudio: logoStyle = .alignStudio
            case .aperturePro: logoStyle = .aperturePro
            case .none: logoStyle = .none
            }
            let specs = PhotoWatermarkSpecs.from(
                iso: metadata.iso,
                shutterSpeed: metadata.shutterSpeed,
                focalLength: metadata.focalLengthMM,
                aperture: metadata.aperture
            )
            return MasterWatermarkRenderer.shared.renderWatermark(
                on: cgImage,
                deviceName: metadata.deviceName,
                theme: theme,
                logoStyle: logoStyle,
                customLogo: customLogo,
                specs: specs
            ) ?? cgImage
        case .filmBorderWhite, .filmBorderBlack, .polaroidClassic:
            return renderPureBorderFrame(on: cgImage, style: style)
        }
    }
    #else
    private func applyFrame(
        to cgImage: CGImage,
        style: PhotoFrameStyle,
        logo: PhotoFrameLogoOption,
        metadata: PhotoDarkroomRenderMetadata
    ) -> CGImage {
        guard style.isEnabled else { return cgImage }
        return renderPureBorderFrame(on: cgImage, style: style)
    }
    #endif

    private func renderPureBorderFrame(on cgImage: CGImage, style: PhotoFrameStyle) -> CGImage {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW >= 16, imgH >= 16 else { return cgImage }

        let baseDim = max(imgW, imgH)
        let topPad: CGFloat
        let sidePad: CGFloat
        let bottomPad: CGFloat
        let bgRGB: (CGFloat, CGFloat, CGFloat)

        switch style {
        case .off:
            return cgImage
        case .filmBorderWhite, .leicaWhite:
            let p = max(8.0, round(baseDim * 0.044))
            topPad = p; sidePad = p; bottomPad = p
            bgRGB = (0.985, 0.985, 0.982)
        case .filmBorderBlack, .studioBlack:
            let p = max(8.0, round(baseDim * 0.044))
            topPad = p; sidePad = p; bottomPad = p
            bgRGB = (0.045, 0.045, 0.052)
        case .polaroidClassic:
            let p = max(10.0, round(baseDim * 0.052))
            topPad = p; sidePad = p
            bottomPad = max(24.0, round(baseDim * 0.175))
            bgRGB = (0.968, 0.960, 0.942)
        }

        let canvasW = Int(round(imgW + sidePad * 2.0))
        let canvasH = Int(round(imgH + topPad + bottomPad))
        let cs = cgImage.colorSpace ?? srgbColorSpace
        guard let ctx = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }

        ctx.setFillColor(red: bgRGB.0, green: bgRGB.1, blue: bgRGB.2, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        // CoreGraphics has bottom-left origin: bottomPad sits below the photo
        let drawRect = CGRect(x: sidePad, y: bottomPad, width: imgW, height: imgH)
        ctx.draw(cgImage, in: drawRect)

        // Subtle crisp hairline bevel around inner photo for Polaroid archival feel
        if style == .polaroidClassic {
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.09)
            ctx.setLineWidth(max(1.0, baseDim * 0.0014))
            ctx.stroke(drawRect)
        }

        return ctx.makeImage() ?? cgImage
    }

    // MARK: - CoreImage Utility Helpers
    private func normalizeOrigin(_ img: CIImage) -> CIImage {
        let ext = img.extent
        guard ext.origin.x != 0 || ext.origin.y != 0 else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
    }

    private func clampPositive(_ img: CIImage) -> CIImage {
        guard let clamp = CIFilter(name: "CIColorClamp") else { return img }
        clamp.setValue(img, forKey: kCIInputImageKey)
        clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clamp.setValue(CIVector(x: 4, y: 4, z: 4, w: 1), forKey: "inputMaxComponents")
        return clamp.outputImage ?? img
    }

    private func clampToUnitRange(_ img: CIImage) -> CIImage {
        guard let clamp = CIFilter(name: "CIColorClamp") else { return img }
        clamp.setValue(img, forKey: kCIInputImageKey)
        clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return clamp.outputImage ?? img
    }

    private func screenBlend(top: CIImage, bottom: CIImage, extent: CGRect) -> CIImage {
        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return bottom }
        screen.setValue(top, forKey: kCIInputImageKey)
        screen.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return screen.outputImage?.cropped(to: extent) ?? bottom
    }
}

#if canImport(UIKit)
// MARK: - Zero-Lag Coalesced Preview & Lazy Thumbnail Session Coordinator (iOS Only)
public final class PhotoDarkroomSessionCoordinator: @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "com.alignai.darkroom.preview", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let thumbQueue = DispatchQueue(label: "com.alignai.darkroom.thumbs", qos: .utility, autoreleaseFrequency: .workItem)
    private let tokenLock = NSLock()
    private var latestPreviewToken: UInt64 = 0
    private var isTornDown: Bool = false

    private let thumbCache = NSCache<NSString, UIImage>()
    private var workingProxyCG: CGImage?
    private var thumbnailBaseCG: CGImage?

    public init() {
        thumbCache.countLimit = 44
        thumbCache.totalCostLimit = 6 * 1024 * 1024 // ~6 MB hard cap
    }

    /// Prepares the single 1440px interactive proxy and 132px thumbnail base once on a background thread.
    public func prepareProxies(
        from originalCG: CGImage,
        predecodedDisplay: UIImage?,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        renderQueue.async { [weak self] in
            guard let self, !self.checkTornDown() else { return }
            autoreleasepool {
                let proxyCG: CGImage
                if let preCG = predecodedDisplay?.cgImage,
                   max(preCG.width, preCG.height) <= 1650,
                   max(preCG.width, preCG.height) >= 480 {
                    proxyCG = preCG
                } else {
                    proxyCG = Self.downsampleCG(originalCG, maxSide: 1440)
                }
                let thumbCG = Self.downsampleCG(proxyCG, maxSide: 132)
                self.tokenLock.lock()
                self.workingProxyCG = proxyCG
                self.thumbnailBaseCG = thumbCG
                self.tokenLock.unlock()
            }
            Task { @MainActor in
                completion()
            }
        }
    }

    /// Coalesced background preview render: rapid 60Hz slider drags automatically skip stale intermediate frames!
    public func scheduleInteractivePreview(
        fallbackOriginal: CGImage,
        state: PhotoDarkroomEditState,
        metadata: PhotoDarkroomRenderMetadata,
        aiColorParams: AIColorParameters?,
        customWatermarkLogo: UIImage?,
        applyCropGeometry: Bool,
        onComplete: @escaping @MainActor @Sendable (UIImage, UIImage, PhotoDarkroomHistogram) -> Void
    ) {
        tokenLock.lock()
        guard !isTornDown else {
            tokenLock.unlock()
            return
        }
        latestPreviewToken &+= 1
        let myToken = latestPreviewToken
        let proxy = workingProxyCG
        tokenLock.unlock()

        renderQueue.async { [weak self] in
            guard let self, self.isLatest(token: myToken) else { return }
            autoreleasepool {
                let sourceCG: CGImage
                if let proxy {
                    sourceCG = proxy
                } else {
                    let built = Self.downsampleCG(fallbackOriginal, maxSide: 1440)
                    self.tokenLock.lock()
                    if self.workingProxyCG == nil { self.workingProxyCG = built }
                    self.tokenLock.unlock()
                    sourceCG = built
                }

                guard self.isLatest(token: myToken) else { return }

                let renderedCG = PhotoDarkroomRenderEngine.shared.render(
                    cgImage: sourceCG,
                    state: state,
                    metadata: metadata,
                    isInteractiveProxy: true,
                    applyGeometryCrop: applyCropGeometry,
                    applyFramesAndDate: true,
                    aiColorParams: aiColorParams,
                    customWatermarkLogo: customWatermarkLogo
                )

                guard self.isLatest(token: myToken) else { return }

                let displayUI = UIImage(cgImage: renderedCG).preparingForDisplay() ?? UIImage(cgImage: renderedCG)
                let miniCG = Self.downsampleCG(renderedCG, maxSide: 220)
                let miniUI = UIImage(cgImage: miniCG).preparingForDisplay() ?? UIImage(cgImage: miniCG)
                let hist = PhotoDarkroomHistogram.compute(from: miniCG, binCount: 48, maxSampleSide: 120)

                guard self.isLatest(token: myToken) else { return }
                Task { @MainActor in
                    onComplete(displayUI, miniUI, hist)
                }
            }
        }
    }

    /// Lazy cached 132px live thumbnail for Film or Recipe card — never blocks main thread, bounded memory.
    public func requestThumbnail(
        cacheKey: String,
        fallbackOriginal: CGImage,
        state: PhotoDarkroomEditState,
        completion: @escaping @MainActor @Sendable (UIImage) -> Void
    ) {
        let nsKey = cacheKey as NSString
        if let hit = thumbCache.object(forKey: nsKey) {
            Task { @MainActor in completion(hit) }
            return
        }
        thumbQueue.async { [weak self] in
            guard let self, !self.checkTornDown() else { return }
            if let hit = self.thumbCache.object(forKey: nsKey) {
                Task { @MainActor in completion(hit) }
                return
            }
            autoreleasepool {
                self.tokenLock.lock()
                var base = self.thumbnailBaseCG
                self.tokenLock.unlock()
                if base == nil {
                    let built = Self.downsampleCG(fallbackOriginal, maxSide: 132)
                    self.tokenLock.lock()
                    if self.thumbnailBaseCG == nil { self.thumbnailBaseCG = built }
                    base = self.thumbnailBaseCG
                    self.tokenLock.unlock()
                }
                guard let baseCG = base, !self.checkTornDown() else { return }
                let rendered = PhotoDarkroomRenderEngine.shared.render(
                    cgImage: baseCG,
                    state: state,
                    isInteractiveProxy: true,
                    applyGeometryCrop: false,
                    applyFramesAndDate: false
                )
                let ui = UIImage(cgImage: rendered).preparingForDisplay() ?? UIImage(cgImage: rendered)
                let cost = rendered.width * rendered.height * 4
                self.thumbCache.setObject(ui, forKey: nsKey, cost: cost)
                Task { @MainActor in
                    completion(ui)
                }
            }
        }
    }

    /// Renders full-resolution 12MP/48MP CGImage asynchronously for Save, Share, or deep >2.3x inspection zoom.
    public func renderFullResolutionAsync(
        original: CGImage,
        state: PhotoDarkroomEditState,
        metadata: PhotoDarkroomRenderMetadata,
        aiColorParams: AIColorParameters?,
        customWatermarkLogo: UIImage?,
        completion: @escaping @MainActor @Sendable (CGImage) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fullCG = autoreleasepool {
                PhotoDarkroomRenderEngine.shared.render(
                    cgImage: original,
                    state: state,
                    metadata: metadata,
                    isInteractiveProxy: false,
                    applyGeometryCrop: true,
                    applyFramesAndDate: true,
                    aiColorParams: aiColorParams,
                    customWatermarkLogo: customWatermarkLogo
                )
            }
            PhotoDarkroomRenderEngine.shared.ciContext.clearCaches()
            Task { @MainActor in
                completion(fullCG)
            }
        }
    }

    public func teardown() {
        tokenLock.lock()
        isTornDown = true
        latestPreviewToken &+= 1
        workingProxyCG = nil
        thumbnailBaseCG = nil
        tokenLock.unlock()
        thumbCache.removeAllObjects()
        PhotoDarkroomRenderEngine.shared.clearCaches()
    }

    private func isLatest(token: UInt64) -> Bool {
        tokenLock.lock()
        let ok = !isTornDown && latestPreviewToken == token
        tokenLock.unlock()
        return ok
    }

    private func checkTornDown() -> Bool {
        tokenLock.lock()
        let dead = isTornDown
        tokenLock.unlock()
        return dead
    }

    public static func downsampleCG(_ cgImage: CGImage, maxSide: CGFloat) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let longest = max(w, h)
        guard longest > maxSide, w > 1, h > 1 else { return cgImage }
        let scale = maxSide / longest
        let tw = max(2, Int(round(w * scale)))
        let th = max(2, Int(round(h * scale)))
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: tw,
            height: th,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? cgImage
    }
}
#endif
