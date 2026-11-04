#include <metal_stdlib>
using namespace metal;

// MARK: - SuperView Anamorphic Warp Params
struct SuperViewParams {
    float beta_x;       // Hệ số dãn phi tuyến trục ngang (Horizontal Anamorphic Dynamic Stretch)
    float beta_y;       // Hệ số dãn phi tuyến trục dọc (Vertical Dynamic Stretch - giữ nhẹ để bảo toàn tỷ lệ người)
    float barrel_k;     // Hệ số cong quang học thấu kính góc siêu rộng (Subtle Optical Barrel Curvature)
    float edge_clarity; // Bù nét và vi tương phản vùng biên (Subtle Edge Contrast & Clarity)
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

    // Tọa độ chuẩn hóa tâm màn hình [-1.0, 1.0]
    float u = ((float(gid.x) + 0.5f) / w - 0.5f) * 2.0f;
    float v = ((float(gid.y) + 0.5f) / h - 0.5f) * 2.0f;

    // 1. Biến đổi Anamorphic Dynamic Stretch (SuperView Full Frame):
    // Giữ tâm 1:1 tự nhiên, dãn mượt dần ra hai mép viền để mở rộng trường nhìn mà không có viền đen
    float u_w = (1.0f + params.beta_x) * u - params.beta_x * (u * u * u);
    float v_w = (1.0f + params.beta_y) * v - params.beta_y * (v * v * v);

    // 2. Nâng cấp: Hiệu ứng cong quang học thấu kính góc siêu rộng (Subtle Optical Barrel Curvature):
    // Mô phỏng độ cong quang học tự nhiên của ống kính 0.5x Ultra-Wide (13mm f/2.2),
    // tạo chiều sâu không gian 3D chân thực, loại bỏ cảm giác kéo dãn phẳng nhân tạo.
    if (params.barrel_k > 0.001f) {
        float r2 = u_w * u_w + v_w * v_w;
        float norm_corner = 1.0f + params.barrel_k;
        float factor = (1.0f + params.barrel_k * r2) / norm_corner;
        u_w *= factor;
        v_w *= factor;
    }

    float2 srcUV = clamp(float2(u_w * 0.5f + 0.5f, v_w * 0.5f + 0.5f), 0.0f, 1.0f);
    float4 centerColor = inTexture.sample(s, srcUV);

    // 3. Nâng cấp: Tăng độ trong trẻo và chi tiết viền (Edge Clarity):
    if (params.edge_clarity > 0.001f) {
        float edgeDist = max(abs(u), abs(v));
        float boost = params.edge_clarity * smoothstep(0.35f, 1.0f, edgeDist);
        centerColor.rgb = mix(centerColor.rgb, centerColor.rgb * (1.0f + 0.035f * boost), boost);
    }

    outTexture.write(centerColor, gid);
}
