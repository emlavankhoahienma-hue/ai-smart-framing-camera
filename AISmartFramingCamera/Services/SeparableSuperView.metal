#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
};

// Separable Anamorphic SuperView Kernel:
// u_src = (1.0 - beta_x) * u + beta_x * (u * u * u)
// v_src = (1.0 - beta_y) * v + beta_y * (v * v * v)
// Monotonically maps [-1.0, 1.0] to [-1.0, 1.0].
// Strictly rectilinear along horizontal and vertical axes, zero streaks, zero hourglass pinching.
kernel void separableSuperViewKernel(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant SuperViewParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float w = float(outTexture.get_width());
    float h = float(outTexture.get_height());

    // Normalized coordinates in [-1.0, 1.0]
    float u = ((float(gid.x) + 0.5f) / w - 0.5f) * 2.0f;
    float v = ((float(gid.y) + 0.5f) / h - 0.5f) * 2.0f;

    float beta_x = params.beta_x;
    float beta_y = params.beta_y;

    // Separable Anamorphic SuperView mapping: [-1, 1] -> [-1, 1]
    float u_src = (1.0f - beta_x) * u + beta_x * (u * u * u);
    float v_src = (1.0f - beta_y) * v + beta_y * (v * v * v);

    // Map back to normalized UV [0.0, 1.0]
    float2 srcUV = float2(u_src * 0.5f + 0.5f, v_src * 0.5f + 0.5f);

    float4 color = inTexture.sample(s, srcUV);
    outTexture.write(color, gid);
}
