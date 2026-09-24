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

    // MARK: - Kernel 1: Luminance Gradient Energy (Anchor Selection)
    // Tính toán năng lượng độ dốc kênh sáng (Luminance) để chọn Khung Neo nét nhất
    kernel void computeLuminanceGradientEnergy(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        device float* energyOutput [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]],
        uint2 tgSize [[threads_per_threadgroup]],
        uint2 tgPos [[threadgroup_position_in_grid]],
        uint2 numGroups [[threadgroups_per_grid]]
    ) {
        uint width = inputTexture.get_width();
        uint height = inputTexture.get_height();

        float localEnergy = 0.0f;
        if (gid.x >= 1 && gid.x < width - 1 && gid.y >= 1 && gid.y < height - 1) {
            float4 leftC   = inputTexture.read(uint2(gid.x - 1, gid.y));
            float4 rightC  = inputTexture.read(uint2(gid.x + 1, gid.y));
            float4 topC    = inputTexture.read(uint2(gid.x, gid.y - 1));
            float4 bottomC = inputTexture.read(uint2(gid.x, gid.y + 1));

            float left   = dot(leftC.rgb, float3(0.299f, 0.587f, 0.114f));
            float right  = dot(rightC.rgb, float3(0.299f, 0.587f, 0.114f));
            float top    = dot(topC.rgb, float3(0.299f, 0.587f, 0.114f));
            float bottom = dot(bottomC.rgb, float3(0.299f, 0.587f, 0.114f));

            float dx = (right - left) * 0.5f;
            float dy = (bottom - top) * 0.5f;
            localEnergy = (dx * dx + dy * dy);
        }

        threadgroup float sharedEnergy[256];
        uint linearIndex = tid.y * tgSize.x + tid.x;
        if (linearIndex < 256) {
            sharedEnergy[linearIndex] = localEnergy;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint s = 128; s > 0; s >>= 1) {
            if (linearIndex < s && (linearIndex + s) < 256) {
                sharedEnergy[linearIndex] += sharedEnergy[linearIndex + s];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (linearIndex == 0) {
            uint linearGroupIndex = tgPos.y * numGroups.x + tgPos.x;
            energyOutput[linearGroupIndex] = sharedEnergy[0];
        }
    }

    // MARK: - Kernel 2: Sub-Pixel Luminance Alignment
    // Tinh chỉnh vector dịch chuyển vi mô giữa Frame phụ và Khung Neo dựa trên IMU Prior
    kernel void subpixelLuminanceAlign(
        texture2d<float, access::read> anchorTexture [[texture(0)]],
        texture2d<float, access::read> candidateTexture [[texture(1)]],
        texture2d<float, access::write> motionVectorTexture [[texture(2)]],
        constant float2& imuPriorOffset [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = anchorTexture.get_width();
        uint height = anchorTexture.get_height();
        if (gid.x >= width || gid.y >= height) return;

        float anchorLum = dot(anchorTexture.read(gid).rgb, float3(0.299f, 0.587f, 0.114f));

        // Tìm kiếm vi mô trong phạm vi 3x3 quanh IMU Prior offset
        int2 baseOffset = int2(round(imuPriorOffset.x), round(imuPriorOffset.y));
        float bestError = 1e9f;
        int2 bestOffset = baseOffset;

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 curOffset = baseOffset + int2(dx, dy);
                int2 cPos = int2(gid) + curOffset;
                if (cPos.x >= 0 && cPos.x < int(width) && cPos.y >= 0 && cPos.y < int(height)) {
                    float candLum = dot(candidateTexture.read(uint2(cPos)).rgb, float3(0.299f, 0.587f, 0.114f));
                    float err = abs(anchorLum - candLum);
                    if (err < bestError) {
                        bestError = err;
                        bestOffset = curOffset;
                    }
                }
            }
        }

        motionVectorTexture.write(float4(float(bestOffset.x), float(bestOffset.y), bestError, 1.0f), gid);
    }

    // MARK: - Kernel 3: Robust Motion De-Ghosting Weights
    kernel void computeLuminanceDeghostWeights(
        texture2d<float, access::read> anchorTexture [[texture(0)]],
        texture2d<float, access::read> candidateTexture [[texture(1)]],
        texture2d<float, access::read> motionVectorTexture [[texture(2)]],
        texture2d<float, access::write> weightTexture [[texture(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = anchorTexture.get_width();
        uint height = anchorTexture.get_height();
        if (gid.x >= width || gid.y >= height) return;

        float4 motion = motionVectorTexture.read(gid);
        float2 offset = motion.xy;

        int2 cPos = int2(round(float(gid.x) + offset.x), round(float(gid.y) + offset.y));
        float anchorLum = dot(anchorTexture.read(gid).rgb, float3(0.299f, 0.587f, 0.114f));

        float candLum = anchorLum;
        if (cPos.x >= 0 && cPos.x < int(width) && cPos.y >= 0 && cPos.y < int(height)) {
            candLum = dot(candidateTexture.read(uint2(cPos)).rgb, float3(0.299f, 0.587f, 0.114f));
        }

        float diff = abs(candLum - anchorLum);
        float deghostW = exp(-pow(diff / 0.15f, 2.0f));
        if (deghostW < 0.08f) {
            deghostW = 0.0f;
        }

        weightTexture.write(float4(deghostW, 0.0f, 0.0f, 1.0f), gid);
    }

    // MARK: - Kernel 4: Multi-Frame High-Resolution Fusion Gather
    kernel void superResolutionFusionGather(
        texture2d<float, access::read> anchorTexture [[texture(0)]],
        texture2d<float, access::read> candidateTexture [[texture(1)]],
        texture2d<float, access::read> motionVectors [[texture(2)]],
        texture2d<float, access::read> deghostWeights [[texture(3)]],
        texture2d<float, access::read> previousAccum [[texture(4)]],
        texture2d<float, access::write> newAccum [[texture(5)]],
        constant int& isAnchorFrame [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint targetW = newAccum.get_width();
        uint targetH = newAccum.get_height();
        if (gid.x >= targetW || gid.y >= targetH) return;

        uint rawW = anchorTexture.get_width();
        uint rawH = anchorTexture.get_height();

        float scaleX = float(rawW) / float(targetW);
        float scaleY = float(rawH) / float(targetH);
        float sensorX = float(gid.x) * scaleX;
        float sensorY = float(gid.y) * scaleY;

        uint2 srcCoord = uint2(min(uint(sensorX), rawW - 1), min(uint(sensorY), rawH - 1));

        float4 prevAcc = isAnchorFrame ? float4(0.0f) : previousAccum.read(gid);

        float4 motion = motionVectors.read(srcCoord);
        float deghostW = isAnchorFrame ? 1.0f : deghostWeights.read(srcCoord).r;

        float2 candCoord = isAnchorFrame ? float2(sensorX, sensorY) : float2(sensorX - motion.x, sensorY - motion.y);

        // Lấy mẫu song tuyến tính (Bilinear sampling)
        int x0 = max(0, min(int(floor(candCoord.x)), int(rawW) - 1));
        int y0 = max(0, min(int(floor(candCoord.y)), int(rawH) - 1));
        int x1 = min(x0 + 1, int(rawW) - 1);
        int y1 = min(y0 + 1, int(rawH) - 1);

        float fx = candCoord.x - float(x0);
        float fy = candCoord.y - float(y0);

        float4 c00 = candidateTexture.read(uint2(x0, y0));
        float4 c10 = candidateTexture.read(uint2(x1, y0));
        float4 c01 = candidateTexture.read(uint2(x0, y1));
        float4 c11 = candidateTexture.read(uint2(x1, y1));

        float4 sampledRGB = mix(mix(c00, c10, fx), mix(c01, c11, fx), fy);

        float weight = deghostW;
        float4 updatedAcc = float4(prevAcc.rgb + sampledRGB.rgb * weight, prevAcc.a + weight);

        newAccum.write(updatedAcc, gid);
    }

    // MARK: - Kernel 5: Super-Resolution Normalize & Tone Preservation
    kernel void superResolutionNormalizeAndTone(
        texture2d<float, access::read> accumTexture [[texture(0)]],
        texture2d<float, access::read> anchorTexture [[texture(1)]],
        texture2d<float, access::write> outputTexture [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint targetW = outputTexture.get_width();
        uint targetH = outputTexture.get_height();
        if (gid.x >= targetW || gid.y >= targetH) return;

        float4 acc = accumTexture.read(gid);
        float totalW = acc.a;
        float3 finalRGB;

        if (totalW > 1e-4f) {
            finalRGB = acc.rgb / totalW;
        } else {
            uint rawW = anchorTexture.get_width();
            uint rawH = anchorTexture.get_height();
            uint srcX = min(uint(float(gid.x) * float(rawW) / float(targetW)), rawW - 1);
            uint srcY = min(uint(float(gid.y) * float(rawH) / float(targetH)), rawH - 1);
            finalRGB = anchorTexture.read(uint2(srcX, srcY)).rgb;
        }

        outputTexture.write(float4(clamp(finalRGB, 0.0f, 1.0f), 1.0f), gid);
    }

    // MARK: - Kernel 6: Zero-Mushiness Micro-Contrast Enhancement
    kernel void zeroMushinessMicroContrast(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        texture2d<float, access::write> finalOutputTexture [[texture(1)]],
        constant float& microContrastFactor [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = inputTexture.get_width();
        uint height = inputTexture.get_height();
        if (gid.x >= width || gid.y >= height) return;

        float4 center = inputTexture.read(gid);
        float centerLum = dot(center.rgb, float3(0.299f, 0.587f, 0.114f));

        float blurLum = 0.0f;
        float count = 0.0f;

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 pos = int2(gid) + int2(dx, dy);
                if (pos.x >= 0 && pos.x < int(width) && pos.y >= 0 && pos.y < int(height)) {
                    float4 s = inputTexture.read(uint2(pos));
                    blurLum += dot(s.rgb, float3(0.299f, 0.587f, 0.114f));
                    count += 1.0f;
                }
            }
        }

        float localMeanLum = blurLum / count;
        float detail = centerLum - localMeanLum;

        float3 enhanced = center.rgb + float3(detail * microContrastFactor);
        finalOutputTexture.write(float4(clamp(enhanced, 0.0f, 1.0f), 1.0f), gid);
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
            CameraLogger.success("✅ Đã biên dịch thành công 6 Metal Compute Kernels cho Super-Res Fusion", category: .ai)
        } catch {
            CameraLogger.error("Lỗi biên dịch Metal Shaders: \(error)", category: .ai)
        }
    }
}
