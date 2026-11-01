#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
};

// Separable Wide-Angle Expansion Kernel:
// u_src = (1.0 + beta_x) * u - beta_x * (u * u * u)
// v_src = (1.0 + beta_y) * v - beta_y * (v * v * v)
// Derivative at center is (1.0 + beta_x) > 1.0: true wide-angle optical FOV expansion (shrinks center, reveals more surroundings)
// Boundaries [-1.0, 1.0] map exactly to [-1.0, 1.0], zero black borders, zero streak artifacts.
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

    // True Wide-Angle Optical Expansion (derivative at center is 1.0 + beta > 1.0):
    float u_src = (1.0f + beta_x) * u - beta_x * (u * u * u);
    float v_src = (1.0f + beta_y) * v - beta_y * (v * v * v);

    // Map back to normalized UV [0.0, 1.0]
    float2 srcUV = float2(u_src * 0.5f + 0.5f, v_src * 0.5f + 0.5f);

    float4 color = inTexture.sample(s, srcUV);
    outTexture.write(color, gid);
}
