import Foundation
import CoreImage
import Metal
import simd

/// Uniforms 16-byte aligned dùng chung giữa Swift và Metal Compute Shader cho 3 nhân Filmic Color Science.
private struct FilmicGamutUniforms {
    var params: SIMD4<Float> // (threshold, gamutStrength, 0, 0)
}

private struct FilmicLocalToneUniforms {
    var params: SIMD4<Float> // (shadows, highlights, chromaProtect, 0)
}

private struct FilmicMatteExposureUniforms {
    var params: SIMD4<Float> // (fade, exposure, 0, 0)
}

/// Bộ biên dịch & đệm runtime MTLComputePipelineState theo từng MTLDevice (thread-safe, không cần `-fcikernel`).
private final class FilmicColorSciencePipelineCache: @unchecked Sendable {
    static let shared = FilmicColorSciencePipelineCache()

    private let lock = NSLock()
    private var libraries: [ObjectIdentifier: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var failedDevices: Set<ObjectIdentifier> = []

    /// 3 Single-Pass Metal Compute Kernels chạy trực tiếp trong không gian Extended Linear sRGB (`.RGBAh`):
    /// 1. `filmicGamutHighlightProtect`: Nén gamut Display P3 âm (bảo toàn luma/hue) + C1 rational highlight rolloff trước 3D LUT.
    /// 2. `filmicLocalShadowHighlightYIQ`: Phục hồi Vùng tối & Vùng sáng cục bộ trong không gian YIQ có bù sắc độ tránh xám bệt.
    /// 3. `filmicMatteFadeAndExposure`: Độ phai giấy ảnh cổ điển bậc 3 đơn điệu nghiêm ngặt + phơi sáng filmic chống cháy trắng.
    private static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct FilmicGamutUniforms {
        float4 params; // x = threshold, y = gamutStrength
    };

    struct FilmicLocalToneUniforms {
        float4 params; // x = shadows, y = highlights, z = chromaProtect
    };

    struct FilmicMatteExposureUniforms {
        float4 params; // x = fade, y = exposure
    };

    inline float3 linearToSRGBExact(float3 lin) {
        float3 c = clamp(lin, 0.0f, 1.0f);
        float3 lo = c * 12.92f;
        float3 hi = 1.055f * pow(max(c, float3(1e-6f)), float3(1.0f / 2.4f)) - 0.055f;
        return select(hi, lo, c <= float3(0.0031308f));
    }

    inline float3 srgbToLinearExact(float3 s) {
        float3 c = clamp(s, 0.0f, 1.0f);
        float3 lo = c / 12.92f;
        float3 hi = pow(max((c + 0.055f) / 1.055f, float3(0.0f)), float3(2.4f));
        return select(hi, lo, c <= float3(0.04045f));
    }

    // 1. Pre-LUT Gamut Compression (Display P3 negative channel rescue) + C1 Rational Highlight Rolloff
    kernel void filmicGamutHighlightProtect(
        texture2d<float, access::read>  inTexture  [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        constant FilmicGamutUniforms&   u          [[buffer(0)]],
        uint2                           gid        [[thread_position_in_grid]]
    ) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }
        uint2 inCoord = uint2(
            min(gid.x, max(1u, inTexture.get_width()) - 1u),
            min(gid.y, max(1u, inTexture.get_height()) - 1u)
        );
        float4 raw = inTexture.read(inCoord);
        float alpha = raw.a;
        if (alpha <= 1e-5f) {
            outTexture.write(raw, gid);
            return;
        }

        float3 c = raw.rgb / alpha;
        float threshold = clamp(u.params.x, 0.55f, 0.96f);
        float gamutStrength = clamp(u.params.y, 0.0f, 1.0f);

        // Bước A: Kéo các kênh âm nhẹ của Display P3 về biên gamut [0, +inf) mà giữ nguyên Rec.709 luminance & sắc độ
        float minChan = min(c.r, min(c.g, c.b));
        if (minChan < 0.0f && gamutStrength > 0.001f) {
            float y = max(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f);
            float denom = max(y - minChan, 1e-5f);
            float3 compressed = max(y + (y / denom) * (c - y), float3(0.0f));
            c = mix(c, compressed, gamutStrength);
        }

        // Bước B: Nén mượt C1 vùng highlight vượt ngưỡng threshold về tiệm cận 1.0 (chống gãy dải sáng khi vào 3D LUT)
        float maxChan = max(c.r, max(c.g, c.b));
        if (maxChan > threshold) {
            float over = maxChan - threshold;
            float headroom = max(0.04f, 1.0f - threshold);
            float rolled = threshold + (over * headroom) / (over + headroom);
            c *= (rolled / max(maxChan, 1e-5f));
        }

        c = clamp(c, float3(0.0f), float3(1.0f));
        if (!all(isfinite(c))) {
            c = clamp(raw.rgb / alpha, float3(0.0f), float3(1.0f));
        }
        outTexture.write(float4(c * alpha, alpha), gid);
    }

