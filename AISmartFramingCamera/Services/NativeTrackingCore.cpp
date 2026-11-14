#include "NativeTrackingCore.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

#if (defined(__ARM_NEON) || defined(__ARM_NEON__)) && defined(__aarch64__)
#include <arm_neon.h>
#define NTC_HAS_NEON 1
#else
#define NTC_HAS_NEON 0
#endif

namespace {

// ============================================================================
// 1. Thread-Local Scratch Buffers for Zero-Allocation Real-Time Execution
// ============================================================================

struct PyramidWorkspace {
    std::vector<uint8_t> prevL1;
    std::vector<uint8_t> prevL2;
    std::vector<uint8_t> currL1;
    std::vector<uint8_t> currL2;
    std::vector<double> znccGrid;

    void ensureCapacity(int32_t w0, int32_t h0) {
        const size_t capL1 = static_cast<size_t>(std::max(1, w0 / 2) * std::max(1, h0 / 2));
        const size_t capL2 = static_cast<size_t>(std::max(1, w0 / 4) * std::max(1, h0 / 4));
        if (prevL1.size() < capL1) prevL1.resize(capL1);
        if (currL1.size() < capL1) currL1.resize(capL1);
        if (prevL2.size() < capL2) prevL2.resize(capL2);
        if (currL2.size() < capL2) currL2.resize(capL2);
        if (znccGrid.size() < 48 * 48) znccGrid.resize(48 * 48, -2.0);
    }
};

static PyramidWorkspace& getWorkspace() {
    thread_local PyramidWorkspace ws;
    return ws;
}

// Fast 2x2 box-Gaussian pyramid downsampling (anti-aliased)
static void downsamplePyramidHalf(
    const uint8_t* src,
    int32_t srcW,
    int32_t srcH,
    uint8_t* dst,
    int32_t dstW,
    int32_t dstH
) {
    for (int32_t y = 0; y < dstH; ++y) {
        const int32_t sy0 = std::min(srcH - 1, y * 2);
        const int32_t sy1 = std::min(srcH - 1, y * 2 + 1);
        const uint8_t* row0 = src + sy0 * srcW;
        const uint8_t* row1 = src + sy1 * srcW;
        uint8_t* outRow = dst + y * dstW;
        int32_t x = 0;
#if NTC_HAS_NEON
        for (; x + 8 <= dstW && (x * 2 + 15) < srcW; x += 8) {
            const uint8x16_t r0 = vld1q_u8(row0 + x * 2);
            const uint8x16_t r1 = vld1q_u8(row1 + x * 2);
            const uint16x8_t sum0 = vpaddlq_u8(r0);
            const uint16x8_t sum1 = vpaddlq_u8(r1);
            const uint16x8_t total = vaddq_u16(sum0, sum1);
            const uint8x8_t avg = vrshrn_n_u16(total, 2);
            vst1_u8(outRow + x, avg);
        }
#endif
        for (; x < dstW; ++x) {
            const int32_t sx0 = std::min(srcW - 1, x * 2);
            const int32_t sx1 = std::min(srcW - 1, x * 2 + 1);
            const int32_t sum = static_cast<int32_t>(row0[sx0]) +
                                static_cast<int32_t>(row0[sx1]) +
                                static_cast<int32_t>(row1[sx0]) +
                                static_cast<int32_t>(row1[sx1]);
            outRow[x] = static_cast<uint8_t>((sum + 2) >> 2);
        }
    }
}

// Sub-pixel bilinear sample on an 8-bit grayscale image
static inline float sampleBilinear(
    const uint8_t* img,
    int32_t w,
    int32_t h,
    float x,
    float y
) {
    const float cx = std::max(0.0f, std::min(static_cast<float>(w - 1) - 1e-4f, x));
    const float cy = std::max(0.0f, std::min(static_cast<float>(h - 1) - 1e-4f, y));
    const int32_t x0 = static_cast<int32_t>(cx);
    const int32_t y0 = static_cast<int32_t>(cy);
    const int32_t x1 = std::min(w - 1, x0 + 1);
    const int32_t y1 = std::min(h - 1, y0 + 1);
    const float fx = cx - static_cast<float>(x0);
    const float fy = cy - static_cast<float>(y0);

    const float p00 = static_cast<float>(img[y0 * w + x0]);
    const float p10 = static_cast<float>(img[y0 * w + x1]);
    const float p01 = static_cast<float>(img[y1 * w + x0]);
    const float p11 = static_cast<float>(img[y1 * w + x1]);

    const float top = p00 + fx * (p10 - p00);
    const float bot = p01 + fx * (p11 - p01);
    return top + fy * (bot - top);
}

// Single-level Zero-Mean Inverse-Compositional Lucas-Kanade (IC-LK) step on 7x7 patch
static bool runSingleLevelICLK(
    const uint8_t* prevImg,
    const uint8_t* currImg,
    int32_t w,
    int32_t h,
    float srcX,
    float srcY,
    float* ioTargetX,
    float* ioTargetY
) {
    if (srcX < 4.0f || srcY < 4.0f || srcX >= static_cast<float>(w - 4) || srcY >= static_cast<float>(h - 4)) {
        return false;
    }

    float tplVals[49];
    float gxVals[49];
    float gyVals[49];
    float sumTpl = 0.0f;
    int32_t idx = 0;

    for (int32_t dy = -3; dy <= 3; ++dy) {
        const float py = srcY + static_cast<float>(dy);
        for (int32_t dx = -3; dx <= 3; ++dx) {
            const float px = srcX + static_cast<float>(dx);
            const float val = sampleBilinear(prevImg, w, h, px, py);
            const float gx = 0.5f * (sampleBilinear(prevImg, w, h, px + 1.0f, py) -
                                     sampleBilinear(prevImg, w, h, px - 1.0f, py));
            const float gy = 0.5f * (sampleBilinear(prevImg, w, h, px, py + 1.0f) -
                                     sampleBilinear(prevImg, w, h, px, py - 1.0f));
            tplVals[idx] = val;
            gxVals[idx] = gx;
            gyVals[idx] = gy;
            sumTpl += val;
            ++idx;
        }
    }

    const float meanTpl = sumTpl * (1.0f / 49.0f);
    float hxx = 0.0f;
    float hyy = 0.0f;
    float hxy = 0.0f;
    float tplVar = 0.0f;

    for (int32_t i = 0; i < 49; ++i) {
        tplVals[i] -= meanTpl;
        tplVar += tplVals[i] * tplVals[i];
        hxx += gxVals[i] * gxVals[i];
        hyy += gyVals[i] * gyVals[i];
        hxy += gxVals[i] * gyVals[i];
    }

    // Reject flat / aperture-ambiguous patches
    const float det = hxx * hyy - hxy * hxy;
    if (tplVar < 12.0f || det < 15.0f) {
        return false;
    }
    const float invDet = 1.0f / det;

    float curX = *ioTargetX;
    float curY = *ioTargetY;

    for (int32_t iter = 0; iter < 6; ++iter) {
        if (curX < 3.5f || curY < 3.5f || curX >= static_cast<float>(w - 4) + 0.5f || curY >= static_cast<float>(h - 4) + 0.5f) {
            return false;
        }

        float curVals[49];
        float sumCur = 0.0f;
        int32_t k = 0;
        for (int32_t dy = -3; dy <= 3; ++dy) {
            const float py = curY + static_cast<float>(dy);
            for (int32_t dx = -3; dx <= 3; ++dx) {
                const float px = curX + static_cast<float>(dx);
                const float v = sampleBilinear(currImg, w, h, px, py);
                curVals[k] = v;
                sumCur += v;
                ++k;
            }
        }
        const float meanCur = sumCur * (1.0f / 49.0f);

        float bx = 0.0f;
        float by = 0.0f;
        int32_t i = 0;
#if NTC_HAS_NEON
        float32x4_t bxVec = vdupq_n_f32(0.0f);
        float32x4_t byVec = vdupq_n_f32(0.0f);
        const float32x4_t meanCurVec = vdupq_n_f32(meanCur);
        for (; i + 4 <= 49; i += 4) {
            const float32x4_t cVec = vsubq_f32(vld1q_f32(curVals + i), meanCurVec);
            const float32x4_t tVec = vld1q_f32(tplVals + i);
            const float32x4_t diff = vsubq_f32(cVec, tVec);
            bxVec = vfmaq_f32(bxVec, vld1q_f32(gxVals + i), diff);
            byVec = vfmaq_f32(byVec, vld1q_f32(gyVals + i), diff);
        }
        bx = vaddvq_f32(bxVec);
        by = vaddvq_f32(byVec);
#endif
        for (; i < 49; ++i) {
            const float diff = (curVals[i] - meanCur) - tplVals[i];
            bx += gxVals[i] * diff;
            by += gyVals[i] * diff;
        }

        float stepX = -invDet * (hyy * bx - hxy * by);
        float stepY = -invDet * (-hxy * bx + hxx * by);
        stepX = std::max(-2.5f, std::min(2.5f, stepX));
        stepY = std::max(-2.5f, std::min(2.5f, stepY));

        curX += stepX;
        curY += stepY;

        if (stepX * stepX + stepY * stepY < 0.000225f) {
            break;
        }
    }

    if (curX < 4.0f || curY < 4.0f || curX >= static_cast<float>(w - 4) || curY >= static_cast<float>(h - 4)) {
        return false;
    }

    *ioTargetX = curX;
    *ioTargetY = curY;
    return true;
}

// 3-Level Pyramidal IC-LK Tracker (Coarse L2 -> Medium L1 -> Fine L0)
static bool trackPointPyramidalICLK(
    const uint8_t* prevL0,
    const uint8_t* prevL1,
    const uint8_t* prevL2,
    const uint8_t* currL0,
    const uint8_t* currL1,
    const uint8_t* currL2,
    int32_t w0,
    int32_t h0,
    float srcX,
    float srcY,
    float initTargetX,
    float initTargetY,
    float* outNewX,
    float* outNewY
) {
    const int32_t w1 = std::max(1, w0 / 2);
    const int32_t h1 = std::max(1, h0 / 2);
    const int32_t w2 = std::max(1, w1 / 2);
    const int32_t h2 = std::max(1, h1 / 2);

    float tx2 = initTargetX * 0.25f;
    float ty2 = initTargetY * 0.25f;
    if (w2 >= 16 && h2 >= 16) {
        (void)runSingleLevelICLK(prevL2, currL2, w2, h2, srcX * 0.25f, srcY * 0.25f, &tx2, &ty2);
    }

    float tx1 = tx2 * 2.0f;
    float ty1 = ty2 * 2.0f;
    if (w1 >= 16 && h1 >= 16) {
        if (!runSingleLevelICLK(prevL1, currL1, w1, h1, srcX * 0.5f, srcY * 0.5f, &tx1, &ty1)) {
            tx1 = initTargetX * 0.5f;
            ty1 = initTargetY * 0.5f;
        }
    }

    float tx0 = tx1 * 2.0f;
    float ty0 = ty1 * 2.0f;
    if (!runSingleLevelICLK(prevL0, currL0, w0, h0, srcX, srcY, &tx0, &ty0)) {
        return false;
    }

    *outNewX = tx0;
    *outNewY = ty0;
    return true;
}

// ============================================================================
// 2. Deterministic 256-Bit Steered ORB Pattern
// ============================================================================

// Compact deterministic generator for 256 point-pairs in [-4, +4] around feature
static void getOrbPairOffsets(int32_t pairIndex, float* ax, float* ay, float* bx, float* by) {
    const uint32_t u = static_cast<uint32_t>(pairIndex);
    const uint32_t h1 = (u * 2654435761u) ^ (u * 2246822519u);
    const uint32_t h2 = (u * 3266489917u) ^ (u * 668265263u);
    *ax = static_cast<float>(static_cast<int32_t>(h1 & 7u) - 3) * 0.95f;
    *ay = static_cast<float>(static_cast<int32_t>((h1 >> 3u) & 7u) - 3) * 0.95f;
    *bx = static_cast<float>(static_cast<int32_t>(h2 & 7u) - 3) * 0.95f;
    *by = static_cast<float>(static_cast<int32_t>((h2 >> 3u) & 7u) - 3) * 0.95f;
    if (*ax == *bx && *ay == *by) {
        *bx = (*ax >= 0.0f) ? (*ax - 2.0f) : (*ax + 2.0f);
    }
}

// ============================================================================
// 3. Wait-Free SeqLock 200Hz IMU Ring Buffer & Quaternion SLERP
// ============================================================================

struct ImuSlot {
    std::atomic<uint64_t> seq{0};
    double timestamp{0.0};
    double qx{0.0};
    double qy{0.0};
    double qz{0.0};
    double qw{1.0};
};

struct ImuSamplePlain {
    double timestamp;
    double qx;
    double qy;
    double qz;
    double qw;
};

static constexpr uint32_t kImuRingCapacity = 1024;
static constexpr uint32_t kImuRingMask = kImuRingCapacity - 1;

static ImuSlot gImuRing[kImuRingCapacity];
static std::atomic<uint64_t> gImuWriteCount{0};

static bool readImuSlot(uint32_t index, ImuSamplePlain* out) {
    const ImuSlot& slot = gImuRing[index & kImuRingMask];
    for (int32_t retry = 0; retry < 4; ++retry) {
        const uint64_t s0 = slot.seq.load(std::memory_order_acquire);
        if ((s0 & 1u) != 0u || s0 == 0u) {
            return false;
        }
        out->timestamp = slot.timestamp;
        out->qx = slot.qx;
        out->qy = slot.qy;
        out->qz = slot.qz;
        out->qw = slot.qw;
        std::atomic_thread_fence(std::memory_order_acquire);
        const uint64_t s1 = slot.seq.load(std::memory_order_relaxed);
        if (s0 == s1) {
            return true;
        }
    }
    return false;
}

static void slerpQuat(
    const ImuSamplePlain& a,
    const ImuSamplePlain& b,
    double t,
    double* outQx,
    double* outQy,
    double* outQz,
    double* outQw
) {
    const double clampedT = std::max(0.0, std::min(1.0, t));
    double bx = b.qx;
    double by = b.qy;
    double bz = b.qz;
    double bw = b.qw;

    double dot = a.qx * bx + a.qy * by + a.qz * bz + a.qw * bw;
    if (dot < 0.0) {
        dot = -dot;
        bx = -bx;
        by = -by;
        bz = -bz;
        bw = -bw;
    }

    double s0 = 1.0 - clampedT;
    double s1 = clampedT;
    if (dot < 0.9995) {
        const double theta = std::acos(std::min(1.0, dot));
        const double sinTheta = std::sin(theta);
        if (sinTheta > 1e-9) {
            s0 = std::sin((1.0 - clampedT) * theta) / sinTheta;
            s1 = std::sin(clampedT * theta) / sinTheta;
        }
    }

    double rx = s0 * a.qx + s1 * bx;
    double ry = s0 * a.qy + s1 * by;
    double rz = s0 * a.qz + s1 * bz;
    double rw = s0 * a.qw + s1 * bw;
    const double norm = std::sqrt(rx * rx + ry * ry + rz * rz + rw * rw);
    if (norm > 1e-12) {
        const double inv = 1.0 / norm;
        *outQx = rx * inv;
        *outQy = ry * inv;
        *outQz = rz * inv;
        *outQw = rw * inv;
    } else {
        *outQx = a.qx;
        *outQy = a.qy;
        *outQz = a.qz;
        *outQw = a.qw;
    }
}

} // namespace

