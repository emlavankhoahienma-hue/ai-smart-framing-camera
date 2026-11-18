#include "NativeOpticsCore.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#define NOC_HAS_NEON 1
#else
#define NOC_HAS_NEON 0
#endif

namespace {

constexpr float kPi = 3.14159265358979323846f;

inline float clampf(float v, float lo, float hi) noexcept {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline int32_t clampi(int32_t v, int32_t lo, int32_t hi) noexcept {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline uint8_t floatToU8(float v) noexcept {
    const float c = clampf(v + 0.5f, 0.0f, 255.0f);
    return static_cast<uint8_t>(c);
}

// Compute the isotropic hyperbolic rectilinear parameter k in [0.0, 0.88]
// from zoomFactor in [0.5, 1.0] and scene architectural rigidity in [0.0, 1.0].
// Using phi_k(t) = tanh(k * t) / tanh(k):
//   - phi_k(0) = 0, phi_k(+-1) = +-1 (exact full-frame bounds, zero corner clipping)
//   - phi_k'(0) = k / tanh(k) > 1 (genuine wide pullback in center)
//   - Same k on X and Y => exact 1:1 aspect ratio at center (no face distortion)
//   - Separable in u and v => 100% straight vertical AND horizontal lines (zero fisheye curve!)
inline float resolveRectilinearK(float zoomFactor, float architecturalRigidity) noexcept {
    const float progress = clampf((1.0f - zoomFactor) / 0.5f, 0.0f, 1.0f);
    if (progress <= 1e-4f) {
        return 0.0f;
    }
    const float rigidity = clampf(architecturalRigidity, 0.0f, 1.0f);
    // Slightly gentler compression when strong architectural lines sit near edges
    const float maxK = 0.86f - 0.14f * rigidity;
    return maxK * progress;
}

inline float evalRectilinearMap1D(float t, float k, float invTanhK) noexcept {
    if (k <= 1e-4f) {
        return t;
    }
    return std::tanh(k * t) * invTanhK;
}

inline float evalRectilinearDeriv1D(float t, float k, float invTanhK) noexcept {
    if (k <= 1e-4f) {
        return 1.0f;
    }
    const float th = std::tanh(k * t);
    const float sech2 = 1.0f - th * th;
    return k * sech2 * invTanhK;
}

// Windowed Lanczos-3 kernel: sinc(x) * sinc(x / 3) for |x| < 3
inline float lanczos3Weight(float x) noexcept {
    const float ax = std::fabs(x);
    if (ax < 1e-6f) {
        return 1.0f;
    }
    if (ax >= 3.0f) {
        return 0.0f;
    }
    const float px = kPi * ax;
    const float px3 = px / 3.0f;
    return (std::sin(px) / px) * (std::sin(px3) / px3);
}

inline void buildLanczos3Taps(float frac, float outWeights[6]) noexcept {
    float sum = 0.0f;
    for (int i = 0; i < 6; ++i) {
        const float dist = static_cast<float>(i - 2) - frac;
        const float w = lanczos3Weight(dist);
        outWeights[i] = w;
        sum += w;
    }
    if (std::fabs(sum) > 1e-6f) {
        const float invSum = 1.0f / sum;
        for (int i = 0; i < 6; ++i) {
            outWeights[i] *= invSum;
        }
    }
}

// Small 3x3 symmetric linear solver (Gaussian elimination with partial pivoting)
bool solve3x3(double A[3][3], double b[3], double x[3]) noexcept {
    double M[3][4];
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            M[r][c] = A[r][c];
        }
        M[r][3] = b[r];
    }

    for (int col = 0; col < 3; ++col) {
        int pivotRow = col;
        double maxAbs = std::fabs(M[col][col]);
        for (int r = col + 1; r < 3; ++r) {
            const double val = std::fabs(M[r][col]);
            if (val > maxAbs) {
                maxAbs = val;
                pivotRow = r;
            }
        }
        if (maxAbs < 1e-9) {
            return false;
        }
        if (pivotRow != col) {
            for (int c = col; c < 4; ++c) {
                std::swap(M[col][c], M[pivotRow][c]);
            }
        }
        const double diag = M[col][col];
        for (int r = col + 1; r < 3; ++r) {
            const double factor = M[r][col] / diag;
            for (int c = col; c < 4; ++c) {
                M[r][c] -= factor * M[col][c];
            }
        }
    }

    for (int r = 2; r >= 0; --r) {
        double sum = M[r][3];
        for (int c = r + 1; c < 3; ++c) {
            sum -= M[r][c] * x[c];
        }
        if (std::fabs(M[r][r]) < 1e-9) {
            return false;
        }
        x[r] = sum / M[r][r];
    }
    return true;
}

inline float medianOfSmall(float* values, int32_t count) noexcept {
    if (count <= 0) {
        return 0.0f;
    }
    std::sort(values, values + count);
    if ((count & 1) != 0) {
        return values[count / 2];
    }
    return 0.5f * (values[count / 2 - 1] + values[count / 2]);
}

} // namespace

// ============================================================================
// 1. 0.5x Rectilinear-Conformal Ultra-Wide Optical Engine Implementation
// ============================================================================