    // 2. Local YIQ Shadow & Highlight Recovery với bù sắc độ nghịch đảo/tỷ lệ (tránh bệt xám & cháy bệt)
    kernel void filmicLocalShadowHighlightYIQ(
        texture2d<float, access::read>  inTexture   [[texture(0)]],
        texture2d<float, access::read>  blurTexture [[texture(1)]],
        texture2d<float, access::write> outTexture  [[texture(2)]],
        constant FilmicLocalToneUniforms& u         [[buffer(0)]],
        uint2                           gid         [[thread_position_in_grid]]
    ) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }
        uint2 inCoord = uint2(
            min(gid.x, max(1u, inTexture.get_width()) - 1u),
            min(gid.y, max(1u, inTexture.get_height()) - 1u)
        );
        uint2 blurCoord = uint2(
            min(gid.x, max(1u, blurTexture.get_width()) - 1u),
            min(gid.y, max(1u, blurTexture.get_height()) - 1u)
        );

        float4 raw = inTexture.read(inCoord);
        float alpha = raw.a;
        if (alpha <= 1e-5f) {
            outTexture.write(raw, gid);
            return;
        }

        float shadows = clamp(u.params.x, -1.0f, 1.0f);
        float highlights = clamp(u.params.y, -1.0f, 1.0f);
        if (abs(shadows) < 0.002f && abs(highlights) < 0.002f) {
            outTexture.write(raw, gid);
            return;
        }

        float3 origLinear = raw.rgb / alpha;
        float4 rawBlur = blurTexture.read(blurCoord);
        float blurAlpha = max(rawBlur.a, 1e-5f);
        float3 blurLinear = rawBlur.rgb / blurAlpha;

        // Chuyển sang miền cảm thụ Gamma 2.0 (sqrt) -> NTSC YIQ chính xác (sai số đảo 8.88e-16)
        float3 srcG = sqrt(max(origLinear, float3(0.0f)));
        float3 blrG = sqrt(max(blurLinear, float3(0.0f)));

        float Y = 0.2990f * srcG.r + 0.5870f * srcG.g + 0.1140f * srcG.b;
        float I = 0.5959f * srcG.r - 0.2746f * srcG.g - 0.3213f * srcG.b;
        float Q = 0.2115f * srcG.r - 0.5227f * srcG.g + 0.3112f * srcG.b;

        float yBlur = clamp(0.2990f * blrG.r + 0.5870f * blrG.g + 0.1140f * blrG.b, 0.0f, 1.0f);
        float invMask = 1.0f - yBlur;

        // Trọng số cục bộ trơn không gây quầng halo
        float wShadow = smoothstep(0.30f, 0.85f, invMask);
        float wHighlight = smoothstep(0.30f, 0.85f, yBlur);

        float yNew = clamp(Y, 0.0f, 2.0f);
        float iNew = I;
        float qNew = Q;

        // Phục hồi Vùng tối cục bộ (Shadows)
        if (abs(shadows) >= 0.002f) {
            float expS = (shadows >= 0.0f) ? (1.0f / (1.0f + shadows * 1.15f)) : (1.0f - shadows * 1.15f);
            float yLifted = pow(max(yNew, 1e-5f), expS);
            float yAfter = mix(yNew, yLifted, wShadow);
            float ratioS = clamp(yAfter / max(yNew, 0.04f), 0.75f, 1.45f);
            float chromaBoost = 1.0f + (ratioS - 1.0f) * 0.55f * wShadow;
            iNew *= chromaBoost;
            qNew *= chromaBoost;
            yNew = yAfter;
        }

        // Phục hồi Vùng sáng cục bộ (Highlights) kèm bù sắc độ nghịch đảo chống xám mây/da
        if (abs(highlights) >= 0.002f) {
            float clampedY = min(yNew, 0.999f);
            if (highlights < 0.0f) {
                float amt = -highlights;
                float yRec = 1.0f - pow(max(1.0f - clampedY, 1e-5f), 1.0f / (1.0f + amt * 1.10f));
                float yAfter = mix(yNew, yRec, wHighlight);
                float ratioH = clamp((1.0f - yAfter) / max(1.0f - clampedY, 0.06f), 0.80f, 1.50f);
                float chromaBoost = 1.0f + (ratioH - 1.0f) * 0.65f * wHighlight;
                iNew *= chromaBoost;
                qNew *= chromaBoost;
                yNew = yAfter;
            } else {
                float amt = highlights;
                float yBright = 1.0f - pow(max(1.0f - clampedY, 1e-5f), 1.0f + amt * 0.95f);
                yNew = mix(yNew, yBright, wHighlight);
            }
        }

        // Ma trận đảo YIQ -> RGB chuẩn kiểm chứng np.linalg.inv
        float3 outG = float3(
            yNew + 0.95605023f * iNew + 0.62075494f * qNew,
            yNew - 0.27205234f * iNew - 0.64720571f * qNew,
            yNew - 1.10670432f * iNew + 1.70442128f * qNew
        );
        outG = max(outG, float3(0.0f));
        float3 outLinear = outG * outG;

        // Bảo toàn thành phần rộng của Display P3 vượt ngoài [0, 1] khi cần
        if (!all(isfinite(outLinear))) {
            outLinear = origLinear;
        }
        outTexture.write(float4(outLinear * alpha, alpha), gid);
    }

    // 3. Vintage Cubic Matte Film Fade (đơn điệu tuyệt đối) + Non-Clipping Filmic Exposure
    kernel void filmicMatteFadeAndExposure(
        texture2d<float, access::read>  inTexture  [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        constant FilmicMatteExposureUniforms& u    [[buffer(0)]],
        uint2                           gid        [[thread_position_in_grid]]
    ) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }
        uint2 inCoord = uint2(
            min(gid.x, max(1u, inTexture.get_width()) - 1u),
            min(gid.y, max(1u, inTexture.get_height()) - 1u)
        );
        float4 raw = inTexture.read(inCoord);
        float alpha = raw.a;
        if (alpha <= 1e-5f) {
            outTexture.write(raw, gid);
            return;
        }

        float fade = clamp(u.params.x, 0.0f, 1.0f);
        float exposure = clamp(u.params.y, -1.2f, 1.2f);
        if (fade < 0.002f && abs(exposure) < 0.002f) {
            outTexture.write(raw, gid);
            return;
        }

        float3 origLinear = raw.rgb / alpha;
        float3 s = linearToSRGBExact(origLinear);

        // Non-clipping filmic exposure: 1 - (1 - c)^p bảo vệ tuyệt đối vùng sáng không cháy trắng
        if (abs(exposure) >= 0.002f) {
            float p = (exposure >= 0.0f) ? (1.0f + 1.045f * exposure) : (1.0f / (1.0f + 1.045f * (-exposure)));
            s = 1.0f - pow(max(1.0f - s, float3(0.0f)), float3(p));
        }

        // Vintage matte paper fade: đường cong Hermite bậc 3 đơn điệu nghiêm ngặt (toe 0.145, shoulder 0.925, slope > 0.42)
        if (fade >= 0.002f) {
            float3 s2 = s * s;
            float3 s3 = s2 * s;
            float3 faded = (-0.68f * s3) + (1.04f * s2) + (0.42f * s) + float3(0.145f);
            s = mix(s, clamp(faded, float3(0.0f), float3(1.0f)), fade);
        }

        float3 outLinear = srgbToLinearExact(s);
        if (!all(isfinite(outLinear))) {
            outLinear = origLinear;
        }
        outTexture.write(float4(outLinear * alpha, alpha), gid);
    }
    """

    func pipeline(named functionName: String, for device: MTLDevice) -> MTLComputePipelineState? {
        let devId = ObjectIdentifier(device)
        let cacheKey = "\(devId.hashValue)_\(functionName)"
        lock.lock()
        defer { lock.unlock() }

        if let cached = pipelines[cacheKey] { return cached }
        if failedDevices.contains(devId) { return nil }

        let library: MTLLibrary
        if let existing = libraries[devId] {
            library = existing
        } else {
            do {
                let compiled = try device.makeLibrary(source: Self.metalSource, options: nil)
                libraries[devId] = compiled
                library = compiled
            } catch {
                failedDevices.insert(devId)
                return nil
            }
        }

        guard let fn = library.makeFunction(name: functionName) else { return nil }
        do {
            let state = try device.makeComputePipelineState(function: fn)
            pipelines[cacheKey] = state
            return state
        } catch {
            return nil
        }
    }

    var isMetalComputeAvailable: Bool {
        guard let dev = MTLCreateSystemDefaultDevice() else { return false }
        return pipeline(named: "filmicGamutHighlightProtect", for: dev) != nil
    }
}

// MARK: - 1. Pre-LUT Gamut Compression + C1 Rational Highlight Rolloff Kernel
private final class FilmicGamutHighlightKernel: CIImageProcessorKernel {
    static let thresholdKey = "threshold"
    static let gamutStrengthKey = "gamutStrength"

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var outputFormat: CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let commandBuffer = output.metalCommandBuffer,
              let input = inputs?.first,
              let srcTex = input.metalTexture,
              let dstTex = output.metalTexture,
              let pipeline = FilmicColorSciencePipelineCache.shared.pipeline(named: "filmicGamutHighlightProtect", for: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let threshold = (arguments?[thresholdKey] as? Float) ?? 0.82
        let gamutStrength = (arguments?[gamutStrengthKey] as? Float) ?? 1.0
        var uniforms = FilmicGamutUniforms(params: SIMD4(threshold, gamutStrength, 0, 0))

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcTex, index: 0)
        encoder.setTexture(dstTex, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<FilmicGamutUniforms>.stride, index: 0)

        let tgW = max(1, min(pipeline.threadExecutionWidth, 16))
        let tgH = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tgW, 16))
        encoder.dispatchThreadgroups(
            MTLSize(width: (dstTex.width + tgW - 1) / tgW, height: (dstTex.height + tgH - 1) / tgH, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
        )
        encoder.endEncoding()
    }
}

// MARK: - 2. Local YIQ Shadow & Highlight Recovery Kernel (2-Input: Source + Quarter-Res Blur Guide)
private final class FilmicLocalToneMetalKernel: CIImageProcessorKernel {
    static let shadowsKey = "shadows"
    static let highlightsKey = "highlights"

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var outputFormat: CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let commandBuffer = output.metalCommandBuffer,
              let inputs = inputs, inputs.count >= 2,
              let srcTex = inputs[0].metalTexture,
              let blurTex = inputs[1].metalTexture,
              let dstTex = output.metalTexture,
              let pipeline = FilmicColorSciencePipelineCache.shared.pipeline(named: "filmicLocalShadowHighlightYIQ", for: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let shadows = (arguments?[shadowsKey] as? Float) ?? 0.0
        let highlights = (arguments?[highlightsKey] as? Float) ?? 0.0
        var uniforms = FilmicLocalToneUniforms(params: SIMD4(shadows, highlights, 1.0, 0.0))

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcTex, index: 0)
        encoder.setTexture(blurTex, index: 1)
        encoder.setTexture(dstTex, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<FilmicLocalToneUniforms>.stride, index: 0)

        let tgW = max(1, min(pipeline.threadExecutionWidth, 16))
        let tgH = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tgW, 16))
        encoder.dispatchThreadgroups(
            MTLSize(width: (dstTex.width + tgW - 1) / tgW, height: (dstTex.height + tgH - 1) / tgH, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
        )
        encoder.endEncoding()
    }
}

// MARK: - 3. Vintage Cubic Matte Fade + Non-Clipping Filmic Exposure Kernel
private final class FilmicMatteFadeExposureKernel: CIImageProcessorKernel {
    static let fadeKey = "fade"
    static let exposureKey = "exposure"

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class var outputFormat: CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let commandBuffer = output.metalCommandBuffer,
              let input = inputs?.first,
              let srcTex = input.metalTexture,
              let dstTex = output.metalTexture,
              let pipeline = FilmicColorSciencePipelineCache.shared.pipeline(named: "filmicMatteFadeAndExposure", for: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let fade = (arguments?[fadeKey] as? Float) ?? 0.0
        let exposure = (arguments?[exposureKey] as? Float) ?? 0.0
        var uniforms = FilmicMatteExposureUniforms(params: SIMD4(fade, exposure, 0, 0))

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcTex, index: 0)
        encoder.setTexture(dstTex, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<FilmicMatteExposureUniforms>.stride, index: 0)

        let tgW = max(1, min(pipeline.threadExecutionWidth, 16))
        let tgH = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tgW, 16))
        encoder.dispatchThreadgroups(
            MTLSize(width: (dstTex.width + tgW - 1) / tgW, height: (dstTex.height + tgH - 1) / tgH, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
        )
        encoder.endEncoding()
    }
}

// MARK: - Public Facade (Single-Pass Metal với Fallback CoreImage an toàn)
public enum FilmicColorScience {
    public static var isMetalAvailable: Bool {
        FilmicColorSciencePipelineCache.shared.isMetalComputeAvailable
    }

    /// Nén gamut âm Display P3 + bo mượt C1 vùng cháy sáng trước khi đưa vào 3D LUT `[0, 1]`.
    public static func applyPreLUTGamutAndHighlightProtection(
        to image: CIImage,
        threshold: Float = 0.82,
        gamutStrength: Float = 1.0
    ) -> CIImage {
        guard !image.extent.isEmpty else { return image }
        if isMetalAvailable,
           let protected = try? FilmicGamutHighlightKernel.apply(
               withExtent: image.extent,
               inputs: [image],
               arguments: [
                   FilmicGamutHighlightKernel.thresholdKey: threshold,
                   FilmicGamutHighlightKernel.gamutStrengthKey: gamutStrength
               ]
           ) {
            return protected
        }
        return image
    }

    /// Phục hồi Vùng tối & Vùng sáng cục bộ trong không gian YIQ (dùng mặt nạ mờ 1/4 độ phân giải, bảo toàn sắc độ).
    public static func applyLocalShadowHighlightRecovery(
        to image: CIImage,
        shadows: Float,
        highlights: Float
    ) -> CIImage {
        let clampedSh = shadows.isFinite ? max(-1.0, min(1.0, shadows)) : 0.0
        let clampedHi = highlights.isFinite ? max(-1.0, min(1.0, highlights)) : 0.0
        guard (abs(clampedSh) >= 0.005 || abs(clampedHi) >= 0.005), !image.extent.isEmpty else {
            return image
        }

        if isMetalAvailable, let blurGuide = makeQuarterResBlurGuide(for: image) {
            if let recovered = try? FilmicLocalToneMetalKernel.apply(
                withExtent: image.extent,
                inputs: [image, blurGuide],
                arguments: [
                    FilmicLocalToneMetalKernel.shadowsKey: clampedSh,
                    FilmicLocalToneMetalKernel.highlightsKey: clampedHi
                ]
            ) {
                return recovered
            }
        }

        // CoreImage fallback an toàn khi chạy CPU headless
        let sh = CGFloat(max(-0.40, min(0.40, clampedSh)))
        let hi = CGFloat(max(-0.40, min(0.40, clampedHi)))
        return FilmSimulationCore.applyToneCurve(
            image,
            p0: CGPoint(x: 0.0, y: max(0.0, sh * 0.12)),
            p1: CGPoint(x: 0.25, y: max(0.05, min(0.45, 0.25 + sh * 0.18))),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: max(0.55, min(0.95, 0.75 + hi * 0.18))),
            p4: CGPoint(x: 1.0, y: min(1.0, max(0.88, 1.0 + hi * 0.10)))
        )
    }

    /// Áp dụng Độ phai giấy ảnh cổ điển (Matte Fade) và/hoặc Phơi sáng filmic chống cháy trắng.
    public static func applyMatteFadeAndExposure(
        to image: CIImage,
        fade: Float = 0.0,
        exposure: Float = 0.0
    ) -> CIImage {
        let clampedFade = fade.isFinite ? max(0.0, min(1.0, fade)) : 0.0
        let clampedExp = exposure.isFinite ? max(-1.2, min(1.2, exposure)) : 0.0
        guard (clampedFade >= 0.005 || abs(clampedExp) >= 0.005), !image.extent.isEmpty else {
            return image
        }

        if isMetalAvailable,
           let graded = try? FilmicMatteFadeExposureKernel.apply(
               withExtent: image.extent,
               inputs: [image],
               arguments: [
                   FilmicMatteFadeExposureKernel.fadeKey: clampedFade,
                   FilmicMatteFadeExposureKernel.exposureKey: clampedExp
               ]
           ) {
            return graded
        }

        // CoreImage fallback
        var out = image
        if abs(clampedExp) >= 0.005 {
            out = FilmSimulationCore.applyExposure(out, ev: clampedExp * 0.75)
        }
        if clampedFade >= 0.005 {
            let f = CGFloat(clampedFade)
            out = FilmSimulationCore.applyToneCurve(
                out,
                p0: CGPoint(x: 0.0, y: 0.145 * f),
                p1: CGPoint(x: 0.25, y: 0.25 + 0.05 * f),
                p2: CGPoint(x: 0.50, y: 0.50 + 0.03 * f),
                p3: CGPoint(x: 0.75, y: 0.75 + 0.01 * f),
                p4: CGPoint(x: 1.0, y: 1.0 - 0.075 * f)
            )
        }
        return out
    }

    /// Tạo bản đồ sáng mờ 1/4 độ phân giải (chỉ xử lý 1/16 số pixel, chống tối viền bằng `clampedToExtent`).
    private static func makeQuarterResBlurGuide(for image: CIImage) -> CIImage? {
        let ext = image.extent
        let maxDim = max(ext.width, ext.height)
        guard maxDim > 8 else { return nil }

        let downScale: CGFloat = maxDim > 480 ? 0.25 : 0.5
        let smallExt = CGRect(
            x: floor(ext.minX * downScale),
            y: floor(ext.minY * downScale),
            width: max(4, ceil(ext.width * downScale)),
            height: max(4, ceil(ext.height * downScale))
        )
        let scaledRadius = max(3.0, min(26.0, maxDim * 0.020 * downScale))

        let downsampled = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downScale, y: downScale))
            .cropped(to: smallExt)

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(downsampled.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(scaledRadius, forKey: kCIInputRadiusKey)
        guard let blurredSmall = blur.outputImage?.cropped(to: smallExt) else { return nil }

        let invScale = 1.0 / downScale
        return blurredSmall
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: invScale, y: invScale))
            .cropped(to: ext)
    }
}
