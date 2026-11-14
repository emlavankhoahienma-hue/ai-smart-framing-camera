#include "../AISmartFramingCamera/Services/NativeTrackingCore.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

static int gFailures = 0;

static void check(bool condition, const char* expr, int line) {
    if (!condition) {
        std::fprintf(stderr, "[FAIL] Line %d: %s\n", line, expr);
        ++gFailures;
    }
}

#define EXPECT_TRUE(cond) check((cond), #cond, __LINE__)
#define EXPECT_NEAR(a, b, tol) check(std::fabs(static_cast<double>(a) - static_cast<double>(b)) <= (tol), #a " ~= " #b, __LINE__)

// Generate a deterministic rich multi-frequency textured image with a localized foreground object
static void renderTexturedScene(
    uint8_t* img,
    int32_t w,
    int32_t h,
    double shiftX,
    double shiftY
) {
    for (int32_t y = 0; y < h; ++y) {
        for (int32_t x = 0; x < w; ++x) {
            const double sx = static_cast<double>(x) - shiftX;
            const double sy = static_cast<double>(y) - shiftY;
            const double v1 = std::sin(sx * 0.31 + sy * 0.17) * std::cos(sx * 0.19 - sy * 0.29);
            const double v2 = std::sin(sx * 0.73 - sy * 0.41) * std::sin(sx * 0.23 + sy * 0.67);
            const double v3 = std::cos(sx * 0.13 + sy * 0.53);
            const double val = 128.0 + 62.0 * v1 + 38.0 * v2 + 22.0 * v3;
            const int32_t clamped = std::max(0, std::min(255, static_cast<int32_t>(std::lround(val))));
            img[y * w + x] = static_cast<uint8_t>(clamped);
        }
    }
}

static void testDownsamplingAndCorners() {
    const int32_t srcW = 320;
    const int32_t srcH = 240;
    const int32_t dstW = 160;
    const int32_t dstH = 120;

    std::vector<uint8_t> luma(static_cast<size_t>(srcW * srcH), 0);
    renderTexturedScene(luma.data(), srcW, srcH, 0.0, 0.0);

    std::vector<uint8_t> bgra(static_cast<size_t>(srcW * srcH * 4), 255);
    for (int32_t i = 0; i < srcW * srcH; ++i) {
        const uint8_t v = luma[static_cast<size_t>(i)];
        bgra[static_cast<size_t>(i * 4 + 0)] = v;
        bgra[static_cast<size_t>(i * 4 + 1)] = v;
        bgra[static_cast<size_t>(i * 4 + 2)] = v;
        bgra[static_cast<size_t>(i * 4 + 3)] = 255;
    }

    std::vector<uint8_t> grayFromLuma(static_cast<size_t>(dstW * dstH), 0);
    std::vector<uint8_t> grayFromBgra(static_cast<size_t>(dstW * dstH), 0);

    ntc_downsample_luma_to_gray(luma.data(), srcW, srcH, srcW, grayFromLuma.data(), dstW, dstH);
    ntc_downsample_bgra_to_gray(bgra.data(), srcW, srcH, srcW * 4, grayFromBgra.data(), dstW, dstH);

    double maxDiff = 0.0;
    for (size_t i = 0; i < grayFromLuma.size(); ++i) {
        const double d = std::fabs(static_cast<double>(grayFromLuma[i]) - static_cast<double>(grayFromBgra[i]));
        if (d > maxDiff) maxDiff = d;
    }
    EXPECT_TRUE(maxDiff <= 1.0);

    float cornersXY[32] = {0.0f};
    const int32_t count = ntc_extract_roi_corners(
        grayFromLuma.data(), dstW, dstH,
        24, dstW - 24, 20, dstH - 20,
        cornersXY, 16
    );
    EXPECT_TRUE(count >= 12);

    // Flat image must yield 0 corners
    std::vector<uint8_t> flat(static_cast<size_t>(dstW * dstH), 120);
    const int32_t flatCount = ntc_extract_roi_corners(
        flat.data(), dstW, dstH,
        24, dstW - 24, 20, dstH - 20,
        cornersXY, 16
    );
    EXPECT_TRUE(flatCount == 0);
}

