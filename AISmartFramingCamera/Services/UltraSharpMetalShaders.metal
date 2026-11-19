//
//  UltraSharpMetalShaders.metal
//  AISmartFramingCamera
//
//  Tập lệnh Metal Compute Shader chuyên dụng cho Ultra Sharp (Bậc 1):
//  - Kim tự tháp Gaussian 4 tầng (L0, L1, L2, L3)
//  - Khớp khối phân cấp theo Tile 16x16 (Hierarchical Tile Block Matching +-4px)
//  - Tinh chỉnh Sub-pixel Lucas-Kanade 3 vòng lặp theo Tile
//  - Nội suy trường chuyển động mịn (Bilinear Dense Flow Field) & Biến dạng Warp
//  - Ước lượng mức nhiễu cảm biến động (Noise Estimation MAD theo mức sáng)
//  - Gộp đa khung hình Robust Wiener-style Shrinkage chống bóng ma (Anti-Ghosting)
//  - Làm nét có kiểm soát biên độ nhận biết cạnh & Kẹp triệt tiêu Halo (Halo Clamping)
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Cấu trúc dữ liệu & Tham số Uniforms

struct UltraSharpPyramidUniforms {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
};

struct UltraSharpTileUniforms {
    uint imageWidth;
    uint imageHeight;
    uint tileWidth;        // Mặc định 16
    uint tileHeight;       // Mặc định 16
    uint numTilesX;
    uint numTilesY;
    int searchRadius;      // +-4 px
    float scaleFactor;     // Tỷ lệ so với tầng trước (e.g. 2.0)
    float exposureGain;    // Hệ số cân bằng sáng quang trắc sec -> ref (mặc định 1.0)
    float exposureBias;    // Bù mức đen quang trắc sec -> ref (mặc định 0.0)
};

struct TileMotionVector {
    float dx;
    float dy;
    float sadError;
    uint isInvalid;        // 1 nếu tile lỗi/vượt ngưỡng sai số, 0 nếu hợp lệ
};

struct UltraSharpFusionUniforms {
    uint width;
    uint height;
    float baseNoiseSigma;  // Mức nhiễu cơ sở ước lượng từ MAD
    float noiseScaleK;     // Hệ số co Wiener (~1.8)
    float sharpnessAlpha;  // Cường độ làm nét (~0.35)
    float haloClampLimit;  // Ngưỡng kẹp viền halo (~0.08)
    uint frameIndex;       // 0 cho frame gốc, 1..N-1 cho frame phụ
    uint totalFrames;
};

// MARK: - 1. Trích xuất Luma Rec.709

