import Foundation

// MARK: - Swift Structs Mirroring NativeOpticsCore.h (Zero Bridging Header Modification Required)

public struct NOCUltraWideSceneMetrics: Sendable {
    public var architecturalLineStrength: Float
    public var peripheralDetailDensity: Float
    public var recommendedK: Float

    public init(architecturalLineStrength: Float, peripheralDetailDensity: Float, recommendedK: Float) {
        self.architecturalLineStrength = architecturalLineStrength
        self.peripheralDetailDensity = peripheralDetailDensity
        self.recommendedK = recommendedK
    }
}

public struct NOCHorizonTransformParams: Sendable {
    public var rollRadians: Float
    public var zoomScale: Float
    public var shakeNormX: Float
    public var shakeNormY: Float

    public init(rollRadians: Float, zoomScale: Float, shakeNormX: Float, shakeNormY: Float) {
        self.rollRadians = rollRadians
        self.zoomScale = zoomScale
        self.shakeNormX = shakeNormX
        self.shakeNormY = shakeNormY
    }
}

public struct NOCTileMotionVector: Sendable {
    public var dx: Float
    public var dy: Float
    public var sadError: Float
    public var isInvalid: UInt32

    public init(dx: Float = 0, dy: Float = 0, sadError: Float = 0, isInvalid: UInt32 = 0) {
        self.dx = dx
        self.dy = dy
        self.sadError = sadError
        self.isInvalid = isInvalid
    }
}

public struct NOCMotionFieldStats: Sendable {
    public var validTileRatio: Float
    public var meanAlignmentError: Float
    public var globalShiftX: Float
    public var globalShiftY: Float
    public var isReliable: Bool

    public init(validTileRatio: Float, meanAlignmentError: Float, globalShiftX: Float, globalShiftY: Float, isReliable: Bool) {
        self.validTileRatio = validTileRatio
        self.meanAlignmentError = meanAlignmentError
        self.globalShiftX = globalShiftX
        self.globalShiftY = globalShiftY
        self.isReliable = isReliable
    }
}

// MARK: - Direct C-ABI @_silgen_name Bindings into NativeOpticsCore.cpp

@_silgen_name("noc_uw_analyze_scene_bgra_out")
private func _noc_uw_analyze_scene_bgra_out(
    _ srcBase: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowBytes: Int32,
    _ outArchStrength: UnsafeMutablePointer<Float>,
    _ outPeriphDensity: UnsafeMutablePointer<Float>,
    _ outRecommendedK: UnsafeMutablePointer<Float>
)

@_silgen_name("noc_uw_build_rectilinear_mesh")
public func noc_uw_build_rectilinear_mesh(
    _ zoomFactor: Float,
    _ imageAspect: Float,
    _ architecturalRigidity: Float,
    _ meshW: Int32,
    _ meshH: Int32,
    _ outMeshRGBA32F: UnsafeMutablePointer<Float>
)

@_silgen_name("noc_uw_render_lanczos3_rgba8_rows_flat")
private func _noc_uw_render_lanczos3_rgba8_rows_flat(
    _ srcRGBA: UnsafePointer<UInt8>,
    _ srcWidth: Int32,
    _ srcHeight: Int32,
    _ srcRowBytes: Int32,
    _ dstRGBA: UnsafeMutablePointer<UInt8>,
    _ dstWidth: Int32,
    _ dstHeight: Int32,
    _ dstRowBytes: Int32,
    _ zoomFactor: Float,
    _ architecturalRigidity: Float,
    _ rollRadians: Float,
    _ zoomScale: Float,
    _ shakeNormX: Float,
    _ shakeNormY: Float,
    _ rowStart: Int32,
    _ rowEnd: Int32
)

@_silgen_name("noc_uw_restore_edge_clarity_rgba8_rows")
public func noc_uw_restore_edge_clarity_rgba8_rows(
    _ srcRGBA: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ srcRowBytes: Int32,
    _ dstRGBA: UnsafeMutablePointer<UInt8>,
    _ dstRowBytes: Int32,
    _ zoomFactor: Float,
    _ architecturalRigidity: Float,
    _ rowStart: Int32,
    _ rowEnd: Int32
)

@_silgen_name("noc_us_evaluate_sharpness_bgra")
public func noc_us_evaluate_sharpness_bgra(
    _ srcBase: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowBytes: Int32
) -> Float

@_silgen_name("noc_us_evaluate_sharpness_luma")
public func noc_us_evaluate_sharpness_luma(
    _ lumaBase: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowBytes: Int32
) -> Float

@_silgen_name("noc_us_regularize_motion_field_out")
private func _noc_us_regularize_motion_field_out(
    _ tileVectorsRaw: UnsafeMutableRawPointer,
    _ numTilesX: Int32,
    _ numTilesY: Int32,
    _ outValidTileRatio: UnsafeMutablePointer<Float>,
    _ outMeanAlignmentError: UnsafeMutablePointer<Float>,
    _ outGlobalShiftX: UnsafeMutablePointer<Float>,
    _ outGlobalShiftY: UnsafeMutablePointer<Float>
) -> Bool