static void testOrbAndZnccSubpixel() {
    const int32_t w = 160;
    const int32_t h = 120;
    std::vector<uint8_t> img0(static_cast<size_t>(w * h), 0);
    std::vector<uint8_t> img1(static_cast<size_t>(w * h), 0);

    const double trueDx = 3.35;
    const double trueDy = -2.40;
    renderTexturedScene(img0.data(), w, h, 0.0, 0.0);
    renderTexturedScene(img1.data(), w, h, trueDx, trueDy);

    const float cornerX = 82.0f;
    const float cornerY = 78.0f;
    uint8_t desc0[32];
    uint8_t desc1[32];
    uint8_t descUnrelated[32];
    ntc_compute_orb_descriptor(img0.data(), w, h, cornerX, cornerY, desc0);
    ntc_compute_orb_descriptor(img1.data(), w, h, static_cast<float>(cornerX + trueDx), static_cast<float>(cornerY + trueDy), desc1);
    ntc_compute_orb_descriptor(img1.data(), w, h, 25.0f, 25.0f, descUnrelated);

    EXPECT_TRUE(ntc_orb_hamming_distance(desc0, desc0) == 0);
    const int32_t distSameFeature = ntc_orb_hamming_distance(desc0, desc1);
    const int32_t distOtherFeature = ntc_orb_hamming_distance(desc0, descUnrelated);
    EXPECT_TRUE(distSameFeature < 48);
    EXPECT_TRUE(distOtherFeature > distSameFeature);

    float bestX = 0.0f;
    float bestY = 0.0f;
    double bestScore = 0.0;
    const bool matched = ntc_match_patch_zncc(
        img0.data(), w, h, cornerX, cornerY,
        img1.data(), w, h, cornerX, cornerY,
        10, true, &bestX, &bestY, &bestScore
    );
    EXPECT_TRUE(matched);
    EXPECT_TRUE(bestScore > 0.92);
    EXPECT_NEAR(bestX, static_cast<double>(cornerX) + trueDx, 0.22);
    EXPECT_NEAR(bestY, static_cast<double>(cornerY) + trueDy, 0.22);
}

static void testConstellationFlowAndPyramidalICLK() {
    const int32_t w = 160;
    const int32_t h = 120;
    std::vector<uint8_t> prevImg(static_cast<size_t>(w * h), 0);
    std::vector<uint8_t> currImg(static_cast<size_t>(w * h), 0);

    const double shiftX = 5.25;
    const double shiftY = -3.65;
    renderTexturedScene(prevImg.data(), w, h, 0.0, 0.0);
    renderTexturedScene(currImg.data(), w, h, shiftX, shiftY);

    float pointsXY[32] = {0.0f};
    const int32_t numPts = ntc_extract_roi_corners(
        prevImg.data(), w, h,
        40, 120, 30, 90,
        pointsXY, 16
    );
    EXPECT_TRUE(numPts >= 10);

    // Inject 2 corrupted outlier points to verify Huber IRLS + median consensus rejection
    if (numPts >= 10) {
        pointsXY[0] = 8.0f;
        pointsXY[1] = 8.0f;
    }

    float survivingXY[32] = {0.0f};
    const double anchorX = 0.50;
    const double anchorY = 0.50;
    const NTCPatchFlowResult res = ntc_evaluate_constellation_flow(
        prevImg.data(), currImg.data(),
        w, h,
        pointsXY, numPts,
        0.0, 0.0,
        0.50, 0.50,
        0.20, 0.20, 0.80, 0.80,
        anchorX, anchorY,
        survivingXY, 16
    );

    EXPECT_TRUE(res.isReliable);
    EXPECT_TRUE(res.inliers >= 6);
    EXPECT_NEAR(res.anchorNormX, anchorX + shiftX / static_cast<double>(w), 0.004);
    EXPECT_NEAR(res.anchorNormY, anchorY + shiftY / static_cast<double>(h), 0.004);
}

