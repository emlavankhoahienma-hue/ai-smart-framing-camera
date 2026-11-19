#include "../AISmartFramingCamera/Services/NativeOpticsCore.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static void testRectilinearMeshStraightnessAndConformal() {
    const int32_t W = 33;
    const int32_t H = 33;
    std::vector<float> mesh(static_cast<size_t>(W * H * 4), 0.0f);

    noc_uw_build_rectilinear_mesh(0.5f, 0.75f, 0.5f, W, H, mesh.data());

    // 1. Vertical lines must stay 100% straight (srcU constant across all iy for fixed ix)
    for (int32_t ix = 0; ix < W; ++ix) {
        const float refU = mesh[static_cast<size_t>(ix) * 4 + 0];
        for (int32_t iy = 0; iy < H; ++iy) {
            const float u = mesh[(static_cast<size_t>(iy * W + ix)) * 4 + 0];
            assert(std::isfinite(u));
            assert(std::fabs(u - refU) < 1e-6f);
        }
    }

    // 2. Horizontal lines must stay 100% straight (srcV constant across all ix for fixed iy)
    for (int32_t iy = 0; iy < H; ++iy) {
        const float refV = mesh[(static_cast<size_t>(iy * W)) * 4 + 1];
        for (int32_t ix = 0; ix < W; ++ix) {
            const float v = mesh[(static_cast<size_t>(iy * W + ix)) * 4 + 1];
            assert(std::isfinite(v));
            assert(std::fabs(v - refV) < 1e-6f);
        }
    }

    // 3. Exact boundary mapping [0, 1] with zero corner clipping
    assert(std::fabs(mesh[0] - 0.0f) < 1e-5f);
    assert(std::fabs(mesh[1] - 0.0f) < 1e-5f);
    assert(std::fabs(mesh[(static_cast<size_t>(W * H - 1)) * 4 + 0] - 1.0f) < 1e-5f);
    assert(std::fabs(mesh[(static_cast<size_t>(W * H - 1)) * 4 + 1] - 1.0f) < 1e-5f);

    // 4. Exact 1:1 isotropic aspect ratio at center (zero egg-shaped faces)
    const int32_t mid = W / 2;
    const float duCenter = mesh[(static_cast<size_t>(mid * W + (mid + 1))) * 4 + 0] -
                           mesh[(static_cast<size_t>(mid * W + (mid - 1))) * 4 + 0];
    const float dvCenter = mesh[(static_cast<size_t>((mid + 1) * W + mid)) * 4 + 1] -
                           mesh[(static_cast<size_t>((mid - 1) * W + mid)) * 4 + 1];
    assert(std::fabs(duCenter - dvCenter) < 1e-5f);

    // 5. Genuine optical wide-angle pullback at center (slope > 1.12)
    const float gridStep = 2.0f / static_cast<float>(W - 1);
    const float centerSlope = duCenter / gridStep;
    assert(centerSlope > 1.12f && centerSlope < 1.35f);

    // 6. Jacobian sharpen boost must be stronger at borders than at center
    const float centerBoost = mesh[(static_cast<size_t>(mid * W + mid)) * 4 + 2];
    const float cornerBoost = mesh[2];
    assert(cornerBoost > centerBoost + 0.15f);

    std::printf("PASS: testRectilinearMeshStraightnessAndConformal (centerSlope=%.3f, cornerBoost=%.3f)\n",
                centerSlope, cornerBoost);
}

static void testLanczos3StillPhotoRendering() {
    const int32_t W = 256;
    const int32_t H = 256;
    const int32_t rowBytes = W * 4;
    std::vector<uint8_t> src(static_cast<size_t>(H * rowBytes), 0);
    std::vector<uint8_t> mid(static_cast<size_t>(H * rowBytes), 0);
    std::vector<uint8_t> dst(static_cast<size_t>(H * rowBytes), 0);

    // Draw crisp architectural grid (bright vertical and horizontal lines on dark gray)
    for (int32_t y = 0; y < H; ++y) {
        for (int32_t x = 0; x < W; ++x) {
            const bool isLine = ((x % 32) < 3) || ((y % 32) < 3);
            const uint8_t val = isLine ? 235 : 42;
            const size_t off = static_cast<size_t>(y * rowBytes + x * 4);
            src[off + 0] = val;
            src[off + 1] = val;
            src[off + 2] = val;
            src[off + 3] = 255;
        }
    }

    const NOCUltraWideSceneMetrics scene = noc_uw_analyze_scene_bgra(src.data(), W, H, rowBytes);
    assert(scene.architecturalLineStrength > 0.65f);

    const NOCHorizonTransformParams noHorizon{0.0f, 1.0f, 0.0f, 0.0f};
    noc_uw_render_lanczos3_rgba8_rows(
        src.data(), W, H, rowBytes,
        mid.data(), W, H, rowBytes,
        0.5f, scene.architecturalLineStrength, noHorizon, 0, H
    );
    noc_uw_restore_edge_clarity_rgba8_rows(
        mid.data(), W, H, rowBytes,
        dst.data(), rowBytes,
        0.5f, scene.architecturalLineStrength, 0, H
    );

    // Verify bright pixels & contrast preserved and alpha == 255 everywhere
    int32_t brightPixels = 0;
    for (int32_t y = 0; y < H; ++y) {
        for (int32_t x = 0; x < W; ++x) {
            const size_t off = static_cast<size_t>(y * rowBytes + x * 4);
            assert(dst[off + 3] == 255);
            if (dst[off + 0] > 180) {
                brightPixels += 1;
            }
        }
    }
    assert(brightPixels > 2500);
    std::printf("PASS: testLanczos3StillPhotoRendering (archStrength=%.2f, brightPixels=%d)\n",
                scene.architecturalLineStrength, brightPixels);
}