@_silgen_name("noc_us_estimate_mad_sigma")
public func noc_us_estimate_mad_sigma(
    _ histogram128: UnsafePointer<UInt32>,
    _ validSampleCount: UInt32,
    _ isoValue: Float
) -> Float

@_silgen_name("noc_uw_resolve_params_out")
private func _noc_uw_resolve_params_out(
    _ zoomFactor: Float,
    _ architecturalRigidity: Float,
    _ outK: UnsafeMutablePointer<Float>,
    _ outInvTanhK: UnsafeMutablePointer<Float>,
    _ outProgress: UnsafeMutablePointer<Float>
)

@_silgen_name("noc_us_match_exposure_bgra_out")
private func _noc_us_match_exposure_bgra_out(
    _ refBGRA: UnsafePointer<UInt8>,
    _ secBGRA: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ refRowBytes: Int32,
    _ secRowBytes: Int32,
    _ outGain: UnsafeMutablePointer<Float>,
    _ outBias: UnsafeMutablePointer<Float>
)

@_silgen_name("noc_us_enhance_superres_bgra_rows")
public func noc_us_enhance_superres_bgra_rows(
    _ srcBGRA: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ srcRowBytes: Int32,
    _ dstBGRA: UnsafeMutablePointer<UInt8>,
    _ dstRowBytes: Int32,
    _ clarityStrength: Float,
    _ shadowRecovery: Float,
    _ rowStart: Int32,
    _ rowEnd: Int32
)

// MARK: - Ergonomic Swift Wrappers

@inline(__always)
public func noc_uw_analyze_scene_bgra(
    _ srcBase: UnsafePointer<UInt8>,
    _ width: Int32,
    _ height: Int32,
    _ rowBytes: Int32
) -> NOCUltraWideSceneMetrics {
    var arch: Float = 0.35
    var periph: Float = 0.35
    var recK: Float = 0.80
    _noc_uw_analyze_scene_bgra_out(srcBase, width, height, rowBytes, &arch, &periph, &recK)
    return NOCUltraWideSceneMetrics(architecturalLineStrength: arch, peripheralDetailDensity: periph, recommendedK: recK)
}

@inline(__always)
public func noc_uw_render_lanczos3_rgba8_rows(
    _ srcRGBA: UnsafePointer<UInt8>,
    _ srcWidth: Int32,
    _ srcHeight: Int32,
    _ srcRowBytes: Int32,
    _ dstRGBA: UnsafeMutablePointer<UInt8>,
    _ dstWidth: Int32,
    _ dstHeight: Int32,
    _ dstRowBytes: Int32,
    _ zoomFactor: Float,
    _ architecturalRigidity: Float,
    _ horizon: NOCHorizonTransformParams,
    _ rowStart: Int32,
    _ rowEnd: Int32
) {
    _noc_uw_render_lanczos3_rgba8_rows_flat(
        srcRGBA, srcWidth, srcHeight, srcRowBytes,
        dstRGBA, dstWidth, dstHeight, dstRowBytes,
        zoomFactor, architecturalRigidity,
        horizon.rollRadians, horizon.zoomScale, horizon.shakeNormX, horizon.shakeNormY,
        rowStart, rowEnd
    )
}

@inline(__always)
public func noc_us_regularize_motion_field(
    _ tileVectors: UnsafeMutablePointer<NOCTileMotionVector>,
    _ numTilesX: Int32,
    _ numTilesY: Int32
) -> NOCMotionFieldStats {
    var validRatio: Float = 0.0
    var meanErr: Float = 1.0
    var shiftX: Float = 0.0
    var shiftY: Float = 0.0
    let ok = _noc_us_regularize_motion_field_out(
        UnsafeMutableRawPointer(tileVectors),
        numTilesX,
        numTilesY,
        &validRatio,
        &meanErr,
        &shiftX,
        &shiftY
    )
    return NOCMotionFieldStats(
        validTileRatio: validRatio,
        meanAlignmentError: meanErr,
        globalShiftX: shiftX,
        globalShiftY: shiftY,
        isReliable: ok
    )
}

@inline(__always)
public func noc_uw_resolve_params(
    zoomFactor: Float,
    architecturalRigidity: Float
) -> (k: Float, invTanhK: Float, progress: Float) {
    var k: Float = 0.0
    var invTanhK: Float = 1.0
    var progress: Float = 0.0
    _noc_uw_resolve_params_out(zoomFactor, architecturalRigidity, &k, &invTanhK, &progress)
    return (k, invTanhK, progress)
}

@inline(__always)
public func noc_us_match_exposure_bgra(
    refBGRA: UnsafePointer<UInt8>,
    secBGRA: UnsafePointer<UInt8>,
    width: Int32,
    height: Int32,
    refRowBytes: Int32,
    secRowBytes: Int32
) -> (gain: Float, bias: Float) {
    var gain: Float = 1.0
    var bias: Float = 0.0
    _noc_us_match_exposure_bgra_out(refBGRA, secBGRA, width, height, refRowBytes, secRowBytes, &gain, &bias)
    return (gain, bias)
}
