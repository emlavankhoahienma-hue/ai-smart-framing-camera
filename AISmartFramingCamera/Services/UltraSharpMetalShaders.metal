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

    // Lấy vector dự đoán ban đầu từ tầng thô (coarse vector)
    float initialDx = 0.0f;
    float initialDy = 0.0f;
    if (coarseVectors != nullptr) {
        TileMotionVector cv = coarseVectors[linearTileIdx];
        initialDx = cv.dx * uniforms.scaleFactor;
        initialDy = cv.dy * uniforms.scaleFactor;
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

                // Gradient không gian trên ảnh tham chiếu (Scharr 1D vi phân)
                float rLeft  = refLuma.sample(bilinearSampler, float2(rx - 1.0f, ry)).r;
                float rRight = refLuma.sample(bilinearSampler, float2(rx + 1.0f, ry)).r;
                float rUp    = refLuma.sample(bilinearSampler, float2(rx, ry - 1.0f)).r;
                float rDown  = refLuma.sample(bilinearSampler, float2(rx, ry + 1.0f)).r;

                float Ix = 0.5f * (rRight - rLeft);
                float Iy = 0.5f * (rDown - rUp);

                float refVal = refLuma.sample(bilinearSampler, float2(rx, ry)).r;
                float secVal = secLuma.sample(bilinearSampler, float2(sx, sy)).r;
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

// MARK: - 5. Biến dạng Warp & Tính toán Sai số Thặng dư (Residual)

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

    // Nội suy 2D vector dịch chuyển
    float interpDx = (1.0f - fx) * (1.0f - fy) * mv00.dx +
                             fx  * (1.0f - fy) * mv10.dx +
                     (1.0f - fx) *        fy   * mv01.dx +
                             fx  *        fy   * mv11.dx;

    float interpDy = (1.0f - fx) * (1.0f - fy) * mv00.dy +
                             fx  * (1.0f - fy) * mv10.dy +
                     (1.0f - fx) *        fy   * mv01.dy +
                             fx  *        fy   * mv11.dy;

    constexpr sampler bilinearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 warpedCoord = float2(gid) + float2(interpDx, interpDy);

    float4 warpedColor = secTexture.sample(bilinearSampler, warpedCoord);
    float4 refColor = refTexture.read(gid);

    // Tính sai số thặng dư luma d
    float warpedLuma = 0.2126f * warpedColor.r + 0.7152f * warpedColor.g + 0.0722f * warpedColor.b;
    float refLuma = 0.2126f * refColor.r + 0.7152f * refColor.g + 0.0722f * refColor.b;
    float residual = abs(warpedLuma - refLuma);

    warpedTexture.write(warpedColor, gid);
    residualTexture.write(float4(residual, warpedLuma, refLuma, 1.0f), gid);
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

// MARK: - 7. Gộp Robust Đa Khung Hình (Wiener-style Shrinkage Accumulation)

kernel void ultrasharpRobustAccumulateKernel(
    texture2d<float, access::read> warpedTexture [[texture(0)]],
    texture2d<float, access::read> residualTexture [[texture(1)]],
    texture2d<float, access::read_write> accumSumColor [[texture(2)]],
    texture2d<float, access::read_write> accumSumWeight [[texture(3)]],
    constant UltraSharpFusionUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) {
        return;
    }

    float4 warpedColor = warpedTexture.read(gid);
    float4 resData = residualTexture.read(gid);
    float residual = resData.r;
    float refLuma = resData.b;

    // Mô hình nhiễu theo mức sáng: sensor noise tăng căn bậc hai ở vùng sáng (shot noise)
    float localSigma = uniforms.baseNoiseSigma * (1.0f + 0.8f * sqrt(refLuma));
    localSigma = max(localSigma, 0.004f);

    float kSigma = uniforms.noiseScaleK * localSigma;

    // Trọng số Wiener-style Shrinkage:
    // w = exp(- (d / kSigma)^2)
    // Khi d vượt 3*sigma (vật thể chuyển động hoặc sai lệch khớp), w -> 0 lập tức!
    float ratio = residual / kSigma;
    float weight = 0.0f;
    if (ratio < 3.2f) {
        weight = exp(-0.5f * ratio * ratio);
    }

    // Đọc bộ tích lũy hiện tại
    float4 currSumColor = accumSumColor.read(gid);
    float currSumWeight = accumSumWeight.read(gid).r;

    currSumColor += warpedColor * weight;
    currSumWeight += weight;

    accumSumColor.write(currSumColor, gid);
    accumSumWeight.write(float4(currSumWeight, 0.0f, 0.0f, 1.0f), gid);
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

    // 2. Tìm min/max cục bộ trong cửa sổ 3x3 để kẹp triệt tiêu quầng hào quang (Halo Clamping)
    float3 minVal = centerNorm.rgb;
    float3 maxVal = centerNorm.rgb;
    float3 blurSum = float3(0.0f);
    float blurWeightTotal = 0.0f;

    // Ma trận làm mờ Gauss 3x3 nhẹ
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

            float kw = kernel3x3[dy + 1][dx + 1];
            blurSum += sampleNorm * kw;
            blurWeightTotal += kw;
        }
    }

    float3 blurred = blurSum / blurWeightTotal;

    // 3. Chi tiết tần số cao (High-pass detail)
    float3 detail = centerNorm.rgb - blurred;

    // 4. Điều biến cường độ làm nét theo SNR cục bộ:
    // Số frame hợp lệ càng nhiều (sumWeight cao) thì nhiễu càng thấp -> cho phép làm nét mạnh hơn
    float snrFactor = clamp(sqrt(centerW / float(uniforms.totalFrames)), 0.6f, 1.3f);
    float alpha = uniforms.sharpnessAlpha * snrFactor;

    // 5. Kẹp biên độ Halo (Halo Clamping)
    float3 unclampedSharp = centerNorm.rgb + alpha * detail;
    float3 clampedSharp = clamp(unclampedSharp, minVal - uniforms.haloClampLimit, maxVal + uniforms.haloClampLimit);

    outFinalTexture.write(float4(clampedSharp, centerNorm.a), gid);
}
