import Foundation
import Metal
import CoreVideo
import CoreGraphics
import UIKit
import simd

// MARK: - Unified Single-Pass Color Grade Render Parameters (Swift -> Metal)
public struct UnifiedColorRenderParams: Equatable, Sendable {
    public var preset: FilmPreset = .standard
    public var isFilmActive: Bool = false
    public var filmIntensity: Float = 1.0
    public var softwareWB: ProPhotoSoftwareWBGrade = .inactive
    public var filmTuning: FilmSimulationTuning = .neutral
    public var photographicStyle: PhotographicStyleState = .standard
    public var splitTransition: PhotographicStyleSplitTransition = .inactive
    public var lightLeak: VintageLightLeakConfig = .off
    /// (exposureEV, contrastCurve, saturationBoost, warmthKelvinShift) when AI Full Color is active
    public var aiGradeVector: SIMD4<Float>? = nil

    // Viewport & Horizon Lock Geometry (Live Preview only; still capture sets isStillMode = true)
    public var isVideoAspectFit: Bool = false
    public var isHorizonLock: Bool = false
    public var horizonRoll: Float = 0.0
    public var horizonZoom: Float = 1.0
    public var horizonShakeX: Float = 0.0
    public var horizonShakeY: Float = 0.0
    public var isStillMode: Bool = false
    public var frameSeed: Float = 0.0

    public init() {}

    public mutating func setAIParameters(_ params: AIColorParameters?) {
        guard let ai = params else {
            self.aiGradeVector = nil
            return
        }
        let exp = Float(max(-1.2, min(1.2, ai.exposureBias)))
        let contrast = Float(max(0.85, min(1.25, ai.contrastCurve)))
        let sat = Float(max(0.80, min(1.28, ai.saturationBoost)))
        let tempShift = Float(max(-0.35, min(0.35, ai.warmthShift)) * 1600.0)
        self.aiGradeVector = SIMD4(exp, contrast, sat, tempShift)
    }

    public var hasEffectiveColorPass: Bool {
        let hasRealFilm = isFilmActive && preset != .standard && preset != .proColorGrade && preset != .aiFullAuto && filmIntensity > 0.002
        return hasRealFilm
            || !softwareWB.isIdentity
            || !filmTuning.isIdentity
            || !photographicStyle.isIdentity
            || splitTransition.isActive
            || !lightLeak.isIdentity
            || aiGradeVector != nil
    }
}

// MARK: - 16-Byte Aligned Metal Uniform Buffer (Exact 1:1 Layout with MSL)
private struct UnifiedColorUniforms {
    var viewportGeo: SIMD4<Float>       // (srcW, srcH, dstW, dstH)
    var transformA: SIMD4<Float>        // (invTotalScale, aspectMode, rollRad, zoomFactor)
    var transformB: SIMD4<Float>        // (shakeX, shakeY, isVideoRangeYUV, isStillMode)
    var splitParams: SIMD4<Float>       // (isSplitActive, splitPosition, frameSeed, 0)
    var wbParams: SIMD4<Float>          // (wbActive, wbKelvin, wbTint, filmIntensity)

    // Photographic Style A (Left or Active)
    var styleA_control: SIMD4<Float>
    var styleA_gradeA: SIMD4<Float>
    var styleA_gradeB: SIMD4<Float>
    var styleA_m0: SIMD4<Float>
    var styleA_m1: SIMD4<Float>
    var styleA_m2: SIMD4<Float>
    var styleA_skinLab: SIMD4<Float>
    var styleA_shTint: SIMD4<Float>
    var styleA_hiTint: SIMD4<Float>
    var styleA_semantic: SIMD4<Float>

    // Photographic Style B (Right during Live Split-Screen Wipe)
    var styleB_control: SIMD4<Float>
    var styleB_gradeA: SIMD4<Float>
    var styleB_gradeB: SIMD4<Float>
    var styleB_m0: SIMD4<Float>
    var styleB_m1: SIMD4<Float>
    var styleB_m2: SIMD4<Float>
    var styleB_skinLab: SIMD4<Float>
    var styleB_shTint: SIMD4<Float>
    var styleB_hiTint: SIMD4<Float>
    var styleB_semantic: SIMD4<Float>

    // Photographic Styles 3 Texture & Grain (textureMode, textureIntensity, grainAmount, grainSize)
    var styleTexture: SIMD4<Float>

    // Vintage Camera / Film Optical Recipe
    var filmFlags: SIMD4<Float>         // (hasFilmPreset, hasLUT, lutSize, specialMode)
    var filmM0: SIMD4<Float>
    var filmM1: SIMD4<Float>
    var filmM2: SIMD4<Float>
    var filmShadowTint: SIMD4<Float>
    var filmHighlightTint: SIMD4<Float>
    var filmToneParams: SIMD4<Float>
    var filmColorParams: SIMD4<Float>
    var filmHslShift: SIMD4<Float>
    var filmAnalogParams: SIMD4<Float>
    var filmOpticalParams: SIMD4<Float>

    // Real-Time User Tuning + Light Leak + AI Params
    var tuningA: SIMD4<Float>           // (contrast, saturation, warmth, highlights)
    var tuningB: SIMD4<Float>           // (shadows, grain, vignette, fade)
    var tuningC: SIMD4<Float>           // (halation, leakIntensity, leakPattern, hasAI)
    var aiParams: SIMD4<Float>          // (exposureEV, contrast, saturation, tempShift)

    init(
        srcW: Float,
        srcH: Float,
        dstW: Float,
        dstH: Float,
        isVideoRangeYUV: Bool,
        hasLUT: Bool,
        lutSize: Float,
        params: UnifiedColorRenderParams
    ) {
        self.viewportGeo = SIMD4(max(1, srcW), max(1, srcH), max(1, dstW), max(1, dstH))

        let scaleX = dstW / max(1, srcW)
        let scaleY = dstH / max(1, srcH)
        let baseScale = params.isStillMode
            ? 1.0
            : (params.isVideoAspectFit ? min(scaleX, scaleY) : max(scaleX, scaleY))
        let zoom = params.isHorizonLock ? max(1.0, params.horizonZoom) : 1.0
        let totalScale = max(0.0001, baseScale * zoom)
        let roll = params.isHorizonLock ? params.horizonRoll : 0.0
        let shakeX = params.isHorizonLock ? params.horizonShakeX : 0.0
        let shakeY = params.isHorizonLock ? params.horizonShakeY : 0.0

        self.transformA = SIMD4(1.0 / totalScale, params.isVideoAspectFit ? 1.0 : 0.0, roll, zoom)
        self.transformB = SIMD4(shakeX, shakeY, isVideoRangeYUV ? 1.0 : 0.0, params.isStillMode ? 1.0 : 0.0)

        let splitActive = params.splitTransition.isActive && !params.isStillMode
        self.splitParams = SIMD4(
            splitActive ? 1.0 : 0.0,
            max(0.0, min(1.0, params.splitTransition.splitPosition)),
            params.frameSeed,
            (splitActive && params.splitTransition.isLandscapeAxis) ? 1.0 : 0.0
        )

        let hasFilm = params.isFilmActive
            && params.preset != .standard
            && params.preset != .proColorGrade
            && params.preset != .aiFullAuto
            && params.filmIntensity > 0.002

        self.wbParams = SIMD4(
            params.softwareWB.isIdentity ? 0.0 : 1.0,
            params.softwareWB.kelvin,
            params.softwareWB.tint,
            hasFilm ? max(0.0, min(1.0, params.filmIntensity)) : 0.0
        )

        let styleA = splitActive ? params.splitTransition.leftStyle : params.photographicStyle
        let styleB = splitActive ? params.splitTransition.rightStyle : params.photographicStyle
        let rA = styleA.preset.recipe
        let rB = styleB.preset.recipe

        let styleAHasColor = !(styleA.preset == .standard && abs(styleA.tone) < 0.005 && abs(styleA.color) < 0.005)
        let styleBHasColor = !(styleB.preset == .standard && abs(styleB.tone) < 0.005 && abs(styleB.color) < 0.005)

        self.styleA_control = SIMD4(styleA.tone, styleA.color, styleAHasColor ? styleA.palette : 0.0, rA.presetKind)
        self.styleA_gradeA = SIMD4(rA.baseContrast, rA.baseShadowLift, rA.baseHighlightRoll, rA.isMonochrome)
        self.styleA_gradeB = SIMD4(rA.baseVibrance, rA.baseSaturation, rA.undertoneStrength, rA.splitStrength)
        self.styleA_m0 = rA.matrixRow0
        self.styleA_m1 = rA.matrixRow1
        self.styleA_m2 = rA.matrixRow2
        self.styleA_skinLab = rA.skinShiftLab
        self.styleA_shTint = rA.shadowTint
        self.styleA_hiTint = rA.highlightTint
        self.styleA_semantic = rA.semanticBoost

        self.styleB_control = SIMD4(styleB.tone, styleB.color, styleBHasColor ? styleB.palette : 0.0, rB.presetKind)
        self.styleB_gradeA = SIMD4(rB.baseContrast, rB.baseShadowLift, rB.baseHighlightRoll, rB.isMonochrome)
        self.styleB_gradeB = SIMD4(rB.baseVibrance, rB.baseSaturation, rB.undertoneStrength, rB.splitStrength)
        self.styleB_m0 = rB.matrixRow0
        self.styleB_m1 = rB.matrixRow1
        self.styleB_m2 = rB.matrixRow2
        self.styleB_skinLab = rB.skinShiftLab
        self.styleB_shTint = rB.shadowTint
        self.styleB_hiTint = rB.highlightTint
        self.styleB_semantic = rB.semanticBoost

        let activeTexStyle = params.photographicStyle
        self.styleTexture = SIMD4(
            activeTexStyle.textureMode.shaderCode,
            activeTexStyle.textureMode == .standard ? 0.0 : activeTexStyle.textureIntensity,
            activeTexStyle.grainEnabled ? activeTexStyle.grainAmount : 0.0,
            activeTexStyle.grainSize
        )

        let recipe = hasFilm ? params.preset.metalOpticalRecipe : .identity
        self.filmFlags = SIMD4(
            hasFilm ? 1.0 : 0.0,
            (hasFilm && hasLUT) ? 1.0 : 0.0,
            max(2.0, lutSize),
            recipe.opticalParams.w
        )
        self.filmM0 = recipe.matrixRow0
        self.filmM1 = recipe.matrixRow1
        self.filmM2 = recipe.matrixRow2
        self.filmShadowTint = recipe.shadowTint
        self.filmHighlightTint = recipe.highlightTint
        self.filmToneParams = recipe.toneParams
        self.filmColorParams = recipe.colorParams
        self.filmHslShift = recipe.hslShift
        self.filmAnalogParams = recipe.analogParams
        self.filmOpticalParams = recipe.opticalParams

        let t = params.filmTuning
        self.tuningA = SIMD4(t.contrast, t.saturation, t.warmth, t.highlights)
        self.tuningB = SIMD4(t.shadows, t.grain, t.vignette, t.fade)
        self.tuningC = SIMD4(
            t.halation,
            params.lightLeak.isIdentity ? 0.0 : params.lightLeak.intensity,
            Float(params.lightLeak.patternIndex),
            params.aiGradeVector != nil ? 1.0 : 0.0
        )

        if let aiVec = params.aiGradeVector {
            self.aiParams = aiVec
        } else {
            self.aiParams = SIMD4(0, 1, 1, 0)
        }
    }
}

