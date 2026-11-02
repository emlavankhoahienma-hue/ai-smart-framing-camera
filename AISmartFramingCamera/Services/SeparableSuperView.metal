#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
};

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

    // Biến đổi 0.5x SuperView anamorphic:
    float u_w = (1.0f + params.beta_x) * u - params.beta_x * (u * u * u);
    float v_w = (1.0f + params.beta_y) * v - params.beta_y * (v * v * v);

    float2 srcUV = clamp(float2(u_w * 0.5f + 0.5f, v_w * 0.5f + 0.5f), 0.0f, 1.0f);
    float4 centerColor = inTexture.sample(s, srcUV);
    outTexture.write(centerColor, gid);
}