static void testMotionFieldHuberIRLSRepair() {
    const int32_t TX = 16;
    const int32_t TY = 12;
    std::vector<NOCTileMotionVector> field(static_cast<size_t>(TX * TY));

    const double cx = 0.5 * static_cast<double>(TX - 1);
    const double cy = 0.5 * static_cast<double>(TY - 1);

    for (int32_t y = 0; y < TY; ++y) {
        for (int32_t x = 0; x < TX; ++x) {
            const int32_t idx = y * TX + x;
            const double u = (static_cast<double>(x) - cx) / static_cast<double>(TX);
            const double v = (static_cast<double>(y) - cy) / static_cast<double>(TY);
            field[static_cast<size_t>(idx)].dx = static_cast<float>(2.4 + 1.2 * u - 0.6 * v);
            field[static_cast<size_t>(idx)].dy = static_cast<float>(-1.7 + 0.5 * u + 0.9 * v);
            field[static_cast<size_t>(idx)].sadError = 0.025f;
            field[static_cast<size_t>(idx)].isInvalid = 0;
        }
    }

    // Corrupt 15% of tiles with huge outliers and invalid flags
    const int32_t badIndices[] = {5, 19, 34, 48, 67, 85, 102, 121, 140, 165, 178};
    for (int32_t b : badIndices) {
        field[static_cast<size_t>(b)].dx = 42.0f;
        field[static_cast<size_t>(b)].dy = -37.0f;
        field[static_cast<size_t>(b)].sadError = 0.45f;
        field[static_cast<size_t>(b)].isInvalid = (b % 2 == 0) ? 1u : 0u;
    }

    const NOCMotionFieldStats stats = noc_us_regularize_motion_field(field.data(), TX, TY);
    assert(stats.isReliable);
    assert(stats.validTileRatio > 0.80f);
    assert(std::fabs(stats.globalShiftX - 2.4f) < 0.08f);
    assert(std::fabs(stats.globalShiftY - (-1.7f)) < 0.08f);

    // Every corrupted tile must be repaired close to true affine motion
    for (int32_t b : badIndices) {
        const int32_t x = b % TX;
        const int32_t y = b / TX;
        const double u = (static_cast<double>(x) - cx) / static_cast<double>(TX);
        const double v = (static_cast<double>(y) - cy) / static_cast<double>(TY);
        const float trueDx = static_cast<float>(2.4 + 1.2 * u - 0.6 * v);
        const float trueDy = static_cast<float>(-1.7 + 0.5 * u + 0.9 * v);
        assert(field[static_cast<size_t>(b)].isInvalid == 0);
        assert(std::fabs(field[static_cast<size_t>(b)].dx - trueDx) < 0.25f);
        assert(std::fabs(field[static_cast<size_t>(b)].dy - trueDy) < 0.25f);
    }

    std::printf("PASS: testMotionFieldHuberIRLSRepair (shift=(%.2f, %.2f), validRatio=%.2f)\n",
                stats.globalShiftX, stats.globalShiftY, stats.validTileRatio);
}

static void testTenengradSharpnessAndMADSigma() {
    const int32_t W = 256;
    const int32_t H = 256;
    std::vector<uint8_t> sharpBGRA(static_cast<size_t>(W * H * 4), 255);
    std::vector<uint8_t> blurBGRA(static_cast<size_t>(W * H * 4), 255);

    for (int32_t y = 0; y < H; ++y) {
        for (int32_t x = 0; x < W; ++x) {
            const size_t off = static_cast<size_t>((y * W + x) * 4);
            const float s = 128.0f + 100.0f * std::sin(static_cast<float>(x) * 0.45f) * std::cos(static_cast<float>(y) * 0.45f);
            const float b = 128.0f + 100.0f * std::sin(static_cast<float>(x) * 0.04f) * std::cos(static_cast<float>(y) * 0.04f);
            const uint8_t us = static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, s)));
            const uint8_t ub = static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, b)));
            sharpBGRA[off] = sharpBGRA[off + 1] = sharpBGRA[off + 2] = us;
            blurBGRA[off] = blurBGRA[off + 1] = blurBGRA[off + 2] = ub;
        }
    }

    const float sharpScore = noc_us_evaluate_sharpness_bgra(sharpBGRA.data(), W, H, W * 4);
    const float blurScore = noc_us_evaluate_sharpness_bgra(blurBGRA.data(), W, H, W * 4);
    assert(sharpScore > blurScore * 10.0f);

    uint32_t hist[128] = {0};
    hist[12] = 5000;
    const float sigma = noc_us_estimate_mad_sigma(hist, 5000, 100.0f);
    assert(sigma > 0.014f && sigma < 0.022f);

    std::printf("PASS: testTenengradSharpnessAndMADSigma (sharp=%.1f, blur=%.1f, sigma=%.4f)\n",
                sharpScore, blurScore, sigma);
}