NOCUltraWideSceneMetrics noc_uw_analyze_scene_bgra(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
) {
    NOCUltraWideSceneMetrics out{0.35f, 0.35f, 0.80f};
    if (!srcBase || width < 16 || height < 16 || rowBytes < width * 4) {
        return out;
    }

    const int32_t stepX = std::max<int32_t>(1, width / 64);
    const int32_t stepY = std::max<int32_t>(1, height / 48);

    double axisAlignedEdgeEnergy = 0.0;
    double totalEdgeEnergy = 0.0;
    double peripheralEdgeSum = 0.0;
    double peripheralCount = 0.0;

    for (int32_t y = stepY; y < height - stepY; y += stepY) {
        const float ny = (static_cast<float>(y) / static_cast<float>(height) - 0.5f) * 2.0f;
        const bool isOuterY = std::fabs(ny) > 0.62f;

        const uint8_t* rowUp = srcBase + static_cast<size_t>(y - stepY) * static_cast<size_t>(rowBytes);
        const uint8_t* rowMid = srcBase + static_cast<size_t>(y) * static_cast<size_t>(rowBytes);
        const uint8_t* rowDn = srcBase + static_cast<size_t>(y + stepY) * static_cast<size_t>(rowBytes);

        for (int32_t x = stepX; x < width - stepX; x += stepX) {
            const float nx = (static_cast<float>(x) / static_cast<float>(width) - 0.5f) * 2.0f;
            const bool isOuter = isOuterY || (std::fabs(nx) > 0.62f);

            const int32_t oL = (x - stepX) * 4 + 1; // Green channel ~71.5% Rec.709 luma
            const int32_t oC = x * 4 + 1;
            const int32_t oR = (x + stepX) * 4 + 1;

            const float gx = static_cast<float>(rowMid[oR]) - static_cast<float>(rowMid[oL]);
            const float gy = static_cast<float>(rowDn[oC]) - static_cast<float>(rowUp[oC]);
            const float ax = std::fabs(gx);
            const float ay = std::fabs(gy);
            const float mag = std::sqrt(gx * gx + gy * gy);

            if (mag > 12.0f) {
                totalEdgeEnergy += static_cast<double>(mag);
                // Strong horizontal or vertical structural edges (walls, horizons, buildings)
                const float ratio = (ax > ay) ? (ay / (ax + 1e-4f)) : (ax / (ay + 1e-4f));
                if (ratio < 0.24f) {
                    axisAlignedEdgeEnergy += static_cast<double>(mag);
                }
            }
            if (isOuter) {
                peripheralEdgeSum += static_cast<double>(mag);
                peripheralCount += 1.0;
            }
        }
    }

    const float archStrength = (totalEdgeEnergy > 1e-3)
        ? clampf(static_cast<float>(axisAlignedEdgeEnergy / totalEdgeEnergy), 0.0f, 1.0f)
        : 0.35f;
    const float periphDensity = (peripheralCount > 1.0)
        ? clampf(static_cast<float>((peripheralEdgeSum / peripheralCount) / 36.0), 0.0f, 1.0f)
        : 0.35f;

    out.architecturalLineStrength = archStrength;
    out.peripheralDetailDensity = periphDensity;
    out.recommendedK = resolveRectilinearK(0.5f, archStrength);
    return out;
}

