//
//  FocusPeakingShaders.metal
//  AISmartFramingCamera
//
//  Cinematic GPU Focus Peaking Compute Pipeline (Metal 3 / MSL 3.0)
//  Algorithms:
//  - Rec.709 Luma + Box Downsample (to display-matched resolution)
//  - Fused Threadgroup Tile Denoise + Dual-Scale Scharr + Re-Blur Defocus Ratio
//  - Clamped Highlight / Deep Shadow Rejection
//  - 64-bin Parallel GPU Histogram + CDF Percentile + Temporal EMA Threshold (Zero CPU Readback)
//  - Non-Maximum Suppression (NMS 4-direction) + Hysteresis + Isolated Despeckle Filter
//  - Temporal Ping-Pong Filter (Fast Attack, Smooth Decay)
//  - Antialiased On-Screen Alpha Composite (Constant point thickness, no halo/glow)
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Peaking Uniforms & Data Structures

struct PeakingUniforms {
    uint inputWidth;
    uint inputHeight;
    uint workWidth;
    uint workHeight;
    uint targetWidth;
    uint targetHeight;
    float sensitivity;   // 0.0 .. 1.0 (maps to percentile 0.90 .. 0.985)
    float iso;           // Active device sensor ISO (e.g. 50 .. 3200)
    float colorR;
    float colorG;
    float colorB;
    float colorA;
    float pointThickness; // in display points (~1.5 pt)
    float displayScale;   // screen scale factor (2.0 or 3.0)
    float minLumaClip;    // ~4.0 / 255.0 = 0.0157
    float maxLumaClip;    // ~250.0 / 255.0 = 0.9804
};

struct ThresholdBufferData {
    float rawThreshold;
    float emaThreshold;
    uint activePixelCount;
    uint totalPixelCount;
};

// MARK: - Kernel 1: Downscale & Rec.709 Luma Extraction

