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

    uint8_t desc0[32];
    uint8_t desc1[32];
    uint8_t descUnrelated[32];
    ntc_compute_orb_descriptor(img0.data(), w, h, 80.0f, 60.0f, desc0);
    ntc_compute_orb_descriptor(img1.data(), w, h, static_cast<float>(80.0 + trueDx), static_cast<float>(60.0 + trueDy), desc1);
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
        img0.data(), w, h, 80.0f, 60.0f,
        img1.data(), w, h, 80.0f, 60.0f,
        10, true, &bestX, &bestY, &bestScore
    );
    EXPECT_TRUE(matched);
    EXPECT_TRUE(bestScore > 0.92);
    EXPECT_NEAR(bestX, 80.0 + trueDx, 0.22);
    EXPECT_NEAR(bestY, 60.0 + trueDy, 0.22);
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

} // namespace

int main() {
    testDownsamplingAndCorners();
    testOrbAndZnccSubpixel();
    testConstellationFlowAndPyramidalICLK();
    testWaitFreeImuRingAndS2Geodesic();
    testPhotometricsAndSharpness();

    if (gFailures == 0) {
        std::printf("NativeTrackingCoreRegression: ALL TESTS PASSED\n");
        return 0;
    }
    std::fprintf(stderr, "NativeTrackingCoreRegression: %d FAILURES\n", gFailures);
    return 1;
}