void noc_uw_build_rectilinear_mesh(
    float zoomFactor,
    float imageAspect,
    float architecturalRigidity,
    int32_t meshW,
    int32_t meshH,
    float* outMeshRGBA32F
) {
    (void)imageAspect;
    if (!outMeshRGBA32F || meshW < 2 || meshH < 2) {
        return;
    }

    const float k = resolveRectilinearK(zoomFactor, architecturalRigidity);
    const float progress = clampf((1.0f - zoomFactor) / 0.5f, 0.0f, 1.0f);
    const float invTanhK = (k > 1e-4f) ? (1.0f / std::tanh(k)) : 1.0f;

    const float invWm1 = 1.0f / static_cast<float>(meshW - 1);
    const float invHm1 = 1.0f / static_cast<float>(meshH - 1);

    std::vector<float> uMap(static_cast<size_t>(meshW));
    std::vector<float> uDeriv(static_cast<size_t>(meshW));
    for (int32_t ix = 0; ix < meshW; ++ix) {
        const float u = static_cast<float>(ix) * invWm1 * 2.0f - 1.0f;
        uMap[static_cast<size_t>(ix)] = evalRectilinearMap1D(u, k, invTanhK);
        uDeriv[static_cast<size_t>(ix)] = evalRectilinearDeriv1D(u, k, invTanhK);
    }

    for (int32_t iy = 0; iy < meshH; ++iy) {
        const float v = static_cast<float>(iy) * invHm1 * 2.0f - 1.0f;
        const float vSrcNorm = evalRectilinearMap1D(v, k, invTanhK);
        const float vDeriv = evalRectilinearDeriv1D(v, k, invTanhK);
        const float srcV = clampf(vSrcNorm * 0.5f + 0.5f, 0.0f, 1.0f);
        const float v2 = v * v;

        for (int32_t ix = 0; ix < meshW; ++ix) {
            const float u = static_cast<float>(ix) * invWm1 * 2.0f - 1.0f;
            const float uSrcNorm = uMap[static_cast<size_t>(ix)];
            const float srcU = clampf(uSrcNorm * 0.5f + 0.5f, 0.0f, 1.0f);

            // Exact local scale Jacobian: < 1 near borders where pixels expand -> restore micro-clarity
            const float localScale = std::sqrt(std::max(1e-4f, uDeriv[static_cast<size_t>(ix)] * vDeriv));
            const float expansionExcess = std::max(0.0f, (1.0f / localScale) - 1.0f);
            const float sharpenBoost = clampf(expansionExcess * 1.55f + 0.14f * progress, 0.0f, 0.90f);

            // Subtle natural 13mm optical cos^4 micro-vignette (max 5.5% in extreme corners)
            const float r2 = std::min(2.0f, u * u + v2);
            const float vignette = 1.0f - (0.028f * progress * r2);

            const size_t idx = (static_cast<size_t>(iy) * static_cast<size_t>(meshW) + static_cast<size_t>(ix)) * 4;
            outMeshRGBA32F[idx + 0] = srcU;
            outMeshRGBA32F[idx + 1] = srcV;
            outMeshRGBA32F[idx + 2] = sharpenBoost;
            outMeshRGBA32F[idx + 3] = vignette;
        }
    }
}

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
) {
    if (!srcRGBA || !dstRGBA || srcWidth < 4 || srcHeight < 4 || dstWidth < 4 || dstHeight < 4) {
        return;
    }

    const int32_t y0 = clampi(rowStart, 0, dstHeight);
    const int32_t y1 = clampi(rowEnd, y0, dstHeight);
    if (y0 >= y1) {
        return;
    }

    const float k = resolveRectilinearK(zoomFactor, architecturalRigidity);
    const float progress = clampf((1.0f - zoomFactor) / 0.5f, 0.0f, 1.0f);
    const float invTanhK = (k > 1e-4f) ? (1.0f / std::tanh(k)) : 1.0f;

    const bool hasHorizon = (std::fabs(horizon.rollRadians) > 0.0005f) ||
                            (horizon.zoomScale > 1.001f) ||
                            (std::fabs(horizon.shakeNormX) > 1e-5f) ||
                            (std::fabs(horizon.shakeNormY) > 1e-5f);
    const float cosR = hasHorizon ? std::cos(horizon.rollRadians) : 1.0f;
    const float sinR = hasHorizon ? std::sin(horizon.rollRadians) : 0.0f;
    const float invHZoom = hasHorizon ? (1.0f / std::max(1.0f, horizon.zoomScale)) : 1.0f;

    const float srcMaxX = static_cast<float>(srcWidth - 1);
    const float srcMaxY = static_cast<float>(srcHeight - 1);
    const float invDstW = 1.0f / static_cast<float>(dstWidth);
    const float invDstH = 1.0f / static_cast<float>(dstHeight);

    // Precompute X mapping when no horizon rotation is active for extreme speed
    std::vector<float> mappedX;
    std::vector<float> uSq;
    if (!hasHorizon) {
        mappedX.resize(static_cast<size_t>(dstWidth));
        uSq.resize(static_cast<size_t>(dstWidth));
        for (int32_t x = 0; x < dstWidth; ++x) {
            const float u = ((static_cast<float>(x) + 0.5f) * invDstW - 0.5f) * 2.0f;
            const float uSrc = evalRectilinearMap1D(u, k, invTanhK);
            mappedX[static_cast<size_t>(x)] = clampf((uSrc * 0.5f + 0.5f) * static_cast<float>(srcWidth) - 0.5f, 0.0f, srcMaxX);
            uSq[static_cast<size_t>(x)] = u * u;
        }
    }

    for (int32_t y = y0; y < y1; ++y) {
        const float v = ((static_cast<float>(y) + 0.5f) * invDstH - 0.5f) * 2.0f;
        const float vSrc = evalRectilinearMap1D(v, k, invTanhK);
        const float v2 = v * v;
        uint8_t* dstRow = dstRGBA + static_cast<size_t>(y) * static_cast<size_t>(dstRowBytes);

        for (int32_t x = 0; x < dstWidth; ++x) {
            float sx;
            float sy;
            float r2;

            if (!hasHorizon) {
                sx = mappedX[static_cast<size_t>(x)];
                sy = clampf((vSrc * 0.5f + 0.5f) * static_cast<float>(srcHeight) - 0.5f, 0.0f, srcMaxY);
                r2 = std::min(2.0f, uSq[static_cast<size_t>(x)] + v2);
            } else {
                const float u = ((static_cast<float>(x) + 0.5f) * invDstW - 0.5f) * 2.0f;
                const float uSrc = evalRectilinearMap1D(u, k, invTanhK);
                // Apply inverse horizon transform around image center
                const float px = (uSrc * 0.5f - horizon.shakeNormX) * static_cast<float>(srcWidth);
                const float py = (vSrc * 0.5f - horizon.shakeNormY) * static_cast<float>(srcHeight);
                const float rx = (px * cosR + py * sinR) * invHZoom + 0.5f * static_cast<float>(srcWidth) - 0.5f;
                const float ry = (-px * sinR + py * cosR) * invHZoom + 0.5f * static_cast<float>(srcHeight) - 0.5f;
                sx = clampf(rx, 0.0f, srcMaxX);
                sy = clampf(ry, 0.0f, srcMaxY);
                r2 = std::min(2.0f, u * u + v2);
            }

            const int32_t bx = static_cast<int32_t>(std::floor(sx));
            const int32_t by = static_cast<int32_t>(std::floor(sy));
            const float fx = sx - static_cast<float>(bx);
            const float fy = sy - static_cast<float>(by);

            float wx[6];
            float wy[6];
            buildLanczos3Taps(fx, wx);
            buildLanczos3Taps(fy, wy);

            float accR = 0.0f;
            float accG = 0.0f;
            float accB = 0.0f;
            float minR = 255.0f, minG = 255.0f, minB = 255.0f;
            float maxR = 0.0f, maxG = 0.0f, maxB = 0.0f;

#if NOC_HAS_NEON
            float32x4_t accVec = vdupq_n_f32(0.0f);
            float32x4_t minVec = vdupq_n_f32(255.0f);
            float32x4_t maxVec = vdupq_n_f32(0.0f);
#endif

            for (int32_t j = 0; j < 6; ++j) {
                const int32_t syIdx = clampi(by + j - 2, 0, srcHeight - 1);
                const uint8_t* sRow = srcRGBA + static_cast<size_t>(syIdx) * static_cast<size_t>(srcRowBytes);
                const float wj = wy[j];

#if NOC_HAS_NEON
                float32x4_t rowVec = vdupq_n_f32(0.0f);
                for (int32_t i = 0; i < 6; ++i) {
                    const int32_t sxIdx = clampi(bx + i - 2, 0, srcWidth - 1);
                    const uint8_t* p = sRow + static_cast<size_t>(sxIdx) * 4;
                    const float vals[4] = {
                        static_cast<float>(p[0]),
                        static_cast<float>(p[1]),
                        static_cast<float>(p[2]),
                        255.0f
                    };
                    const float32x4_t pv = vld1q_f32(vals);
                    rowVec = vmlaq_n_f32(rowVec, pv, wx[i]);
                    if ((j == 2 || j == 3) && (i == 2 || i == 3)) {
                        minVec = vminq_f32(minVec, pv);
                        maxVec = vmaxq_f32(maxVec, pv);
                    }
                }
                accVec = vmlaq_n_f32(accVec, rowVec, wj);
#else
                float rowR = 0.0f, rowG = 0.0f, rowB = 0.0f;
                for (int32_t i = 0; i < 6; ++i) {
                    const int32_t sxIdx = clampi(bx + i - 2, 0, srcWidth - 1);
                    const uint8_t* p = sRow + static_cast<size_t>(sxIdx) * 4;
                    const float pr = static_cast<float>(p[0]);
                    const float pg = static_cast<float>(p[1]);
                    const float pb = static_cast<float>(p[2]);
                    const float wi = wx[i];
                    rowR += pr * wi;
                    rowG += pg * wi;
                    rowB += pb * wi;
                    if ((j == 2 || j == 3) && (i == 2 || i == 3)) {
                        minR = std::min(minR, pr); maxR = std::max(maxR, pr);
                        minG = std::min(minG, pg); maxG = std::max(maxG, pg);
                        minB = std::min(minB, pb); maxB = std::max(maxB, pb);
                    }
                }
                accR += rowR * wj;
                accG += rowG * wj;
                accB += rowB * wj;
#endif
            }

#if NOC_HAS_NEON
            float tmpAcc[4], tmpMin[4], tmpMax[4];
            vst1q_f32(tmpAcc, accVec);
            vst1q_f32(tmpMin, minVec);
            vst1q_f32(tmpMax, maxVec);
            accR = tmpAcc[0]; accG = tmpAcc[1]; accB = tmpAcc[2];
            minR = tmpMin[0]; minG = tmpMin[1]; minB = tmpMin[2];
            maxR = tmpMax[0]; maxG = tmpMax[1]; maxB = tmpMax[2];
#endif

            // Anti-ringing clamp with tiny 4% overshoot allowance to keep crisp Lanczos edges without dark halos
            const float padR = (maxR - minR) * 0.04f;
            const float padG = (maxG - minG) * 0.04f;
            const float padB = (maxB - minB) * 0.04f;
            const float vignette = 1.0f - (0.025f * progress * r2);

            const float outR = clampf(accR, minR - padR, maxR + padR) * vignette;
            const float outG = clampf(accG, minG - padG, maxG + padG) * vignette;
            const float outB = clampf(accB, minB - padB, maxB + padB) * vignette;

            uint8_t* dp = dstRow + static_cast<size_t>(x) * 4;
            dp[0] = floatToU8(outR);
            dp[1] = floatToU8(outG);
            dp[2] = floatToU8(outB);
            dp[3] = 255;
        }
    }
}

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
) {
    if (!srcRGBA || !dstRGBA || width < 4 || height < 4) {
        return;
    }

    const int32_t y0 = clampi(rowStart, 0, height);
    const int32_t y1 = clampi(rowEnd, y0, height);
    if (y0 >= y1) {
        return;
    }

    const float k = resolveRectilinearK(zoomFactor, architecturalRigidity);
    const float progress = clampf((1.0f - zoomFactor) / 0.5f, 0.0f, 1.0f);
    const float invTanhK = (k > 1e-4f) ? (1.0f / std::tanh(k)) : 1.0f;
    const float invW = 1.0f / static_cast<float>(width);
    const float invH = 1.0f / static_cast<float>(height);

    std::vector<float> uDeriv(static_cast<size_t>(width));
    for (int32_t x = 0; x < width; ++x) {
        const float u = ((static_cast<float>(x) + 0.5f) * invW - 0.5f) * 2.0f;
        uDeriv[static_cast<size_t>(x)] = evalRectilinearDeriv1D(u, k, invTanhK);
    }

    for (int32_t y = y0; y < y1; ++y) {
        const float v = ((static_cast<float>(y) + 0.5f) * invH - 0.5f) * 2.0f;
        const float vDeriv = evalRectilinearDeriv1D(v, k, invTanhK);

        const int32_t yUp = clampi(y - 1, 0, height - 1);
        const int32_t yDn = clampi(y + 1, 0, height - 1);
        const uint8_t* rUp = srcRGBA + static_cast<size_t>(yUp) * static_cast<size_t>(srcRowBytes);
        const uint8_t* rMid = srcRGBA + static_cast<size_t>(y) * static_cast<size_t>(srcRowBytes);
        const uint8_t* rDn = srcRGBA + static_cast<size_t>(yDn) * static_cast<size_t>(srcRowBytes);
        uint8_t* dRow = dstRGBA + static_cast<size_t>(y) * static_cast<size_t>(dstRowBytes);

        for (int32_t x = 0; x < width; ++x) {
            const int32_t xL = clampi(x - 1, 0, width - 1);
            const int32_t xR = clampi(x + 1, 0, width - 1);

            const uint8_t* pC = rMid + static_cast<size_t>(x) * 4;
            const uint8_t* pL = rMid + static_cast<size_t>(xL) * 4;
            const uint8_t* pR = rMid + static_cast<size_t>(xR) * 4;
            const uint8_t* pU = rUp + static_cast<size_t>(x) * 4;
            const uint8_t* pD = rDn + static_cast<size_t>(x) * 4;

            const float localScale = std::sqrt(std::max(1e-4f, uDeriv[static_cast<size_t>(x)] * vDeriv));
            const float stretchExcess = std::max(0.0f, (1.0f / localScale) - 1.0f);
            // Adaptive edge restoration: stronger in expanded periphery, gentle in crisp center
            const float gain = clampf(0.18f * progress + stretchExcess * 1.15f, 0.0f, 0.72f);

            const float cR = static_cast<float>(pC[0]);
            const float cG = static_cast<float>(pC[1]);
            const float cB = static_cast<float>(pC[2]);

            const float avgR = 0.25f * (static_cast<float>(pL[0]) + static_cast<float>(pR[0]) + static_cast<float>(pU[0]) + static_cast<float>(pD[0]));
            const float avgG = 0.25f * (static_cast<float>(pL[1]) + static_cast<float>(pR[1]) + static_cast<float>(pU[1]) + static_cast<float>(pD[1]));
            const float avgB = 0.25f * (static_cast<float>(pL[2]) + static_cast<float>(pR[2]) + static_cast<float>(pU[2]) + static_cast<float>(pD[2]));

            // Luma-driven halo-clamped unsharp (avoids amplifying chroma noise)
            const float lumaC = 0.2126f * cR + 0.7152f * cG + 0.0722f * cB;
            const float lumaAvg = 0.2126f * avgR + 0.7152f * avgG + 0.0722f * avgB;
            float detail = lumaC - lumaAvg;
            // Suppress micro noise floor (< 1.5 luma levels) and clamp extreme halo spikes
            if (std::fabs(detail) < 1.5f) {
                detail = 0.0f;
            }
            const float delta = clampf(detail * gain, -24.0f, 24.0f);

            uint8_t* dp = dRow + static_cast<size_t>(x) * 4;
            dp[0] = floatToU8(cR + delta);
            dp[1] = floatToU8(cG + delta);
            dp[2] = floatToU8(cB + delta);
            dp[3] = 255;
        }
    }
}

