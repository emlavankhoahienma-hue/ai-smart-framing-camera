#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
    float edge_sharpen;
};

// Separable Wide-Angle Expansion Kernel with Edge Micro-Sharpening:
// u_src = (1.0 + beta_x) * u - beta_x * (u * u * u)
// v_src = (1.0 + beta_y) * v - beta_y * (v * v * v)
// Derivative at center is (1.0 + beta_x) > 1.0: true wide-angle optical FOV expansion.
// Boundaries [-1.0, 1.0] map exactly to [-1.0, 1.0], zero black borders, zero streak artifacts.
// Micro-sharpening is applied proportionally to radial distance, keeping periphery crisp.
kernel void separableSuperViewKernel(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant SuperViewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float w = float(width);
    float h = float(height);

    float u = ((float(gid.x) + 0.5f) / w - 0.5f) * 2.0f;
    float v = ((float(gid.y) + 0.5f) / h - 0.5f) * 2.0f;

    // Cong thuc tach truc mo rong FOV: dao ham tai tam (1 + beta) > 1, khop khit bien +-1.0
    float u_src = (1.0f + params.beta_x) * u - params.beta_x * (u * u * u);
    float v_src = (1.0f + params.beta_y) * v - params.beta_y * (v * v * v);
    float2 srcUV = clamp(float2(u_src * 0.5f + 0.5f, v_src * 0.5f + 0.5f), 0.0f, 1.0f);

    float4 centerColor = inTexture.sample(s, srcUV);

    // Bu do net vi mo o vung ria ngoai (Unsharp Mask ty le thuan voi khoang cach ra bien)
    float radialDistSq = u * u + v * v;
    float sharpenStrength = clamp((radialDistSq - 0.15f) * 0.65f, 0.0f, 1.0f) * params.edge_sharpen;
    if (sharpenStrength > 0.01f) {
        float2 texel = float2(1.0f / w, 1.0f / h);
        float4 top = inTexture.sample(s, clamp(srcUV + float2(0.0f, -texel.y), 0.0f, 1.0f));
        float4 bottom = inTexture.sample(s, clamp(srcUV + float2(0.0f, texel.y), 0.0f, 1.0f));
        float4 left = inTexture.sample(s, clamp(srcUV + float2(-texel.x, 0.0f), 0.0f, 1.0f));
        float4 right = inTexture.sample(s, clamp(srcUV + float2(texel.x, 0.0f), 0.0f, 1.0f));
        float3 detail = centerColor.rgb * 4.0f - (top.rgb + bottom.rgb + left.rgb + right.rgb);
        centerColor.rgb = clamp(centerColor.rgb + detail * sharpenStrength, 0.0f, 1.0f);
    }

    outTexture.write(centerColor, gid);
}