// ============================================================================
// Extern "C" Public Implementation
// ============================================================================

extern "C" {

void ntc_downsample_bgra_to_gray(
    const uint8_t* srcBase,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstGray,
    int32_t dstWidth,
    int32_t dstHeight
) {
    if (!srcBase || !dstGray || srcWidth <= 0 || srcHeight <= 0 || dstWidth <= 0 || dstHeight <= 0) {
        return;
    }
    const double scaleX = static_cast<double>(srcWidth) / static_cast<double>(dstWidth);
    const double scaleY = static_cast<double>(srcHeight) / static_cast<double>(dstHeight);

    for (int32_t y = 0; y < dstHeight; ++y) {
        const int32_t sy0 = std::min(srcHeight - 1, static_cast<int32_t>((static_cast<double>(y) + 0.25) * scaleY));
        const int32_t sy1 = std::min(srcHeight - 1, static_cast<int32_t>((static_cast<double>(y) + 0.75) * scaleY));
        const uint8_t* row0 = srcBase + sy0 * srcRowBytes;
        const uint8_t* row1 = srcBase + sy1 * srcRowBytes;
        uint8_t* outRow = dstGray + y * dstWidth;

        for (int32_t x = 0; x < dstWidth; ++x) {
            const int32_t sx0 = std::min(srcWidth - 1, static_cast<int32_t>((static_cast<double>(x) + 0.25) * scaleX)) * 4;
            const int32_t sx1 = std::min(srcWidth - 1, static_cast<int32_t>((static_cast<double>(x) + 0.75) * scaleX)) * 4;

            const int32_t g00 = (29 * static_cast<int32_t>(row0[sx0]) + 150 * static_cast<int32_t>(row0[sx0 + 1]) + 77 * static_cast<int32_t>(row0[sx0 + 2])) >> 8;
            const int32_t g10 = (29 * static_cast<int32_t>(row0[sx1]) + 150 * static_cast<int32_t>(row0[sx1 + 1]) + 77 * static_cast<int32_t>(row0[sx1 + 2])) >> 8;
            const int32_t g01 = (29 * static_cast<int32_t>(row1[sx0]) + 150 * static_cast<int32_t>(row1[sx0 + 1]) + 77 * static_cast<int32_t>(row1[sx0 + 2])) >> 8;
            const int32_t g11 = (29 * static_cast<int32_t>(row1[sx1]) + 150 * static_cast<int32_t>(row1[sx1 + 1]) + 77 * static_cast<int32_t>(row1[sx1 + 2])) >> 8;

            outRow[x] = static_cast<uint8_t>((g00 + g10 + g01 + g11 + 2) >> 2);
        }
    }
}

void ntc_downsample_luma_to_gray(
    const uint8_t* srcLuma,
    int32_t srcWidth,
    int32_t srcHeight,
    int32_t srcRowBytes,
    uint8_t* dstGray,
    int32_t dstWidth,
    int32_t dstHeight
) {
    if (!srcLuma || !dstGray || srcWidth <= 0 || srcHeight <= 0 || dstWidth <= 0 || dstHeight <= 0) {
        return;
    }
    const double scaleX = static_cast<double>(srcWidth) / static_cast<double>(dstWidth);
    const double scaleY = static_cast<double>(srcHeight) / static_cast<double>(dstHeight);

    for (int32_t y = 0; y < dstHeight; ++y) {
        const int32_t sy0 = std::min(srcHeight - 1, static_cast<int32_t>((static_cast<double>(y) + 0.25) * scaleY));
        const int32_t sy1 = std::min(srcHeight - 1, static_cast<int32_t>((static_cast<double>(y) + 0.75) * scaleY));
        const uint8_t* row0 = srcLuma + sy0 * srcRowBytes;
        const uint8_t* row1 = srcLuma + sy1 * srcRowBytes;
        uint8_t* outRow = dstGray + y * dstWidth;

        for (int32_t x = 0; x < dstWidth; ++x) {
            const int32_t sx0 = std::min(srcWidth - 1, static_cast<int32_t>((static_cast<double>(x) + 0.25) * scaleX));
            const int32_t sx1 = std::min(srcWidth - 1, static_cast<int32_t>((static_cast<double>(x) + 0.75) * scaleX));
            const int32_t sum = static_cast<int32_t>(row0[sx0]) +
                                static_cast<int32_t>(row0[sx1]) +
                                static_cast<int32_t>(row1[sx0]) +
                                static_cast<int32_t>(row1[sx1]);
            outRow[x] = static_cast<uint8_t>((sum + 2) >> 2);
        }
    }
}

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
) {
    if (!gray || !outPointsXY || width <= 8 || height <= 8 || maxPoints <= 0) {
        return 0;
    }
    const int32_t safeLeft = std::max(4, left);
    const int32_t safeRight = std::min(width - 5, right);
    const int32_t safeTop = std::max(4, top);
    const int32_t safeBottom = std::min(height - 5, bottom);
    if (safeRight <= safeLeft + 8 || safeBottom <= safeTop + 8) {
        return 0;
    }

    int32_t count = 0;
    for (int32_t gy = 0; gy < 4 && count < maxPoints; ++gy) {
        for (int32_t gx = 0; gx < 4 && count < maxPoints; ++gx) {
            const int32_t x0 = safeLeft + (safeRight - safeLeft) * gx / 4;
            const int32_t x1 = safeLeft + (safeRight - safeLeft) * (gx + 1) / 4;
            const int32_t y0 = safeTop + (safeBottom - safeTop) * gy / 4;
            const int32_t y1 = safeTop + (safeBottom - safeTop) * (gy + 1) / 4;

            float bestScore = 0.0f;
            int32_t bestX = x0;
            int32_t bestY = y0;

            for (int32_t y = y0; y < y1; y += 2) {
                if (y < 4 || y >= height - 4) continue;
                for (int32_t x = x0; x < x1; x += 2) {
                    if (x < 4 || x >= width - 4) continue;
                    float sxx = 0.0f;
                    float syy = 0.0f;
                    float sxy = 0.0f;
                    for (int32_t v = -1; v <= 1; ++v) {
                        const int32_t row = (y + v) * width;
                        const int32_t rowPrev = (y + v - 1) * width;
                        const int32_t rowNext = (y + v + 1) * width;
                        for (int32_t u = -1; u <= 1; ++u) {
                            const int32_t col = x + u;
                            const float ix = 0.5f * (static_cast<float>(gray[row + col + 1]) -
                                                     static_cast<float>(gray[row + col - 1]));
                            const float iy = 0.5f * (static_cast<float>(gray[rowNext + col]) -
                                                     static_cast<float>(gray[rowPrev + col]));
                            sxx += ix * ix;
                            syy += iy * iy;
                            sxy += ix * iy;
                        }
                    }
                    const float trace = sxx + syy;
                    const float diff = sxx - syy;
                    const float disc = std::sqrt(std::max(0.0f, diff * diff + 4.0f * sxy * sxy));
                    const float minEigen = 0.5f * (trace - disc);
                    if (minEigen > bestScore) {
                        bestScore = minEigen;
                        bestX = x;
                        bestY = y;
                    }
                }
            }
            if (bestScore >= 16.0f) {
                outPointsXY[count * 2] = static_cast<float>(bestX);
                outPointsXY[count * 2 + 1] = static_cast<float>(bestY);
                ++count;
            }
        }
    }
    return count;
}