// MARK: - Portable IEEE-754 Float32 -> Float16 Bit Converter (for .rgba16Float 3D LUT Texture)
private func float32ToFloat16Bits(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exp = Int((bits >> 23) & 0xFF) - 127 + 15
    let mant = bits & 0x007FFFFF

    if exp <= 0 {
        if exp < -10 { return sign }
        let shifted = (mant | 0x00800000) >> UInt32(14 - exp)
        return sign | UInt16(shifted)
    } else if exp >= 31 {
        return sign | 0x7C00
    } else {
        let rounded = (exp << 10) + Int((mant + 0x00001000) >> 13)
        return sign | UInt16(min(0x7C00, rounded))
    }
}

// MARK: - Unified Single-Pass Direct Metal Color Engine (60 FPS Zero-Lag Live Preview + Still Capture)
/// Kiến trúc Single-Pass Direct Metal Compute thay thế chuỗi đa pass CoreImage nặng VRAM:
/// - Đọc trực tiếp CVPixelBuffer (420f/420v YCbCr hoặc 32BGRA) qua CVMetalTextureCache (Zero-Copy).
/// - Hợp nhất 100% đường ống màu trong ĐÚNG 1 PASS GPU (~0.4ms/frame trên Apple Silicon):
///   Viewport/Horizon Lock -> Software WB -> OkLab Photographic Styles (+ Live Split-Screen Wipe)
///   -> Pre-LUT Gamut/Highlight Protection -> Hardware .rgba16Float 3D LUT -> Vintage Camera Emulsion
///   -> Real-time Tuning -> Single-Pass Remjet Halation/Diffusion -> 8-Pattern Organic Light Leak
///   -> Resolution-Normalized Silver Grain & Optical Vignette -> sRGB OETF.
public final class UnifiedMetalColorEngine: @unchecked Sendable {
    public static let shared = UnifiedMetalColorEngine()

    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    private let yuvPipeline: MTLComputePipelineState?
    private let bgraPipeline: MTLComputePipelineState?
    private let identityLUTTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?

    private let lutLock = NSLock()
    private var lutTextureCache: [String: MTLTexture] = [:]
    private var missingLUTs: Set<String> = []

    public static var isAvailable: Bool {
        shared.isReady
    }

    public var isReady: Bool {
        device != nil && commandQueue != nil && yuvPipeline != nil && bgraPipeline != nil && identityLUTTexture != nil
    }

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = UltraWideWarpEngine.live.commandQueue ?? dev.makeCommandQueue() else {
            self.device = nil
            self.commandQueue = nil
            self.yuvPipeline = nil
            self.bgraPipeline = nil
            self.identityLUTTexture = nil
            self.textureCache = nil
            return
        }

        self.device = dev
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        self.textureCache = cache

        var yuvState: MTLComputePipelineState?
        var bgraState: MTLComputePipelineState?
        do {
            let library = try dev.makeLibrary(source: Self.metalShaderSource, options: nil)
            if let yuvFn = library.makeFunction(name: "unifiedCameraGradeYUV") {
                yuvState = try dev.makeComputePipelineState(function: yuvFn)
            }
            if let bgraFn = library.makeFunction(name: "unifiedCameraGradeBGRA") {
                bgraState = try dev.makeComputePipelineState(function: bgraFn)
            }
        } catch {
            yuvState = nil
            bgraState = nil
        }