// ============================================================================
// 2. Ultra Sharp Multi-Frame Super-Resolution C++20 NEON Core Implementation
// ============================================================================

float noc_us_evaluate_sharpness_bgra(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
) {
    if (!srcBase || width < 16 || height < 16 || rowBytes < width * 4) {
        return 0.0f;
    }

    const int32_t step = (width >= 2000) ? 4 : 2;
    double weightedTenengrad = 0.0;
    double sumLap = 0.0;
    double sumLapSq = 0.0;
    double weightSum = 0.0;
    double lapCount = 0.0;

    for (int32_t y = step; y < height - step; y += step) {
        const float ny = (static_cast<float>(y) / static_cast<float>(height)) - 0.5f;
        const bool inCenterY = std::fabs(ny) <= 0.35f;

        const uint8_t* rU = srcBase + static_cast<size_t>(y - 1) * static_cast<size_t>(rowBytes);
        const uint8_t* rM = srcBase + static_cast<size_t>(y) * static_cast<size_t>(rowBytes);
        const uint8_t* rD = srcBase + static_cast<size_t>(y + 1) * static_cast<size_t>(rowBytes);

        for (int32_t x = step; x < width - step; x += step) {
            const float nx = (static_cast<float>(x) / static_cast<float>(width)) - 0.5f;
            const double w = (inCenterY && std::fabs(nx) <= 0.35f) ? 2.2 : 1.0;

            const int32_t oL = (x - 1) * 4 + 1;
            const int32_t oC = x * 4 + 1;
            const int32_t oR = (x + 1) * 4 + 1;

            const double c = static_cast<double>(rM[oC]);
            // Skip saturated clipped highlight/shadow regions
            if (c <= 3.0 || c >= 252.0) {
                continue;
            }
            const double ul = static_cast<double>(rU[oL]);
            const double uc = static_cast<double>(rU[oC]);
            const double ur = static_cast<double>(rU[oR]);
            const double ml = static_cast<double>(rM[oL]);
            const double mr = static_cast<double>(rM[oR]);
            const double dl = static_cast<double>(rD[oL]);
            const double dc = static_cast<double>(rD[oC]);
            const double dr = static_cast<double>(rD[oR]);

            // Sobel Tenengrad gradient energy
            const double gx = -ul + ur - 2.0 * ml + 2.0 * mr - dl + dr;
            const double gy = -ul - 2.0 * uc - ur + dl + 2.0 * dc + dr;
            weightedTenengrad += w * (gx * gx + gy * gy) * 0.0625;
            weightSum += w;

            // Discrete Laplacian variance
            const double lap = 4.0 * c - ml - mr - uc - dc;
            sumLap += lap;
            sumLapSq += lap * lap;
            lapCount += 1.0;
        }
    }

    if (weightSum < 10.0 || lapCount < 10.0) {
        return 0.0f;
    }
    const double meanLap = sumLap / lapCount;
    const double lapVar = std::max(0.0, (sumLapSq / lapCount) - (meanLap * meanLap));
    const double tenengrad = weightedTenengrad / weightSum;
    return static_cast<float>(0.65 * tenengrad + 0.35 * lapVar);
}