void ntc_compute_orb_descriptor(
    const uint8_t* gray,
    int32_t width,
    int32_t height,
    float px,
    float py,
    uint8_t* outDesc32
) {
    if (!outDesc32) return;
    std::memset(outDesc32, 0, 32);
    if (!gray || width <= 10 || height <= 10) return;

    const int32_t cx = static_cast<int32_t>(std::lround(px));
    const int32_t cy = static_cast<int32_t>(std::lround(py));
    if (cx < 5 || cy < 5 || cx >= width - 5 || cy >= height - 5) return;

    // 1. Intensity Centroid Orientation (Radius 4)
    float m10 = 0.0f;
    float m01 = 0.0f;
    for (int32_t dy = -4; dy <= 4; ++dy) {
        const uint8_t* row = gray + (cy + dy) * width;
        for (int32_t dx = -4; dx <= 4; ++dx) {
            if (dx * dx + dy * dy > 18) continue;
            const float val = static_cast<float>(row[cx + dx]);
            m10 += static_cast<float>(dx) * val;
            m01 += static_cast<float>(dy) * val;
        }
    }
    const float angle = std::atan2(m01, m10);
    const float cosT = std::cos(angle);
    const float sinT = std::sin(angle);

    // 2. Steer 256 binary tests by (cosT, sinT)
    for (int32_t byteIdx = 0; byteIdx < 32; ++byteIdx) {
        uint8_t byteVal = 0;
        for (int32_t bit = 0; bit < 8; ++bit) {
            float ax = 0.0f, ay = 0.0f, bx = 0.0f, by = 0.0f;
            getOrbPairOffsets(byteIdx * 8 + bit, &ax, &ay, &bx, &by);
            const float rax = px + (ax * cosT - ay * sinT);
            const float ray = py + (ax * sinT + ay * cosT);
            const float rbx = px + (bx * cosT - by * sinT);
            const float rby = py + (bx * sinT + by * cosT);

            const float ia = sampleBilinear(gray, width, height, rax, ray);
            const float ib = sampleBilinear(gray, width, height, rbx, rby);
            if (ia < ib) {
                byteVal |= static_cast<uint8_t>(1u << static_cast<uint32_t>(bit));
            }
        }
        outDesc32[byteIdx] = byteVal;
    }
}