static void testWaitFreeImuRingAndS2Geodesic() {
    ntc_imu_reset();
    // Simulate 200Hz IMU samples rotating around Y axis at 1.0 rad/s
    const double omega = 1.0;
    for (int32_t i = 0; i <= 40; ++i) {
        const double t = 10.0 + static_cast<double>(i) * 0.005;
        const double halfTheta = 0.5 * omega * (t - 10.0);
        ntc_imu_push_sample(t, 0.0, std::sin(halfTheta), 0.0, std::cos(halfTheta));
    }

    double qx = 0.0, qy = 0.0, qz = 0.0, qw = 1.0;
    const double queryT = 10.1025; // halfway between sample 20 (10.100) and sample 21 (10.105)
    const bool ok = ntc_imu_interpolate_pose(queryT, &qx, &qy, &qz, &qw);
    EXPECT_TRUE(ok);
    const double expectedHalf = 0.5 * omega * (queryT - 10.0);
    EXPECT_NEAR(qy, std::sin(expectedHalf), 1e-5);
    EXPECT_NEAR(qw, std::cos(expectedHalf), 1e-5);

    const double speed = ntc_imu_current_angular_speed();
    EXPECT_NEAR(speed, omega, 1e-3);

    const double disp = ntc_imu_angular_displacement_since(10.100);
    EXPECT_NEAR(disp, omega * 0.100, 1e-3);

    // Test S^2 1-Euro SLERP
    double sx = 0.0, sy = 0.0, sz = -1.0;
    const double targetAngle = 0.05;
    const double tx = std::sin(targetAngle);
    const double ty = 0.0;
    const double tz = -std::cos(targetAngle);
    for (int32_t step = 0; step < 25; ++step) {
        double nx = 0.0, ny = 0.0, nz = -1.0;
        ntc_s2_1euro_slerp(sx, sy, sz, tx, ty, tz, 0.80, 0.005, &nx, &ny, &nz);
        sx = nx;
        sy = ny;
        sz = nz;
    }
    EXPECT_NEAR(sx, tx, 1e-4);
    EXPECT_NEAR(sz, tz, 1e-4);
}

static void testPhotometricsAndSharpness() {
    const int32_t w = 128;
    const int32_t h = 128;
    std::vector<uint8_t> sharpImg(static_cast<size_t>(w * h), 0);
    std::vector<uint8_t> flatImg(static_cast<size_t>(w * h), 128);
    renderTexturedScene(sharpImg.data(), w, h, 0.0, 0.0);

    const float sharpScore = ntc_measure_roi_sharpness(sharpImg.data(), w, h, w, 0.2f, 0.2f, 0.8f, 0.8f);
    const float flatScore = ntc_measure_roi_sharpness(flatImg.data(), w, h, w, 0.2f, 0.2f, 0.8f, 0.8f);
    EXPECT_TRUE(sharpScore > 0.35f);
    EXPECT_TRUE(flatScore < 0.02f);

    NTCSceneLumaMetrics metrics = {};
    const bool ok = ntc_analyze_scene_luma(
        sharpImg.data(), w, h, w,
        true, false,
        0.0f, 0.0f, 1.0f, 1.0f,
        true, 0.25f, 0.25f, 0.75f, 0.75f,
        &metrics
    );
    EXPECT_TRUE(ok);
    EXPECT_NEAR(metrics.overallLuma, 0.50, 0.08);
    EXPECT_TRUE(metrics.subjectSharpness > 0.35f);
}