float noc_us_evaluate_sharpness_luma(
    const uint8_t* lumaBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes
) {
    if (!lumaBase || width < 16 || height < 16 || rowBytes < width) {
        return 0.0f;
    }

    const int32_t step = (width >= 2000) ? 4 : 2;
    double weightedTenengrad = 0.0;
    double sumLap = 0.0;
    double sumLapSq = 0.0;
    double weightSum = 0.0;
    double lapCount = 0.0;

    for (int32_t y = step; y < height - step; y += step) {
        const float ny = (static_cast<float>(y) / static_cast<float>(height)) - 0.5f;
        const bool inCenterY = std::fabs(ny) <= 0.35f;

        const uint8_t* rU = lumaBase + static_cast<size_t>(y - 1) * static_cast<size_t>(rowBytes);
        const uint8_t* rM = lumaBase + static_cast<size_t>(y) * static_cast<size_t>(rowBytes);
        const uint8_t* rD = lumaBase + static_cast<size_t>(y + 1) * static_cast<size_t>(rowBytes);

        for (int32_t x = step; x < width - step; x += step) {
            const float nx = (static_cast<float>(x) / static_cast<float>(width)) - 0.5f;
            const double w = (inCenterY && std::fabs(nx) <= 0.35f) ? 2.2 : 1.0;

            const double c = static_cast<double>(rM[x]);
            if (c <= 3.0 || c >= 252.0) {
                continue;
            }
            const double ul = static_cast<double>(rU[x - 1]);
            const double uc = static_cast<double>(rU[x]);
            const double ur = static_cast<double>(rU[x + 1]);
            const double ml = static_cast<double>(rM[x - 1]);
            const double mr = static_cast<double>(rM[x + 1]);
            const double dl = static_cast<double>(rD[x - 1]);
            const double dc = static_cast<double>(rD[x]);
            const double dr = static_cast<double>(rD[x + 1]);

            const double gx = -ul + ur - 2.0 * ml + 2.0 * mr - dl + dr;
            const double gy = -ul - 2.0 * uc - ur + dl + 2.0 * dc + dr;
            weightedTenengrad += w * (gx * gx + gy * gy) * 0.0625;
            weightSum += w;

            const double lap = 4.0 * c - ml - mr - uc - dc;
            sumLap += lap;
            sumLapSq += lap * lap;
            lapCount += 1.0;
        }
    }

    if (weightSum < 10.0 || lapCount < 10.0) {
        return 0.0f;
    }
    const double meanLap = sumLap / lapCount;
    const double lapVar = std::max(0.0, (sumLapSq / lapCount) - (meanLap * meanLap));
    const double tenengrad = weightedTenengrad / weightSum;
    return static_cast<float>(0.65 * tenengrad + 0.35 * lapVar);
}