int32_t ntc_orb_hamming_distance(
    const uint8_t* descA,
    const uint8_t* descB
) {
    if (!descA || !descB) return 256;
#if NTC_HAS_NEON
    const uint8x16_t a0 = vld1q_u8(descA);
    const uint8x16_t b0 = vld1q_u8(descB);
    const uint8x16_t a1 = vld1q_u8(descA + 16);
    const uint8x16_t b1 = vld1q_u8(descB + 16);
    const uint8x16_t cnt0 = vcntq_u8(veorq_u8(a0, b0));
    const uint8x16_t cnt1 = vcntq_u8(veorq_u8(a1, b1));
    return static_cast<int32_t>(vaddvq_u8(cnt0)) + static_cast<int32_t>(vaddvq_u8(cnt1));
#else
    int32_t dist = 0;
    for (int32_t i = 0; i < 4; ++i) {
        uint64_t va = 0;
        uint64_t vb = 0;
        std::memcpy(&va, descA + i * 8, sizeof(uint64_t));
        std::memcpy(&vb, descB + i * 8, sizeof(uint64_t));
        dist += __builtin_popcountll(va ^ vb);
    }
    return dist;
#endif
}

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
) {
    if (!tplGray || !tgtGray || !outBestX || !outBestY || !outBestScore) {
        return false;
    }
    if (!std::isfinite(srcX) || !std::isfinite(srcY) || !std::isfinite(centerX) || !std::isfinite(centerY)) {
        return false;
    }

    const int32_t sx = static_cast<int32_t>(std::lround(srcX));
    const int32_t sy = static_cast<int32_t>(std::lround(srcY));
    if (sx < 4 || sy < 4 || sx >= tplWidth - 4 || sy >= tplHeight - 4) {
        return false;
    }

    const int32_t cx = static_cast<int32_t>(std::lround(centerX));
    const int32_t cy = static_cast<int32_t>(std::lround(centerY));
    const int32_t minX = std::max(4, std::min(tgtWidth - 5, cx - radius));
    const int32_t maxX = std::min(tgtWidth - 5, std::max(4, cx + radius));
    const int32_t minY = std::max(4, std::min(tgtHeight - 5, cy - radius));
    const int32_t maxY = std::min(tgtHeight - 5, std::max(4, cy + radius));
    if (minX > maxX || minY > maxY) {
        return false;
    }

    alignas(16) float aFlat[52] = {0.0f};
    double sumA = 0.0;
    double sumAA = 0.0;
    int32_t idx = 0;
    for (int32_t oy = -3; oy <= 3; ++oy) {
        const uint8_t* row = tplGray + (sy + oy) * tplWidth + sx;
        for (int32_t ox = -3; ox <= 3; ++ox) {
            const double v = static_cast<double>(row[ox]);
            aFlat[idx++] = static_cast<float>(v);
            sumA += v;
            sumAA += v * v;
        }
    }
    const double varA = 49.0 * sumAA - sumA * sumA;
    if (varA <= 10.0) {
        return false;
    }

    const int32_t spanX = maxX - minX + 1;
    const int32_t spanY = maxY - minY + 1;
    const size_t gridCount = static_cast<size_t>(spanX * spanY);
    PyramidWorkspace& ws = getWorkspace();
    if (ws.znccGrid.size() < gridCount) {
        ws.znccGrid.resize(gridCount, -2.0);
    }
    double* scores = ws.znccGrid.data();

#if NTC_HAS_NEON
    const float32x4_t aVec0 = vld1q_f32(aFlat + 0);
    const float32x4_t aVec1 = vld1q_f32(aFlat + 4);
    const float32x4_t aVec2 = vld1q_f32(aFlat + 8);
    const float32x4_t aVec3 = vld1q_f32(aFlat + 12);
    const float32x4_t aVec4 = vld1q_f32(aFlat + 16);
    const float32x4_t aVec5 = vld1q_f32(aFlat + 20);
    const float32x4_t aVec6 = vld1q_f32(aFlat + 24);
    const float32x4_t aVec7 = vld1q_f32(aFlat + 28);
    const float32x4_t aVec8 = vld1q_f32(aFlat + 32);
    const float32x4_t aVec9 = vld1q_f32(aFlat + 36);
    const float32x4_t aVec10 = vld1q_f32(aFlat + 40);
    const float32x4_t aVec11 = vld1q_f32(aFlat + 44);
    const float aLast = aFlat[48];
#endif

    double bestScore = -1e30;
    int32_t bestX = minX;
    int32_t bestY = minY;

    for (int32_t y = minY; y <= maxY; ++y) {
        const int32_t gridRow = (y - minY) * spanX;
        const uint8_t* r0 = tgtGray + (y - 3) * tgtWidth;
        const uint8_t* r1 = tgtGray + (y - 2) * tgtWidth;
        const uint8_t* r2 = tgtGray + (y - 1) * tgtWidth;
        const uint8_t* r3 = tgtGray + y * tgtWidth;
        const uint8_t* r4 = tgtGray + (y + 1) * tgtWidth;
        const uint8_t* r5 = tgtGray + (y + 2) * tgtWidth;
        const uint8_t* r6 = tgtGray + (y + 3) * tgtWidth;

        for (int32_t x = minX; x <= maxX; ++x) {
            const int32_t gridIdx = gridRow + (x - minX);
            if (x < 4 || y < 4 || x >= tgtWidth - 4 || y >= tgtHeight - 4) {
                scores[gridIdx] = -2.0;
                continue;
            }
            const int32_t c = x - 3;
            alignas(16) float bFlat[52];
            for (int32_t k = 0; k < 7; ++k) {
                bFlat[0 + k] = static_cast<float>(r0[c + k]);
                bFlat[7 + k] = static_cast<float>(r1[c + k]);
                bFlat[14 + k] = static_cast<float>(r2[c + k]);
                bFlat[21 + k] = static_cast<float>(r3[c + k]);
                bFlat[28 + k] = static_cast<float>(r4[c + k]);
                bFlat[35 + k] = static_cast<float>(r5[c + k]);
                bFlat[42 + k] = static_cast<float>(r6[c + k]);
            }

            double sumB = 0.0;
            double sumBB = 0.0;
            double sumAB = 0.0;

#if NTC_HAS_NEON
            const float32x4_t b0 = vld1q_f32(bFlat + 0);
            const float32x4_t b1 = vld1q_f32(bFlat + 4);
            const float32x4_t b2 = vld1q_f32(bFlat + 8);
            const float32x4_t b3 = vld1q_f32(bFlat + 12);
            const float32x4_t b4 = vld1q_f32(bFlat + 16);
            const float32x4_t b5 = vld1q_f32(bFlat + 20);
            const float32x4_t b6 = vld1q_f32(bFlat + 24);
            const float32x4_t b7 = vld1q_f32(bFlat + 28);
            const float32x4_t b8 = vld1q_f32(bFlat + 32);
            const float32x4_t b9 = vld1q_f32(bFlat + 36);
            const float32x4_t b10 = vld1q_f32(bFlat + 40);
            const float32x4_t b11 = vld1q_f32(bFlat + 44);
            const float bLast = bFlat[48];

            const float32x4_t sB0 = vaddq_f32(vaddq_f32(b0, b1), vaddq_f32(b2, b3));
            const float32x4_t sB1 = vaddq_f32(vaddq_f32(b4, b5), vaddq_f32(b6, b7));
            const float32x4_t sB2 = vaddq_f32(vaddq_f32(b8, b9), vaddq_f32(b10, b11));
            sumB = static_cast<double>(vaddvq_f32(vaddq_f32(vaddq_f32(sB0, sB1), sB2)) + bLast);

            float32x4_t sBB = vmulq_f32(b0, b0);
            sBB = vfmaq_f32(sBB, b1, b1);
            sBB = vfmaq_f32(sBB, b2, b2);
            sBB = vfmaq_f32(sBB, b3, b3);
            sBB = vfmaq_f32(sBB, b4, b4);
            sBB = vfmaq_f32(sBB, b5, b5);
            sBB = vfmaq_f32(sBB, b6, b6);
            sBB = vfmaq_f32(sBB, b7, b7);
            sBB = vfmaq_f32(sBB, b8, b8);
            sBB = vfmaq_f32(sBB, b9, b9);
            sBB = vfmaq_f32(sBB, b10, b10);
            sBB = vfmaq_f32(sBB, b11, b11);
            sumBB = static_cast<double>(vaddvq_f32(sBB) + bLast * bLast);

            float32x4_t sAB = vmulq_f32(aVec0, b0);
            sAB = vfmaq_f32(sAB, aVec1, b1);
            sAB = vfmaq_f32(sAB, aVec2, b2);
            sAB = vfmaq_f32(sAB, aVec3, b3);
            sAB = vfmaq_f32(sAB, aVec4, b4);
            sAB = vfmaq_f32(sAB, aVec5, b5);
            sAB = vfmaq_f32(sAB, aVec6, b6);
            sAB = vfmaq_f32(sAB, aVec7, b7);
            sAB = vfmaq_f32(sAB, aVec8, b8);
            sAB = vfmaq_f32(sAB, aVec9, b9);
            sAB = vfmaq_f32(sAB, aVec10, b10);
            sAB = vfmaq_f32(sAB, aVec11, b11);
            sumAB = static_cast<double>(vaddvq_f32(sAB) + aLast * bLast);
#else
            for (int32_t k = 0; k < 49; ++k) {
                const double bv = static_cast<double>(bFlat[k]);
                sumB += bv;
                sumBB += bv * bv;
                sumAB += static_cast<double>(aFlat[k]) * bv;
            }
#endif
            const double varB = 49.0 * sumBB - sumB * sumB;
            if (varB <= 10.0) {
                scores[gridIdx] = -2.0;
                continue;
            }
            const double score = (49.0 * sumAB - sumA * sumB) / std::sqrt(varA * varB);
            scores[gridIdx] = score;
            if (score > bestScore) {
                bestScore = score;
                bestX = x;
                bestY = y;
            }
        }
    }

    if (bestScore < 0.78) {
        return false;
    }

    if (requireUnique) {
        double secondBest = -1e30;
        for (int32_t y = minY; y <= maxY; ++y) {
            const int32_t gridRow = (y - minY) * spanX;
            for (int32_t x = minX; x <= maxX; ++x) {
                if (std::abs(x - bestX) <= 2 && std::abs(y - bestY) <= 2) continue;
                const double s = scores[gridRow + (x - minX)];
                if (s > secondBest) {
                    secondBest = s;
                }
            }
        }
        if (secondBest > -1.5 && bestScore - secondBest < 0.03) {
            return false;
        }
    }

    // Autocorrelation-debiased 2D sub-pixel parabolic refinement around (bestX, bestY).
    // Subtracting the template's own +-1 px self-correlation asymmetry (autoLeft - autoRight)
    // eliminates the asymmetric 7x7 window bias at integer shifts while preserving sub-pixel accuracy.
    auto evalTplSelfZNCC = [&](int32_t cx, int32_t cy) -> double {
        double sB = 0.0;
        double sBB = 0.0;
        double sAB = 0.0;
        int32_t m = 0;
        for (int32_t oy = -3; oy <= 3; ++oy) {
            const uint8_t* r = tplGray + (cy + oy) * tplWidth + cx;
            for (int32_t ox = -3; ox <= 3; ++ox) {
                const double bv = static_cast<double>(r[ox]);
                sB += bv;
                sBB += bv * bv;
                sAB += static_cast<double>(aFlat[m++]) * bv;
            }
        }
        const double vB = 49.0 * sBB - sB * sB;
        if (vB <= 10.0) {
            return -2.0;
        }
        return (49.0 * sAB - sumA * sB) / std::sqrt(varA * vB);
    };

    double subDeltaX = 0.0;
    double subDeltaY = 0.0;
    if (bestX > minX && bestX < maxX) {
        const double sLeft = scores[(bestY - minY) * spanX + (bestX - 1 - minX)];
        const double sRight = scores[(bestY - minY) * spanX + (bestX + 1 - minX)];
        const double autoLeft = evalTplSelfZNCC(sx - 1, sy);
        const double autoRight = evalTplSelfZNCC(sx + 1, sy);
        if (sLeft > -1.0 && sRight > -1.0 && autoLeft > -1.0 && autoRight > -1.0) {
            const double denom = 2.0 * (sLeft - 2.0 * bestScore + sRight);
            if (denom < -1e-6) {
                const double debiasedNum = (sLeft - sRight) - (autoLeft - autoRight);
                subDeltaX = std::max(-0.45, std::min(0.45, debiasedNum / denom));
            }
        }
    }
    if (bestY > minY && bestY < maxY) {
        const double sUp = scores[(bestY - 1 - minY) * spanX + (bestX - minX)];
        const double sDown = scores[(bestY + 1 - minY) * spanX + (bestX - minX)];
        const double autoUp = evalTplSelfZNCC(sx, sy - 1);
        const double autoDown = evalTplSelfZNCC(sx, sy + 1);
        if (sUp > -1.0 && sDown > -1.0 && autoUp > -1.0 && autoDown > -1.0) {
            const double denom = 2.0 * (sUp - 2.0 * bestScore + sDown);
            if (denom < -1e-6) {
                const double debiasedNum = (sUp - sDown) - (autoUp - autoDown);
                subDeltaY = std::max(-0.45, std::min(0.45, debiasedNum / denom));
            }
        }
    }

    *outBestX = static_cast<float>(static_cast<double>(bestX) + subDeltaX);
    *outBestY = static_cast<float>(static_cast<double>(bestY) + subDeltaY);
    *outBestScore = bestScore;
    return true;
}

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
) {
    NTCPatchFlowResult failed = {anchorNormX, anchorNormY, 0, 0, false};
    if (!prevGray || !currGray || !prevPointsXY || width <= 8 || height <= 8 || numPoints < 5) {
        return failed;
    }

    PyramidWorkspace& ws = getWorkspace();
    ws.ensureCapacity(width, height);
    const int32_t w1 = std::max(1, width / 2);
    const int32_t h1 = std::max(1, height / 2);
    const int32_t w2 = std::max(1, w1 / 2);
    const int32_t h2 = std::max(1, h1 / 2);

    downsamplePyramidHalf(prevGray, width, height, ws.prevL1.data(), w1, h1);
    downsamplePyramidHalf(ws.prevL1.data(), w1, h1, ws.prevL2.data(), w2, h2);
    downsamplePyramidHalf(currGray, width, height, ws.currL1.data(), w1, h1);
    downsamplePyramidHalf(ws.currL1.data(), w1, h1, ws.currL2.data(), w2, h2);

    struct MatchedPair {
        double oldX;
        double oldY;
        double newX;
        double newY;
        double weight;
    };

    const double anchorPxX = anchorNormX * static_cast<double>(width);
    const double anchorPxY = anchorNormY * static_cast<double>(height);
    const double boxSpanPx = std::max(16.0, (boxMaxX - boxMinX) * static_cast<double>(width));

    MatchedPair pairs[64];
    int32_t pairCount = 0;
    const int32_t clampedPoints = std::min(numPoints, 64);

    for (int32_t i = 0; i < clampedPoints; ++i) {
        const float oldX = prevPointsXY[i * 2];
        const float oldY = prevPointsXY[i * 2 + 1];
        const double targetX = static_cast<double>(oldX) + coarseDx;
        const double targetY = static_cast<double>(oldY) + coarseDy;
        if (!std::isfinite(targetX) || !std::isfinite(targetY)) {
            continue;
        }

        const float clampedCenterX = static_cast<float>(std::max(4.0, std::min(static_cast<double>(width - 5), targetX)));
        const float clampedCenterY = static_cast<float>(std::max(4.0, std::min(static_cast<double>(height - 5), targetY)));

        // Step 1: Run 3-Level Pyramidal IC-LK to handle large fast pans up to +/-36 px
        float lkX = clampedCenterX;
        float lkY = clampedCenterY;
        const bool lkOk = trackPointPyramidalICLK(
            prevGray, ws.prevL1.data(), ws.prevL2.data(),
            currGray, ws.currL1.data(), ws.currL2.data(),
            width, height, oldX, oldY, clampedCenterX, clampedCenterY, &lkX, &lkY
        );

        // Step 2: Evaluate ZNCC + parabolic sub-pixel refinement around both the coarse center
        // and (if Pyramidal IC-LK moved further during a fast pan) around the IC-LK estimate
        float candX = 0.0f;
        float candY = 0.0f;
        double fwdScore = -2.0;
        bool matched = ntc_match_patch_zncc(
            prevGray, width, height, oldX, oldY,
            currGray, width, height, clampedCenterX, clampedCenterY,
            10, true, &candX, &candY, &fwdScore
        );

        // Only consult Pyramidal IC-LK when it predicts significant motion (> 2.5 px)
        // and use the debiased ZNCC peak lkCand directly without blending raw lkX.
        const float lkShift = std::hypot(lkX - clampedCenterX, lkY - clampedCenterY);
        if (lkOk && lkShift > 2.5f) {
            float lkCandX = 0.0f;
            float lkCandY = 0.0f;
            double lkScore = -2.0;
            if (ntc_match_patch_zncc(
                    prevGray, width, height, oldX, oldY,
                    currGray, width, height, lkX, lkY,
                    4, true, &lkCandX, &lkCandY, &lkScore)) {
                if ((!matched && lkScore >= 0.82) || lkScore > fwdScore + 0.015) {
                    candX = lkCandX;
                    candY = lkCandY;
                    fwdScore = lkScore;
                    matched = true;
                }
            }
        }

        if (!matched) {
            continue;
        }

        // Step 3: Forward-Backward consistency verification
        float revX = 0.0f;
        float revY = 0.0f;
        double revScore = 0.0;
        if (!ntc_match_patch_zncc(
                currGray, width, height, candX, candY,
                prevGray, width, height, oldX, oldY,
                4, false, &revX, &revY, &revScore)) {
            continue;
        }

        const double fbError = std::hypot(static_cast<double>(revX - oldX), static_cast<double>(revY - oldY));
        if (fbError > 1.5) {
            continue;
        }

        // Step 4: Rotation-invariant 256-bit ORB descriptor verification & weighting
        uint8_t descOld[32];
        uint8_t descNew[32];
        ntc_compute_orb_descriptor(prevGray, width, height, oldX, oldY, descOld);
        ntc_compute_orb_descriptor(currGray, width, height, candX, candY, descNew);
        const int32_t hamming = ntc_orb_hamming_distance(descOld, descNew);
        if (hamming > 104 && fwdScore < 0.88) {
            continue;
        }
        const double orbFactor = std::max(0.75, 1.0 - 0.25 * (static_cast<double>(hamming) / 128.0));

        // Step 5: Foreground centrality weight (suppresses background parallax near box borders)
        const double distFromAnchor = std::hypot(static_cast<double>(oldX) - anchorPxX,
                                                 static_cast<double>(oldY) - anchorPxY);
        const double centrality = 1.0 / (1.0 + 0.35 * (distFromAnchor / boxSpanPx));

        const double qualityWeight =
            std::max(0.25, std::min(1.0, (fwdScore - 0.75) / 0.25)) *
            std::max(0.35, 1.0 - fbError / 2.0) *
            orbFactor *
            centrality;

        pairs[pairCount++] = {
            static_cast<double>(oldX),
            static_cast<double>(oldY),
            static_cast<double>(candX),
            static_cast<double>(candY),
            qualityWeight
        };
    }

    if (pairCount < 5) {
        failed.inliers = pairCount;
        return failed;
    }

    double dxs[64];
    double dys[64];
    double cOldX = 0.0;
    double cOldY = 0.0;
    for (int32_t i = 0; i < pairCount; ++i) {
        dxs[i] = pairs[i].newX - pairs[i].oldX;
        dys[i] = pairs[i].newY - pairs[i].oldY;
        cOldX += pairs[i].oldX;
        cOldY += pairs[i].oldY;
    }
    std::sort(dxs, dxs + pairCount);
    std::sort(dys, dys + pairCount);
    const double medianDx = dxs[pairCount / 2];
    const double medianDy = dys[pairCount / 2];
    cOldX /= static_cast<double>(pairCount);
    cOldY /= static_cast<double>(pairCount);

    const double scaleRatio = (prevBoxWidth > 0.001 && currBoxWidth > 0.001)
        ? (currBoxWidth / prevBoxWidth)
        : 1.0;
    const double clampedScale = std::max(0.80, std::min(1.25, scaleRatio));

    MatchedPair inliers[64];
    int32_t inlierCount = 0;
    for (int32_t i = 0; i < pairCount; ++i) {
        const double expectedDx = medianDx + (clampedScale - 1.0) * (pairs[i].oldX - cOldX);
        const double expectedDy = medianDy + (clampedScale - 1.0) * (pairs[i].oldY - cOldY);
        const double res = std::hypot((pairs[i].newX - pairs[i].oldX) - expectedDx,
                                      (pairs[i].newY - pairs[i].oldY) - expectedDy);
        if (res <= 2.6) {
            inliers[inlierCount++] = pairs[i];
        }
    }

    if (inlierCount < 5) {
        failed.inliers = inlierCount;
        return failed;
    }

    // 2-Pass Huber-Weighted IRLS for 4-DOF Similarity Transform (a, b, tx, ty)
    double weights[64];
    for (int32_t i = 0; i < inlierCount; ++i) {
        weights[i] = inliers[i].weight;
    }

    double meanOldX = 0.0;
    double meanOldY = 0.0;
    double meanNewX = 0.0;
    double meanNewY = 0.0;
    double a = 1.0;
    double b = 0.0;

    for (int32_t pass = 0; pass < 2; ++pass) {
        double wSum = 0.0;
        meanOldX = 0.0;
        meanOldY = 0.0;
        meanNewX = 0.0;
        meanNewY = 0.0;
        for (int32_t i = 0; i < inlierCount; ++i) {
            const double w = weights[i];
            wSum += w;
            meanOldX += inliers[i].oldX * w;
            meanOldY += inliers[i].oldY * w;
            meanNewX += inliers[i].newX * w;
            meanNewY += inliers[i].newY * w;
        }
        wSum = std::max(1e-9, wSum);
        meanOldX /= wSum;
        meanOldY /= wSum;
        meanNewX /= wSum;
        meanNewY /= wSum;

        double denominator = 0.0;
        double numeratorA = 0.0;
        double numeratorB = 0.0;
        for (int32_t i = 0; i < inlierCount; ++i) {
            const double w = weights[i];
            const double x = inliers[i].oldX - meanOldX;
            const double y = inliers[i].oldY - meanOldY;
            const double u = inliers[i].newX - meanNewX;
            const double v = inliers[i].newY - meanNewY;
            denominator += w * (x * x + y * y);
            numeratorA += w * (x * u + y * v);
            numeratorB += w * (x * v - y * u);
        }

        const double priorWeight = 48.0;
        a = (denominator > 1.0) ? ((numeratorA + priorWeight) / (denominator + priorWeight)) : 1.0;
        b = (denominator > 1.0) ? (numeratorB / (denominator + priorWeight)) : 0.0;

        if (pass == 0) {
            const double huberDelta = 1.25;
            for (int32_t i = 0; i < inlierCount; ++i) {
                const double x = inliers[i].oldX - meanOldX;
                const double y = inliers[i].oldY - meanOldY;
                const double predU = a * x - b * y;
                const double predV = b * x + a * y;
                const double u = inliers[i].newX - meanNewX;
                const double v = inliers[i].newY - meanNewY;
                const double err = std::hypot(u - predU, v - predV);
                const double huber = (err <= huberDelta) ? 1.0 : (huberDelta / err);
                weights[i] = inliers[i].weight * huber;
            }
        }
    }

    const double scale = std::hypot(a, b);
    if (scale < 0.75 || scale > 1.35) {
        failed.inliers = inlierCount;
        return failed;
    }

    const double oldAnchorX = anchorPxX - meanOldX;
    const double oldAnchorY = anchorPxY - meanOldY;
    const double resX = (meanNewX + a * oldAnchorX - b * oldAnchorY) / static_cast<double>(width);
    const double resY = (meanNewY + b * oldAnchorX + a * oldAnchorY) / static_cast<double>(height);
    const double visionY = 1.0 - resY;

    if (!std::isfinite(resX) || !std::isfinite(resY) ||
        resX < 0.0 || resX > 1.0 || resY < 0.0 || resY > 1.0 ||
        resX < boxMinX - 0.04 || resX > boxMaxX + 0.04 ||
        visionY < boxMinY - 0.04 || visionY > boxMaxY + 0.04) {
        failed.inliers = inlierCount;
        return failed;
    }

    int32_t writtenSurvivors = 0;
    if (outSurvivingPointsXY && maxSurvivingPoints > 0) {
        writtenSurvivors = std::min(inlierCount, maxSurvivingPoints);
        for (int32_t i = 0; i < writtenSurvivors; ++i) {
            outSurvivingPointsXY[i * 2] = static_cast<float>(inliers[i].newX);
            outSurvivingPointsXY[i * 2 + 1] = static_cast<float>(inliers[i].newY);
        }
    }

    NTCPatchFlowResult ok = {resX, resY, inlierCount, writtenSurvivors, true};
    return ok;
}

