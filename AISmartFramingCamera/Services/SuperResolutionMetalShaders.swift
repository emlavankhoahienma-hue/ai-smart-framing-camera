import Foundation
import Metal
import CoreGraphics

/// Quản lý mã nguồn Metal Shading Language (MSL) và biên dịch Compute Pipeline tại runtime.
/// Biên dịch động qua `MTLDevice.makeLibrary(source:options:)` giúp tương thích 100%
/// với mọi dòng vi xử lý Apple Silicon (A11 Bionic đến A18 Pro) mà không cần cấu hình project.pbxproj phức tạp.
public final class SuperResolutionMetalShaders: @unchecked Sendable {
    public static let shared = SuperResolutionMetalShaders()

    private let lock = NSLock()
    private var library: MTLLibrary?
    private var device: MTLDevice?

    public private(set) var gradientEnergyPipeline: MTLComputePipelineState?
    public private(set) var subpixelAlignPipeline: MTLComputePipelineState?
    public private(set) var deghostWeightsPipeline: MTLComputePipelineState?
    public private(set) var fusionGatherPipeline: MTLComputePipelineState?
    public private(set) var normalizeTonePipeline: MTLComputePipelineState?
    public private(set) var microContrastPipeline: MTLComputePipelineState?

    // Aliases for compatibility
    public var kernelSplatting2xPipeline: MTLComputePipelineState? { fusionGatherPipeline }
    public var appleP3ColorTransformPipeline: MTLComputePipelineState? { normalizeTonePipeline }