NOCMotionFieldStats noc_us_regularize_motion_field(
    NOCTileMotionVector* tileVectors,
    int32_t numTilesX,
    int32_t numTilesY
) {
    NOCMotionFieldStats stats{0.0f, 1.0f, 0.0f, 0.0f, false};
    if (!tileVectors || numTilesX <= 0 || numTilesY <= 0) {
        return stats;
    }

    const int32_t totalTiles = numTilesX * numTilesY;
    std::vector<NOCTileMotionVector> snapshot(tileVectors, tileVectors + totalTiles);

    const double cx = 0.5 * static_cast<double>(numTilesX - 1);
    const double cy = 0.5 * static_cast<double>(numTilesY - 1);
    const double invSpanX = 1.0 / std::max(1.0, static_cast<double>(numTilesX));
    const double invSpanY = 1.0 / std::max(1.0, static_cast<double>(numTilesY));

    // Step 1: Fit global 2D affine camera shake model using 4 iterations of Huber-IRLS:
    //   dx(tx, ty) = px[0] + px[1] * u + px[2] * v
    //   dy(tx, ty) = py[0] + py[1] * u + py[2] * v
    double px[3] = {0.0, 0.0, 0.0};
    double py[3] = {0.0, 0.0, 0.0};

    int32_t initialValid = 0;
    double sadSum = 0.0;
    for (int32_t i = 0; i < totalTiles; ++i) {
        const auto& mv = snapshot[static_cast<size_t>(i)];
        if (mv.isInvalid == 0 && std::isfinite(mv.dx) && std::isfinite(mv.dy) &&
            std::fabs(mv.dx) <= 64.0f && std::fabs(mv.dy) <= 64.0f) {
            initialValid += 1;
            sadSum += static_cast<double>(mv.sadError);
        }
    }

    if (initialValid < std::max<int32_t>(4, totalTiles / 20)) {
        stats.validTileRatio = static_cast<float>(initialValid) / static_cast<float>(std::max<int32_t>(1, totalTiles));
        stats.meanAlignmentError = 1.0f;
        stats.isReliable = false;
        return stats;
    }

    bool modelValid = false;
    const double huberDelta = 1.25;
    for (int iter = 0; iter < 4; ++iter) {
        double A[3][3] = {{1e-4, 0.0, 0.0}, {0.0, 1e-4, 0.0}, {0.0, 0.0, 1e-4}};
        double bx[3] = {0.0, 0.0, 0.0};
        double by[3] = {0.0, 0.0, 0.0};

        for (int32_t ty = 0; ty < numTilesY; ++ty) {
            const double v = (static_cast<double>(ty) - cy) * invSpanY;
            for (int32_t tx = 0; tx < numTilesX; ++tx) {
                const auto& mv = snapshot[static_cast<size_t>(ty * numTilesX + tx)];
                if (mv.isInvalid != 0 || !std::isfinite(mv.dx) || !std::isfinite(mv.dy)) {
                    continue;
                }
                const double u = (static_cast<double>(tx) - cx) * invSpanX;
                double w = 1.0 / (0.02 + static_cast<double>(std::max(0.0f, mv.sadError)));
                if (iter > 0) {
                    const double predX = px[0] + px[1] * u + px[2] * v;
                    const double predY = py[0] + py[1] * u + py[2] * v;
                    const double err = std::hypot(static_cast<double>(mv.dx) - predX, static_cast<double>(mv.dy) - predY);
                    if (err > huberDelta) {
                        w *= (huberDelta / err);
                    }
                }
                const double basis[3] = {1.0, u, v};
                for (int r = 0; r < 3; ++r) {
                    bx[r] += w * basis[r] * static_cast<double>(mv.dx);
                    by[r] += w * basis[r] * static_cast<double>(mv.dy);
                    for (int c = 0; c < 3; ++c) {
                        A[r][c] += w * basis[r] * basis[c];
                    }
                }
            }
        }

        double nextPx[3] = {0.0, 0.0, 0.0};
        double nextPy[3] = {0.0, 0.0, 0.0};
        if (solve3x3(A, bx, nextPx) && solve3x3(A, by, nextPy)) {
            for (int i = 0; i < 3; ++i) {
                px[i] = nextPx[i];
                py[i] = nextPy[i];
            }
            modelValid = true;
        } else {
            break;
        }
    }

    // Step 2: Repair invalid & outlier tiles using 3x3 spatial median + global consensus model
    int32_t inlierCount = 0;
    double inlierSadSum = 0.0;

    for (int32_t ty = 0; ty < numTilesY; ++ty) {
        const double v = (static_cast<double>(ty) - cy) * invSpanY;
        for (int32_t tx = 0; tx < numTilesX; ++tx) {
            const int32_t idx = ty * numTilesX + tx;
            const auto& mv = snapshot[static_cast<size_t>(idx)];
            const double u = (static_cast<double>(tx) - cx) * invSpanX;
            const float modelDx = modelValid ? static_cast<float>(px[0] + px[1] * u + px[2] * v) : 0.0f;
            const float modelDy = modelValid ? static_cast<float>(py[0] + py[1] * u + py[2] * v) : 0.0f;

            // Gather 3x3 valid neighbor vectors
            float nbX[9];
            float nbY[9];
            int32_t nbCount = 0;
            for (int32_t dy = -1; dy <= 1; ++dy) {
                const int32_t ny = ty + dy;
                if (ny < 0 || ny >= numTilesY) continue;
                for (int32_t dx = -1; dx <= 1; ++dx) {
                    const int32_t nx = tx + dx;
                    if (nx < 0 || nx >= numTilesX) continue;
                    const auto& nMv = snapshot[static_cast<size_t>(ny * numTilesX + nx)];
                    if (nMv.isInvalid == 0 && std::isfinite(nMv.dx) && std::isfinite(nMv.dy)) {
                        nbX[nbCount] = nMv.dx;
                        nbY[nbCount] = nMv.dy;
                        nbCount += 1;
                    }
                }
            }

            const float medX = (nbCount >= 3) ? medianOfSmall(nbX, nbCount) : modelDx;
            const float medY = (nbCount >= 3) ? medianOfSmall(nbY, nbCount) : modelDy;

            const bool finite = std::isfinite(mv.dx) && std::isfinite(mv.dy);
            const float modelDev = finite ? std::hypot(mv.dx - modelDx, mv.dy - modelDy) : 999.0f;
            const float medDev = finite ? std::hypot(mv.dx - medX, mv.dy - medY) : 999.0f;

            const bool isOutlier = (mv.isInvalid != 0) || !finite ||
                                   (modelValid && modelDev > 3.25f && medDev > 1.75f);

            if (isOutlier) {
                // Blend spatial median with global camera motion model to seamlessly repair tile
                const float repairedX = (nbCount >= 3 && modelValid) ? (0.55f * medX + 0.45f * modelDx) : (nbCount >= 3 ? medX : modelDx);
                const float repairedY = (nbCount >= 3 && modelValid) ? (0.55f * medY + 0.45f * modelDy) : (nbCount >= 3 ? medY : modelDy);
                tileVectors[idx].dx = clampf(repairedX, -64.0f, 64.0f);
                tileVectors[idx].dy = clampf(repairedY, -64.0f, 64.0f);
                tileVectors[idx].isInvalid = 0;
            } else {
                // Mild spatial regularization only when local tile jitters slightly off consensus
                if (medDev > 0.65f && nbCount >= 4) {
                    tileVectors[idx].dx = 0.75f * mv.dx + 0.25f * medX;
                    tileVectors[idx].dy = 0.75f * mv.dy + 0.25f * medY;
                }
                inlierCount += 1;
                inlierSadSum += static_cast<double>(mv.sadError);
            }
        }
    }

    const float validRatio = static_cast<float>(inlierCount) / static_cast<float>(std::max<int32_t>(1, totalTiles));
    const float meanSad = (inlierCount > 0)
        ? static_cast<float>(inlierSadSum / static_cast<double>(inlierCount))
        : static_cast<float>(sadSum / static_cast<double>(std::max<int32_t>(1, initialValid)));

    stats.validTileRatio = validRatio;
    stats.meanAlignmentError = meanSad;
    stats.globalShiftX = static_cast<float>(px[0]);
    stats.globalShiftY = static_cast<float>(py[0]);
    stats.isReliable = (validRatio >= 0.22f && meanSad <= 0.19f);
    return stats;
}