// ============================================================================
// Wait-Free SeqLock 200Hz IMU Ring Buffer & SO(3)/S^2 Functions
// ============================================================================

void ntc_imu_reset(void) {
    gImuWriteCount.store(0, std::memory_order_release);
    for (uint32_t i = 0; i < kImuRingCapacity; ++i) {
        gImuRing[i].seq.store(0, std::memory_order_relaxed);
    }
}

void ntc_imu_push_sample(
    double timestamp,
    double qx,
    double qy,
    double qz,
    double qw
) {
    const double norm = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    if (!std::isfinite(timestamp) || !std::isfinite(norm) || norm <= 1e-9) {
        return;
    }
    const double inv = 1.0 / norm;
    const uint64_t pos = gImuWriteCount.load(std::memory_order_relaxed);
    if (pos > 0) {
        ImuSamplePlain prev;
        if (readImuSlot(static_cast<uint32_t>(pos - 1), &prev) && timestamp <= prev.timestamp) {
            return;
        }
    }

    ImuSlot& slot = gImuRing[static_cast<uint32_t>(pos) & kImuRingMask];
    const uint64_t nextSeqBase = (pos + 1u) * 2u;
    slot.seq.store(nextSeqBase - 1u, std::memory_order_release);
    slot.timestamp = timestamp;
    slot.qx = qx * inv;
    slot.qy = qy * inv;
    slot.qz = qz * inv;
    slot.qw = qw * inv;
    slot.seq.store(nextSeqBase, std::memory_order_release);
    gImuWriteCount.store(pos + 1u, std::memory_order_release);
}

