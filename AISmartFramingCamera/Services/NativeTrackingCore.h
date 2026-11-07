#ifndef NATIVE_TRACKING_CORE_H
#define NATIVE_TRACKING_CORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Output structure for zero-copy C++ NEON scene luminance and sharpness analysis
typedef struct NTCSceneLumaMetrics {
    float subjectLuma;
    float backgroundLuma;
    float overallLuma;
    float highlightClippingRatio;
    float shadowRatio;
    float maxLuma;
    float subjectSharpness;
} NTCSceneLumaMetrics;

// Output structure for C++ NEON Pyramidal IC-LK + ORB + Huber IRLS patch flow
typedef struct NTCPatchFlowResult {
    double anchorNormX;
    double anchorNormY;
    int32_t inliers;
    int32_t survivingCount;
    bool isReliable;
} NTCPatchFlowResult;

// 1. Anti-aliased 2x2 box-filtered grayscale downsampling (BGRA8888 and Bi-Planar YUV420)
void ntc_downsample_bgra_to_gray(
    const uint8_t* srcBase,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstGray,
    int32_t dstWidth,
    int32_t dstHeight
);

void ntc_downsample_luma_to_gray(
    const uint8_t* srcLuma,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstGray,
    int32_t dstWidth,
    int32_t dstHeight
);

// 2. Structure-tensor Shi-Tomasi minimum eigenvalue corner extraction in C++ NEON
int32_t ntc_extract_roi_corners(
    const uint8_t* gray,
    int32_t width,
    int32_t height,
    int32_t left,
    int32_t right,
    int32_t top,
    int32_t bottom,
    float* outPointsXY,
    int32_t maxPoints
);

// 3. Rotation-steered 256-bit ORB descriptor and hardware NEON popcount Hamming distance
void ntc_compute_orb_descriptor(
    const uint8_t* gray,
    int32_t width,
    int32_t height,
    float px,
    float py,
    uint8_t* outDesc32
);

int32_t ntc_orb_hamming_distance(
    const uint8_t* descA,
    const uint8_t* descB
);

// 4. Vectorized 7x7 ZNCC patch matching with 2D sub-pixel parabolic refinement in C++ NEON
bool ntc_match_patch_zncc(
    const uint8_t* tplGray,
    int32_t tplWidth,
    int32_t tplHeight,
    float srcX,
    float srcY,
    const uint8_t* tgtGray,
    int32_t tgtWidth,
    int32_t tgtHeight,
    float centerX,
    float centerY,
    int32_t radius,
    bool requireUnique,
    float* outBestX,
    float* outBestY,
    double* outBestScore
);

// 5. Full 3-Level Pyramidal Inverse-Compositional Lucas-Kanade (IC-LK) + ORB + Huber IRLS constellation tracker
NTCPatchFlowResult ntc_evaluate_constellation_flow(
    const uint8_t* prevGray,
    const uint8_t* currGray,
    int32_t width,
    int32_t height,
    const float* prevPointsXY,
    int32_t numPoints,
    double coarseDx,
    double coarseDy,
    double prevBoxWidth,
    double currBoxWidth,
    double boxMinX,
    double boxMinY,
    double boxMaxX,
    double boxMaxY,
    double anchorNormX,
    double anchorNormY,
    float* outSurvivingPointsXY,
    int32_t maxSurvivingPoints
);

// 6. Wait-free SeqLock 200Hz IMU Ring Buffer and SO(3) / S^2 geodesic math in C++
void ntc_imu_reset(void);

void ntc_imu_push_sample(
    double timestamp,
    double qx,
    double qy,
    double qz,
    double qw
);

bool ntc_imu_interpolate_pose(
    double targetTimestamp,
    double* outQx,
    double* outQy,
    double* outQz,
    double* outQw
);

double ntc_imu_current_angular_speed(void);

double ntc_imu_angular_displacement_since(double pastTimestamp);

void ntc_s2_1euro_slerp(
    double prevX,
    double prevY,
    double prevZ,
    double targetX,
    double targetY,
    double targetZ,
    double focalScale,
    double dt,
    double* outX,
    double* outY,
    double* outZ
);

// 7. Zero-copy YUV420 / BGRA photometrics and Tenengrad/Laplacian ROI sharpness in C++ NEON
float ntc_measure_roi_sharpness(
    const uint8_t* lumaBase,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow,
    float normMinX,
    float normMinY,
    float normMaxX,
    float normMaxY
);

float ntc_estimate_scene_luminance(
    const uint8_t* baseAddress,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow,
    bool isBiPlanar
);

bool ntc_analyze_scene_luma(
    const uint8_t* baseAddress,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow,
    bool isBiPlanar,
    bool isVideoRange,
    float cropMinX,
    float cropMinY,
    float cropMaxX,
    float cropMaxY,
    bool hasSubjectRect,
    float subjMinX,
    float subjMinY,
    float subjMaxX,
    float subjMaxY,
    NTCSceneLumaMetrics* outMetrics
);

#ifdef __cplusplus
}
#endif

#endif // NATIVE_TRACKING_CORE_H