float noc_us_estimate_mad_sigma(
    const uint32_t* histogram128,
    uint32_t validSampleCount,
    float isoValue
) {
    // ISO-based baseline sensor noise floor
    const float safeISO = clampf(isoValue, 32.0f, 6400.0f);
    const float isoPrior = clampf(0.0085f + 0.0045f * std::sqrt(safeISO / 100.0f), 0.008f, 0.032f);

    if (!histogram128 || validSampleCount < 64) {
        return isoPrior;
    }

    const uint32_t halfCount = validSampleCount / 2;
    uint32_t cumulative = 0;
    uint32_t medianBin = 10;
    for (uint32_t i = 0; i < 128; ++i) {
        cumulative += histogram128[i];
        if (cumulative >= halfCount) {
            medianBin = i;
            break;
        }
    }

    // Each bin corresponds to 0.001 residual; sigma = 1.4826 * MAD
    const float madResidual = (static_cast<float>(medianBin) + 0.5f) * 0.001f;
    const float madSigma = 1.4826f * madResidual;
    const float blended = 0.70f * madSigma + 0.30f * isoPrior;
    return clampf(blended, 0.0065f, 0.038f);
}

void noc_uw_analyze_scene_bgra_out(
    const uint8_t* srcBase,
    int32_t width,
    int32_t height,
    int32_t rowBytes,
    float* outArchStrength,
    float* outPeriphDensity,
    float* outRecommendedK
) {
    const NOCUltraWideSceneMetrics m = noc_uw_analyze_scene_bgra(srcBase, width, height, rowBytes);
    if (outArchStrength) *outArchStrength = m.architecturalLineStrength;
    if (outPeriphDensity) *outPeriphDensity = m.peripheralDetailDensity;
    if (outRecommendedK) *outRecommendedK = m.recommendedK;
}

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
) {
    const NOCHorizonTransformParams h{rollRadians, zoomScale, shakeNormX, shakeNormY};
    noc_uw_render_lanczos3_rgba8_rows(
        srcRGBA, srcWidth, srcHeight, srcRowBytes,
        dstRGBA, dstWidth, dstHeight, dstRowBytes,
        zoomFactor, architecturalRigidity, h,
        rowStart, rowEnd
    );
}

bool noc_us_regularize_motion_field_out(
    void* tileVectorsRaw,
    int32_t numTilesX,
    int32_t numTilesY,
    float* outValidTileRatio,
    float* outMeanAlignmentError,
    float* outGlobalShiftX,
    float* outGlobalShiftY
) {
    auto* ptr = static_cast<NOCTileMotionVector*>(tileVectorsRaw);
    const NOCMotionFieldStats s = noc_us_regularize_motion_field(ptr, numTilesX, numTilesY);
    if (outValidTileRatio) *outValidTileRatio = s.validTileRatio;
    if (outMeanAlignmentError) *outMeanAlignmentError = s.meanAlignmentError;
    if (outGlobalShiftX) *outGlobalShiftX = s.globalShiftX;
    if (outGlobalShiftY) *outGlobalShiftY = s.globalShiftY;
    return s.isReliable;
}