bool ntc_imu_interpolate_pose(
    double targetTimestamp,
    double* outQx,
    double* outQy,
    double* outQz,
    double* outQw
) {
    if (!outQx || !outQy || !outQz || !outQw || !std::isfinite(targetTimestamp)) {
        return false;
    }
    const uint64_t count = gImuWriteCount.load(std::memory_order_acquire);
    if (count == 0) {
        return false;
    }

    const uint64_t startIdx = (count > kImuRingCapacity) ? (count - kImuRingCapacity) : 0;
    ImuSamplePlain newest;
    if (!readImuSlot(static_cast<uint32_t>(count - 1), &newest)) {
        return false;
    }
    ImuSamplePlain oldest;
    uint64_t validStart = startIdx;
    while (validStart < count && !readImuSlot(static_cast<uint32_t>(validStart), &oldest)) {
        ++validStart;
    }
    if (validStart >= count) {
        return false;
    }

    // Small boundary tolerance (20ms) matching CompositionPureCalculations.interpolateHistoricalPose
    if (targetTimestamp < oldest.timestamp - 0.02 || targetTimestamp > newest.timestamp + 0.02) {
        return false;
    }
    if (targetTimestamp <= oldest.timestamp) {
        *outQx = oldest.qx;
        *outQy = oldest.qy;
        *outQz = oldest.qz;
        *outQw = oldest.qw;
        return true;
    }
    if (targetTimestamp >= newest.timestamp) {
        *outQx = newest.qx;
        *outQy = newest.qy;
        *outQz = newest.qz;
        *outQw = newest.qw;
        return true;
    }

    // Binary search for bracketing IMU samples [lo, hi]
    uint64_t lo = validStart;
    uint64_t hi = count - 1;
    while (lo + 1 < hi) {
        const uint64_t mid = lo + (hi - lo) / 2;
        ImuSamplePlain midSample;
        if (!readImuSlot(static_cast<uint32_t>(mid), &midSample)) {
            break;
        }
        if (midSample.timestamp <= targetTimestamp) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    ImuSamplePlain s0;
    ImuSamplePlain s1;
    if (!readImuSlot(static_cast<uint32_t>(lo), &s0) || !readImuSlot(static_cast<uint32_t>(hi), &s1)) {
        return false;
    }
    const double dt = s1.timestamp - s0.timestamp;
    if (dt <= 1e-6 || dt >= 0.10) {
        if (std::abs(targetTimestamp - s0.timestamp) <= 1e-6) {
            *outQx = s0.qx;
            *outQy = s0.qy;
            *outQz = s0.qz;
            *outQw = s0.qw;
            return true;
        }
        if (std::abs(targetTimestamp - s1.timestamp) <= 1e-6) {
            *outQx = s1.qx;
            *outQy = s1.qy;
            *outQz = s1.qz;
            *outQw = s1.qw;
            return true;
        }
        return false;
    }
    const double frac = (targetTimestamp - s0.timestamp) / dt;
    slerpQuat(s0, s1, frac, outQx, outQy, outQz, outQw);
    return true;
}

double ntc_imu_current_angular_speed(void) {
    const uint64_t count = gImuWriteCount.load(std::memory_order_acquire);
    if (count < 2) {
        return 0.0;
    }
    ImuSamplePlain s1;
    ImuSamplePlain s2;
    if (!readImuSlot(static_cast<uint32_t>(count - 1), &s1) ||
        !readImuSlot(static_cast<uint32_t>(count - 2), &s2)) {
        return 0.0;
    }
    const double dt = s1.timestamp - s2.timestamp;
    if (dt <= 1e-4 || dt >= 0.15) {
        return 0.0;
    }
    const double dot = std::max(-1.0, std::min(1.0, std::abs(
        s2.qx * s1.qx + s2.qy * s1.qy + s2.qz * s1.qz + s2.qw * s1.qw
    )));
    return (2.0 * std::acos(dot)) / dt;
}

double ntc_imu_angular_displacement_since(double pastTimestamp) {
    const uint64_t count = gImuWriteCount.load(std::memory_order_acquire);
    if (count == 0) {
        return 0.0;
    }
    ImuSamplePlain cur;
    if (!readImuSlot(static_cast<uint32_t>(count - 1), &cur)) {
        return 0.0;
    }
    double px = 0.0, py = 0.0, pz = 0.0, pw = 1.0;
    if (!ntc_imu_interpolate_pose(pastTimestamp, &px, &py, &pz, &pw)) {
        return 0.0;
    }
    const double dot = std::max(-1.0, std::min(1.0, std::abs(
        px * cur.qx + py * cur.qy + pz * cur.qz + pw * cur.qw
    )));
    return 2.0 * std::acos(dot);
}

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
) {
    if (!outX || !outY || !outZ) return;
    const double crossX = prevY * targetZ - prevZ * targetY;
    const double crossY = prevZ * targetX - prevX * targetZ;
    const double crossZ = prevX * targetY - prevY * targetX;
    const double crossLen = std::sqrt(crossX * crossX + crossY * crossY + crossZ * crossZ);
    const double dot = prevX * targetX + prevY * targetY + prevZ * targetZ;
    const double gapAngle = std::atan2(crossLen, dot);

    if (gapAngle <= 1e-9 || dt <= 1e-5) {
        *outX = targetX;
        *outY = targetY;
        *outZ = targetZ;
        return;
    }

    const double normalizedGap = gapAngle * focalScale;
    const double cutoffHz = 14.0 + std::min(85.0, normalizedGap * 120.0);
    const double alpha = 1.0 - std::exp(-2.0 * 3.14159265358979323846 * cutoffHz * dt);
    const double smoothStep = std::max(1e-7, gapAngle * std::max(0.32, std::min(1.0, alpha)));

    if (gapAngle <= smoothStep) {
        *outX = targetX;
        *outY = targetY;
        *outZ = targetZ;
        return;
    }

    const double frac = smoothStep / gapAngle;
    const double sinGap = std::sin(gapAngle);
    if (sinGap <= 1e-9) {
        *outX = targetX;
        *outY = targetY;
        *outZ = targetZ;
        return;
    }

    const double w0 = std::sin((1.0 - frac) * gapAngle) / sinGap;
    const double w1 = std::sin(frac * gapAngle) / sinGap;
    double rx = w0 * prevX + w1 * targetX;
    double ry = w0 * prevY + w1 * targetY;
    double rz = w0 * prevZ + w1 * targetZ;
    const double norm = std::sqrt(rx * rx + ry * ry + rz * rz);
    if (norm > 1e-12) {
        *outX = rx / norm;
        *outY = ry / norm;
        *outZ = rz / norm;
    } else {
        *outX = targetX;
        *outY = targetY;
        *outZ = targetZ;
    }
}