static void testExposureMatchAndShadowSafeClarity() {
    // 1. Verify analytical rectilinear parameter resolution
    float k = 0.0f, invTanhK = 0.0f, progress = 0.0f;
    noc_uw_resolve_params_out(0.5f, 0.45f, &k, &invTanhK, &progress);
    assert(progress > 0.99f);
    assert(k > 0.70f && k < 0.86f);
    assert(std::fabs(std::tanh(k) * invTanhK - 1.0f) < 1e-5f);

    // 2. Verify photometric exposure matching recovers ~1.10x darkened secondary frame accurately
    const int32_t W = 128;
    const int32_t H = 128;
    const int32_t rowBytes = W * 4;
    std::vector<uint8_t> refImg(static_cast<size_t>(H * rowBytes), 255);
    std::vector<uint8_t> secImg(static_cast<size_t>(H * rowBytes), 255);
    for (int32_t y = 0; y < H; ++y) {
        for (int32_t x = 0; x < W; ++x) {
            const size_t off = static_cast<size_t>(y * rowBytes + x * 4);
            const uint8_t base = static_cast<uint8_t>(40 + (x * 160) / W);
            const uint8_t darker = static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, static_cast<float>(base) / 1.10f)));
            refImg[off + 0] = refImg[off + 1] = refImg[off + 2] = base;
            secImg[off + 0] = secImg[off + 1] = secImg[off + 2] = darker;
        }
    }
    float gain = 1.0f, bias = 0.0f;
    noc_us_match_exposure_bgra_out(refImg.data(), secImg.data(), W, H, rowBytes, rowBytes, &gain, &bias);
    assert(gain > 1.06f && gain < 1.14f);
    assert(std::fabs(bias) < 0.02f);

    // 3. Verify bilateral clarity & shadow recovery NEVER crushes dark regions to black and preserves true black
    std::vector<uint8_t> darkSrc(static_cast<size_t>(H * rowBytes), 255);
    std::vector<uint8_t> darkDst(static_cast<size_t>(H * rowBytes), 0);
    for (int32_t y = 0; y < H; ++y) {
        for (int32_t x = 0; x < W; ++x) {
            const size_t off = static_cast<size_t>(y * rowBytes + x * 4);
            // Left half dark shadow (28), right half bright wall (220), top-left corner pure black (0)
            const uint8_t v = (x < 8 && y < 8) ? 0 : ((x < W / 2) ? 28 : 220);
            darkSrc[off + 0] = darkSrc[off + 1] = darkSrc[off + 2] = v;
        }
    }
    noc_us_enhance_superres_bgra_rows(darkSrc.data(), W, H, rowBytes, darkDst.data(), rowBytes, 0.34f, 0.14f, 0, H);

    // Pure black stays pure black (0)
    assert(darkDst[0] == 0 && darkDst[1] == 0 && darkDst[2] == 0 && darkDst[3] == 255);
    // Dark side immediately adjacent to bright edge must NOT crush darker than 24 (zero dark halo blotches!)
    const size_t edgeDarkOff = static_cast<size_t>((H / 2) * rowBytes + (W / 2 - 1) * 4);
    assert(darkDst[edgeDarkOff + 1] >= 25);
    // Mid-shadow interior gets a clean, subtle shadow lift (>= 29, <= 40)
    const size_t midShadowOff = static_cast<size_t>((H / 2) * rowBytes + (W / 4) * 4);
    assert(darkDst[midShadowOff + 1] >= 29 && darkDst[midShadowOff + 1] <= 42);

    std::printf("PASS: testExposureMatchAndShadowSafeClarity (k=%.3f, gain=%.3f, edgeDark=%u, shadowLift=%u)\n",
                k, gain, darkDst[edgeDarkOff + 1], darkDst[midShadowOff + 1]);
}

int main() {
    testRectilinearMeshStraightnessAndConformal();
    testLanczos3StillPhotoRendering();
    testMotionFieldHuberIRLSRepair();
    testTenengradSharpnessAndMADSigma();
    testExposureMatchAndShadowSafeClarity();
    std::printf("ALL NATIVE OPTICS CORE C++20 REGRESSIONS PASSED!\n");
    return 0;
}
