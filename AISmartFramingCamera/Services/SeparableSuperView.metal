#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
    float roll_angle;       // Goc bu tru tu horizonRollAngle (0.0 neu tat Horizon Lock)
    float zoom_scale;       // He so tu horizonAdaptiveZoom (1.0 neu tat Horizon Lock)
    float shake_x;          // Bu rung +-0.03 truc X
    float shake_y;          // Bu rung +-0.03 truc Y
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

    // 1. Bien doi 0.5x SuperView (neu bat 0.5x):
    float u_w = (1.0f + params.beta_x) * u - params.beta_x * (u * u * u);
    float v_w = (1.0f + params.beta_y) * v - params.beta_y * (v * v * v);

    // 2. Xoay bu tru 360 do Horizon Lock trong khong gian vat ly dang huong (khong meo det khi xoay 90 do, khong lo goc den):
    if (params.zoom_scale > 1.001f || abs(params.roll_angle) > 0.0005f) {
        float minDim = min(w, h);
        float2 metricScale = float2(w / minDim, h / minDim);
        float2 metricPos = float2(u_w * metricScale.x, v_w * metricScale.y) / params.zoom_scale;
        float c = cos(params.roll_angle);
        float sn = sin(params.roll_angle);
        float2 rotatedMetric = float2(
            metricPos.x * c - metricPos.y * sn,
            metricPos.x * sn + metricPos.y * c
        );
        u_w = (rotatedMetric.x / metricScale.x) + params.shake_x;
        v_w = (rotatedMetric.y / metricScale.y) + params.shake_y;
    }

    float2 srcUV = clamp(float2(u_w * 0.5f + 0.5f, v_w * 0.5f + 0.5f), 0.0f, 1.0f);
    float4 centerColor = inTexture.sample(s, srcUV);
    outTexture.write(centerColor, gid);
}