static void renderLocalizedSubjectScene(
    uint8_t* img,
    int32_t w,
    int32_t h,
    double subjShiftX,
    double subjShiftY,
    double bgShiftX,
    double bgShiftY
) {
    for (int32_t y = 0; y < h; ++y) {
        for (int32_t x = 0; x < w; ++x) {
            const double sx = static_cast<double>(x) - subjShiftX;
            const double sy = static_cast<double>(y) - subjShiftY;
            const bool inSubj = (sx >= 58.0 && sx <= 98.0 && sy >= 38.0 && sy <= 82.0);
            double val = 0.0;
            if (inSubj) {
                const double edge = 45.0 * std::exp(-0.15 * (sx - 60.0));
                const double t1 = std::sin(sx * 0.41 + sy * 0.23) * std::cos(sx * 0.29 - sy * 0.37);
                const double t2 = std::sin(sx * 0.83 - sy * 0.51);
                val = 140.0 + edge + 42.0 * t1 + 25.0 * t2;
            } else {
                const double bx = static_cast<double>(x) - bgShiftX;
                const double by = static_cast<double>(y) - bgShiftY;
                val = 70.0 + 18.0 * std::sin(bx * 0.15) * std::cos(by * 0.15);
            }
            const int32_t v = std::max(0, std::min(255, static_cast<int32_t>(std::lround(val))));
            img[y * w + x] = static_cast<uint8_t>(v);
        }
    }
}