        self.yuvPipeline = yuvState
        self.bgraPipeline = bgraState
        self.identityLUTTexture = Self.makeIdentity3DLUTTexture(device: dev)
    }

    public func flushCaches() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - 3D Hardware LUT Loader (Float32 .bin -> .rgba16Float MTLTexture for Apple GPU Trilinear)
    private static func makeIdentity3DLUTTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = 2
        desc.height = 2
        desc.depth = 2
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        var pixels = [UInt16](repeating: 0, count: 2 * 2 * 2 * 4)
        let oneHalf = float32ToFloat16Bits(1.0)
        var idx = 0
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    pixels[idx] = float32ToFloat16Bits(Float(r))
                    pixels[idx + 1] = float32ToFloat16Bits(Float(g))
                    pixels[idx + 2] = float32ToFloat16Bits(Float(b))
                    pixels[idx + 3] = oneHalf
                    idx += 4
                }
            }
        }
        let bytesPerRow = 2 * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = bytesPerRow * 2
        pixels.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                tex.replace(
                    region: MTLRegionMake3D(0, 0, 0, 2, 2, 2),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: ptr,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            }
        }
        return tex
    }

    private func lutTexture(named name: String?) -> (texture: MTLTexture, hasLUT: Bool, size: Float)? {
        guard let fallback = identityLUTTexture else { return nil }
        guard let name = name, !name.isEmpty, let dev = device else {
            return (fallback, false, 2.0)
        }

        lutLock.lock()
        if let cached = lutTextureCache[name] {
            lutLock.unlock()
            return (cached, true, Float(cached.width))
        }
        if missingLUTs.contains(name) {
            lutLock.unlock()
            return (fallback, false, 2.0)
        }
        lutLock.unlock()

        let dim = 32
        guard let data = FilmSimulationCore.load3DLUT(named: name, dimension: dim) else {
            lutLock.lock()
            missingLUTs.insert(name)
            lutLock.unlock()
            return (fallback, false, 2.0)
        }

        let expectedCount = dim * dim * dim * 4
        guard data.count >= expectedCount * MemoryLayout<Float32>.size else {
            lutLock.lock()
            missingLUTs.insert(name)
            lutLock.unlock()
            return (fallback, false, 2.0)
        }

        var halfPixels = [UInt16](repeating: 0, count: expectedCount)
        data.withUnsafeBytes { rawBuf in
            let floats = rawBuf.bindMemory(to: Float32.self)
            for i in 0..<expectedCount {
                halfPixels[i] = float32ToFloat16Bits(floats[i])
            }
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = dim
        desc.height = dim
        desc.depth = dim
        desc.usage = [.shaderRead]
        guard let tex = dev.makeTexture(descriptor: desc) else {
            return (fallback, false, 2.0)
        }

        let bytesPerRow = dim * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = bytesPerRow * dim
        halfPixels.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                tex.replace(
                    region: MTLRegionMake3D(0, 0, 0, dim, dim, dim),
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: ptr,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            }
        }

        lutLock.lock()
        lutTextureCache[name] = tex
        lutLock.unlock()
        return (tex, true, Float(dim))
    }

    // MARK: - Live Preview Zero-Copy Single-Pass Metal Dispatch (60 FPS)
    @discardableResult
    public func encodePreviewFrame(
        pixelBuffer: CVPixelBuffer,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        params: UnifiedColorRenderParams
    ) -> Bool {
        guard let cache = textureCache,
              let yuvState = yuvPipeline,
              let bgraState = bgraPipeline else {
            return false
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isBiPlanarYUV = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            || (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let isVideoRangeYUV = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 1, srcH > 1, outputTexture.width > 1, outputTexture.height > 1 else {
            return false
        }

        let activeLUTName: String? = (params.isFilmActive && params.preset != .standard && params.preset != .proColorGrade && params.preset != .aiFullAuto && params.filmIntensity > 0.002)
            ? params.preset.metalOpticalRecipe.lutName
            : nil
        guard let lutResolved = lutTexture(named: activeLUTName) else {
            return false
        }

        var uniforms = UnifiedColorUniforms(
            srcW: Float(srcW),
            srcH: Float(srcH),
            dstW: Float(outputTexture.width),
            dstH: Float(outputTexture.height),
            isVideoRangeYUV: isVideoRangeYUV,
            hasLUT: lutResolved.hasLUT,
            lutSize: lutResolved.size,
            params: params
        )

        if isBiPlanarYUV {
            var yTexRef: CVMetalTexture?
            var uvTexRef: CVMetalTexture?
            let yW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let yH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let uvW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            let sY = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, yW, yH, 0, &yTexRef
            )
            let sUV = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, uvW, uvH, 1, &uvTexRef
            )
            guard sY == kCVReturnSuccess, sUV == kCVReturnSuccess,
                  let yRef = yTexRef, let uvRef = uvTexRef,
                  let texY = CVMetalTextureGetTexture(yRef),
                  let texUV = CVMetalTextureGetTexture(uvRef),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }

            encoder.setComputePipelineState(yuvState)
            encoder.setTexture(texY, index: 0)
            encoder.setTexture(texUV, index: 1)
            encoder.setTexture(lutResolved.texture, index: 2)
            encoder.setTexture(outputTexture, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<UnifiedColorUniforms>.stride, index: 0)

            let tgW = max(1, min(yuvState.threadExecutionWidth, 16))
            let tgH = max(1, min(yuvState.maxTotalThreadsPerThreadgroup / tgW, 16))
            encoder.dispatchThreadgroups(
                MTLSize(width: (outputTexture.width + tgW - 1) / tgW, height: (outputTexture.height + tgH - 1) / tgH, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
            )
            encoder.endEncoding()
            return true
        } else if pixelFormat == kCVPixelFormatType_32BGRA {
            var bgraRef: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, srcW, srcH, 0, &bgraRef
            )
            guard status == kCVReturnSuccess,
                  let ref = bgraRef,
                  let srcTex = CVMetalTextureGetTexture(ref),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }

            encoder.setComputePipelineState(bgraState)
            encoder.setTexture(srcTex, index: 0)
            encoder.setTexture(lutResolved.texture, index: 2)
            encoder.setTexture(outputTexture, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<UnifiedColorUniforms>.stride, index: 0)

            let tgW = max(1, min(bgraState.threadExecutionWidth, 16))
            let tgH = max(1, min(bgraState.maxTotalThreadsPerThreadgroup / tgW, 16))
            encoder.dispatchThreadgroups(
                MTLSize(width: (outputTexture.width + tgW - 1) / tgW, height: (outputTexture.height + tgH - 1) / tgH, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
            )
            encoder.endEncoding()
            return true
        }

        return false
    }

    // MARK: - Full-Resolution Still Photo & Sample Look Rendering (Exact Same Metal Shader + Date Stamp)
    public func renderStillCGImage(
        _ cgImage: CGImage,
        params: UnifiedColorRenderParams,
        dateStampStyle: VintageDateStampStyle = .off,
        date: Date = Date()
    ) -> CGImage? {
        let needsColor = params.hasEffectiveColorPass
        let needsStamp = dateStampStyle.isEnabled
        guard needsColor || needsStamp else { return cgImage }

        var gradedImage: CGImage = cgImage

        if needsColor,
           let dev = device,
           let queue = commandQueue,
           let bgraState = bgraPipeline {
            let width = cgImage.width
            let height = cgImage.height
            if width > 1, height > 1 {
                let bytesPerPixel = 4
                let bytesPerRow = width * bytesPerPixel
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

                var rawBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
                let drawOK = rawBytes.withUnsafeMutableBytes { buf -> Bool in
                    guard let ctx = CGContext(
                        data: buf.baseAddress,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo
                    ) else { return false }
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }

                if drawOK {
                    let inDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm,
                        width: width,
                        height: height,
                        mipmapped: false
                    )
                    inDesc.usage = [.shaderRead]

                    let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm,
                        width: width,
                        height: height,
                        mipmapped: false
                    )
                    outDesc.usage = [.shaderWrite]

                    var stillParams = params
                    stillParams.isStillMode = true
                    stillParams.splitTransition = .inactive
                    stillParams.isHorizonLock = false

                    let activeLUTName: String? = (stillParams.isFilmActive && stillParams.preset != .standard && stillParams.preset != .proColorGrade && stillParams.preset != .aiFullAuto && stillParams.filmIntensity > 0.002)
                        ? stillParams.preset.metalOpticalRecipe.lutName
                        : nil

                    if let inTex = dev.makeTexture(descriptor: inDesc),
                       let outTex = dev.makeTexture(descriptor: outDesc),
                       let lutResolved = lutTexture(named: activeLUTName),
                       let cmdBuf = queue.makeCommandBuffer(),
                       let encoder = cmdBuf.makeComputeCommandEncoder() {

                        rawBytes.withUnsafeBytes { buf in
                            if let ptr = buf.baseAddress {
                                inTex.replace(
                                    region: MTLRegionMake2D(0, 0, width, height),
                                    mipmapLevel: 0,
                                    withBytes: ptr,
                                    bytesPerRow: bytesPerRow
                                )
                            }
                        }

                        var uniforms = UnifiedColorUniforms(
                            srcW: Float(width),
                            srcH: Float(height),
                            dstW: Float(width),
                            dstH: Float(height),
                            isVideoRangeYUV: false,
                            hasLUT: lutResolved.hasLUT,
                            lutSize: lutResolved.size,
                            params: stillParams
                        )

                        encoder.setComputePipelineState(bgraState)
                        encoder.setTexture(inTex, index: 0)
                        encoder.setTexture(lutResolved.texture, index: 2)
                        encoder.setTexture(outTex, index: 3)
                        encoder.setBytes(&uniforms, length: MemoryLayout<UnifiedColorUniforms>.stride, index: 0)

                        let tgW = max(1, min(bgraState.threadExecutionWidth, 16))
                        let tgH = max(1, min(bgraState.maxTotalThreadsPerThreadgroup / tgW, 16))
                        encoder.dispatchThreadgroups(
                            MTLSize(width: (width + tgW - 1) / tgW, height: (height + tgH - 1) / tgH, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
                        )
                        encoder.endEncoding()
                        cmdBuf.commit()
                        cmdBuf.waitUntilCompleted()

                        var outBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
                        outBytes.withUnsafeMutableBytes { buf in
                            if let ptr = buf.baseAddress {
                                outTex.getBytes(
                                    ptr,
                                    bytesPerRow: bytesPerRow,
                                    from: MTLRegionMake2D(0, 0, width, height),
                                    mipmapLevel: 0
                                )
                            }
                        }

                        let outData = Data(outBytes)
                        if let provider = CGDataProvider(data: outData as CFData),
                           let rendered = CGImage(
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: bytesPerRow,
                            space: colorSpace,
                            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: true,
                            intent: .defaultIntent
                           ) {
                            gradedImage = rendered
                        }
                    }
                }
            }
        }

        if needsStamp,
           let stamped = VintageDateStampRenderer.imprint(on: gradedImage, style: dateStampStyle, date: date) {
            return stamped
        }
        return gradedImage
    }

    // MARK: - Single-Pass Metal Shading Language Source (Compiled Runtime, Zero -fcikernel)
    private static let metalShaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct UnifiedColorUniforms {
        float4 viewportGeo;
        float4 transformA;
        float4 transformB;
        float4 splitParams;
        float4 wbParams;

        float4 styleA_control;
        float4 styleA_gradeA;
        float4 styleA_gradeB;
        float4 styleA_m0;
        float4 styleA_m1;
        float4 styleA_m2;
        float4 styleA_skinLab;
        float4 styleA_shTint;
        float4 styleA_hiTint;
        float4 styleA_semantic;

        float4 styleB_control;
        float4 styleB_gradeA;
        float4 styleB_gradeB;
        float4 styleB_m0;
        float4 styleB_m1;
        float4 styleB_m2;
        float4 styleB_skinLab;
        float4 styleB_shTint;
        float4 styleB_hiTint;
        float4 styleB_semantic;

        float4 styleTexture;

        float4 filmFlags;
        float4 filmM0;
        float4 filmM1;
        float4 filmM2;
        float4 filmShadowTint;
        float4 filmHighlightTint;
        float4 filmToneParams;
        float4 filmColorParams;
        float4 filmHslShift;
        float4 filmAnalogParams;
        float4 filmOpticalParams;

        float4 tuningA;
        float4 tuningB;
        float4 tuningC;
        float4 aiParams;
    };

    inline float signedCbrt(float x) {
        return sign(x) * pow(abs(x), 1.0f / 3.0f);
    }

    inline float3 srgbToLinearExact(float3 s) {
        float3 c = clamp(s, 0.0f, 1.0f);
        float3 lo = c / 12.92f;
        float3 hi = pow(max((c + 0.055f) / 1.055f, float3(0.0f)), float3(2.4f));
        return select(hi, lo, c <= float3(0.04045f));
    }

    inline float3 linearToSRGBExact(float3 lin) {
        float3 c = clamp(lin, 0.0f, 1.0f);
        float3 lo = c * 12.92f;
        float3 hi = 1.055f * pow(max(c, float3(1e-6f)), float3(1.0f / 2.4f)) - 0.055f;
        return select(hi, lo, c <= float3(0.0031308f));
    }

    // Verified Björn Ottosson OkLab (round-trip max error 4.47e-7)
    inline float3 linearSRGBToOkLab(float3 c) {
        float l = 0.4122214708f * c.r + 0.5363325363f * c.g + 0.0514459929f * c.b;
        float m = 0.2119034982f * c.r + 0.6806995451f * c.g + 0.1073969566f * c.b;
        float s = 0.0883024619f * c.r + 0.2817188376f * c.g + 0.6299787005f * c.b;
        float l_ = signedCbrt(l);
        float m_ = signedCbrt(m);
        float s_ = signedCbrt(s);
        return float3(
            0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
            1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
            0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
        );
    }

    inline float3 okLabToLinearSRGB(float3 lab) {
        float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
        float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
        float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
        float l = l_ * l_ * l_;
        float m = m_ * m_ * m_;
        float s = s_ * s_ * s_;
        return float3(
            +4.0767416613f * l - 3.3077115904f * m + 0.2309699287f * s,
            -1.2684380041f * l + 2.6097574007f * m - 0.3413193963f * s,
            -0.0041960865f * l - 0.7034186145f * m + 1.7076147009f * s
        );
    }

    inline float computeSkinMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(0.18f, 0.44f, hue) * (1.0f - smoothstep(0.95f, 1.24f, hue));
        float chromaMask = smoothstep(0.016f, 0.036f, chroma) * (1.0f - smoothstep(0.145f, 0.220f, chroma));
        float lumaMask = smoothstep(0.18f, 0.32f, L) * (1.0f - smoothstep(0.86f, 0.96f, L));
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeSkinMaskOkLab(float3 lab) {
        return computeSkinMaskOkLab(lab.x, length(lab.yz), atan2(lab.z, lab.y));
    }

    inline float computeSkyMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(-2.75f, -2.25f, hue) * (1.0f - smoothstep(-1.15f, -0.75f, hue));
        float chromaMask = smoothstep(0.020f, 0.055f, chroma);
        float lumaMask = smoothstep(0.32f, 0.56f, L);
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeFoliageMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(1.48f, 1.95f, hue) * (1.0f - smoothstep(2.65f, 3.02f, hue));
        float chromaMask = smoothstep(0.022f, 0.060f, chroma);
        float lumaMask = smoothstep(0.12f, 0.28f, L);
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeWarmRedMaskOkLab(float chroma, float hue) {
        float hueMask = smoothstep(-0.22f, 0.18f, hue) * (1.0f - smoothstep(0.75f, 1.15f, hue));
        float chromaMask = smoothstep(0.045f, 0.105f, chroma);
        return clamp(hueMask * chromaMask, 0.0f, 1.0f);
    }

    // Nén mượt tiệm cận biên dải màu theo tia về độ sáng trung tính (giữ nguyên sắc độ & độ sáng, chống bệt neon)
    inline float3 softGamutClampLinear(float3 rgb, float lumaFallback) {
        float minC = min(rgb.r, min(rgb.g, rgb.b));
        if (minC < 0.0f) {
            float yPos = dot(max(rgb, float3(0.0f)), float3(0.2126f, 0.7152f, 0.0722f));
            float targetY = max(max(yPos, lumaFallback), 1e-4f);
            float t = clamp(targetY / max(targetY - minC, 1e-5f), 0.0f, 1.0f);
            rgb = mix(float3(targetY), rgb, t);
        }
        return max(rgb, float3(0.0f));
    }

    inline float applyHighlightShoulder(float y, float knee, float strength) {
        if (y <= knee || strength <= 0.001f) {
            return y;
        }
        float headroom = max(0.08f, 1.0f - knee);
        float over = y - knee;
        float compressed = knee + (headroom * over) / (over + headroom);
        return mix(y, compressed, clamp(strength, 0.0f, 1.0f));
    }

    inline float3 ycbcrToSRGB(float ySample, float2 uvSample, float isVideoRange) {
        float y = (isVideoRange > 0.5f) ? ((ySample - (16.0f / 255.0f)) * (255.0f / 219.0f)) : ySample;
        float cb = ((isVideoRange > 0.5f) ? ((uvSample.x - 0.5f) * (255.0f / 224.0f)) : (uvSample.x - 0.5f));
        float cr = ((isVideoRange > 0.5f) ? ((uvSample.y - 0.5f) * (255.0f / 224.0f)) : (uvSample.y - 0.5f));
        float r = y + 1.574800f * cr;
        float g = y - 0.187324f * cb - 0.468124f * cr;
        float b = y + 1.855600f * cb;
        return clamp(float3(r, g, b), 0.0f, 1.0f);
    }

    inline float2 computeSourceUV(uint2 gid, constant UnifiedColorUniforms& u) {
        float srcW = u.viewportGeo.x;
        float srcH = u.viewportGeo.y;
        float dstW = u.viewportGeo.z;
        float dstH = u.viewportGeo.w;

        if (u.transformB.w > 0.5f) {
            return (float2(gid) + 0.5f) / float2(dstW, dstH);
        }

        float2 dstPos = float2(gid) + 0.5f;
        float2 dstCenter = float2(dstW, dstH) * 0.5f;
        float2 rel = dstPos - dstCenter;
        float dx = rel.x - (u.transformB.x * dstW);
        float dy = rel.y + (u.transformB.y * dstH);

        float invScale = u.transformA.x;
        float roll = u.transformA.z;
        float2 srcOffset;
        if (abs(roll) > 0.0005f) {
            float cr = cos(roll);
            float sr = sin(roll);
            srcOffset = float2(dx * cr + dy * sr, -dx * sr + dy * cr) * invScale;
        } else {
            srcOffset = float2(dx, dy) * invScale;
        }
        float2 srcPixel = float2(srcW, srcH) * 0.5f + srcOffset;
        return srcPixel / float2(srcW, srcH);
    }

    inline float3 applySoftwareWB(float3 lin, float kelvin, float tint) {
        float normK = clamp((kelvin - 5500.0f) / 3500.0f, -1.0f, 1.2f);
        float normT = clamp(tint / 50.0f, -1.0f, 1.0f);
        float rGain = exp2(normK * 0.28f + normT * 0.10f);
        float gGain = exp2(-normT * 0.14f);
        float bGain = exp2(-normK * 0.34f + normT * 0.08f);
        float lumNorm = 0.2126f * rGain + 0.7152f * gGain + 0.0722f * bGain;
        float3 gains = float3(rGain, gGain, bGain) / max(lumNorm, 0.25f);
        return max(lin * gains, float3(0.0f));
    }

    inline float3 applyPhotographicStylePass(
        float3 origLinear,
        float4 control,
        float4 gradeA,
        float4 gradeB,
        float4 m0, float4 m1, float4 m2,
        float4 skinShiftLab,
        float4 shadowTint,
        float4 highlightTint,
        float4 semanticBoost
    ) {
        bool isMono = gradeA.w > 0.5f;
        float palette = clamp(control.z, 0.0f, 1.0f);
        if (!isMono && palette <= 0.001f) {
            return origLinear;
        }
        float tone = clamp(control.x, -1.0f, 1.0f);
        float colorCtrl = clamp(control.y, -1.0f, 1.0f);
        float presetKind = control.w;

        float baseContrast = gradeA.x;
        float baseShadowLift = gradeA.y;
        float baseHighlightRoll = gradeA.z;
        float baseVibrance = gradeB.x;
        float baseSaturation = gradeB.y;
        float undertoneStrength = gradeB.z;
        float splitStrength = gradeB.w;

        float3 origLab = linearSRGBToOkLab(origLinear);
        float origChroma = length(origLab.yz);
        float origHue = atan2(origLab.z, origLab.y);
        float skinMask = computeSkinMaskOkLab(origLab.x, origChroma, origHue);
        float skyMask = computeSkyMaskOkLab(origLab.x, origChroma, origHue);
        float foliageMask = computeFoliageMaskOkLab(origLab.x, origChroma, origHue);
        float warmRedMask = computeWarmRedMaskOkLab(origChroma, origHue);
        float nonNeutralMask = smoothstep(0.010f, 0.032f, origChroma);
        float midtoneMask = smoothstep(0.04f, 0.28f, origLab.x) * (1.0f - smoothstep(0.78f, 0.96f, origLab.x));
        float skinProtect = clamp(skinShiftLab.w, 0.0f, 0.85f);

        float3 graded = origLinear;
        if (!isMono) {
            float3 matRGB = float3(dot(graded, m0.xyz), dot(graded, m1.xyz), dot(graded, m2.xyz));
            if (presetKind > 0.5f && presetKind < 1.5f) {
                float blueSkyGuard = 1.0f - skyMask * 0.72f;
                float matrixMix = clamp((0.36f + 0.64f * max(skinMask, nonNeutralMask * 0.70f)) * blueSkyGuard, 0.18f, 1.0f);
                graded = mix(graded, matRGB, matrixMix);
            } else {
                graded = matRGB;
            }
        }

        float yIn = max(0.0f, dot(graded, float3(0.2126f, 0.7152f, 0.0722f)));
        float yOut = yIn;

        if (abs(baseShadowLift) > 0.001f) {
            float shadowWeight = smoothstep(0.001f, 0.035f, yOut) * (1.0f - smoothstep(0.04f, 0.45f, yOut));
            float shDelta = baseShadowLift * 0.115f * shadowWeight * (0.28f + yOut);
            yOut = max(yOut * 0.45f, yOut + shDelta);
        }
        if (abs(baseContrast) > 0.001f) {
            float pivot = 0.18f;
            float power = max(0.62f, 1.0f + baseContrast * 0.68f);
            float yPivot = pivot * pow(max(yOut / pivot, 1e-6f), power);
            yOut = mix(yOut, yPivot, 0.85f);
        }

        // Skin-Protected Local HDR Tone Mapping (trục Y: -1 sâu bóng phim vẫn giữ sáng highlight | +1 nâng bóng thoáng, neo đen tuyệt đối không sương xám)
        if (tone < -0.001f) {
            float neg = -tone;
            float effNeg = neg * (1.0f - skinMask * skinProtect * 0.52f);
            float gamma = 1.0f + 0.56f * effNeg;
            float yDeep = pow(max(yOut, 1e-6f), gamma) * exp(-0.10f * effNeg);
            float toeKeep = exp(-yOut * 12.0f) * 0.34f;
            float yShaped = mix(yDeep, yOut * 0.68f, toeKeep);
            float hiKeep = smoothstep(0.38f, 0.92f, yOut) * 0.52f;
            yOut = mix(yShaped, yOut * (1.0f - 0.08f * effNeg), hiKeep);
        } else if (tone > 0.001f) {
            float gamma = 1.0f - 0.38f * tone;
            float yLifted = pow(max(yOut, 1e-6f), gamma) * (1.0f + 0.16f * tone);
            float shBell = smoothstep(0.0015f, 0.045f, yOut) * (1.0f - smoothstep(0.06f, 0.42f, yOut));
            yOut = yLifted + shBell * 0.036f * tone;
        }

        float skyProtect = clamp(highlightTint.w, 0.0f, 0.85f);
        float shoulderKnee = mix(0.72f, 0.58f, skyMask * skyProtect);
        float shoulderStrength = clamp(baseHighlightRoll + max(0.0f, tone) * 0.78f + skyMask * skyProtect * 0.55f, 0.0f, 0.96f);
        yOut = applyHighlightShoulder(yOut, shoulderKnee, shoulderStrength);

        if (isMono) {
            // Đơn sắc phim bạc thuần: Color = bộ lọc kính quang học (Blue <-> Panchromatic <-> Red #25) + Silver Split Tone
            // Palette trên B&W điều khiển độ sáng & độ gắt highlight (giữ 100% đơn sắc, không pha lại màu gốc)
            float3 filterW = (colorCtrl >= 0.0f)
                ? mix(float3(0.31f, 0.58f, 0.11f), float3(0.56f, 0.38f, 0.06f), colorCtrl)
                : mix(float3(0.31f, 0.58f, 0.11f), float3(0.16f, 0.48f, 0.36f), -colorCtrl);
            float monoLum = max(0.0f, dot(max(origLinear, 0.0f), filterW));
            float lumScale = yOut / max(yIn, 1e-5f);
            float monoTone = clamp(monoLum * clamp(lumScale, 0.0f, 3.6f), 0.0f, 4.0f);
            monoTone = max(0.0f, monoTone + semanticBoost.x * skinMask * 0.25f);

            float hiMaskBW = smoothstep(0.26f, 0.92f, monoTone);
            float bwHiGain = 1.0f + (palette - 0.5f) * 0.56f * hiMaskBW;
            monoTone = applyHighlightShoulder(clamp(monoTone * bwHiGain, 0.0f, 3.8f), 0.78f, 0.55f);

            float shW = (1.0f - smoothstep(0.03f, 0.52f, monoTone)) * smoothstep(0.004f, 0.07f, monoTone);
            float hiW = smoothstep(0.36f, 0.92f, monoTone);
            float3 splitTone = shadowTint.xyz * shW * splitStrength + highlightTint.xyz * hiW * splitStrength;
            float3 silverShift = (colorCtrl >= 0.0f)
                ? float3(0.042f, 0.020f, -0.034f) * colorCtrl
                : float3(-0.024f, 0.006f, 0.042f) * (-colorCtrl);
            graded = float3(monoTone) + splitTone + silverShift * (0.22f + 0.78f * midtoneMask) * clamp(monoTone * 1.35f, 0.0f, 1.0f);
            return max(graded, float3(0.0f));
        }

        float ratio = clamp(yOut / max(yIn, 1e-5f), 0.0f, 3.5f);
        graded *= ratio;
        float hiDesat = smoothstep(0.82f, 1.35f, yOut) * 0.18f;
        graded = mix(graded, float3(yOut), hiDesat);

        if (splitStrength > 0.001f) {
            float shW = (1.0f - smoothstep(0.03f, 0.48f, yOut)) * smoothstep(0.003f, 0.045f, yOut);
            float hiW = smoothstep(0.42f, 0.92f, yOut) * (1.0f - smoothstep(0.95f, 1.28f, yOut));
            float3 effShadowTint = shadowTint.xyz;
            if (presetKind > 2.5f) {
                // Dramatic: thanh Palette dịch chuyển mượt sắc bóng từ slate ấm nhẹ sang xanh cyan Bắc Âu sâu
                float3 warmSlate = float3(0.018f, 0.008f, -0.012f);
                effShadowTint = mix(warmSlate, shadowTint.xyz * 1.28f, smoothstep(0.15f, 0.85f, palette));
            }
            graded += (effShadowTint * shW + highlightTint.xyz * hiW) * splitStrength;
        }

        float blueShCut = semanticBoost.w;
        if (blueShCut > 0.005f) {
            float shMidW = 1.0f - smoothstep(0.08f, 0.62f, yOut);
            graded.b *= max(0.72f, 1.0f - blueShCut * 0.28f * shMidW);
        }

        float3 lab = linearSRGBToOkLab(max(graded, float3(-0.08f)));
        float cMag = length(lab.yz);
        if (undertoneStrength > 0.001f) {
            float skinWeight = (0.18f + 0.82f * skinMask) * midtoneMask * nonNeutralMask;
            lab.x += (skinShiftLab.x + semanticBoost.x * skinMask) * skinWeight * undertoneStrength;
            lab.yz += skinShiftLab.yz * skinWeight * undertoneStrength;
        } else if (abs(semanticBoost.x) > 0.002f) {
            lab.x += semanticBoost.x * skinMask * midtoneMask;
        }

        // Semantic 4-band grading: tán lá xanh, bầu trời lam và dải đỏ ấm
        float foliagePop = semanticBoost.y;
        if (abs(foliagePop) > 0.005f) {
            lab.x += foliagePop * 0.018f * foliageMask;
            lab.yz *= (1.0f + foliagePop * 0.45f * foliageMask);
            lab.y -= foliagePop * 0.014f * foliageMask;
        }
        float skyShift = semanticBoost.z;
        if (abs(skyShift) > 0.005f) {
            lab.z -= skyShift * 0.026f * skyMask;
            lab.y -= skyShift * 0.008f * skyMask;
            if (skyShift > 0.0f) {
                lab.x -= skyShift * 0.016f * skyMask * smoothstep(0.55f, 0.90f, lab.x);
            }
        }
        float warmRedPop = shadowTint.w;
        if (abs(warmRedPop) > 0.005f) {
            float redW = warmRedMask * (1.0f - skinMask * 0.65f);
            lab.yz *= (1.0f + warmRedPop * 0.42f * redW);
            lab.x += warmRedPop * 0.012f * redW;
        }

        float satRoll = 1.0f - smoothstep(0.068f, 0.245f, cMag);
        float skinProtection = 1.0f - 0.48f * skinMask;
        float chromaScale = baseSaturation + baseVibrance * satRoll * skinProtection;
        if (colorCtrl > 0.001f) {
            chromaScale *= (1.0f + colorCtrl * (0.72f * satRoll + 0.24f) * skinProtection);
        } else if (colorCtrl < -0.001f) {
            chromaScale *= mix(1.0f, 0.08f, -colorCtrl);
        }
        float2 scaledAB = lab.yz * clamp(chromaScale, 0.0f, 2.05f);
        float newChroma = length(scaledAB);
        if (newChroma > 0.21f) {
            float overC = newChroma - 0.21f;
            float softC = 0.21f + (overC * 0.11f) / (overC + 0.11f);
            scaledAB *= (softC / max(newChroma, 1e-5f));
        }
        lab.yz = scaledAB;
        graded = softGamutClampLinear(okLabToLinearSRGB(lab), yOut);

        return max(mix(origLinear, graded, palette), float3(0.0f));
    }

    // Strictly monotonic cubic Hermite Vintage Matte Paper Fade (toe 0.145, shoulder 0.925, slope >= 0.42)
    inline float3 applyVintageMatteFadeSRGB(float3 s, float fade) {
        if (fade <= 0.002f) return s;
        float3 s2 = s * s;
        float3 s3 = s2 * s;
        float3 faded = (-0.68f * s3) + (1.04f * s2) + (0.42f * s) + float3(0.145f);
        return mix(s, clamp(faded, 0.0f, 1.0f), clamp(fade, 0.0f, 1.0f));
    }

    // 8 Authentic Organic Analog Light Leak Patterns (35mm Cassette Seal Edge Burns & Corner Flares)
    inline float3 evaluateOrganicLightLeak(float2 uv, int patternIndex) {
        float w1 = sin(uv.y * 5.2f + uv.x * 2.1f) * 0.06f + cos(uv.y * 11.3f) * 0.025f;
        float w2 = cos(uv.x * 4.8f - uv.y * 3.0f) * 0.055f;
        float3 leak = float3(0.0f);

        int p = patternIndex & 7;
        if (p == 0) {
            // Right-edge warm fiery orange-amber burn + crimson inner rim (classic Dazz 35mm leak)
            float edge = smoothstep(0.56f, 1.04f, uv.x + w1);
            float vBand = exp(-pow((uv.y - 0.44f) / 0.46f, 2.0f));
            float hotCore = smoothstep(0.80f, 1.02f, uv.x + w1 * 0.6f) * exp(-pow((uv.y - 0.36f) / 0.30f, 2.0f));
            leak += float3(1.00f, 0.28f, 0.05f) * edge * vBand * 0.95f;
            leak += float3(1.00f, 0.68f, 0.16f) * hotCore * 0.78f;
        } else if (p == 1) {
            // Left-edge ruby-crimson sprocket streak + golden amber wash
            float edge = 1.0f - smoothstep(-0.04f, 0.42f, uv.x + w1);
            float vBand = exp(-pow((uv.y - 0.56f) / 0.48f, 2.0f));
            float streak = exp(-pow((uv.x - 0.14f - w1 * 0.5f) / 0.075f, 2.0f)) * vBand;
            leak += float3(0.95f, 0.16f, 0.08f) * edge * vBand * 0.90f;
            leak += float3(1.00f, 0.52f, 0.14f) * streak * 0.65f;
        } else if (p == 2) {
            // Top-right golden sun-flare + warm diagonal sweep
            float d = length((uv - float2(0.95f, 0.08f)) * float2(1.0f, 1.15f));
            float glow = exp(-d * d * 4.8f);
            float diag = exp(-pow(((uv.x * 0.75f - uv.y * 0.65f) - 0.52f + w2) / 0.22f, 2.0f)) * smoothstep(0.30f, 0.98f, uv.x);
            leak += float3(1.00f, 0.54f, 0.12f) * glow * 1.05f;
            leak += float3(0.98f, 0.26f, 0.10f) * diag * 0.55f;
        } else if (p == 3) {
            // Bottom-left burnt orange + vintage magenta film-gate flare
            float d1 = length((uv - float2(0.06f, 0.94f)) * float2(1.1f, 1.0f));
            float d2 = length((uv - float2(0.28f, 0.88f)) * float2(1.3f, 1.2f));
            leak += float3(1.00f, 0.34f, 0.06f) * exp(-d1 * d1 * 5.2f) * 1.02f;
            leak += float3(0.88f, 0.14f, 0.36f) * exp(-d2 * d2 * 6.5f) * 0.58f;
        } else if (p == 4) {
            // Vertical cassette gap golden-amber ribbon + soft left red haze
            float ribbon = exp(-pow((uv.x - 0.78f - w1 * 0.45f) / 0.11f, 2.0f)) * (0.45f + 0.55f * exp(-pow((uv.y - 0.50f) / 0.52f, 2.0f)));
            float leftRim = (1.0f - smoothstep(0.0f, 0.22f, uv.x - w1 * 0.4f)) * 0.45f;
            leak += float3(1.00f, 0.44f, 0.10f) * ribbon * 0.92f;
            leak += float3(0.94f, 0.18f, 0.12f) * leftRim;
        } else if (p == 5) {
            // Soft peach-rose top-left corner bloom + subtle warm bottom edge
            float dTop = length((uv - float2(0.10f, 0.10f)) * float2(0.95f, 1.15f));
            float bottom = smoothstep(0.70f, 1.04f, uv.y + w2) * 0.50f;
            leak += float3(1.00f, 0.42f, 0.28f) * exp(-dTop * dTop * 4.5f) * 0.95f;
            leak += float3(0.96f, 0.30f, 0.08f) * bottom;
        } else if (p == 6) {
            // Dramatic dual-side scarlet/amber 35mm end-of-roll burn
            float rBurn = smoothstep(0.68f, 1.02f, uv.x + w1 * 0.7f);
            float lBurn = 1.0f - smoothstep(-0.02f, 0.26f, uv.x - w1 * 0.6f);
            leak += float3(1.00f, 0.24f, 0.04f) * rBurn * 0.92f;
            leak += float3(1.00f, 0.58f, 0.14f) * lBurn * 0.68f;
        } else {
            // Warm sunset amber-coral diagonal corner sweep (bottom-right)
            float d = length((uv - float2(0.92f, 0.88f)) * float2(0.90f, 1.10f));
            float sweep = exp(-pow((uv.y - 0.74f + (1.0f - uv.x) * 0.26f + w2) / 0.18f, 2.0f)) * smoothstep(0.25f, 0.98f, uv.x);
            leak += float3(1.00f, 0.46f, 0.10f) * exp(-d * d * 4.2f) * 0.96f;
            leak += float3(0.96f, 0.22f, 0.16f) * sweep * 0.56f;
        }
        return clamp(leak, 0.0f, 1.0f);
    }

    // Fast ALU Hash for Resolution-Normalized Silver-Halide Film Grain
    inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031f);
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.x + p3.y) * p3.z);
    }

    // Main Shared Grading Core (runs identically for both YUV live frames and BGRA stills)
    inline float3 runUnifiedColorScience(
        float3 srcSRGB,
        float3 halationSampleSum,
        float3 diffusionSampleSum,
        float3 softSkinSample,
        float2 dstUV,
        uint2 gid,
        texture3d<float, access::sample> lutTex,
        constant UnifiedColorUniforms& u
    ) {
        constexpr sampler triSampler(coord::normalized, filter::linear, address::clamp_to_edge);

        // 1. Decode sRGB -> Linear RGB
        float3 lin = srgbToLinearExact(srcSRGB);

        // 1b. Photographic Styles 3 — Soft Skin (Semantic Skin-Only Bilateral Smoothing, giữ nguyên độ nét mắt/tóc/nền)
        float texMode = u.styleTexture.x;
        float texInt = clamp(u.styleTexture.y, 0.0f, 1.0f);
        if (texMode > 0.5f && texMode < 1.5f && texInt > 0.005f) {
            float skinM = computeSkinMaskOkLab(linearSRGBToOkLab(lin));
            float3 softLin = srgbToLinearExact(softSkinSample);
            lin = mix(lin, softLin, skinM * texInt * 0.72f);
        }

        // 2. Pro Software White Balance
        if (u.wbParams.x > 0.5f) {
            lin = applySoftwareWB(lin, u.wbParams.y, u.wbParams.z);
        }

        // 3. Single-Pass OkLab Photographic Styles (+ Live 60 FPS GPU Split-Screen Wipe hỗ trợ cả dọc & ngang)
        float splitCoord = (u.splitParams.w > 0.5f) ? dstUV.y : dstUV.x;
        bool useStyleB = (u.splitParams.x > 0.5f) && (splitCoord >= u.splitParams.y);
        if (useStyleB) {
            lin = applyPhotographicStylePass(
                lin, u.styleB_control, u.styleB_gradeA, u.styleB_gradeB,
                u.styleB_m0, u.styleB_m1, u.styleB_m2,
                u.styleB_skinLab, u.styleB_shTint, u.styleB_hiTint, u.styleB_semantic
            );
        } else {
            lin = applyPhotographicStylePass(
                lin, u.styleA_control, u.styleA_gradeA, u.styleA_gradeB,
                u.styleA_m0, u.styleA_m1, u.styleA_m2,
                u.styleA_skinLab, u.styleA_shTint, u.styleA_hiTint, u.styleA_semantic
            );
        }

        // 3b. Photographic Styles 3 — Film Texture gentle highlight rolloff (khi chọn Kết cấu Film)
        if (texMode > 2.5f && texInt > 0.005f) {
            float yF = max(0.0f, dot(lin, float3(0.2126f, 0.7152f, 0.0722f)));
            float yFOut = applyHighlightShoulder(yF, 0.70f, texInt * 0.45f);
            lin *= clamp(yFOut / max(yF, 1e-5f), 0.0f, 2.0f);
        }

        // 4. Vintage Camera / Film Emulsion Emulation (76 Presets + Hardware .rgba16Float 3D LUT)
        float filmIntensity = u.wbParams.w;
        float styleGrain = clamp(u.styleTexture.z, 0.0f, 1.0f);
        float totalGrain = clamp(u.tuningB.y + styleGrain, 0.0f, 1.0f);
        float grainSize = (styleGrain > 0.005f) ? clamp(u.styleTexture.w, 0.7f, 1.8f) : 1.25f;
        float totalVignette = u.tuningB.z;
        float totalFade = u.tuningB.w;

        if (u.filmFlags.x > 0.5f && filmIntensity > 0.002f) {
            float3 preFilm = lin;
            float3 f = lin;

            // 4a. Pre-LUT Gamut Compression + C1 Rational Highlight Rolloff (threshold 0.82)
            float maxC = max(f.r, max(f.g, f.b));
            if (maxC > 0.82f) {
                float over = maxC - 0.82f;
                float rolled = 0.82f + (over * 0.18f) / (over + 0.18f);
                f *= (rolled / max(maxC, 1e-5f));
            }
            f = clamp(f, 0.0f, 1.0f);

            // 4b. Hardware Trilinear 3D LUT Texture (when present for Fuji/CCD/Canon recipes)
            if (u.filmFlags.y > 0.5f) {
                float3 sLUTIn = linearToSRGBExact(f);
                float lutN = u.filmFlags.z;
                float3 lutUV = (sLUTIn * (lutN - 1.0f) + 0.5f) / lutN;
                float3 lutOutSRGB = clamp(lutTex.sample(triSampler, lutUV).rgb, 0.0f, 1.0f);
                f = mix(f, srgbToLinearExact(lutOutSRGB), 0.72f);
            }

            // 4c. Analog Exposure EV + Warmth/Tint + 3x3 Emulsion Color Matrix
            float ev = u.filmToneParams.w;
            if (abs(ev) > 0.002f) {
                f *= exp2(ev);
            }
            float rWarm = u.filmColorParams.z;
            float rTint = u.filmColorParams.w;
            if (abs(rWarm) > 0.002f || abs(rTint) > 0.002f) {
                float3 wg = float3(
                    1.0f + rWarm * 0.34f + rTint * 0.14f,
                    1.0f - rTint * 0.18f,
                    1.0f - rWarm * 0.36f + rTint * 0.10f
                );
                f = max(f * wg, float3(0.0f));
            }

            f = max(float3(dot(f, u.filmM0.xyz), dot(f, u.filmM1.xyz), dot(f, u.filmM2.xyz)), float3(0.0f));

            // 4d. Filmic S-Curve Contrast + D-Min Toe Lift + D-Max Highlight Shoulder Roll
            float yFilm = max(0.0f, dot(f, float3(0.2126f, 0.7152f, 0.0722f)));
            float yMapped = yFilm;
            float contrast = clamp(u.filmToneParams.x, 0.65f, 1.65f);
            if (abs(contrast - 1.0f) > 0.005f) {
                float pivot = 0.18f;
                yMapped = pivot * pow(max(yMapped / pivot, 1e-6f), contrast);
            }
            float toeLift = u.filmToneParams.y;
            if (toeLift > 0.001f) {
                yMapped = yMapped + toeLift * (1.0f - smoothstep(0.0f, 0.42f, yMapped)) * 0.60f;
            }
            float shRoll = u.filmToneParams.z;
            if (shRoll > 0.001f) {
                yMapped = applyHighlightShoulder(yMapped, 0.70f, clamp(shRoll * 2.2f, 0.0f, 0.92f));
            }
            f *= clamp(yMapped / max(yFilm, 1e-5f), 0.0f, 3.0f);

            // 4e. 3-Way Shadow & Highlight Split Toning
            float shStr = u.filmShadowTint.w;
            float hiStr = u.filmHighlightTint.w;
            if (shStr > 0.001f || hiStr > 0.001f) {
                float shW = (1.0f - smoothstep(0.03f, 0.48f, yMapped)) * smoothstep(0.002f, 0.05f, yMapped);
                float hiW = smoothstep(0.42f, 0.92f, yMapped);
                f = max(f + u.filmShadowTint.xyz * shW * shStr + u.filmHighlightTint.xyz * hiW * hiStr, float3(0.0f));
            }

            // 4f. Special Emulsion Modes vs Color Emulsion OkLab Hue-Selective Shift
            int specialMode = int(round(u.filmFlags.w));
            if (specialMode == 1) {
                // Silver-Halide Monochrome (Tri-X / Acros / Leica / GR High B&W)
                float mono = dot(f, float3(0.30f, 0.59f, 0.11f));
                float shW = 1.0f - smoothstep(0.05f, 0.55f, mono);
                float hiW = smoothstep(0.45f, 0.92f, mono);
                f = max(float3(mono) + u.filmShadowTint.xyz * shW * shStr + u.filmHighlightTint.xyz * hiW * hiStr, float3(0.0f));
            } else if (specialMode == 2) {
                // Historic Prussian Blue Cyanotype
                float lum = clamp(sqrt(max(dot(f, float3(0.299f, 0.587f, 0.114f)), 0.0f)), 0.0f, 1.0f);
                float3 deepBlue = srgbToLinearExact(float3(0.045f, 0.165f, 0.345f));
                float3 midCyan  = srgbToLinearExact(float3(0.160f, 0.420f, 0.620f));
                float3 paperWht = srgbToLinearExact(float3(0.930f, 0.945f, 0.955f));
                f = (lum < 0.5f) ? mix(deepBlue, midCyan, lum * 2.0f) : mix(midCyan, paperWht, (lum - 0.5f) * 2.0f);
            } else if (specialMode == 3) {
                // Nokia 3310 Olive Monochrome Matrix LCD (4-level Ordered Bayer Dither)
                float lum = clamp(sqrt(max(dot(f, float3(0.299f, 0.587f, 0.114f)), 0.0f)), 0.0f, 1.0f);
                uint bx = (gid.x / 3u) & 1u;
                uint by = (gid.y / 3u) & 1u;
                float bayer = float((bx ^ by) * 2u + by) * 0.25f - 0.375f;
                float q = clamp(floor((lum + bayer * 0.16f) * 3.99f) / 3.0f, 0.0f, 1.0f);
                float3 lcdDark   = srgbToLinearExact(float3(0.145f, 0.208f, 0.118f));
                float3 lcdBright = srgbToLinearExact(float3(0.659f, 0.725f, 0.443f));
                f = mix(lcdDark, lcdBright, q);
            } else {
                // OkLab Hue-Selective Emulsion Shift (Red Warmth, Green->Emerald/Teal, Blue->Cyan, Skin Glow) + Saturation/Vibrance
                float3 lab = linearSRGBToOkLab(f);
                float chroma = length(lab.yz);
                float hue = atan2(lab.z, lab.y);
                float skinM = computeSkinMaskOkLab(lab);

                // Skin luminosity glow
                lab.x += u.filmHslShift.w * 0.06f * skinM;

                // Green foliage shift -> Fuji emerald/teal or Kodak warm olive
                float greenM = smoothstep(1.55f, 2.05f, hue) * (1.0f - smoothstep(2.65f, 3.05f, hue)) * smoothstep(0.02f, 0.06f, chroma);
                lab.z -= u.filmHslShift.y * 0.045f * greenM;
                lab.y -= u.filmHslShift.y * 0.025f * greenM;

                // Blue sky shift -> Vintage cyan-cobalt
                float blueM = smoothstep(-2.65f, -2.10f, hue) * (1.0f - smoothstep(-1.15f, -0.75f, hue)) * smoothstep(0.02f, 0.06f, chroma);
                lab.y += u.filmHslShift.z * 0.032f * blueM;
                lab.z += u.filmHslShift.z * 0.022f * blueM;

                // Red brick / neon warmth shift
                float redM = smoothstep(-0.15f, 0.25f, hue) * (1.0f - smoothstep(0.65f, 1.05f, hue)) * smoothstep(0.03f, 0.08f, chroma);
                lab.z += u.filmHslShift.x * 0.040f * redM;

                float satRoll = 1.0f - smoothstep(0.075f, 0.235f, chroma);
                float cScale = u.filmColorParams.x + u.filmColorParams.y * satRoll * (1.0f - 0.35f * skinM);
                if (specialMode == 4) {
                    // Bleach Bypass metallic silver retention
                    cScale *= 0.56f;
                }
                lab.yz *= clamp(cScale, 0.0f, 1.85f);
                f = max(okLabToLinearSRGB(lab), float3(0.0f));
            }

            // Recipe Matte Fade blended by filmIntensity
            if (u.filmAnalogParams.w > 0.002f) {
                float3 fSRGB = applyVintageMatteFadeSRGB(linearToSRGBExact(f), u.filmAnalogParams.w);
                f = srgbToLinearExact(fSRGB);
            }

            lin = mix(preFilm, f, filmIntensity);
            totalGrain = clamp(totalGrain + u.filmAnalogParams.x * filmIntensity, 0.0f, 1.0f);
            grainSize = mix(1.25f, max(0.85f, u.filmAnalogParams.y), filmIntensity);
            totalVignette = clamp(totalVignette + u.filmAnalogParams.z * filmIntensity, 0.0f, 1.25f);
        }

        // 5. Real-Time User FilmSimulationTuning (Contrast, Saturation, Warmth, Shadows, Highlights)
        float tContrast = u.tuningA.x;
        float tSat = u.tuningA.y;
        float tWarmth = u.tuningA.z;
        float tHighlights = u.tuningA.w;
        float tShadows = u.tuningB.x;

        if (abs(tWarmth) > 0.003f) {
            float3 wg = float3(1.0f + tWarmth * 0.38f, 1.0f + tWarmth * 0.04f, 1.0f - tWarmth * 0.40f);
            lin = max(lin * wg, float3(0.0f));
        }
        if (abs(tContrast) > 0.003f || abs(tShadows) > 0.003f || abs(tHighlights) > 0.003f) {
            float y = max(0.0f, dot(lin, float3(0.2126f, 0.7152f, 0.0722f)));
            float yNew = y;
            if (abs(tContrast) > 0.003f) {
                float pivot = 0.18f;
                yNew = pivot * pow(max(yNew / pivot, 1e-6f), clamp(1.0f + tContrast * 1.15f, 0.55f, 1.65f));
            }
            if (abs(tShadows) > 0.003f) {
                float wSh = 1.0f - smoothstep(0.02f, 0.42f, yNew);
                float expS = (tShadows >= 0.0f) ? (1.0f / (1.0f + tShadows * 1.45f)) : (1.0f - tShadows * 1.45f);
                yNew = mix(yNew, pow(max(yNew, 1e-5f), expS), wSh);
            }
            if (abs(tHighlights) > 0.003f) {
                float wHi = smoothstep(0.32f, 0.90f, yNew);
                float clampedY = min(yNew, 0.998f);
                float expH = (tHighlights < 0.0f) ? (1.0f / (1.0f + (-tHighlights) * 1.35f)) : (1.0f + tHighlights * 1.15f);
                float yRec = 1.0f - pow(max(1.0f - clampedY, 1e-5f), expH);
                yNew = mix(yNew, yRec, wHi);
            }
            lin *= clamp(yNew / max(y, 1e-5f), 0.0f, 3.2f);
        }
        if (abs(tSat) > 0.003f) {
            float3 lab = linearSRGBToOkLab(lin);
            lab.yz *= clamp(1.0f + tSat, 0.0f, 1.85f);
            lin = max(okLabToLinearSRGB(lab), float3(0.0f));
        }

        // 6. Optional AI Full Auto Parameters
        if (u.tuningC.w > 0.5f) {
            float aiEV = u.aiParams.x;
            float aiContrast = u.aiParams.y;
            float aiSat = u.aiParams.z;
            float aiTemp = u.aiParams.w;
            if (abs(aiEV) > 0.02f) {
                float y = max(0.0f, dot(lin, float3(0.2126f, 0.7152f, 0.0722f)));
                float yAdj = applyHighlightShoulder(y * exp2(aiEV), 0.78f, aiEV > 0.0f ? 0.65f : 0.0f);
                lin *= clamp(yAdj / max(y, 1e-5f), 0.0f, 3.0f);
            }
            if (abs(aiTemp) > 25.0f) {
                lin = applySoftwareWB(lin, 5500.0f + aiTemp, 0.0f);
            }
            if (abs(aiContrast - 1.0f) > 0.02f) {
                float y = max(0.0f, dot(lin, float3(0.2126f, 0.7152f, 0.0722f)));
                float yC = 0.18f * pow(max(y / 0.18f, 1e-6f), aiContrast);
                lin *= clamp(yC / max(y, 1e-5f), 0.0f, 3.0f);
            }
            if (abs(aiSat - 1.0f) > 0.02f) {
                float3 lab = linearSRGBToOkLab(lin);
                lab.yz *= clamp(aiSat, 0.0f, 1.75f);
                lin = max(okLabToLinearSRGB(lab), float3(0.0f));
            }
        }

        // 7. Encode sRGB + User Matte Fade
        float3 srgb = linearToSRGBExact(lin);
        if (totalFade > 0.002f) {
            srgb = applyVintageMatteFadeSRGB(srgb, totalFade);
        }

        // 8. Single-Pass Remjet Halation (fiery red-orange highlight ring) & Optical Diffusion Mist (Film + Styles 3 Glow/Film)
        float styleHalo = (texMode > 2.5f) ? (texInt * 0.74f) : 0.0f;
        float styleDiff = (texMode > 1.5f && texMode < 2.5f) ? (texInt * 0.68f) : ((texMode > 2.5f) ? (texInt * 0.24f) : 0.0f);
        float totalHalation = clamp(u.tuningC.x + styleHalo + (u.filmFlags.x > 0.5f ? u.filmOpticalParams.x * filmIntensity : 0.0f), 0.0f, 1.0f);
        float totalDiffusion = clamp(styleDiff + (u.filmFlags.x > 0.5f ? u.filmOpticalParams.y * filmIntensity : 0.0f), 0.0f, 1.0f);
        if (totalHalation > 0.005f) {
            float3 haloGlow = halationSampleSum * float3(1.00f, 0.25f, 0.06f) * (totalHalation * 0.85f);
            srgb = 1.0f - (1.0f - srgb) * (1.0f - clamp(haloGlow, 0.0f, 0.92f));
        }
        if (totalDiffusion > 0.005f) {
            float3 mistGlow = diffusionSampleSum * float3(1.00f, 0.98f, 0.94f) * (totalDiffusion * 0.54f);
            srgb = 1.0f - (1.0f - srgb) * (1.0f - clamp(mistGlow, 0.0f, 0.74f));
        }

        // 9. Adjustable Organic Analog Light Leak (Screen-blended 8-pattern cassette seal flare)
        float leakAmt = clamp(u.tuningC.y, 0.0f, 1.0f);
        if (leakAmt > 0.004f) {
            float3 leakRGB = evaluateOrganicLightLeak(dstUV, int(round(u.tuningC.z))) * (leakAmt * 0.95f);
            srgb = 1.0f - (1.0f - srgb) * (1.0f - clamp(leakRGB, 0.0f, 0.96f));
        }

        // 10. Resolution-Normalized Midtone-Weighted Silver-Halide Film Grain (1080p == 12MP == 48MP)
        if (totalGrain > 0.004f) {
            float maxDim = max(u.viewportGeo.z, u.viewportGeo.w);
            float cellPx = max(1.0f, (maxDim / 1080.0f) * grainSize);
            float2 cell = floor(float2(gid) / cellPx);
            float n1 = hash12(cell + float2(u.splitParams.z * 17.3f, u.splitParams.z * 31.7f));
            float n2 = hash12(cell * 1.37f + float2(19.1f + u.splitParams.z * 7.1f, 43.9f));
            float grain = ((n1 + n2) - 1.0f); // triangular zero-mean silver grain [-1, +1]
            float lum = dot(srgb, float3(0.299f, 0.587f, 0.114f));
            float midWeight = 0.35f + 0.65f * (4.0f * lum * (1.0f - lum));
            srgb = clamp(srgb + float3(grain * totalGrain * 0.115f * midWeight), 0.0f, 1.0f);
        }

        // 11. Smooth Optical Radial Vignette
        if (totalVignette > 0.004f) {
            float2 centered = (dstUV - 0.5f) * 2.0f;
            float r2 = dot(centered, centered);
            float vig = clamp(1.0f - totalVignette * 0.30f * r2 * (0.45f + 0.55f * r2), 0.22f, 1.0f);
            srgb *= vig;
        }

        if (!all(isfinite(srgb))) {
            return srcSRGB;
        }
        return clamp(srgb, 0.0f, 1.0f);
    }

    // 8-Tap Golden-Angle Ring Helper for Zero-Allocation Remjet Halation, Optical Diffusion & Bilateral Soft Skin
    inline void accumulateOpticalGlowYUV(
        texture2d<float, access::sample> texY,
        texture2d<float, access::sample> texUV,
        sampler s,
        float2 uv,
        float3 centerSRGB,
        float isVideoRange,
        float radiusUV,
        bool computeSoftSkin,
        thread float3& outHalation,
        thread float3& outDiffusion,
        thread float3& outSoftSkin
    ) {
        constexpr float2 offsets[8] = {
            float2( 1.000f,  0.000f),
            float2( 0.707f,  0.707f),
            float2( 0.000f,  1.000f),
            float2(-0.707f,  0.707f),
            float2(-1.000f,  0.000f),
            float2(-0.707f, -0.707f),
            float2( 0.000f, -1.000f),
            float2( 0.707f, -0.707f)
        };
        float3 haloAcc = float3(0.0f);
        float3 diffAcc = float3(0.0f);
        float3 skinAcc = centerSRGB;
        float skinWAcc = 1.0f;
        for (int i = 0; i < 8; ++i) {
            float ringScale = (i & 1) == 0 ? 1.0f : 0.52f;
            float2 suv = clamp(uv + offsets[i] * (radiusUV * ringScale), 0.0f, 1.0f);
            float3 c = ycbcrToSRGB(texY.sample(s, suv).r, texUV.sample(s, suv).rg, isVideoRange);
            float lum = dot(c, float3(0.299f, 0.587f, 0.114f));
            haloAcc += c * smoothstep(0.68f, 0.98f, lum);
            diffAcc += c * smoothstep(0.55f, 0.95f, lum);
            if (computeSoftSkin) {
                float3 diff = c - centerSRGB;
                float bw = exp(-dot(diff, diff) * 85.0f) * (ringScale < 0.7f ? 1.0f : 0.65f);
                skinAcc += c * bw;
                skinWAcc += bw;
            }
        }
        outHalation = haloAcc * 0.125f;
        outDiffusion = diffAcc * 0.125f;
        outSoftSkin = skinAcc / max(skinWAcc, 1e-4f);
    }

    inline void accumulateOpticalGlowBGRA(
        texture2d<float, access::sample> texBGRA,
        sampler s,
        float2 uv,
        float3 centerSRGB,
        float radiusUV,
        bool computeSoftSkin,
        thread float3& outHalation,
        thread float3& outDiffusion,
        thread float3& outSoftSkin
    ) {
        constexpr float2 offsets[8] = {
            float2( 1.000f,  0.000f),
            float2( 0.707f,  0.707f),
            float2( 0.000f,  1.000f),
            float2(-0.707f,  0.707f),
            float2(-1.000f,  0.000f),
            float2(-0.707f, -0.707f),
            float2( 0.000f, -1.000f),
            float2( 0.707f, -0.707f)
        };
        float3 haloAcc = float3(0.0f);
        float3 diffAcc = float3(0.0f);
        float3 skinAcc = centerSRGB;
        float skinWAcc = 1.0f;
        for (int i = 0; i < 8; ++i) {
            float ringScale = (i & 1) == 0 ? 1.0f : 0.52f;
            float2 suv = clamp(uv + offsets[i] * (radiusUV * ringScale), 0.0f, 1.0f);
            float3 c = texBGRA.sample(s, suv).rgb;
            float lum = dot(c, float3(0.299f, 0.587f, 0.114f));
            haloAcc += c * smoothstep(0.68f, 0.98f, lum);
            diffAcc += c * smoothstep(0.55f, 0.95f, lum);
            if (computeSoftSkin) {
                float3 diff = c - centerSRGB;
                float bw = exp(-dot(diff, diff) * 85.0f) * (ringScale < 0.7f ? 1.0f : 0.65f);
                skinAcc += c * bw;
                skinWAcc += bw;
            }
        }
        outHalation = haloAcc * 0.125f;
        outDiffusion = diffAcc * 0.125f;
        outSoftSkin = skinAcc / max(skinWAcc, 1e-4f);
    }

    // Kernel 1: Zero-Copy Bi-Planar YUV Camera Buffer -> Graded Output Texture
    kernel void unifiedCameraGradeYUV(
        texture2d<float, access::sample> texY   [[texture(0)]],
        texture2d<float, access::sample> texUV  [[texture(1)]],
        texture3d<float, access::sample> lutTex [[texture(2)]],
        texture2d<float, access::write>  outTex [[texture(3)]],
        constant UnifiedColorUniforms&   u      [[buffer(0)]],
        uint2                            gid    [[thread_position_in_grid]]
    ) {
        uint outW = outTex.get_width();
        uint outH = outTex.get_height();
        if (gid.x >= outW || gid.y >= outH) return;

        float2 srcUV = computeSourceUV(gid, u);
        if (srcUV.x < 0.0f || srcUV.x > 1.0f || srcUV.y < 0.0f || srcUV.y > 1.0f) {
            outTex.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }

        constexpr sampler linSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float isVideoRange = u.transformB.z;

        // Optional Nokia 3310 LCD Grid Quantization
        if (u.filmFlags.x > 0.5f && int(round(u.filmFlags.w)) == 3) {
            float2 grid = float2(96.0f, 96.0f * (u.viewportGeo.y / max(1.0f, u.viewportGeo.x)));
            srcUV = (floor(srcUV * grid) + 0.5f) / grid;
        }

        // Optional Analog Chroma Bleed (VHS / Hi8 / Polaroid / Lomo)
        float bleedPx = (u.filmFlags.x > 0.5f) ? (u.filmOpticalParams.z * u.wbParams.w) : 0.0f;
        float3 srcSRGB;
        if (bleedPx > 0.08f) {
            float dx = bleedPx / max(1.0f, u.viewportGeo.x);
            float3 cL = ycbcrToSRGB(texY.sample(linSampler, clamp(srcUV + float2(dx, 0.0f), 0.0f, 1.0f)).r,
                                    texUV.sample(linSampler, clamp(srcUV + float2(dx, 0.0f), 0.0f, 1.0f)).rg, isVideoRange);
            float3 cC = ycbcrToSRGB(texY.sample(linSampler, srcUV).r, texUV.sample(linSampler, srcUV).rg, isVideoRange);
            float3 cR = ycbcrToSRGB(texY.sample(linSampler, clamp(srcUV - float2(dx, 0.0f), 0.0f, 1.0f)).r,
                                    texUV.sample(linSampler, clamp(srcUV - float2(dx, 0.0f), 0.0f, 1.0f)).rg, isVideoRange);
            srcSRGB = float3(cL.r, cC.g, cR.b);
        } else {
            srcSRGB = ycbcrToSRGB(texY.sample(linSampler, srcUV).r, texUV.sample(linSampler, srcUV).rg, isVideoRange);
        }

        float3 haloSum = float3(0.0f);
        float3 diffSum = float3(0.0f);
        float3 softSkin = srcSRGB;
        bool needSoftSkin = (u.styleTexture.x > 0.5f && u.styleTexture.x < 1.5f && u.styleTexture.y > 0.005f);
        bool needStyleGlow = (u.styleTexture.x > 1.5f && u.styleTexture.y > 0.005f);
        float needGlow = u.tuningC.x + (u.filmFlags.x > 0.5f ? (u.filmOpticalParams.x + u.filmOpticalParams.y) * u.wbParams.w : 0.0f);
        if (needGlow > 0.008f || needStyleGlow || needSoftSkin) {
            float sampleRadius = (needSoftSkin && needGlow <= 0.008f && !needStyleGlow) ? 0.0046f : 0.0115f;
            accumulateOpticalGlowYUV(texY, texUV, linSampler, srcUV, srcSRGB, isVideoRange, sampleRadius, needSoftSkin, haloSum, diffSum, softSkin);
        }

        float2 dstUV = (float2(gid) + 0.5f) / float2(float(outW), float(outH));
        float3 outSRGB = runUnifiedColorScience(srcSRGB, haloSum, diffSum, softSkin, dstUV, gid, lutTex, u);
        outTex.write(float4(outSRGB, 1.0f), gid);
    }

    // Kernel 2: BGRA Texture (32BGRA Live Frame or Full-Res Still CGImage) -> Graded Output Texture
    kernel void unifiedCameraGradeBGRA(
        texture2d<float, access::sample> texBGRA [[texture(0)]],
        texture3d<float, access::sample> lutTex  [[texture(2)]],
        texture2d<float, access::write>  outTex  [[texture(3)]],
        constant UnifiedColorUniforms&   u       [[buffer(0)]],
        uint2                            gid     [[thread_position_in_grid]]
    ) {
        uint outW = outTex.get_width();
        uint outH = outTex.get_height();
        if (gid.x >= outW || gid.y >= outH) return;

        float2 srcUV = computeSourceUV(gid, u);
        if (srcUV.x < 0.0f || srcUV.x > 1.0f || srcUV.y < 0.0f || srcUV.y > 1.0f) {
            outTex.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }

        constexpr sampler linSampler(coord::normalized, filter::linear, address::clamp_to_edge);

        if (u.filmFlags.x > 0.5f && int(round(u.filmFlags.w)) == 3) {
            float2 grid = float2(96.0f, 96.0f * (u.viewportGeo.y / max(1.0f, u.viewportGeo.x)));
            srcUV = (floor(srcUV * grid) + 0.5f) / grid;
        }

        float bleedPx = (u.filmFlags.x > 0.5f) ? (u.filmOpticalParams.z * u.wbParams.w) : 0.0f;
        float3 srcSRGB;
        if (bleedPx > 0.08f) {
            float dx = bleedPx / max(1.0f, u.viewportGeo.x);
            float3 cL = texBGRA.sample(linSampler, clamp(srcUV + float2(dx, 0.0f), 0.0f, 1.0f)).rgb;
            float3 cC = texBGRA.sample(linSampler, srcUV).rgb;
            float3 cR = texBGRA.sample(linSampler, clamp(srcUV - float2(dx, 0.0f), 0.0f, 1.0f)).rgb;
            srcSRGB = float3(cL.r, cC.g, cR.b);
        } else {
            srcSRGB = texBGRA.sample(linSampler, srcUV).rgb;
        }

        float3 haloSum = float3(0.0f);
        float3 diffSum = float3(0.0f);
        float3 softSkin = srcSRGB;
        bool needSoftSkin = (u.styleTexture.x > 0.5f && u.styleTexture.x < 1.5f && u.styleTexture.y > 0.005f);
        bool needStyleGlow = (u.styleTexture.x > 1.5f && u.styleTexture.y > 0.005f);
        float needGlow = u.tuningC.x + (u.filmFlags.x > 0.5f ? (u.filmOpticalParams.x + u.filmOpticalParams.y) * u.wbParams.w : 0.0f);
        if (needGlow > 0.008f || needStyleGlow || needSoftSkin) {
            float sampleRadius = (needSoftSkin && needGlow <= 0.008f && !needStyleGlow) ? 0.0046f : 0.0115f;
            accumulateOpticalGlowBGRA(texBGRA, linSampler, srcUV, srcSRGB, sampleRadius, needSoftSkin, haloSum, diffSum, softSkin);
        }

        float2 dstUV = (float2(gid) + 0.5f) / float2(float(outW), float(outH));
        float3 outSRGB = runUnifiedColorScience(srcSRGB, haloSum, diffSum, softSkin, dstUV, gid, lutTex, u);
        outTex.write(float4(outSRGB, 1.0f), gid);
    }
    """
}

// MARK: - Authentic 35mm Glowing Quartz Date Stamp Renderer (Baked into Still Photos & Sample Look)
public enum VintageDateStampRenderer {
    public static func imprint(
        on cgImage: CGImage,
        style: VintageDateStampStyle,
        date: Date = Date()
    ) -> CGImage? {
        guard style.isEnabled else { return cgImage }
        let stampText = style.formattedDate(from: date)
        guard !stampText.isEmpty else { return cgImage }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 32, height > 32 else { return cgImage }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return cgImage
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip to UIKit top-left coordinates for crisp NSAttributedString drawing
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(ctx)

        let shortSide = CGFloat(min(width, height))
        let fontSize: CGFloat
        let tracking: CGFloat
        let coreColor: UIColor
        let glowColor: UIColor
        let innerFilamentColor: UIColor
        let slantShear: CGFloat

        switch style {
        case .off:
            UIGraphicsPopContext()
            ctx.restoreGState()
            return cgImage
        case .classicQuartz:
            fontSize = max(14.0, shortSide * 0.032)
            tracking = fontSize * 0.14
            coreColor = UIColor(red: 1.00, green: 0.30, blue: 0.11, alpha: 0.96)
            glowColor = UIColor(red: 1.00, green: 0.14, blue: 0.02, alpha: 0.88)
            innerFilamentColor = UIColor(red: 1.00, green: 0.64, blue: 0.28, alpha: 0.72)
            slantShear = 0.0
        case .retroLED:
            fontSize = max(14.0, shortSide * 0.030)
            tracking = fontSize * 0.12
            coreColor = UIColor(red: 1.00, green: 0.44, blue: 0.12, alpha: 0.98)
            glowColor = UIColor(red: 1.00, green: 0.24, blue: 0.02, alpha: 0.90)
            innerFilamentColor = UIColor(red: 1.00, green: 0.78, blue: 0.36, alpha: 0.78)
            slantShear = 0.0
        case .compactSlanted:
            fontSize = max(14.0, shortSide * 0.032)
            tracking = fontSize * 0.15
            coreColor = UIColor(red: 1.00, green: 0.25, blue: 0.10, alpha: 0.96)
            glowColor = UIColor(red: 0.96, green: 0.08, blue: 0.02, alpha: 0.92)
            innerFilamentColor = UIColor(red: 1.00, green: 0.58, blue: 0.22, alpha: 0.70)
            slantShear = -0.18
        }

        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: style == .retroLED ? .bold : .semibold)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking
        ]
        let measured = (stampText as NSString).size(withAttributes: baseAttrs)
        let marginX = CGFloat(width) * 0.048
        let marginY = CGFloat(height) * 0.042
        let drawX = CGFloat(width) - marginX - measured.width
        let drawY = CGFloat(height) - marginY - measured.height

        ctx.saveGState()
        if abs(slantShear) > 0.001 {
            let pivotX = drawX + measured.width * 0.5
            let pivotY = drawY + measured.height * 0.5
            ctx.translateBy(x: pivotX, y: pivotY)
            ctx.concatenate(CGAffineTransform(a: 1.0, b: 0.0, c: slantShear, d: 1.0, tx: 0.0, ty: 0.0))
            ctx.translateBy(x: -pivotX, y: -pivotY)
        }

        let glowBlur = max(2.0, fontSize * 0.28)
        let drawPoint = CGPoint(x: drawX, y: drawY)

        // Layer 1: Soft outer analog LED bleed on film emulsion
        ctx.setShadow(offset: .zero, blur: glowBlur * 1.45, color: glowColor.cgColor)
        var outerAttrs = baseAttrs
        outerAttrs[.foregroundColor] = coreColor.withAlphaComponent(0.65)
        (stampText as NSString).draw(at: drawPoint, withAttributes: outerAttrs)

        // Layer 2: Crisp glowing red-orange quartz digit body
        ctx.setShadow(offset: .zero, blur: glowBlur * 0.55, color: glowColor.cgColor)
        var coreAttrs = baseAttrs
        coreAttrs[.foregroundColor] = coreColor
        (stampText as NSString).draw(at: drawPoint, withAttributes: coreAttrs)

        // Layer 3: Subtle bright warm core filament
        ctx.setShadow(offset: .zero, blur: 0.0, color: nil)
        var innerAttrs = baseAttrs
        innerAttrs[.foregroundColor] = innerFilamentColor
        (stampText as NSString).draw(at: drawPoint, withAttributes: innerAttrs)

        ctx.restoreGState()
        UIGraphicsPopContext()
        ctx.restoreGState()

        return ctx.makeImage() ?? cgImage
    }
}

// MARK: - Thread-Safe Cache for Studio-Lit Camera Hardware PNG Icons & Sample Look Reference
public final class VintageCameraIconCache: @unchecked Sendable {
    public static let shared = VintageCameraIconCache()

    private let imageCache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var cachedSampleLook: UIImage?

    private init() {
        imageCache.countLimit = 40
    }

    public func icon(named assetName: String) -> UIImage? {
        let key = assetName as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let url = Bundle.main.url(forResource: assetName, withExtension: "png", subdirectory: "CameraIcons")
            ?? Bundle.main.url(forResource: assetName, withExtension: "png")
        guard let url, let img = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        imageCache.setObject(img, forKey: key)
        return img
    }

    public func sampleLookUIImage() -> UIImage? {
        lock.lock()
        if let existing = cachedSampleLook {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let url = Bundle.main.url(forResource: "sample_look", withExtension: "jpg", subdirectory: "CameraIcons")
            ?? Bundle.main.url(forResource: "sample_look", withExtension: "jpg")
        guard let url, let img = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        lock.lock()
        cachedSampleLook = img
        lock.unlock()
        return img
    }
}
