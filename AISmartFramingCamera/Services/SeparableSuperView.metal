#include <metal_stdlib>
using namespace metal;

// MARK: - C++20 Rectilinear-Conformal 0.5x Ultra-Wide Optical Params
struct SuperViewParams {
    float edge_clarity; // Master optical clarity gain (modulated by C++20 Jacobian boost in mesh.z)
    float vignette_mix; // Subtle 13mm optical vignette blend [0..1]
    float chroma_guard; // Anti-aliasing & chroma-noise suppression threshold
    float reserved;
};

inline float4 uwCatmullRomWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(
        -0.5f * t3 + t2 - 0.5f * t,
         1.5f * t3 - 2.5f * t2 + 1.0f,
        -1.5f * t3 + 2.0f * t2 + 0.5f * t,
         0.5f * t3 - 0.5f * t2
    );
}

// 16-tap Catmull-Rom Bicubic Anti-Ringing sampler reading exact pixel coordinates
inline float4 sampleCatmullRomAntiRinging(
    texture2d<float, access::sample> tex,
    float2 uv,
    float w,
    float h
) {
    constexpr sampler nearestS(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 pixelPos = uv * float2(w, h) - 0.5f;
    float2 basePos = floor(pixelPos);
    float2 frac = pixelPos - basePos;

    float4 wx = uwCatmullRomWeights(frac.x);
    float4 wy = uwCatmullRomWeights(frac.y);

    float4 accum = float4(0.0f);
    float4 minCore = float4(1.0f);
    float4 maxCore = float4(0.0f);

    for (int j = -1; j <= 2; ++j) {
        float4 rowSum = float4(0.0f);
        for (int i = -1; i <= 2; ++i) {
            float2 coord = basePos + float2(float(i) + 0.5f, float(j) + 0.5f);
            float4 s = tex.sample(nearestS, coord);
            rowSum += s * wx[i + 1];
            if (i >= 0 && i <= 1 && j >= 0 && j <= 1) {
                minCore = min(minCore, s);
                maxCore = max(maxCore, s);
            }
        }
        accum += rowSum * wy[j + 1];
    }

    float4 pad = (maxCore - minCore) * 0.04f;
    return clamp(accum, max(float4(0.0f), minCore - pad), min(float4(1.0f), maxCore + pad));
}

kernel void separableSuperViewKernel(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    texture2d<float, access::sample> opticalMeshTexture [[texture(2)]],
    constant SuperViewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    constexpr sampler meshSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float w = float(width);
    float h = float(height);
    float2 dstUV = float2((float(gid.x) + 0.5f) / w, (float(gid.y) + 0.5f) / h);

    // 1. Sample C++20-solved Rectilinear-Conformal Optical Mesh:
    //    .xy = exact straight-line-preserving source UV in [0, 1]
    //    .z  = analytical Jacobian peripheral sharpness boost
    //    .w  = subtle natural 13mm optical micro-vignette
    float4 meshSample = opticalMeshTexture.sample(meshSampler, dstUV);
    float2 srcUV = clamp(meshSample.xy, 0.0f, 1.0f);
    float jacobianBoost = clamp(meshSample.z, 0.0f, 1.0f);
    float vignetteGain = mix(1.0f, clamp(meshSample.w, 0.88f, 1.0f), params.vignette_mix);

    // 2. High-Order 16-Tap Catmull-Rom Bicubic Anti-Ringing Resampling
    float4 centerColor = sampleCatmullRomAntiRinging(inTexture, srcUV, float(inTexture.get_width()), float(inTexture.get_height()));

    // 3. Luma-Only Jacobian-Guided Micro-Contrast & Peripheral Sharpness Restoration
    if (params.edge_clarity > 0.001f && jacobianBoost > 0.001f) {
        float2 texel = float2(1.0f / float(inTexture.get_width()), 1.0f / float(inTexture.get_height()));
        float3 nAvg = 0.25f * (
            inTexture.sample(linearSampler, clamp(srcUV + float2(texel.x, 0.0f), 0.0f, 1.0f)).rgb +
            inTexture.sample(linearSampler, clamp(srcUV - float2(texel.x, 0.0f), 0.0f, 1.0f)).rgb +
            inTexture.sample(linearSampler, clamp(srcUV + float2(0.0f, texel.y), 0.0f, 1.0f)).rgb +
            inTexture.sample(linearSampler, clamp(srcUV - float2(0.0f, texel.y), 0.0f, 1.0f)).rgb
        );

        float centerLuma = dot(centerColor.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        float avgLuma = dot(nAvg, float3(0.2126f, 0.7152f, 0.0722f));
        float detail = centerLuma - avgLuma;

        // Threshold micro noise floor to avoid sharpening sensor grain
        float absDetail = abs(detail);
        float noiseGate = smoothstep(params.chroma_guard, params.chroma_guard * 3.0f, absDetail);
        float delta = clamp(detail * noiseGate * (params.edge_clarity * jacobianBoost), -0.095f, 0.095f);
        centerColor.rgb = clamp(centerColor.rgb + float3(delta), 0.0f, 1.0f);
    }

    centerColor.rgb = clamp(centerColor.rgb * vignetteGain, 0.0f, 1.0f);
    centerColor.a = 1.0f;
    outTexture.write(centerColor, gid);
}