static void testMultiFrameZeroDriftAndT0Anchoring() {
    const int32_t w = 160;
    const int32_t h = 120;
    std::vector<uint8_t> seedImg(static_cast<size_t>(w * h), 0);
    std::vector<uint8_t> prevImg(static_cast<size_t>(w * h), 0);
    std::vector<uint8_t> currImg(static_cast<size_t>(w * h), 0);

    // 1. 90-frame static stability test on asymmetric subject edges with sensor noise
    renderLocalizedSubjectScene(seedImg.data(), w, h, 0.0, 0.0, 0.0, 0.0);
    prevImg = seedImg;
    double anchorX = 0.50;
    double anchorY = 0.50;
    float seedPts[32] = {0.0f};
    const int32_t seedNumPts = ntc_extract_roi_corners(seedImg.data(), w, h, 50, 110, 30, 90, seedPts, 16);
    EXPECT_TRUE(seedNumPts >= 8);

    float pts[32] = {0.0f};
    std::memcpy(pts, seedPts, sizeof(pts));
    int32_t numPts = seedNumPts;
    uint32_t rng = 123456789U;

    for (int32_t f = 1; f <= 90; ++f) {
        renderLocalizedSubjectScene(currImg.data(), w, h, 0.0, 0.0, 0.0, 0.0);
        for (int32_t i = 0; i < w * h; ++i) {
            rng = rng * 1664525U + 1013904223U;
            const int32_t noise = static_cast<int32_t>((rng >> 28U) & 3U) - 1;
            currImg[static_cast<size_t>(i)] = static_cast<uint8_t>(
                std::max(0, std::min(255, static_cast<int32_t>(currImg[static_cast<size_t>(i)]) + noise))
            );
        }
        float surv[32] = {0.0f};
        const NTCPatchFlowResult res = ntc_evaluate_constellation_flow(
            prevImg.data(), currImg.data(), w, h,
            pts, numPts,
            0.0, 0.0,
            0.375, 0.375,
            0.31, 0.25, 0.69, 0.75,
            anchorX, anchorY,
            surv, 16
        );
        EXPECT_TRUE(res.isReliable);
        anchorX = res.anchorNormX;
        anchorY = res.anchorNormY;
        prevImg = currImg;
        numPts = ntc_extract_roi_corners(prevImg.data(), w, h, 50, 110, 30, 90, pts, 16);
    }
    const double staticDriftPxX = (anchorX - 0.50) * static_cast<double>(w);
    const double staticDriftPxY = (anchorY - 0.50) * static_cast<double>(h);
    EXPECT_TRUE(std::hypot(staticDriftPxX, staticDriftPxY) < 0.15);

    // 2. 120-frame continuous sub-pixel pan-and-return with T0 seed constellation anchoring
    prevImg = seedImg;
    anchorX = 0.50;
    anchorY = 0.50;
    std::memcpy(pts, seedPts, sizeof(pts));
    numPts = seedNumPts;
    double prevShiftX = 0.0;
    double prevShiftY = 0.0;

    for (int32_t f = 1; f <= 120; ++f) {
        const double sx = 12.0 * std::sin(2.0 * 3.14159265358979323846 * static_cast<double>(f) / 60.0);
        const double sy = 6.0 * std::sin(2.0 * 3.14159265358979323846 * static_cast<double>(f) / 60.0);
        renderLocalizedSubjectScene(currImg.data(), w, h, sx, sy, sx * 1.25, sy * 1.25);
        const double dShiftX = sx - prevShiftX;
        const double dShiftY = sy - prevShiftY;
        const double boxMinX = (50.0 + sx) / static_cast<double>(w);
        const double boxMaxX = (110.0 + sx) / static_cast<double>(w);
        const double boxMinY = 1.0 - (90.0 + sy) / static_cast<double>(h);
        const double boxMaxY = 1.0 - (30.0 + sy) / static_cast<double>(h);
        float surv[32] = {0.0f};
        const NTCPatchFlowResult res = ntc_evaluate_constellation_flow(
            prevImg.data(), currImg.data(), w, h,
            pts, numPts,
            dShiftX * 0.85, dShiftY * 0.85,
            0.375, 0.375,
            boxMinX, boxMinY, boxMaxX, boxMaxY,
            anchorX, anchorY,
            surv, 16
        );
        EXPECT_TRUE(res.isReliable);
        double newAnchorX = res.anchorNormX;
        double newAnchorY = res.anchorNormY;

        const double totalCoarseX = (newAnchorX - 0.50) * static_cast<double>(w);
        const double totalCoarseY = (newAnchorY - 0.50) * static_cast<double>(h);
        float seedSurv[32] = {0.0f};
        const NTCPatchFlowResult seedRes = ntc_evaluate_constellation_flow(
            seedImg.data(), currImg.data(), w, h,
            seedPts, seedNumPts,
            totalCoarseX, totalCoarseY,
            0.375, 0.375,
            boxMinX, boxMinY, boxMaxX, boxMaxY,
            0.50, 0.50,
            seedSurv, 16
        );
        if (seedRes.isReliable && seedRes.inliers >= 6) {
            const double alpha = (seedRes.inliers >= 8) ? 0.80 : 0.50;
            newAnchorX = (1.0 - alpha) * newAnchorX + alpha * seedRes.anchorNormX;
            newAnchorY = (1.0 - alpha) * newAnchorY + alpha * seedRes.anchorNormY;
        }
        anchorX = newAnchorX;
        anchorY = newAnchorY;
        prevImg = currImg;
        prevShiftX = sx;
        prevShiftY = sy;
        const int32_t left = std::max(4, static_cast<int32_t>((boxMinX + 0.12 * (boxMaxX - boxMinX)) * w));
        const int32_t right = std::min(w - 5, static_cast<int32_t>((boxMaxX - 0.12 * (boxMaxX - boxMinX)) * w));
        const int32_t top = std::max(4, static_cast<int32_t>((1.0 - boxMaxY + 0.12 * (boxMaxY - boxMinY)) * h));
        const int32_t bottom = std::min(h - 5, static_cast<int32_t>((1.0 - boxMinY - 0.12 * (boxMaxY - boxMinY)) * h));
        numPts = ntc_extract_roi_corners(prevImg.data(), w, h, left, right, top, bottom, pts, 16);
    }
    const double panReturnDriftPxX = (anchorX - 0.50) * static_cast<double>(w);
    const double panReturnDriftPxY = (anchorY - 0.50) * static_cast<double>(h);
    EXPECT_TRUE(std::hypot(panReturnDriftPxX, panReturnDriftPxY) < 0.45);
}

} // namespace

int main() {
    testDownsamplingAndCorners();
    testOrbAndZnccSubpixel();
    testConstellationFlowAndPyramidalICLK();
    testWaitFreeImuRingAndS2Geodesic();
    testPhotometricsAndSharpness();
    testMultiFrameZeroDriftAndT0Anchoring();

    if (gFailures == 0) {
        std::printf("NativeTrackingCoreRegression: ALL TESTS PASSED\n");
        return 0;
    }
    std::fprintf(stderr, "NativeTrackingCoreRegression: %d FAILURES\n", gFailures);
    return 1;
}