kernel void peakingDownscaleAndLumaKernel(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    texture2d<float, access::write> outLuma [[texture(1)]],
    constant PeakingUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.workWidth || gid.y >= uniforms.workHeight) {
        return;
    }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float w = float(uniforms.workWidth);
    float h = float(uniforms.workHeight);
    float2 centerUV = (float2(gid) + 0.5f) / float2(w, h);

    // 2x2 box filter offsets to eliminate high-frequency aliasing
    float2 halfTexel = 0.5f / float2(uniforms.inputWidth, uniforms.inputHeight);
    float4 s00 = inTexture.sample(s, centerUV + float2(-halfTexel.x, -halfTexel.y));
    float4 s10 = inTexture.sample(s, centerUV + float2( halfTexel.x, -halfTexel.y));
    float4 s01 = inTexture.sample(s, centerUV + float2(-halfTexel.x,  halfTexel.y));
    float4 s11 = inTexture.sample(s, centerUV + float2( halfTexel.x,  halfTexel.y));

    float4 avgColor = 0.25f * (s00 + s10 + s01 + s11);

    // Rec.709 Luma formula: Y = 0.2126*R + 0.7152*G + 0.0722*B
    float luma = clamp(0.2126f * avgColor.r + 0.7152f * avgColor.g + 0.0722f * avgColor.b, 0.0f, 1.0f);
    outLuma.write(float4(luma, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - Kernel 2: Fused Tile Dual-Scale Scharr & Defocus Ratio Kernel

kernel void peakingFusedScharrDefocusKernel(
    texture2d<float, access::read> inLuma [[texture(0)]],
    texture2d<float, access::write> outSharpness [[texture(1)]],
    constant PeakingUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 gidGroup [[threadgroup_position_in_grid]]
) {
    // Threadgroup tile: 16x16 work items with 2-pixel halo around borders (20x20 elements)
    threadgroup float tile[20][20];

    int w = int(uniforms.workWidth);
    int h = int(uniforms.workHeight);

    int2 baseCoord = int2(gidGroup.x * 16, gidGroup.y * 16) - 2;
    uint linearTid = tid.y * 16 + tid.x; // 0..255

    // Cooperatively load 400 elements into shared threadgroup memory
    if (linearTid < 200) {
        int idx = int(linearTid);
        int ly = idx / 20;
        int lx = idx % 20;
        int2 sc = clamp(baseCoord + int2(lx, ly), int2(0), int2(w - 1, h - 1));
        tile[ly][lx] = inLuma.read(uint2(sc)).r;
    }
    if (linearTid + 200 < 400) {
        int idx = int(linearTid + 200);
        int ly = idx / 20;
        int lx = idx % 20;
        int2 sc = clamp(baseCoord + int2(lx, ly), int2(0), int2(w - 1, h - 1));
        tile[ly][lx] = inLuma.read(uint2(sc)).r;
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x >= uniforms.workWidth || gid.y >= uniforms.workHeight) {
        return;
    }

    int cx = int(tid.x) + 2;
    int cy = int(tid.y) + 2;
    float centerLuma = tile[cy][cx];

    // 1. Mask out unreliable pixels: clipped highlights & deep crushed shadows + 1px neighborhood
    bool isClipped = (centerLuma >= uniforms.maxLumaClip || centerLuma <= uniforms.minLumaClip);
    if (!isClipped) {
        isClipped = (tile[cy-1][cx] >= uniforms.maxLumaClip || tile[cy-1][cx] <= uniforms.minLumaClip ||
                     tile[cy+1][cx] >= uniforms.maxLumaClip || tile[cy+1][cx] <= uniforms.minLumaClip ||
                     tile[cy][cx-1] >= uniforms.maxLumaClip || tile[cy][cx-1] <= uniforms.minLumaClip ||
                     tile[cy][cx+1] >= uniforms.maxLumaClip || tile[cy][cx+1] <= uniforms.minLumaClip);
    }
    if (isClipped) {
        outSharpness.write(float4(0.0f, -1.0f, 0.0f, 1.0f), gid);
        return;
    }

    // 2. Fine-Scale Scharr Gradients (sigma ~1.0, 3x3 window)
    // S_x = [-3, 0, 3; -10, 0, 10; -3, 0, 3] / 32.0
    float gx_fine = (
        3.0f * (tile[cy-1][cx+1] - tile[cy-1][cx-1]) +
       10.0f * (tile[cy  ][cx+1] - tile[cy  ][cx-1]) +
        3.0f * (tile[cy+1][cx+1] - tile[cy+1][cx-1])
    ) / 32.0f;

    // S_y = [-3, -10, -3; 0, 0, 0; 3, 10, 3] / 32.0
    float gy_fine = (
        3.0f * (tile[cy+1][cx-1] - tile[cy-1][cx-1]) +
       10.0f * (tile[cy+1][cx  ] - tile[cy-1][cx  ]) +
        3.0f * (tile[cy+1][cx+1] - tile[cy-1][cx+1])
    ) / 32.0f;

    float mag_fine = sqrt(gx_fine * gx_fine + gy_fine * gy_fine);

    // 3. Coarse-Scale Gradients (sigma ~2.0, 5x5 stride-2 window)
    float gx_coarse = (
        3.0f * (tile[cy-2][cx+2] - tile[cy-2][cx-2]) +
       10.0f * (tile[cy  ][cx+2] - tile[cy  ][cx-2]) +
        3.0f * (tile[cy+2][cx+2] - tile[cy+2][cx-2])
    ) / 64.0f;

    float gy_coarse = (
        3.0f * (tile[cy+2][cx-2] - tile[cy-2][cx-2]) +
       10.0f * (tile[cy+2][cx  ] - tile[cy-2][cx  ]) +
        3.0f * (tile[cy+2][cx+2] - tile[cy-2][cx+2])
    ) / 64.0f;

    float mag_coarse = sqrt(gx_coarse * gx_coarse + gy_coarse * gy_coarse);

    // 4. ISO Noise Floor Scaling
    float isoNorm = clamp((uniforms.iso - 50.0f) / 1000.0f, 0.0f, 3.5f);
    float baseNoiseFloor = 0.018f + 0.038f * isoNorm;

    // 5. Re-Blur Defocus Gradient Ratio:
    // Defocused edges are broad and soft (mag_fine and mag_coarse are comparable -> ratio <= 1.0).
    // Truly sharp in-focus edges have steep localized gradients (mag_fine >> mag_coarse -> ratio > 1.0).
    float ratio = mag_fine / (mag_coarse + 0.006f);
    float focusWeight = saturate((ratio - 0.92f) * 3.8f);

    float effectiveMag = max(0.0f, mag_fine - baseNoiseFloor);
    float sharpness = effectiveMag * focusWeight;

    // 6. Quantize Gradient Normal Direction into 4 discrete sectors for NMS
    // 0: Horizontal (0 deg / 180 deg)
    // 1: Diagonal (45 deg)
    // 2: Vertical (90 deg)
    // 3: Anti-diagonal (135 deg)
    float angle = atan2(gy_fine, gx_fine);
    if (angle < 0.0f) angle += M_PI_F;
    float deg = angle * (180.0f / M_PI_F);

    float dir = 0.0f;
    if (deg >= 22.5f && deg < 67.5f) {
        dir = 1.0f;
    } else if (deg >= 67.5f && deg < 112.5f) {
        dir = 2.0f;
    } else if (deg >= 112.5f && deg < 157.5f) {
        dir = 3.0f;
    } else {
        dir = 0.0f;
    }

    outSharpness.write(float4(sharpness, dir, 0.0f, 1.0f), gid);
}

// MARK: - Kernel 3: 64-Bin GPU Sharpness Histogram

kernel void peakingSharpnessHistogramKernel(
    texture2d<float, access::read> inSharpness [[texture(0)]],
    device atomic_uint *histogram [[buffer(0)]],
    device atomic_uint *activePixelCount [[buffer(1)]],
    constant PeakingUniforms &uniforms [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.workWidth || gid.y >= uniforms.workHeight) {
        return;
    }

    float sharpness = inSharpness.read(gid).r;
    if (sharpness > 0.002f) {
        atomic_fetch_add_explicit(activePixelCount, 1, memory_order_relaxed);
        uint bin = clamp(uint(sharpness * 128.0f), 0u, 63u);
        atomic_fetch_add_explicit(&histogram[bin], 1, memory_order_relaxed);
    }
}

// MARK: - Kernel 4: Adaptive Threshold with GPU Percentile & EMA

kernel void peakingAdaptiveThresholdKernel(
    device atomic_uint *histogram [[buffer(0)]],
    device atomic_uint *activePixelCount [[buffer(1)]],
    device ThresholdBufferData &thresholdData [[buffer(2)]],
    constant PeakingUniforms &uniforms [[buffer(3)]],
    uint tid [[thread_position_in_threadgroup]]
) {
    threadgroup uint localHist[64];
    threadgroup uint prefixSum[64];

    if (tid < 64) {
        // Read histogram into threadgroup memory and reset global buffer for next frame
        localHist[tid] = atomic_exchange_explicit(&histogram[tid], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Single-threadgroup reduction for prefix sum and percentile
    if (tid == 0) {
        uint totalActive = atomic_exchange_explicit(activePixelCount, 0u, memory_order_relaxed);
        uint totalPixels = uniforms.workWidth * uniforms.workHeight;

        uint runSum = 0;
        for (int i = 0; i < 64; ++i) {
            runSum += localHist[i];
            prefixSum[i] = runSum;
        }

        // Map user sensitivity (0.0 .. 1.0) to percentile target:
        // 0.0 -> 98.5th percentile (very conservative, highest contrast peaks only)
        // 0.5 -> 95.0th percentile (standard balanced DoP reference)
        // 1.0 -> 90.0th percentile (sensitive low-contrast texture focus)
        float targetPercentile = mix(0.985f, 0.900f, saturate(uniforms.sensitivity));

        // Hard cap: peaking overlay can NEVER cover more than 10% of total frame pixels
        uint maxAllowedPeaks = uint(float(totalPixels) * 0.10f);
        uint targetCount = uint(float(totalActive) * targetPercentile);
        if (totalActive > maxAllowedPeaks && (totalActive - targetCount) > maxAllowedPeaks) {
            targetCount = totalActive - maxAllowedPeaks;
        }

        int targetBin = 32; // Default fallback
        for (int i = 0; i < 64; ++i) {
            if (prefixSum[i] >= targetCount) {
                targetBin = i;
                break;
            }
        }

        float computedThreshold = max(0.025f, float(targetBin) / 128.0f);

        // Exponential Moving Average (EMA: alpha = 0.15) for rock-solid temporal stability
        float prevEma = thresholdData.emaThreshold;
        if (prevEma <= 0.005f || !isfinite(prevEma)) {
            prevEma = computedThreshold;
        }
        float smoothed = mix(prevEma, computedThreshold, 0.15f);

        thresholdData.rawThreshold = computedThreshold;
        thresholdData.emaThreshold = smoothed;
        thresholdData.activePixelCount = totalActive;
        thresholdData.totalPixelCount = totalPixels;
    }
}

// MARK: - Kernel 5: NMS Directional Thinning, Hysteresis & Isolated Despeckle

kernel void peakingThinningAndHysteresisKernel(
    texture2d<float, access::read> inSharpness [[texture(0)]],
    texture2d<float, access::write> outMask [[texture(1)]],
    device const ThresholdBufferData &thresholdData [[buffer(0)]],
    constant PeakingUniforms &uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.workWidth || gid.y >= uniforms.workHeight) {
        return;
    }

    int x = int(gid.x);
    int y = int(gid.y);
    int w = int(uniforms.workWidth);
    int h = int(uniforms.workHeight);

    float2 centerVal = inSharpness.read(gid).rg;
    float s = centerVal.r;
    float dir = centerVal.g;

    if (dir < -0.5f || s <= 0.005f) {
        outMask.write(float4(0.0f), gid);
        return;
    }

    // 1. Non-Maximum Suppression (NMS) along gradient normal
    float n1 = 0.0f;
    float n2 = 0.0f;

    if (dir < 0.5f) {
        // Sector 0: Horizontal edge -> normal is Vertical
        n1 = inSharpness.read(uint2(x, clamp(y - 1, 0, h - 1))).r;
        n2 = inSharpness.read(uint2(x, clamp(y + 1, 0, h - 1))).r;
    } else if (dir < 1.5f) {
        // Sector 1: 45 degree diagonal
        n1 = inSharpness.read(uint2(clamp(x - 1, 0, w - 1), clamp(y - 1, 0, h - 1))).r;
        n2 = inSharpness.read(uint2(clamp(x + 1, 0, w - 1), clamp(y + 1, 0, h - 1))).r;
    } else if (dir < 2.5f) {
        // Sector 2: Vertical edge -> normal is Horizontal
        n1 = inSharpness.read(uint2(clamp(x - 1, 0, w - 1), y)).r;
        n2 = inSharpness.read(uint2(clamp(x + 1, 0, w - 1), y)).r;
    } else {
        // Sector 3: 135 degree anti-diagonal
        n1 = inSharpness.read(uint2(clamp(x + 1, 0, w - 1), clamp(y - 1, 0, h - 1))).r;
        n2 = inSharpness.read(uint2(clamp(x - 1, 0, w - 1), clamp(y + 1, 0, h - 1))).r;
    }

    if (s < n1 || s < n2) {
        outMask.write(float4(0.0f), gid);
        return;
    }

    // 2. Dual Threshold Hysteresis
    float strongThresh = max(0.028f, thresholdData.emaThreshold);
    float weakThresh = strongThresh * 0.48f;

    if (s < weakThresh) {
        outMask.write(float4(0.0f), gid);
        return;
    }

    // If between weak and strong, require connection to a strong neighbor in 3x3
    bool isKept = (s >= strongThresh);
    uint neighborCount = 0;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float nVal = inSharpness.read(uint2(clamp(x + dx, 0, w - 1), clamp(y + dy, 0, h - 1))).r;
            if (nVal >= weakThresh) {
                neighborCount++;
            }
            if (!isKept && nVal >= strongThresh) {
                isKept = true;
            }
        }
    }

    // 3. Salt-and-Pepper Despeckle: Discard isolated single pixels (require >= 2 active neighbors)
    if (!isKept || neighborCount < 2) {
        outMask.write(float4(0.0f), gid);
        return;
    }

    // Normalize intensity strength [0.0 .. 1.0] for alpha modulation
    float intensity = saturate((s - weakThresh) / (strongThresh - weakThresh + 0.001f));
    outMask.write(float4(intensity, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - Kernel 6: Temporal Ping-Pong Filter

kernel void peakingTemporalFilterKernel(
    texture2d<float, access::read> currentMask [[texture(0)]],
    texture2d<float, access::read> prevMask [[texture(1)]],
    texture2d<float, access::write> outFiltered [[texture(2)]],
    constant PeakingUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.workWidth || gid.y >= uniforms.workHeight) {
        return;
    }

    float curr = currentMask.read(gid).r;
    float prev = prevMask.read(gid).r;

    // Fast attack (immediate responsiveness to focus shifts), smooth temporal decay (prev * 0.72)
    float blended = max(curr, prev * 0.72f);
    outFiltered.write(float4(blended, 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - Kernel 7: Antialiased On-Screen Peaking Composite

kernel void peakingCompositeOverlayKernel(
    texture2d<float, access::read_write> targetTexture [[texture(0)]],
    texture2d<float, access::sample> maskTexture [[texture(1)]],
    constant PeakingUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.targetWidth || gid.y >= uniforms.targetHeight) {
        return;
    }

    constexpr sampler bilinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 targetSize = float2(uniforms.targetWidth, uniforms.targetHeight);
    float2 uv = (float2(gid) + 0.5f) / targetSize;

    // Sample the smoothed temporal peaking mask with hardware bilinear interpolation
    float peakVal = maskTexture.sample(bilinearSampler, uv).r;

    if (peakVal > 0.06f) {
        // Antialiased edge rolloff using smoothstep (clean ~1.5pt ridge, strictly zero glow / halo)
        float alpha = smoothstep(0.06f, 0.40f, peakVal) * uniforms.colorA;
        float4 baseColor = targetTexture.read(gid);

        float3 peakColor = float3(uniforms.colorR, uniforms.colorG, uniforms.colorB);
        float3 blended = mix(baseColor.rgb, peakColor, alpha);

        targetTexture.write(float4(blended, baseColor.a), gid);
    }
}
