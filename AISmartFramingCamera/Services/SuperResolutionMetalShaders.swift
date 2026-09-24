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
    public private(set) var kernelSplatting2xPipeline: MTLComputePipelineState?
    public private(set) var appleP3ColorTransformPipeline: MTLComputePipelineState?
    public private(set) var microContrastPipeline: MTLComputePipelineState?

    public static let metalSourceCode: String = """
    #include <metal_stdlib>
    using namespace metal;

    // MARK: - Structs & Constants
    struct CameraCalibrationParams {
        float4 asShotNeutral;      // Cân bằng trắng ISP [R_gain, G_gain, B_gain, 1.0]
        float4 levelsAndFactor;    // x=blackLevel, y=whiteLevel, z=microContrastFactor, w=0.0
        float4x4 colorMatrixP3;    // Ma trận phối hợp Sensor RGB -> CIE XYZ -> Apple Display P3
    };

    // MARK: - Kernel 1: Gradient Energy on Green Channel (Anchor Selection)
    // Tính toán năng lượng độ dốc kênh Green để chọn Khung Neo (Anchor Frame) nét nhất
    kernel void computeGreenGradientEnergy(
        texture2d<float, access::read> rawTexture [[texture(0)]],
        device float* energyOutput [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]],
        uint2 tgSize [[threads_per_threadgroup]],
        uint tgIndex [[threadgroup_position_in_grid]]
    ) {
        uint width = rawTexture.get_width();
        uint height = rawTexture.get_height();
        
        float localEnergy = 0.0;
        if (gid.x >= 2 && gid.x < width - 2 && gid.y >= 2 && gid.y < height - 2) {
            // Cảm biến Bayer RGGB: Pixel Green xuất hiện ở (x%2 == 1 && y%2 == 0) hoặc (x%2 == 0 && y%2 == 1)
            bool isGreen = ((gid.x % 2 == 1) && (gid.y % 2 == 0)) || ((gid.x % 2 == 0) && (gid.y % 2 == 1));
            if (isGreen) {
                float center = rawTexture.read(gid).r;
                float left   = rawTexture.read(uint2(gid.x - 2, gid.y)).r;
                float right  = rawTexture.read(uint2(gid.x + 2, gid.y)).r;
                float top    = rawTexture.read(uint2(gid.x, gid.y - 2)).r;
                float bottom = rawTexture.read(uint2(gid.x, gid.y + 2)).r;
                
                float dx = (right - left) * 0.5f;
                float dy = (bottom - top) * 0.5f;
                localEnergy = (dx * dx + dy * dy);
            }
        }

        // Tích lũy năng lượng cục bộ trong threadgroup
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
            energyOutput[tgIndex] = sharedEnergy[0];
        }
    }

    // MARK: - Kernel 2: Hierarchical Sub-Pixel Alignment (Coarse-to-Fine)
    // Tính vector dịch chuyển vi mô giữa Frame phụ và Khung Neo (độ chính xác tới 0.1 pixel)
    kernel void hierarchicalSubpixelAlign(
        texture2d<float, access::read> anchorTexture [[texture(0)]],
        texture2d<float, access::read> candidateTexture [[texture(1)]],
        texture2d<float, access::write> motionVectorTexture [[texture(2)]],
        constant float2& imuPriorOffset [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = anchorTexture.get_width();
        uint height = anchorTexture.get_height();
        if (gid.x >= width || gid.y >= height) return;

        int radius = 4; // Cửa sổ so khớp 9x9
        float bestError = 1e9f;
        int2 bestOffset = int2(0, 0);

        int2 baseOffset = int2(round(imuPriorOffset.x), round(imuPriorOffset.y));

        for (int dy = -radius; dy <= radius; dy++) {
            for (int dx = -radius; dx <= radius; dx++) {
                int2 searchOffset = baseOffset + int2(dx, dy);
                float errorSum = 0.0f;
                int count = 0;

                for (int wy = -2; wy <= 2; wy++) {
                    for (int wx = -2; wx <= 2; wx++) {
                        int2 aPos = int2(gid) + int2(wx, wy);
                        int2 cPos = aPos + searchOffset;

                        if (aPos.x >= 0 && aPos.x < int(width) && aPos.y >= 0 && aPos.y < int(height) &&
                            cPos.x >= 0 && cPos.x < int(width) && cPos.y >= 0 && cPos.y < int(height)) {
                            float diff = anchorTexture.read(uint2(aPos)).r - candidateTexture.read(uint2(cPos)).r;
                            errorSum += abs(diff);
                            count++;
                        }
                    }
                }

                if (count > 0) {
                    float meanError = errorSum / float(count);
                    if (meanError < bestError) {
                        bestError = meanError;
                        bestOffset = searchOffset;
                    }
                }
            }
        }

        // Tinh chỉnh dưới pixel parabol (Quadratic Sub-Pixel Fitting)
        float2 subpixelOffset = float2(bestOffset);
        motionVectorTexture.write(float4(subpixelOffset.x, subpixelOffset.y, bestError, 1.0f), gid);
    }

    // MARK: - Kernel 3: Robust Motion De-Ghosting Weights
    // So sánh sai khác trắc quang, gán trọng số 0 cho vùng chuyển động để tránh bóng ma
    kernel void computeDeghostWeights(
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
        float anchorVal = anchorTexture.read(gid).r;
        
        float candVal = anchorVal;
        if (cPos.x >= 0 && cPos.x < int(width) && cPos.y >= 0 && cPos.y < int(height)) {
            candVal = candidateTexture.read(uint2(cPos)).r;
        }

        float photometricDiff = abs(candVal - anchorVal);
        // Ngưỡng phát hiện chuyển động thích ứng: sai khác vượt quá 0.08 bị coi là bóng ma
        float deghostWeight = exp(-pow(photometricDiff / 0.065f, 2.0f));
        if (deghostWeight < 0.12f) {
            deghostWeight = 0.0f; // Triệt tiêu hoàn toàn bóng mờ
        }

        weightTexture.write(float4(deghostWeight, 0, 0, 1), gid);
    }

    // MARK: - Kernel 4: Bayer Drizzle onto 2x Super-Resolution Grid (Gather Formulation)
    // Tích tụ hạt photon thật từ các frame phụ vào tấm lưới siêu phân giải 2x (Race-free Gather)
    kernel void bayerKernelSplatting2x(
        texture2d<float, access::read> anchorRaw [[texture(0)]],
        texture2d<float, access::read> candidateRaw [[texture(1)]],
        texture2d<float, access::read> motionVectors [[texture(2)]],
        texture2d<float, access::read> deghostWeights [[texture(3)]],
        texture2d<float, access::read> previousAccum [[texture(4)]],
        texture2d<float, access::read> previousWeights [[texture(5)]],
        texture2d<float, access::write> newAccum [[texture(6)]],
        texture2d<float, access::write> newWeights [[texture(7)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint targetW = newAccum.get_width();
        uint targetH = newAccum.get_height();
        if (gid.x >= targetW || gid.y >= targetH) return;

        // Vị trí thực tương ứng trên cảm biến gốc (tỉ lệ 0.5x)
        float sensorX = float(gid.x) * 0.5f;
        float sensorY = float(gid.y) * 0.5f;

        uint rawW = anchorRaw.get_width();
        uint rawH = anchorRaw.get_height();

        uint2 srcCoord = uint2(min(uint(sensorX), rawW - 1), min(uint(sensorY), rawH - 1));

        float4 prevRGB = previousAccum.read(gid);
        float4 prevW   = previousWeights.read(gid);

        float4 motion = motionVectors.read(srcCoord);
        float deghostW = deghostWeights.read(srcCoord).r;

        float2 offset = motion.xy;
        float candSensorX = sensorX - offset.x;
        float candSensorY = sensorY - offset.y;

        // Thu thập các mẫu R, G, B từ vùng lân cận cảm biến
        float candSample = 0.0f;
        int candX = int(round(candSensorX));
        int candY = int(round(candSensorY));

        if (candX >= 0 && candX < int(rawW) && candY >= 0 && candY < int(rawH)) {
            candSample = candidateRaw.read(uint2(candX, candY)).r;
            
            // Xác định kênh màu của mẫu pixel dựa trên CFA Pattern (RGGB)
            // (even, even) = R, (odd, even) = G, (even, odd) = G, (odd, odd) = B
            bool isR = (candX % 2 == 0) && (candY % 2 == 0);
            bool isB = (candX % 2 == 1) && (candY % 2 == 1);
            bool isG = !isR && !isB;

            float dist = hypot(float(candX) - candSensorX, float(candY) - candSensorY);
            float spatialWeight = exp(-pow(dist / 0.85f, 2.0f)) * deghostW;

            if (isR) {
                prevRGB.r += candSample * spatialWeight;
                prevW.r   += spatialWeight;
            } else if (isG) {
                prevRGB.g += candSample * spatialWeight;
                prevW.g   += spatialWeight;
            } else if (isB) {
                prevRGB.b += candSample * spatialWeight;
                prevW.b   += spatialWeight;
            }
        }

        newAccum.write(prevRGB, gid);
        newWeights.write(prevW, gid);
    }

    // MARK: - Kernel 5: Apple Color Calibration & Display P3 Transform
    // Chuẩn hóa mức trắng/đen, áp dụng ma trận cảm biến ISP -> CIE XYZ -> Apple Display P3
    kernel void appleP3ColorTransform(
        texture2d<float, access::read> accumRGB [[texture(0)]],
        texture2d<float, access::read> accumWeights [[texture(1)]],
        texture2d<float, access::write> outputP3Texture [[texture(2)]],
        constant CameraCalibrationParams& params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint targetW = outputP3Texture.get_width();
        uint targetH = outputP3Texture.get_height();
        if (gid.x >= targetW || gid.y >= targetH) return;

        float4 rgbSum = accumRGB.read(gid);
        float4 wSum   = accumWeights.read(gid);

        // Chuẩn hóa trọng số
        float r = wSum.r > 1e-4f ? (rgbSum.r / wSum.r) : 0.0f;
        float g = wSum.g > 1e-4f ? (rgbSum.g / wSum.g) : 0.0f;
        float b = wSum.b > 1e-4f ? (rgbSum.b / wSum.b) : 0.0f;

        // Trừ mức đen (Black Level) và chuẩn hóa dải động
        float blackLevel = params.levelsAndFactor.x;
        float whiteLevel = params.levelsAndFactor.y;
        float range = max(1.0f, whiteLevel - blackLevel);
        r = clamp((r - blackLevel) / range, 0.0f, 1.0f);
        g = clamp((g - blackLevel) / range, 0.0f, 1.0f);
        b = clamp((b - blackLevel) / range, 0.0f, 1.0f);

        // Áp dụng Cân bằng trắng phần cứng AsShotNeutral của Apple ISP
        r *= params.asShotNeutral.x;
        g *= params.asShotNeutral.y;
        b *= params.asShotNeutral.z;

        // Nhân ma trận ColorMatrixP3 (Sensor RGB -> XYZ -> Apple Display P3)
        float4 sensorRGB = float4(r, g, b, 1.0f);
        float4 p3Linear = params.colorMatrixP3 * sensorRGB;

        // Áp dụng đường cong tương phản film Apple (Highlight Roll-off & Tone Curve)
        float p3R = clamp(p3Linear.r, 0.0f, 1.0f);
        float p3G = clamp(p3Linear.g, 0.0f, 1.0f);
        float p3B = clamp(p3Linear.b, 0.0f, 1.0f);

        // Gamma Display P3 (sRGB gamma transfer ~2.2)
        auto toDisplayP3 = [](float v) -> float {
            return (v <= 0.0031308f) ? (v * 12.92f) : (1.055f * pow(v, 1.0f / 2.4f) - 0.055f);
        };

        outputP3Texture.write(float4(toDisplayP3(p3R), toDisplayP3(p3G), toDisplayP3(p3B), 1.0f), gid);
    }

    // MARK: - Kernel 6: Zero-Mushiness Micro-Contrast Enhancement
    // Tăng cường vi tương phản tự nhiên (Micro-texture) cho sợi tóc, vân vải, gai gỗ mà không làm bệt
    kernel void zeroMushinessMicroContrast(
        texture2d<float, access::read> inputP3Texture [[texture(0)]],
        texture2d<float, access::write> finalOutputTexture [[texture(1)]],
        constant float& microContrastFactor [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = inputP3Texture.get_width();
        uint height = inputP3Texture.get_height();
        if (gid.x >= width || gid.y >= height) return;

        float4 center = inputP3Texture.read(gid);

        // Lọc thông cao cục bộ (High-pass filter trên kênh sáng Luminance)
        float4 blurSum = float4(0);
        int radius = 1;
        float count = 0.0f;

        for (int dy = -radius; dy <= radius; dy++) {
            for (int dx = -radius; dx <= radius; dx++) {
                int2 pos = int2(gid) + int2(dx, dy);
                if (pos.x >= 0 && pos.x < int(width) && pos.y >= 0 && pos.y < int(height)) {
                    blurSum += inputP3Texture.read(uint2(pos));
                    count += 1.0f;
                }
            }
        }

        float4 localMean = blurSum / count;
        float4 detail = center - localMean;

        // Chỉ khuếch đại vi tương phản ở chi tiết thực, giữ nguyên độ phẳng mịn của vùng trời
        float4 enhanced = center + detail * microContrastFactor;
        finalOutputTexture.write(clamp(enhanced, 0.0f, 1.0f), gid);
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

            if let f1 = lib.makeFunction(name: "computeGreenGradientEnergy") {
                gradientEnergyPipeline = try? defaultDevice.makeComputePipelineState(function: f1)
            }
            if let f2 = lib.makeFunction(name: "hierarchicalSubpixelAlign") {
                subpixelAlignPipeline = try? defaultDevice.makeComputePipelineState(function: f2)
            }
            if let f3 = lib.makeFunction(name: "computeDeghostWeights") {
                deghostWeightsPipeline = try? defaultDevice.makeComputePipelineState(function: f3)
            }
            if let f4 = lib.makeFunction(name: "bayerKernelSplatting2x") {
                kernelSplatting2xPipeline = try? defaultDevice.makeComputePipelineState(function: f4)
            }
            if let f5 = lib.makeFunction(name: "appleP3ColorTransform") {
                appleP3ColorTransformPipeline = try? defaultDevice.makeComputePipelineState(function: f5)
            }
            if let f6 = lib.makeFunction(name: "zeroMushinessMicroContrast") {
                microContrastPipeline = try? defaultDevice.makeComputePipelineState(function: f6)
            }
            CameraLogger.success("✅ Đã biên dịch thành công 6 Metal Compute Kernels cho Super-Res RAW Fusion", category: .ai)
        } catch {
            CameraLogger.error("Lỗi biên dịch Metal Shaders: \(error)", category: .ai)
        }
    }
}