    public static let metalSourceCode: String = """
    #include <metal_stdlib>
    using namespace metal;

    inline float luma(float3 c) {
        return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    }
    inline float3 linearize(float3 c) {
        return select(c / 12.92f, pow((c + 0.055f) / 1.055f, float3(2.4f)),
                      c > float3(0.04045f));
    }
    inline float3 encodeP3(float3 c) {
        c = max(c, float3(0.0f));
        return select(c * 12.92f, 1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f,
                      c > float3(0.0031308f));
    }
    inline float3 bilinear(texture2d<float, access::read> tex, float2 position) {
        float2 p = clamp(position, float2(0.0f),
                         float2(tex.get_width() - 1, tex.get_height() - 1));
        uint2 a = uint2(floor(p));
        uint2 b = min(a + uint2(1), uint2(tex.get_width() - 1, tex.get_height() - 1));
        float2 t = p - float2(a);
        float3 top = mix(tex.read(a).rgb, tex.read(uint2(b.x, a.y)).rgb, t.x);
        float3 bottom = mix(tex.read(uint2(a.x, b.y)).rgb, tex.read(b).rgb, t.x);
        return mix(top, bottom, t.y);
    }

    kernel void computeLuminanceGradientEnergy(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        device float* energyOutput [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]],
        uint2 tgSize [[threads_per_threadgroup]],
        uint2 tgPos [[threadgroup_position_in_grid]],
        uint2 numGroups [[threadgroups_per_grid]]
    ) {
        float energy = 0.0f;
        if (gid.x > 0 && gid.y > 0 &&
            gid.x + 1 < inputTexture.get_width() &&
            gid.y + 1 < inputTexture.get_height()) {
            float dx = luma(inputTexture.read(gid + uint2(1, 0)).rgb) -
                       luma(inputTexture.read(gid - uint2(1, 0)).rgb);
            float dy = luma(inputTexture.read(gid + uint2(0, 1)).rgb) -
                       luma(inputTexture.read(gid - uint2(0, 1)).rgb);
            energy = (dx * dx + dy * dy) * 0.25f;
        }
        threadgroup float sharedEnergy[256];
        uint i = tid.y * tgSize.x + tid.x;
        sharedEnergy[i] = energy;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (i < stride) sharedEnergy[i] += sharedEnergy[i + stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (i == 0) {
            energyOutput[tgPos.y * numGroups.x + tgPos.x] = sharedEnergy[0];
        }
    }

    inline float patchError(texture2d<float, access::read> anchor,
                            texture2d<float, access::read> candidate,
                            float2 center, float2 offset) {
        float sum = 0.0f;
        uint samples = 0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 p = center + float2(x * 5, y * 5);
                float2 q = p + offset;
                if (p.x < 1 || p.y < 1 ||
                    p.x >= anchor.get_width() - 1 ||
                    p.y >= anchor.get_height() - 1 ||
                    q.x < 1 || q.y < 1 ||
                    q.x >= candidate.get_width() - 1 ||
                    q.y >= candidate.get_height() - 1) continue;
                sum += fabs(luma(anchor.read(uint2(p)).rgb) -
                            luma(bilinear(candidate, q)));
                samples++;
            }
        }
        return samples > 0 ? sum / float(samples) : 1.0f;
    }

    // One vector per 16 x 16 image block. A patch, rather than a single
    // pixel, constrains the search and preserves fractional offsets.
    kernel void subpixelLuminanceAlign(
        texture2d<float, access::read> anchor [[texture(0)]],
        texture2d<float, access::read> candidate [[texture(1)]],
        texture2d<float, access::write> motion [[texture(2)]],
        constant float2& prior [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= motion.get_width() || gid.y >= motion.get_height()) return;
        float2 center = float2(gid * 16 + 8);
        float2 base = floor(prior + 0.5f);
        float2 best = base;
        float error = 1.0f;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float2 offset = base + float2(x, y);
                float e = patchError(anchor, candidate, center, offset);
                if (e < error) { error = e; best = offset; }
            }
        }
        float left = patchError(anchor, candidate, center, best + float2(-1, 0));
        float right = patchError(anchor, candidate, center, best + float2(1, 0));
        float up = patchError(anchor, candidate, center, best + float2(0, -1));
        float down = patchError(anchor, candidate, center, best + float2(0, 1));
        float curvatureX = left + right - 2.0f * error;
        float curvatureY = up + down - 2.0f * error;
        if (curvatureX > 1e-4f)
            best.x += clamp(0.5f * (left - right) / curvatureX, -0.5f, 0.5f);
        if (curvatureY > 1e-4f)
            best.y += clamp(0.5f * (up - down) / curvatureY, -0.5f, 0.5f);
        float texture = 0.0f;
        if (center.x > 2 && center.y > 2 &&
            center.x + 2 < anchor.get_width() &&
            center.y + 2 < anchor.get_height()) {
            float centerLuma = luma(anchor.read(uint2(center)).rgb);
            texture = fabs(centerLuma - luma(anchor.read(uint2(center + float2(2, 0))).rgb)) +
                      fabs(centerLuma - luma(anchor.read(uint2(center + float2(0, 2))).rgb));
        }
        float confidence = clamp((0.16f - error) / 0.12f, 0.0f, 1.0f) *
                           clamp(texture / 0.025f, 0.0f, 1.0f);
        // Scalar Kalman measurement update for each axis: the synchronized
        // CoreMotion pose is the prediction and patch registration is the
        // measurement. Flat or inconsistent patches receive little weight.
        float priorVariance = 1.0f;
        float measurementVariance = 0.02f +
            20.0f * error * error / max(texture, 0.01f);
        float kalmanGain = priorVariance / (priorVariance + measurementVariance);
        best = prior + kalmanGain * (best - prior);
        motion.write(float4(best, error, confidence), gid);
    }

    // Gather real decoded sensor samples at fractional positions. The anchor
    // supplies a small full-coverage baseline; candidates use nearest source
    // samples so bilinear interpolation cannot erase their phase information.
    kernel void superResolutionFusionGather(
        texture2d<float, access::read> anchor [[texture(0)]],
        texture2d<float, access::read> candidate [[texture(1)]],
        texture2d<float, access::read> motion [[texture(2)]],
        texture2d<float, access::read> previous [[texture(3)]],
        texture2d<float, access::write> result [[texture(4)]],
        constant int& isAnchor [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= result.get_width() || gid.y >= result.get_height()) return;
        float2 p = (float2(gid) + 0.5f) *
                   float2(float(anchor.get_width()) / result.get_width(),
                          float(anchor.get_height()) / result.get_height()) - 0.5f;
        float3 anchorRGB = bilinear(anchor, p);
        float4 old = isAnchor ? float4(0.0f) : previous.read(gid);
        if (isAnchor) {
            result.write(float4(linearize(anchorRGB) * 0.55f, 0.55f), gid);
            return;
        }
        uint2 block = min(uint2(max(p, float2(0.0f))) / 16,
                          uint2(motion.get_width() - 1, motion.get_height() - 1));
        float4 vector = motion.read(block);
        float2 source = p + vector.xy;
        float2 rounded = floor(source + 0.5f);
        if (rounded.x < 0 || rounded.y < 0 ||
            rounded.x >= candidate.get_width() ||
            rounded.y >= candidate.get_height()) {
            result.write(old, gid);
            return;
        }
        float3 rgb = candidate.read(uint2(rounded)).rgb;
        float2 residual = source - rounded;
        float spatial = exp(-dot(residual, residual) / 0.22f);
        float difference = fabs(luma(rgb) - luma(anchorRGB));
        float colorDifference = max(max(fabs(rgb.r - anchorRGB.r),
                                        fabs(rgb.g - anchorRGB.g)),
                                    fabs(rgb.b - anchorRGB.b));
        float deghost = exp(-difference * difference / 0.015f -
                            colorDifference * colorDifference / 0.035f);
        float weight = spatial * deghost * vector.w;
        result.write(float4(old.rgb + linearize(rgb) * weight,
                            old.a + weight), gid);
    }

    // Only the RAW decoder performs exposure/tone mapping. This kernel
    // normalizes linear P3 samples and applies the P3 transfer function once.
    kernel void superResolutionNormalizeAndTone(
        texture2d<float, access::read> accumulated [[texture(0)]],
        texture2d<float, access::read> anchor [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float4 a = accumulated.read(gid);
        float3 linearRGB;
        if (a.a > 1e-5f) {
            linearRGB = a.rgb / a.a;
        } else {
            float2 p = (float2(gid) + 0.5f) *
                       float2(float(anchor.get_width()) / output.get_width(),
                              float(anchor.get_height()) / output.get_height()) - 0.5f;
            linearRGB = linearize(bilinear(anchor, p));
        }
        output.write(float4(clamp(encodeP3(linearRGB), 0.0f, 1.0f), 1.0f), gid);
    }
    """