// ============================================================================
// Zero-Copy YUV420 / BGRA Photometrics & ROI Sharpness in C++ NEON
// ============================================================================

float ntc_measure_roi_sharpness(
    const uint8_t* lumaBase,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow,
    float normMinX,
    float normMinY,
    float normMaxX,
    float normMaxY
) {
    if (!lumaBase || width <= 8 || height <= 8 || bytesPerRow < width) {
        return 0.5f;
    }
    const int32_t x0 = std::max(2, std::min(width - 3, static_cast<int32_t>(normMinX * static_cast<float>(width))));
    const int32_t x1 = std::max(x0 + 2, std::min(width - 2, static_cast<int32_t>(normMaxX * static_cast<float>(width))));
    const int32_t y0 = std::max(2, std::min(height - 3, static_cast<int32_t>(normMinY * static_cast<float>(height))));
    const int32_t y1 = std::max(y0 + 2, std::min(height - 2, static_cast<int32_t>(normMaxY * static_cast<float>(height))));

    const int32_t stepX = std::max(1, (x1 - x0) / 32);
    const int32_t stepY = std::max(1, (y1 - y0) / 32);

    double energySum = 0.0;
    int32_t count = 0;

    for (int32_t y = y0; y < y1; y += stepY) {
        const uint8_t* rPrev = lumaBase + (y - 1) * bytesPerRow;
        const uint8_t* rCurr = lumaBase + y * bytesPerRow;
        const uint8_t* rNext = lumaBase + (y + 1) * bytesPerRow;
        for (int32_t x = x0; x < x1; x += stepX) {
            // Sobel Tenengrad gradient + 4-neighbor Laplacian
            const int32_t gx = (static_cast<int32_t>(rPrev[x + 1]) + 2 * static_cast<int32_t>(rCurr[x + 1]) + static_cast<int32_t>(rNext[x + 1])) -
                               (static_cast<int32_t>(rPrev[x - 1]) + 2 * static_cast<int32_t>(rCurr[x - 1]) + static_cast<int32_t>(rNext[x - 1]));
            const int32_t gy = (static_cast<int32_t>(rNext[x - 1]) + 2 * static_cast<int32_t>(rNext[x]) + static_cast<int32_t>(rNext[x + 1])) -
                               (static_cast<int32_t>(rPrev[x - 1]) + 2 * static_cast<int32_t>(rPrev[x]) + static_cast<int32_t>(rPrev[x + 1]));
            const int32_t lap = 4 * static_cast<int32_t>(rCurr[x]) -
                                static_cast<int32_t>(rCurr[x - 1]) -
                                static_cast<int32_t>(rCurr[x + 1]) -
                                static_cast<int32_t>(rPrev[x]) -
                                static_cast<int32_t>(rNext[x]);
            const double gradMag = std::sqrt(static_cast<double>(gx * gx + gy * gy)) * (1.0 / 1020.0);
            const double lapMag = static_cast<double>(std::abs(lap)) * (1.0 / 1020.0);
            energySum += 0.65 * gradMag + 0.35 * lapMag;
            ++count;
        }
    }

    if (count <= 0) return 0.5f;
    const double rawScore = (energySum / static_cast<double>(count)) * 4.5;
    return static_cast<float>(std::max(0.0, std::min(1.0, rawScore)));
}