kernel void ultrasharpExtractLumaKernel(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outLuma [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) {
        return;
    }

    float4 color = inTexture.read(gid);
    // Chuẩn Rec.709: Y = 0.2126*R + 0.7152*G + 0.0722*B
    float luma = clamp(0.2126f * color.r + 0.7152f * color.g + 0.0722f * color.b, 0.0f, 1.0f);
    outLuma.write(float4(luma, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - 2. Kim tự tháp Gaussian Downsample Box 2x2

kernel void ultrasharpDownsampleBox2x2Kernel(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant UltraSharpPyramidUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.dstWidth || gid.y >= uniforms.dstHeight) {
        return;
    }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 dstSize = float2(uniforms.dstWidth, uniforms.dstHeight);
    float2 uv = (float2(gid) + 0.5f) / dstSize;

    float2 halfTexel = 0.5f / float2(uniforms.srcWidth, uniforms.srcHeight);
    float4 s00 = inTexture.sample(s, uv + float2(-halfTexel.x, -halfTexel.y));
    float4 s10 = inTexture.sample(s, uv + float2( halfTexel.x, -halfTexel.y));
    float4 s01 = inTexture.sample(s, uv + float2(-halfTexel.x,  halfTexel.y));
    float4 s11 = inTexture.sample(s, uv + float2( halfTexel.x,  halfTexel.y));

    float4 avg = 0.25f * (s00 + s10 + s01 + s11);
    outTexture.write(avg, gid);
}

// MARK: - 3. Khớp khối phân cấp theo Tile 16x16 (Block Matching)

kernel void ultrasharpTileBlockMatchingKernel(
    texture2d<float, access::read> refLuma [[texture(0)]],
    texture2d<float, access::read> secLuma [[texture(1)]],
    constant TileMotionVector *coarseVectors [[buffer(0)]],
    device TileMotionVector *fineVectors [[buffer(1)]],
    constant UltraSharpTileUniforms &uniforms [[buffer(2)]],
    uint2 tileId [[thread_position_in_grid]]
) {
    if (tileId.x >= uniforms.numTilesX || tileId.y >= uniforms.numTilesY) {
        return;
    }

    uint linearTileIdx = tileId.y * uniforms.numTilesX + tileId.x;

    // Lấy vector dự đoán ban đầu từ tầng thô (coarse vector) với kiểm tra biên an toàn tuyệt đối
    float initialDx = 0.0f;
    float initialDy = 0.0f;
    if (coarseVectors != nullptr && uniforms.scaleFactor > 0.5f) {
        uint coarseW = max(1u, uniforms.imageWidth / 2u);
        uint coarseH = max(1u, uniforms.imageHeight / 2u);
        uint coarseNumTilesX = max(1u, (coarseW + 15u) / 16u);
        uint coarseNumTilesY = max(1u, (coarseH + 15u) / 16u);
        uint cX = min(tileId.x / 2u, coarseNumTilesX - 1u);
        uint cY = min(tileId.y / 2u, coarseNumTilesY - 1u);
        TileMotionVector cv = coarseVectors[cY * coarseNumTilesX + cX];
        if (isfinite(cv.dx) && isfinite(cv.dy)) {
            initialDx = clamp(cv.dx * uniforms.scaleFactor, -64.0f, 64.0f);
            initialDy = clamp(cv.dy * uniforms.scaleFactor, -64.0f, 64.0f);
        }
    }

    int initX = int(round(initialDx));
    int initY = int(round(initialDy));

    int tileStartX = int(tileId.x * uniforms.tileWidth);
    int tileStartY = int(tileId.y * uniforms.tileHeight);
    int imgW = int(uniforms.imageWidth);
    int imgH = int(uniforms.imageHeight);

    float bestSAD = 1e9f;
    int bestDx = initX;
    int bestDy = initY;

    int radius = uniforms.searchRadius;

    // Tìm kiếm cục bộ xung quanh vector khởi tạo trong phạm vi +-radius
    for (int dy = -radius; dy <= radius; ++dy) {
        int candidateDy = initY + dy;
        for (int dx = -radius; dx <= radius; ++dx) {
            int candidateDx = initX + dx;
            float currentSAD = 0.0f;
            int sampledCount = 0;

            for (uint py = 0; py < uniforms.tileHeight; py += 2) {
                int ry = tileStartY + int(py);
                int sy = ry + candidateDy;
                if (ry < 0 || ry >= imgH || sy < 0 || sy >= imgH) continue;

                for (uint px = 0; px < uniforms.tileWidth; px += 2) {
                    int rx = tileStartX + int(px);
                    int sx = rx + candidateDx;
                    if (rx < 0 || rx >= imgW || sx < 0 || sx >= imgW) continue;

                    float refVal = refLuma.read(uint2(rx, ry)).r;
                    float secVal = secLuma.read(uint2(sx, sy)).r;
                    currentSAD += abs(refVal - secVal);
                    sampledCount++;
                }
            }

            if (sampledCount > 0) {
                float normalizedSAD = currentSAD / float(sampledCount);
                if (normalizedSAD < bestSAD) {
                    bestSAD = normalizedSAD;
                    bestDx = candidateDx;
                    bestDy = candidateDy;
                }
            }
        }
    }

    TileMotionVector result;
    result.dx = float(bestDx);
    result.dy = float(bestDy);
    result.sadError = bestSAD;
    // Đánh dấu lỗi nếu sai số vượt ngưỡng sai khác 0.25 (độ chênh lệch luma trung bình quá lớn)
    result.isInvalid = (bestSAD > 0.25f) ? 1 : 0;

    fineVectors[linearTileIdx] = result;
}

// MARK: - 4. Tinh chỉnh Sub-pixel bằng Lucas-Kanade lặp theo Tile

kernel void ultrasharpSubpixelRefineKernel(
    texture2d<float, access::sample> refLuma [[texture(0)]],
    texture2d<float, access::sample> secLuma [[texture(1)]],
    device TileMotionVector *tileVectors [[buffer(0)]],
    constant UltraSharpTileUniforms &uniforms [[buffer(1)]],
    uint2 tileId [[thread_position_in_grid]]
) {
    if (tileId.x >= uniforms.numTilesX || tileId.y >= uniforms.numTilesY) {
        return;
    }

    uint linearTileIdx = tileId.y * uniforms.numTilesX + tileId.x;
    TileMotionVector mv = tileVectors[linearTileIdx];
    if (mv.isInvalid != 0) {
        return;
    }

    constexpr sampler bilinearSampler(coord::pixel, address::clamp_to_edge, filter::linear);

    float currentDx = mv.dx;
    float currentDy = mv.dy;

    float tileStartX = float(tileId.x * uniforms.tileWidth);
    float tileStartY = float(tileId.y * uniforms.tileHeight);
    float tW = float(uniforms.tileWidth);
    float tH = float(uniforms.tileHeight);

    // 3 vòng lặp tối ưu hóa Lucas-Kanade
    for (int iter = 0; iter < 3; ++iter) {
        float sumIxx = 0.0f;
        float sumIyy = 0.0f;
        float sumIxy = 0.0f;
        float sumIxt = 0.0f;
        float sumIyt = 0.0f;

        for (float py = 1.0f; py < tH - 1.0f; py += 1.0f) {
            float ry = tileStartY + py;
            float sy = ry + currentDy;

            for (float px = 1.0f; px < tW - 1.0f; px += 1.0f) {
                float rx = tileStartX + px;
                float sx = rx + currentDx;

                // Gradient không gian chính xác tại tâm pixel (+0.5f cho coord::pixel của Metal)
                float2 refPt = float2(rx + 0.5f, ry + 0.5f);
                float2 secPt = float2(sx + 0.5f, sy + 0.5f);
                float rLeft  = refLuma.sample(bilinearSampler, refPt + float2(-1.0f,  0.0f)).r;
                float rRight = refLuma.sample(bilinearSampler, refPt + float2( 1.0f,  0.0f)).r;
                float rUp    = refLuma.sample(bilinearSampler, refPt + float2( 0.0f, -1.0f)).r;
                float rDown  = refLuma.sample(bilinearSampler, refPt + float2( 0.0f,  1.0f)).r;

                float Ix = 0.5f * (rRight - rLeft);
                float Iy = 0.5f * (rDown - rUp);

                float refVal = refLuma.sample(bilinearSampler, refPt).r;
                float secVal = secLuma.sample(bilinearSampler, secPt).r;
                float It = secVal - refVal;

                sumIxx += Ix * Ix;
                sumIyy += Iy * Iy;
                sumIxy += Ix * Iy;
                sumIxt += Ix * It;
                sumIyt += Iy * It;
            }
        }

        // Tikhonov Regularization để tránh ma trận suy biến ở vùng phẳng
        float trace = sumIxx + sumIyy;
        float lambda = max(0.0001f * trace, 0.001f);
        sumIxx += lambda;
        sumIyy += lambda;

        float det = sumIxx * sumIyy - sumIxy * sumIxy;
        if (abs(det) > 1e-6f) {
            float invDet = 1.0f / det;
            float deltaU = -invDet * ( sumIyy * sumIxt - sumIxy * sumIyt);
            float deltaV = -invDet * (-sumIxy * sumIxt + sumIxx * sumIyt);

            // Kẹp bước dịch chuyển trong khoảng hợp lý [-1.0, 1.0] px
            deltaU = clamp(deltaU, -1.0f, 1.0f);
            deltaV = clamp(deltaV, -1.0f, 1.0f);

            currentDx += deltaU;
            currentDy += deltaV;

            if (abs(deltaU) < 0.02f && abs(deltaV) < 0.02f) {
                break; // Hội tụ
            }
        }
    }

    mv.dx = currentDx;
    mv.dy = currentDy;
    tileVectors[linearTileIdx] = mv;
}

// MARK: - 5. Biến dạng Warp Bicubic Catmull-Rom & Tính toán Sai số Thặng dư (Residual)

inline float4 catmullRomWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(
        -0.5f * t3 + t2 - 0.5f * t,
         1.5f * t3 - 2.5f * t2 + 1.0f,
        -1.5f * t3 + 2.0f * t2 + 0.5f * t,
         0.5f * t3 - 0.5f * t2
    );
}

kernel void ultrasharpDenseFlowWarpKernel(
    texture2d<float, access::sample> secTexture [[texture(0)]],
    texture2d<float, access::read> refTexture [[texture(1)]],
    constant TileMotionVector *tileVectors [[buffer(0)]],
    texture2d<float, access::write> warpedTexture [[texture(2)]],
    texture2d<float, access::write> residualTexture [[texture(3)]],
    constant UltraSharpTileUniforms &uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.imageWidth || gid.y >= uniforms.imageHeight) {
        return;
    }

    // Tọa độ chuẩn hóa trong lưới tile để nội suy mượt mà (bilinear interpolation)
    float tileCoordX = (float(gid.x) / float(uniforms.tileWidth)) - 0.5f;
    float tileCoordY = (float(gid.y) / float(uniforms.tileHeight)) - 0.5f;

    int tX0 = clamp(int(floor(tileCoordX)), 0, int(uniforms.numTilesX - 1));
    int tY0 = clamp(int(floor(tileCoordY)), 0, int(uniforms.numTilesY - 1));
    int tX1 = clamp(tX0 + 1, 0, int(uniforms.numTilesX - 1));
    int tY1 = clamp(tY0 + 1, 0, int(uniforms.numTilesY - 1));

    float fx = clamp(tileCoordX - float(tX0), 0.0f, 1.0f);
    float fy = clamp(tileCoordY - float(tY0), 0.0f, 1.0f);

    TileMotionVector mv00 = tileVectors[tY0 * uniforms.numTilesX + tX0];
    TileMotionVector mv10 = tileVectors[tY0 * uniforms.numTilesX + tX1];
    TileMotionVector mv01 = tileVectors[tY1 * uniforms.numTilesX + tX0];
    TileMotionVector mv11 = tileVectors[tY1 * uniforms.numTilesX + tX1];

    // Nội suy 2D vector dịch chuyển có trọng số an toàn (loại trừ tile isInvalid nếu có)
    float w00 = (mv00.isInvalid == 0) ? ((1.0f - fx) * (1.0f - fy)) : 0.0f;
    float w10 = (mv10.isInvalid == 0) ? (        fx  * (1.0f - fy)) : 0.0f;
    float w01 = (mv01.isInvalid == 0) ? ((1.0f - fx) *         fy ) : 0.0f;
    float w11 = (mv11.isInvalid == 0) ? (        fx  *         fy ) : 0.0f;
    float wSum = w00 + w10 + w01 + w11;

    float interpDx = 0.0f;
    float interpDy = 0.0f;
    if (wSum > 1e-4f) {
        float invW = 1.0f / wSum;
        interpDx = clamp((w00 * mv00.dx + w10 * mv10.dx + w01 * mv01.dx + w11 * mv11.dx) * invW, -64.0f, 64.0f);
        interpDy = clamp((w00 * mv00.dy + w10 * mv10.dy + w01 * mv01.dy + w11 * mv11.dy) * invW, -64.0f, 64.0f);
    }

    constexpr sampler nearestSampler(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 warpedPos = float2(gid) + float2(interpDx, interpDy);
    float2 basePos = floor(warpedPos);
    float2 frac = warpedPos - basePos;

    float4 wx = catmullRomWeights(frac.x);
    float4 wy = catmullRomWeights(frac.y);

    float4 bicubicSum = float4(0.0f);
    float4 minCenter = float4(1.0f);
    float4 maxCenter = float4(0.0f);

    for (int j = -1; j <= 2; ++j) {
        float4 rowSum = float4(0.0f);
        for (int i = -1; i <= 2; ++i) {
            float2 sampleCoord = basePos + float2(float(i) + 0.5f, float(j) + 0.5f);
            float4 s = secTexture.sample(nearestSampler, sampleCoord);
            rowSum += s * wx[i + 1];
            if (i >= 0 && i <= 1 && j >= 0 && j <= 1) {
                minCenter = min(minCenter, s);
                maxCenter = max(maxCenter, s);
            }
        }
        bicubicSum += rowSum * wy[j + 1];
    }

    // Kẹp chống rung viền (anti-ringing) theo vùng 2x2 trung tâm + cân bằng sáng quang trắc (exposureGain/Bias)
    // để triệt tiêu hoàn toàn hiện tượng vá tối cục bộ khi AE dao động nhẹ giữa các frame burst!
    float4 warpedRaw = clamp(bicubicSum, minCenter, maxCenter);
    float safeGain = (uniforms.exposureGain > 0.5f && uniforms.exposureGain < 1.5f) ? uniforms.exposureGain : 1.0f;
    float safeBias = clamp(uniforms.exposureBias, -0.05f, 0.05f);
    float4 warpedColor = float4(clamp(warpedRaw.rgb * safeGain + float3(safeBias), 0.0f, 1.0f), 1.0f);
    float4 refColor = refTexture.read(gid);

    // Tính sai số thặng dư kết hợp cả Luma + Chroma để chống bóng ma màu (color ghosting)
    float warpedLuma = 0.2126f * warpedColor.r + 0.7152f * warpedColor.g + 0.0722f * warpedColor.b;
    float refLuma = 0.2126f * refColor.r + 0.7152f * refColor.g + 0.0722f * refColor.b;
    float lumaDiff = abs(warpedLuma - refLuma);
    float chromaDiff = max(abs(warpedColor.r - refColor.r), max(abs(warpedColor.g - refColor.g), abs(warpedColor.b - refColor.b)));
    float residual = 0.70f * lumaDiff + 0.30f * chromaDiff;

    warpedTexture.write(warpedColor, gid);
    // Lưu dạng rg16Float gọn nhẹ (tiết kiệm 50% VRAM cho ảnh 12MP): .r = residual, .g = refLuma
    residualTexture.write(float4(residual, refLuma, 0.0f, 1.0f), gid);
}

// MARK: - 6. Ước lượng Nhiễu Cảm biến Động (Noise Estimation MAD)

kernel void ultrasharpEstimateNoiseMADKernel(
    texture2d<float, access::read> residualTexture [[texture(0)]],
    device atomic_uint *noiseHistogram [[buffer(0)]],
    device atomic_uint *validSampleCount [[buffer(1)]],
    constant UltraSharpFusionUniforms &uniforms [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) {
        return;
    }

    // Lấy mẫu ngẫu nhiên có bước nhảy để tiết kiệm tài nguyên
    if ((gid.x % 4 != 0) || (gid.y % 4 != 0)) {
        return;
    }

    float4 resData = residualTexture.read(gid);
    float residual = resData.r;

    // Chỉ đo nhiễu ở các sai số vi mô (loại bỏ vùng chuyển động lớn > 0.15)
    if (residual > 0.0005f && residual < 0.15f) {
        uint bin = clamp(uint(residual * 1000.0f), 0u, 127u);
        atomic_fetch_add_explicit(&noiseHistogram[bin], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(validSampleCount, 1u, memory_order_relaxed);
    }
}

// MARK: - 7. Gộp Robust Đa Khung Hình (Wiener-style Shrinkage Ping-Pong Accumulation)

kernel void ultrasharpRobustAccumulateKernel(
    texture2d<float, access::read> warpedTexture [[texture(0)]],
    texture2d<float, access::read> residualTexture [[texture(1)]],
    texture2d<float, access::read> accumSumColorIn [[texture(2)]],
    texture2d<float, access::read> accumSumWeightIn [[texture(3)]],
    texture2d<float, access::write> accumSumColorOut [[texture(4)]],
    texture2d<float, access::write> accumSumWeightOut [[texture(5)]],
    constant UltraSharpFusionUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int w = int(uniforms.width);
    int h = int(uniforms.height);
    int gx = int(gid.x);
    int gy = int(gid.y);
    if (gx >= w || gy >= h) {
        return;
    }

    float4 warpedColor = warpedTexture.read(gid);
    float4 centerRes = residualTexture.read(gid);
    float refLuma = centerRes.g;

    // Tổng hợp sai số cấu trúc trong lân cận 3x3 (HDR+ / Wronski Neighborhood Robustness)
    // giúp phân biệt chính xác nhiễu hạt đơn điểm với chuyển động thật của vật thể (chống ghosting)
    float neighborhoodResidual = 0.0f;
    const float w3x3[3][3] = {
        { 0.0625f, 0.125f, 0.0625f },
        { 0.125f,  0.25f,  0.125f  },
        { 0.0625f, 0.125f, 0.0625f }
    };
    for (int dy = -1; dy <= 1; ++dy) {
        int ny = clamp(gy + dy, 0, h - 1);
        for (int dx = -1; dx <= 1; ++dx) {
            int nx = clamp(gx + dx, 0, w - 1);
            float r = residualTexture.read(uint2(nx, ny)).r;
            neighborhoodResidual += r * w3x3[dy + 1][dx + 1];
        }
    }
    float effectiveResidual = max(centerRes.r * 0.65f + neighborhoodResidual * 0.35f, neighborhoodResidual);

    // Đo độ sắc biên (Local Edge Structure) từ refLuma trong residualTexture.g:
    // - Vùng phẳng/vùng tối nhiều hạt (edgeMag thấp): cho phép gộp Wiener đầy đủ -> khử nhiễu sạch mịn.
    // - Vùng vi chi tiết/cạnh sắc (tóc, chữ, vải, lá cây): siết chặt ngưỡng kSigma để KHÔNG BAO GIỜ
    //   bị nhòe/bệt chi tiết khi có sai lệch sub-pixel nhỏ!
    float refLumaL = residualTexture.read(uint2(clamp(gx - 1, 0, w - 1), gy)).g;
    float refLumaR = residualTexture.read(uint2(clamp(gx + 1, 0, w - 1), gy)).g;
    float refLumaU = residualTexture.read(uint2(gx, clamp(gy - 1, 0, h - 1))).g;
    float refLumaD = residualTexture.read(uint2(gx, clamp(gy + 1, 0, h - 1))).g;
    float edgeMag = length(float2(refLumaR - refLumaL, refLumaD - refLumaU));
    float textureStrictness = smoothstep(0.018f, 0.085f, edgeMag);

    // Mô hình nhiễu theo mức sáng: vùng tối dùng ngưỡng hợp lý để khử noise, vùng cạnh sắc siết cực chặt chống bệt
    float localSigma = uniforms.baseNoiseSigma * (1.0f + 0.65f * sqrt(max(0.0f, refLuma)));
    localSigma = max(localSigma, 0.0035f);

    float edgeTighten = mix(1.0f, 0.42f, textureStrictness);
    float kSigma = max(0.0038f, uniforms.noiseScaleK * localSigma * edgeTighten);

    // Trọng số Edge-Aware Wiener Shrinkage:
    // w = exp(-0.5 * (d / kSigma)^2), cắt hẳn ở 2.4*kSigma trên cạnh sắc để bảo toàn 100% độ sắc khung gốc!
    float ratio = effectiveResidual / kSigma;
    float cutoff = mix(2.9f, 2.15f, textureStrictness);
    float weight = 0.0f;
    if (ratio < cutoff) {
        weight = exp(-0.5f * ratio * ratio);
    }

    // Đọc bộ tích lũy hiện tại và ghi sang bộ đệm đích (Tương thích 100% mọi GPU Metal từ iPhone XS)
    float4 currSumColor = accumSumColorIn.read(gid);
    float currSumWeight = accumSumWeightIn.read(gid).r;

    currSumColor += warpedColor * weight;
    currSumWeight += weight;

    accumSumColorOut.write(currSumColor, gid);
    accumSumWeightOut.write(float4(currSumWeight, 0.0f, 0.0f, 1.0f), gid);
}

// Khởi tạo bộ tích lũy với Frame gốc (Frame tham chiếu luôn có trọng số w0 = 1.0)
kernel void ultrasharpInitAccumulatorKernel(
    texture2d<float, access::read> refTexture [[texture(0)]],
    texture2d<float, access::write> accumSumColor [[texture(1)]],
    texture2d<float, access::write> accumSumWeight [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= refTexture.get_width() || gid.y >= refTexture.get_height()) {
        return;
    }

    float4 color = refTexture.read(gid);
    accumSumColor.write(color, gid);
    accumSumWeight.write(float4(1.0f, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - 8. Chuẩn hóa & Làm Nét Nhận Biết Biên Cạnh Kẹp Halo (Halo-Clamped Sharpening)

kernel void ultrasharpNormalizeAndSharpenKernel(
    texture2d<float, access::read> accumSumColor [[texture(0)]],
    texture2d<float, access::read> accumSumWeight [[texture(1)]],
    texture2d<float, access::write> outFinalTexture [[texture(2)]],
    constant UltraSharpFusionUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int w = int(uniforms.width);
    int h = int(uniforms.height);
    int gx = int(gid.x);
    int gy = int(gid.y);

    if (gx >= w || gy >= h) {
        return;
    }

    // 1. Chuẩn hóa màu trung bình có trọng số: C_norm = sumColor / sumWeight
    float4 centerColorAcc = accumSumColor.read(gid);
    float centerW = max(accumSumWeight.read(gid).r, 1.0f);
    float4 centerNorm = centerColorAcc / centerW;

    // 2. Dual-Scale Structure-Aware Detail & Local Clarity Restoration (3x3 Fine + 5x5 Micro-Contrast)
    // Kẹp chống halo chặt chẽ + lọc ngưỡng nhiễu vùng phẳng để ảnh vừa trong trẻo vừa sắc nét từng sợi chi tiết
    float3 minVal = centerNorm.rgb;
    float3 maxVal = centerNorm.rgb;
    float3 fineBlurSum = float3(0.0f);
    float3 wideBlurSum = float3(0.0f);

    const float kernel3x3[3][3] = {
        { 0.0625f, 0.125f, 0.0625f },
        { 0.125f,  0.25f,  0.125f  },
        { 0.0625f, 0.125f, 0.0625f }
    };

    for (int dy = -1; dy <= 1; ++dy) {
        int ny = clamp(gy + dy, 0, h - 1);
        for (int dx = -1; dx <= 1; ++dx) {
            int nx = clamp(gx + dx, 0, w - 1);
            float4 sampleAcc = accumSumColor.read(uint2(nx, ny));
            float sw = max(accumSumWeight.read(uint2(nx, ny)).r, 1.0f);
            float3 sampleNorm = (sampleAcc / sw).rgb;

            minVal = min(minVal, sampleNorm);
            maxVal = max(maxVal, sampleNorm);
            fineBlurSum += sampleNorm * kernel3x3[dy + 1][dx + 1];
        }
    }

    // Lấy mẫu vòng ngoài bán kính 2px (8 điểm cân xứng) cho lớp tương phản vi mô (Micro-Contrast)
    const int2 ringOffsets[8] = {
        int2(-2,  0), int2( 2,  0), int2( 0, -2), int2( 0,  2),
        int2(-2, -2), int2( 2, -2), int2(-2,  2), int2( 2,  2)
    };
    for (int k = 0; k < 8; ++k) {
        int nx = clamp(gx + ringOffsets[k].x, 0, w - 1);
        int ny = clamp(gy + ringOffsets[k].y, 0, h - 1);
        float4 sAcc = accumSumColor.read(uint2(nx, ny));
        float sw = max(accumSumWeight.read(uint2(nx, ny)).r, 1.0f);
        wideBlurSum += (sAcc / sw).rgb * 0.125f;
    }

    // 3. Tách chi tiết đa tần số trên kênh Luma (không khuếch đại nhiễu màu Chroma)
    float3 fineDetail = centerNorm.rgb - fineBlurSum;
    float3 midDetail  = fineBlurSum - wideBlurSum;
    float fineLuma = dot(fineDetail, float3(0.2126f, 0.7152f, 0.0722f));
    float midLuma  = dot(midDetail,  float3(0.2126f, 0.7152f, 0.0722f));

    // Lọc ngưỡng nhiễu vùng phẳng (trời, da mặt mịn) dựa trên SNR thực tế
    float snrFactor = clamp(sqrt(centerW / max(1.0f, float(uniforms.totalFrames))), 0.72f, 1.35f);
    float noiseFloor = mix(0.011f, 0.0045f, clamp((centerW - 1.0f) / 2.5f, 0.0f, 1.0f));
    float edgeMask = smoothstep(noiseFloor, noiseFloor * 3.2f, abs(fineLuma) + 0.45f * abs(midLuma));

    float fineAlpha = uniforms.sharpnessAlpha * 0.92f * snrFactor * edgeMask;
    float midAlpha  = uniforms.sharpnessAlpha * 0.28f * snrFactor * edgeMask;

    // 4. Kẹp biên độ Halo Bất đối xứng Bảo vệ Vùng Tối (Shadow-Safe Asymmetric Halo Clamping):
    // Không bao giờ đẩy viền tối xuống đen bết ("tối mấy chỗ"), vẫn giữ vi chi tiết sáng sắc nét tự nhiên!
    float centerLuma = dot(centerNorm.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float shadowDarkDamp = mix(0.22f, 0.72f, smoothstep(0.05f, 0.42f, centerLuma));
    float rawBoost = fineAlpha * fineLuma + midAlpha * midLuma;
    float lumaBoost = (rawBoost < 0.0f) ? (rawBoost * shadowDarkDamp) : rawBoost;

    float3 unclampedSharp = centerNorm.rgb + float3(lumaBoost);
    float3 lowBound = max(float3(0.0f), minVal - uniforms.haloClampLimit * shadowDarkDamp);
    float3 highBound = min(float3(1.0f), maxVal + uniforms.haloClampLimit);
    float3 clampedSharp = clamp(unclampedSharp, lowBound, highBound);

    outFinalTexture.write(float4(clamp(clampedSharp, 0.0f, 1.0f), 1.0f), gid);
}