    private init() {
        prepare()
    }

    public func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard library == nil else { return }

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            CameraLogger.error("Metal không khả dụng trên thiết bị này", category: .ai)
            return
        }
        self.device = defaultDevice

        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            let lib = try defaultDevice.makeLibrary(source: Self.metalSourceCode, options: options)
            self.library = lib

            if let f1 = lib.makeFunction(name: "computeLuminanceGradientEnergy") {
                gradientEnergyPipeline = try? defaultDevice.makeComputePipelineState(function: f1)
            }
            if let f2 = lib.makeFunction(name: "subpixelLuminanceAlign") {
                subpixelAlignPipeline = try? defaultDevice.makeComputePipelineState(function: f2)
            }
            if let f3 = lib.makeFunction(name: "computeLuminanceDeghostWeights") {
                deghostWeightsPipeline = try? defaultDevice.makeComputePipelineState(function: f3)
            }
            if let f4 = lib.makeFunction(name: "superResolutionFusionGather") {
                fusionGatherPipeline = try? defaultDevice.makeComputePipelineState(function: f4)
            }
            if let f5 = lib.makeFunction(name: "superResolutionNormalizeAndTone") {
                normalizeTonePipeline = try? defaultDevice.makeComputePipelineState(function: f5)
            }
            if let f6 = lib.makeFunction(name: "zeroMushinessMicroContrast") {
                microContrastPipeline = try? defaultDevice.makeComputePipelineState(function: f6)
            }
            CameraLogger.success("Đã biên dịch Metal kernels cho Super-Res Fusion", category: .ai)
        } catch {
            CameraLogger.error("Lỗi biên dịch Metal Shaders: \(error)", category: .ai)
        }
    }
}