float ntc_estimate_scene_luminance(
    const uint8_t* baseAddress,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow,
    bool isBiPlanar
) {
    if (!baseAddress || width <= 0 || height <= 0 || bytesPerRow <= 0) {
        return 0.5f;
    }
    const int32_t stepX = std::max(1, width / 16);
    const int32_t stepY = std::max(1, height / 16);
    float sum = 0.0f;
    int32_t count = 0;

    if (isBiPlanar) {
        for (int32_t y = stepY / 2; y < height; y += stepY) {
            const uint8_t* row = baseAddress + y * bytesPerRow;
            for (int32_t x = stepX / 2; x < width; x += stepX) {
                sum += static_cast<float>(row[x]) * (1.0f / 255.0f);
                ++count;
            }
        }
    } else {
        for (int32_t y = stepY / 2; y < height; y += stepY) {
            const uint8_t* row = baseAddress + y * bytesPerRow;
            for (int32_t x = stepX / 2; x < width; x += stepX) {
                const int32_t off = x * 4;
                const float b = static_cast<float>(row[off]) * (1.0f / 255.0f);
                const float g = static_cast<float>(row[off + 1]) * (1.0f / 255.0f);
                const float r = static_cast<float>(row[off + 2]) * (1.0f / 255.0f);
                sum += 0.299f * r + 0.587f * g + 0.114f * b;
                ++count;
            }
        }
    }
    return (count > 0) ? (sum / static_cast<float>(count)) : 0.5f;
}

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
) {
    if (!baseAddress || !outMetrics || width <= 0 || height <= 0 || bytesPerRow <= 0) {
        return false;
    }

    const int32_t startX = std::max(0, std::min(width - 1, static_cast<int32_t>(cropMinX * static_cast<float>(width))));
    const int32_t endX = std::max(startX + 1, std::min(width, static_cast<int32_t>(cropMaxX * static_cast<float>(width))));
    const int32_t startY = std::max(0, std::min(height - 1, static_cast<int32_t>(cropMinY * static_cast<float>(height))));
    const int32_t endY = std::max(startY + 1, std::min(height, static_cast<int32_t>(cropMaxY * static_cast<float>(height))));

    const int32_t stepX = std::max(1, (endX - startX) / 32);
    const int32_t stepY = std::max(1, (endY - startY) / 32);

    float totalSubjLuma = 0.0f;
    int32_t countSubj = 0;
    float totalBgLuma = 0.0f;
    int32_t countBg = 0;
    float totalOverall = 0.0f;
    int32_t countTotal = 0;
    int32_t countHighlight = 0;
    int32_t countShadow = 0;
    float maxLumaVal = 0.0f;

    const float invW = 1.0f / static_cast<float>(width);
    const float invH = 1.0f / static_cast<float>(height);

    for (int32_t y = startY; y < endY; y += stepY) {
        const uint8_t* row = baseAddress + y * bytesPerRow;
        const float normY = static_cast<float>(y) * invH;
        for (int32_t x = startX; x < endX; x += stepX) {
            float lum = 0.0f;
            if (isBiPlanar) {
                const float rawY = static_cast<float>(row[x]);
                if (isVideoRange) {
                    lum = std::min(1.0f, std::max(0.0f, (rawY - 16.0f) * (1.0f / 219.0f)));
                } else {
                    lum = rawY * (1.0f / 255.0f);
                }
            } else {
                const int32_t off = x * 4;
                const float b = static_cast<float>(row[off]);
                const float g = static_cast<float>(row[off + 1]);
                const float r = static_cast<float>(row[off + 2]);
                lum = (r * 0.2126f + g * 0.7152f + b * 0.0722f) * (1.0f / 255.0f);
            }

            totalOverall += lum;
            ++countTotal;
            if (lum > maxLumaVal) maxLumaVal = lum;
            if (lum >= 0.95f) ++countHighlight;
            if (lum <= 0.07f) ++countShadow;

            const float normX = static_cast<float>(x) * invW;
            if (hasSubjectRect &&
                normX >= subjMinX && normX <= subjMaxX &&
                normY >= subjMinY && normY <= subjMaxY) {
                totalSubjLuma += lum;
                ++countSubj;
            } else {
                totalBgLuma += lum;
                ++countBg;
            }
        }
    }

    if (countTotal <= 0) {
        return false;
    }

    const float overall = totalOverall / static_cast<float>(countTotal);
    outMetrics->overallLuma = overall;
    outMetrics->subjectLuma = (countSubj > 0) ? (totalSubjLuma / static_cast<float>(countSubj)) : overall;
    outMetrics->backgroundLuma = (countBg > 0) ? (totalBgLuma / static_cast<float>(countBg)) : overall;
    outMetrics->highlightClippingRatio = static_cast<float>(countHighlight) / static_cast<float>(countTotal);
    outMetrics->shadowRatio = static_cast<float>(countShadow) / static_cast<float>(countTotal);
    outMetrics->maxLuma = maxLumaVal;
    outMetrics->subjectSharpness = (isBiPlanar && hasSubjectRect)
        ? ntc_measure_roi_sharpness(baseAddress, width, height, bytesPerRow, subjMinX, subjMinY, subjMaxX, subjMaxY)
        : 0.5f;
    return true;
}

} // extern "C"
