#ifndef NATIVE_OPTICS_CORE_H
#define NATIVE_OPTICS_CORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// 1. 0.5x Rectilinear-Conformal Ultra-Wide Optical Engine (C++20 + ARM64 NEON)
// ============================================================================

typedef struct NOCUltraWideSceneMetrics {
    float architecturalLineStrength; // [0..1] density of straight vertical/horizontal lines
    float peripheralDetailDensity;   // [0..1] edge energy in outer 30% band
    float recommendedK;              // Optimal hyperbolic rectilinear parameter k (zero barrel bend)
} NOCUltraWideSceneMetrics;

typedef struct NOCHorizonTransformParams {
    float rollRadians;
    float zoomScale;
    float shakeNormX;
    float shakeNormY;
} NOCHorizonTransformParams;

// Analyze downsampled BGRA frame in C++ NEON to adapt 0.5x rectilinear strength cleanly
NOCUltraWideSceneMetrics noc_uw_analyze_scene_bgra(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
);

// Build a C-infinity isotropic hyperbolic-rectilinear 2D UV + Jacobian sharpening mesh.
// outMeshRGBA32F must have size meshW * meshH * 4 floats:
//   [0] = srcU in [0, 1]
//   [1] = srcV in [0, 1]
//   [2] = jacobianSharpenBoost in [0, 1]
//   [3] = subtleOpticalVignette in [0.90, 1.0]
// Guarantees:
//   - Vertical straight lines remain 100% straight (zero fisheye barrel bending)
//   - Horizontal straight lines remain 100% straight
//   - Exact 1:1 center aspect ratio (zero egg-shaped faces)
//   - Exact [0, 1] boundary mapping (zero black borders, zero corner clipping)
void noc_uw_build_rectilinear_mesh(
    float zoomFactor,
    float imageAspect,
    float architecturalRigidity,
    int32_t meshW,
    int32_t meshH,
    float* outMeshRGBA32F
);

// High-precision C++20 NEON 6x6 Lanczos-3 windowed sinc resampling + anti-ringing +
// optional Horizon Lock for full-resolution still 0.5x photos.
// Processes rows [rowStart, rowEnd) so caller can dispatch parallel tiles across CPU cores.
void noc_uw_render_lanczos3_rgba8_rows(
    const uint8_t* srcRGBA,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstRGBA,
    int32_t dstWidth,
    int32_t dstHeight,
    int32_t dstRowBytes,
    float zoomFactor,
    float architecturalRigidity,
    NOCHorizonTransformParams horizon,
    int32_t rowStart,
    int32_t rowEnd
);

// Jacobian-guided micro-contrast & optical peripheral sharpness restoration pass (C++20 NEON)
// Processes rows [rowStart, rowEnd) from intermediate buffer into final output buffer.
void noc_uw_restore_edge_clarity_rgba8_rows(
    const uint8_t* srcRGBA,
    int32_t width,
    int32_t height,
    int32_t srcRowBytes,
    uint8_t* dstRGBA,
    int32_t dstRowBytes,
    float zoomFactor,
    float architecturalRigidity,
    int32_t rowStart,
    int32_t rowEnd
);

// ============================================================================
// 2. Ultra Sharp Multi-Frame Super-Resolution C++20 NEON Core
// ============================================================================

// Exact 16-byte memory layout matching Metal's TileMotionVector
typedef struct NOCTileMotionVector {
    float dx;
    float dy;
    float sadError;
    uint32_t isInvalid;
} NOCTileMotionVector;

typedef struct NOCMotionFieldStats {
    float validTileRatio;      // Fraction of tiles passing block matching + global consensus
    float meanAlignmentError;  // Average normalized SAD error over valid tiles
    float globalShiftX;        // Fitted global camera translation X (px)
    float globalShiftY;        // Fitted global camera translation Y (px)
    bool isReliable;           // False if extreme shake / mismatch -> reject frame safely
} NOCMotionFieldStats;

// Center-weighted Sobel Tenengrad + Laplacian optical focus metric (C++20 NEON)
float noc_us_evaluate_sharpness_bgra(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
);

float noc_us_evaluate_sharpness_luma(
    const uint8_t* lumaBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
);

// Robust Huber-IRLS global affine camera motion fit + 3x3 spatial median outlier repair
// operating directly in-place on Metal's shared Level-0 TileMotionVector buffer.
NOCMotionFieldStats noc_us_regularize_motion_field(
    NOCTileMotionVector* tileVectors,
    int32_t numTilesX,
    int32_t numTilesY
);

// Estimate adaptive per-frame sensor noise sigma from the 128-bin residual MAD histogram
float noc_us_estimate_mad_sigma(
    const uint32_t* histogram128,
    uint32_t validSampleCount,
    float isoValue
);

// Flat scalar/pointer C-ABI entry points for direct Swift @_silgen_name binding
void noc_uw_analyze_scene_bgra_out(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes,
    float* outArchStrength,
    float* outPeriphDensity,
    float* outRecommendedK
);

void noc_uw_render_lanczos3_rgba8_rows_flat(
    const uint8_t* srcRGBA,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstRGBA,
    int32_t dstWidth,
    int32_t dstHeight,
    int32_t dstRowBytes,
    float zoomFactor,
    float architecturalRigidity,
    float rollRadians,
    float zoomScale,
    float shakeNormX,
    float shakeNormY,
    int32_t rowStart,
    int32_t rowEnd
);

bool noc_us_regularize_motion_field_out(
    void* tileVectorsRaw,
    int32_t numTilesX,
    int32_t numTilesY,
    float* outValidTileRatio,
    float* outMeanAlignmentError,
    float* outGlobalShiftX,
    float* outGlobalShiftY
);

#ifdef __cplusplus
}
#endif

#endif // NATIVE_OPTICS_CORE_H
