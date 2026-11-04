#include <metal_stdlib>
using namespace metal;

struct SuperViewParams {
    float beta_x;
    float beta_y;
};

// MARK: - Legacy Kernel (SuperView Anamorphic Warp - Giữ để Rollback)
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

// MARK: - New Kernel (Canvas Zoom-Out với Phản Chiếu Mờ & Vignette Mép)
struct WideParams {
    float scale;     // = factor, từ 0.5 đến 1.0
    float blur;      // 0.10
    float vignette;  // 0.25
};

constant float2 kTaps[8] = {
    float2(1.0, 0.0), float2(-1.0, 0.0), float2(0.0, 1.0), float2(0.0, -1.0),
    float2(0.7071, 0.7071), float2(-0.7071, 0.7071),
    float2(0.7071, -0.7071), float2(-0.7071, -0.7071)
};

kernel void ultraWideCanvasKernel(
    texture2d<float, access::sample> inTex  [[texture(0)]],
    texture2d<float, access::write>  outTex [[texture(1)]],
    constant WideParams &p                  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint W = outTex.get_width();
    uint H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler sClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler sMirror(coord::normalized, address::mirrored_repeat, filter::linear);

    float2 uvOut = (float2(gid) + 0.5f) / float2(float(W), float(H));
    float2 c = (uvOut - 0.5f) / max(p.scale, 0.05f); // |c| <= 0.5 nghĩa là nằm trong ảnh gốc
    float2 srcUV = c + 0.5f;
    float dist = length(max(abs(c) - 0.5f, float2(0.0f)));

    float3 rgb;
    if (dist <= 0.0f) {
        rgb = inTex.sample(sClamp, srcUV).rgb;      // vùng thật, giữ nguyên
    } else {
        float r = p.blur * dist;                    // mờ tăng dần, bằng 0 tại mép nên không có đường nối
        float3 acc = inTex.sample(sMirror, srcUV).rgb;
        for (int k = 1; k <= 2; k++) {
            float rr = r * 0.5f * float(k);
            for (int i = 0; i < 8; i++) {
                acc += inTex.sample(sMirror, srcUV + kTaps[i] * rr).rgb;
            }
        }
        rgb = acc / 17.0f;
        rgb *= 1.0f - p.vignette * smoothstep(0.0f, 0.6f, dist);
    }
    outTex.write(float4(rgb, 1.0f), gid);
}
