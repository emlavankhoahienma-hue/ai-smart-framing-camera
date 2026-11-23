import Foundation
import CoreImage
import Metal
import simd

/// Uniforms căn lề 16-byte khớp tuyệt đối 1:1 giữa Swift và Metal Shading Language (10 × SIMD4<Float> = 160 bytes).
private struct PhotographicStyleUniforms {
    var control: SIMD4<Float>       // (tone, color, palette, presetKind)
    var gradeA: SIMD4<Float>        // (baseContrast, baseShadowLift, baseHighlightRoll, isMonochrome)
    var gradeB: SIMD4<Float>        // (baseVibrance, baseSaturation, undertoneStrength, splitStrength)
    var matrixRow0: SIMD4<Float>
    var matrixRow1: SIMD4<Float>
    var matrixRow2: SIMD4<Float>
    var skinShiftLab: SIMD4<Float>
    var shadowTint: SIMD4<Float>
    var highlightTint: SIMD4<Float>
    var semanticBoost: SIMD4<Float>

    init(style: PhotographicStyleState) {
        let r = style.preset.recipe
        self.control = SIMD4(style.tone, style.color, style.palette, r.presetKind)
        self.gradeA = SIMD4(r.baseContrast, r.baseShadowLift, r.baseHighlightRoll, r.isMonochrome)
        self.gradeB = SIMD4(r.baseVibrance, r.baseSaturation, r.undertoneStrength, r.splitStrength)
        self.matrixRow0 = r.matrixRow0
        self.matrixRow1 = r.matrixRow1
        self.matrixRow2 = r.matrixRow2
        self.skinShiftLab = r.skinShiftLab
        self.shadowTint = r.shadowTint
        self.highlightTint = r.highlightTint
        self.semanticBoost = r.semanticBoost
    }
}

/// Bộ đệm biên dịch runtime MTLComputePipelineState theo từng MTLDevice (thread-safe, không cần flag `-fcikernel`).
private final class PhotographicStylePipelineCache: @unchecked Sendable {
    static let shared = PhotographicStylePipelineCache()

    private let lock = NSLock()
    private var pipelines: [ObjectIdentifier: MTLComputePipelineState] = [:]
    private var failedDevices: Set<ObjectIdentifier> = []

    /// Single-pass Linear RGB + Björn Ottosson OkLab Color Science Compute Shader.
    /// Lưu ý không gian màu: Core Image `.RGBAh` truyền trực tiếp Extended Linear sRGB (premultiplied alpha)
    /// và tự mã hóa OETF về Display P3/sRGB ở đầu ra — tuyệt đối không double-gamma trong shader.
    private static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct PhotographicStyleUniforms {
        float4 control;       // tone, color, palette, presetKind
        float4 gradeA;        // baseContrast, baseShadowLift, baseHighlightRoll, isMonochrome
        float4 gradeB;        // baseVibrance, baseSaturation, undertoneStrength, splitStrength
        float4 matrixRow0;
        float4 matrixRow1;
        float4 matrixRow2;
        float4 skinShiftLab;
        float4 shadowTint;
        float4 highlightTint;
        float4 semanticBoost;
    };

    // Signed cube root: an toàn tuyệt đối cho giá trị âm nhẹ của Display P3 trong Extended Linear sRGB (tránh NaN).
    inline float signedCbrt(float x) {
        return sign(x) * pow(abs(x), 1.0f / 3.0f);
    }

    // Ma trận OkLab chính xác theo Björn Ottosson (Linear sRGB <-> LMS <-> OkLab).
    inline float3 linearSRGBToOkLab(float3 c) {
        float l = 0.4122214708f * c.r + 0.5363325363f * c.g + 0.0514459929f * c.b;
        float m = 0.2119034982f * c.r + 0.6806995451f * c.g + 0.1073969566f * c.b;
        float s = 0.0883024619f * c.r + 0.2817188376f * c.g + 0.6299787005f * c.b;

        float l_ = signedCbrt(l);
        float m_ = signedCbrt(m);
        float s_ = signedCbrt(s);

        return float3(
            0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
            1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
            0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
        );
    }

    inline float3 okLabToLinearSRGB(float3 lab) {
        float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
        float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
        float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

        float l = l_ * l_ * l_;
        float m = m_ * m_ * m_;
        float s = s_ * s_ * s_;

        return float3(
            +4.0767416613f * l - 3.3077115904f * m + 0.2309699287f * s,
            -1.2684380041f * l + 2.6097574007f * m - 0.3413193963f * s,
            -0.0041960865f * l - 0.7034186145f * m + 1.7076147009f * s
        );
    }

    // Mặt nạ sắc da mượt trong OkLab: tập trung quanh sắc da Fitzpatrick I-VI, về 0 trên tường trắng & trời xanh.
    inline float computeSkinMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(0.18f, 0.44f, hue) * (1.0f - smoothstep(0.95f, 1.24f, hue));
        float chromaMask = smoothstep(0.016f, 0.036f, chroma) * (1.0f - smoothstep(0.145f, 0.220f, chroma));
        float lumaMask = smoothstep(0.18f, 0.32f, L) * (1.0f - smoothstep(0.86f, 0.96f, L));
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeSkyMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(-2.75f, -2.25f, hue) * (1.0f - smoothstep(-1.15f, -0.75f, hue));
        float chromaMask = smoothstep(0.020f, 0.055f, chroma);
        float lumaMask = smoothstep(0.32f, 0.56f, L);
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeFoliageMaskOkLab(float L, float chroma, float hue) {
        float hueMask = smoothstep(1.48f, 1.95f, hue) * (1.0f - smoothstep(2.65f, 3.02f, hue));
        float chromaMask = smoothstep(0.022f, 0.060f, chroma);
        float lumaMask = smoothstep(0.12f, 0.28f, L);
        return clamp(hueMask * chromaMask * lumaMask, 0.0f, 1.0f);
    }

    inline float computeWarmRedMaskOkLab(float chroma, float hue) {
        float hueMask = smoothstep(-0.22f, 0.18f, hue) * (1.0f - smoothstep(0.75f, 1.15f, hue));
        float chromaMask = smoothstep(0.045f, 0.105f, chroma);
        return clamp(hueMask * chromaMask, 0.0f, 1.0f);
    }

    // Nén mượt tiệm cận biên dải màu theo tia về độ sáng trung tính (giữ nguyên sắc độ & độ sáng, chống bệt neon)
    inline float3 softGamutClampLinear(float3 rgb, float lumaFallback) {
        float minC = min(rgb.r, min(rgb.g, rgb.b));
        if (minC < 0.0f) {
            float yPos = dot(max(rgb, float3(0.0f)), float3(0.2126f, 0.7152f, 0.0722f));
            float targetY = max(max(yPos, lumaFallback), 1e-4f);
            float t = clamp(targetY / max(targetY - minC, 1e-5f), 0.0f, 1.0f);
            rgb = mix(float3(targetY), rgb, t);
        }
        return max(rgb, float3(0.0f));
    }

    // Filmic highlight shoulder liên tục C1 nén mượt vùng sáng > knee (chống cháy trắng trời/đèn).
    inline float applyHighlightShoulder(float y, float knee, float strength) {
        if (y <= knee || strength <= 0.001f) {
            return y;
        }
        float headroom = max(0.08f, 1.0f - knee);
        float over = y - knee;
        float compressed = knee + (headroom * over) / (over + headroom);
        return mix(y, compressed, clamp(strength, 0.0f, 1.0f));
    }

    kernel void photographicStyleGrade(
        texture2d<float, access::read>  inTexture  [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        constant PhotographicStyleUniforms& u      [[buffer(0)]],
        uint2                           gid        [[thread_position_in_grid]]
    ) {
        uint outW = outTexture.get_width();
        uint outH = outTexture.get_height();
        if (gid.x >= outW || gid.y >= outH) {
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

        // 1. Un-premultiply alpha -> True Extended Linear sRGB (Core Image đã decode EOTF sẵn).
        float3 origLinear = raw.rgb / alpha;
        float tone = clamp(u.control.x, -1.0f, 1.0f);
        float colorCtrl = clamp(u.control.y, -1.0f, 1.0f);
        float palette = clamp(u.control.z, 0.0f, 1.0f);
        float presetKind = u.control.w;

        bool isMono = u.gradeA.w > 0.5f;
        if (!isMono && palette <= 0.001f) {
            outTexture.write(raw, gid);
            return;
        }

        float baseContrast = u.gradeA.x;
        float baseShadowLift = u.gradeA.y;
        float baseHighlightRoll = u.gradeA.z;
        float baseVibrance = u.gradeB.x;
        float baseSaturation = u.gradeB.y;
        float undertoneStrength = u.gradeB.z;
        float splitStrength = u.gradeB.w;

        // 2. Phân tích OkLab gốc (tính duy nhất 1 lần chroma & hue cho cả 4 mặt nạ ngữ nghĩa).
        float3 origLab = linearSRGBToOkLab(origLinear);
        float origChroma = length(origLab.yz);
        float origHue = atan2(origLab.z, origLab.y);
        float skinMask = computeSkinMaskOkLab(origLab.x, origChroma, origHue);
        float skyMask = computeSkyMaskOkLab(origLab.x, origChroma, origHue);
        float foliageMask = computeFoliageMaskOkLab(origLab.x, origChroma, origHue);
        float warmRedMask = computeWarmRedMaskOkLab(origChroma, origHue);
        float nonNeutralMask = smoothstep(0.010f, 0.032f, origChroma);
        float midtoneMask = smoothstep(0.04f, 0.28f, origLab.x) * (1.0f - smoothstep(0.78f, 0.96f, origLab.x));
        float skinProtect = clamp(u.skinShiftLab.w, 0.0f, 0.85f);

        float3 graded = origLinear;

        // 3. Per-Preset 3x3 Optical Color Matrix
        if (!isMono) {
            float3 matRGB = float3(
                dot(graded, u.matrixRow0.xyz),
                dot(graded, u.matrixRow1.xyz),
                dot(graded, u.matrixRow2.xyz)
            );
            if (presetKind > 0.5f && presetKind < 1.5f) {
                float blueSkyGuard = 1.0f - skyMask * 0.72f;
                float matrixMix = clamp((0.36f + 0.64f * max(skinMask, nonNeutralMask * 0.70f)) * blueSkyGuard, 0.18f, 1.0f);
                graded = mix(graded, matRGB, matrixMix);
            } else {
                graded = matRGB;
            }
        }

        // 4. Skin-Protected Local HDR Tone Mapping (Trục Y: Tone -1 ... +1)
        float yIn = max(0.0f, dot(graded, float3(0.2126f, 0.7152f, 0.0722f)));
        float yOut = yIn;

        if (abs(baseShadowLift) > 0.001f) {
            float shadowWeight = smoothstep(0.001f, 0.035f, yOut) * (1.0f - smoothstep(0.04f, 0.45f, yOut));
            float shDelta = baseShadowLift * 0.115f * shadowWeight * (0.28f + yOut);
            yOut = max(yOut * 0.45f, yOut + shDelta);
        }
        if (abs(baseContrast) > 0.001f) {
            float pivot = 0.18f;
            float power = max(0.62f, 1.0f + baseContrast * 0.68f);
            float yPivot = pivot * pow(max(yOut / pivot, 1e-6f), power);
            yOut = mix(yOut, yPivot, 0.85f);
        }

        if (tone < -0.001f) {
            float neg = -tone;
            float effNeg = neg * (1.0f - skinMask * skinProtect * 0.52f);
            float gamma = 1.0f + 0.56f * effNeg;
            float yDeep = pow(max(yOut, 1e-6f), gamma) * exp(-0.10f * effNeg);
            float toeKeep = exp(-yOut * 12.0f) * 0.34f;
            float yShaped = mix(yDeep, yOut * 0.68f, toeKeep);
            float hiKeep = smoothstep(0.38f, 0.92f, yOut) * 0.52f;
            yOut = mix(yShaped, yOut * (1.0f - 0.08f * effNeg), hiKeep);
        } else if (tone > 0.001f) {
            float gamma = 1.0f - 0.38f * tone;
            float yLifted = pow(max(yOut, 1e-6f), gamma) * (1.0f + 0.16f * tone);
            float shBell = smoothstep(0.0015f, 0.045f, yOut) * (1.0f - smoothstep(0.06f, 0.42f, yOut));
            yOut = yLifted + shBell * 0.036f * tone;
        }

        float skyProtect = clamp(u.highlightTint.w, 0.0f, 0.85f);
        float shoulderKnee = mix(0.72f, 0.58f, skyMask * skyProtect);
        float shoulderStrength = clamp(baseHighlightRoll + max(0.0f, tone) * 0.78f + skyMask * skyProtect * 0.55f, 0.0f, 0.96f);
        yOut = applyHighlightShoulder(yOut, shoulderKnee, shoulderStrength);

        if (isMono) {
            float3 filterW = (colorCtrl >= 0.0f)
                ? mix(float3(0.31f, 0.58f, 0.11f), float3(0.56f, 0.38f, 0.06f), colorCtrl)
                : mix(float3(0.31f, 0.58f, 0.11f), float3(0.16f, 0.48f, 0.36f), -colorCtrl);
            float monoLum = max(0.0f, dot(max(origLinear, 0.0f), filterW));
            float lumScale = yOut / max(yIn, 1e-5f);
            float monoTone = clamp(monoLum * clamp(lumScale, 0.0f, 3.6f), 0.0f, 4.0f);
            monoTone = max(0.0f, monoTone + u.semanticBoost.x * skinMask * 0.25f);

            float hiMaskBW = smoothstep(0.26f, 0.92f, monoTone);
            float bwHiGain = 1.0f + (palette - 0.5f) * 0.56f * hiMaskBW;
            monoTone = applyHighlightShoulder(clamp(monoTone * bwHiGain, 0.0f, 3.8f), 0.78f, 0.55f);

            float shW = (1.0f - smoothstep(0.03f, 0.52f, monoTone)) * smoothstep(0.004f, 0.07f, monoTone);
            float hiW = smoothstep(0.36f, 0.92f, monoTone);
            float3 splitTone = u.shadowTint.xyz * shW * splitStrength + u.highlightTint.xyz * hiW * splitStrength;
            float3 silverShift = (colorCtrl >= 0.0f)
                ? float3(0.042f, 0.020f, -0.034f) * colorCtrl
                : float3(-0.024f, 0.006f, 0.042f) * (-colorCtrl);
            graded = float3(monoTone) + splitTone + silverShift * (0.22f + 0.78f * midtoneMask) * clamp(monoTone * 1.35f, 0.0f, 1.0f);
        } else {
            float ratio = clamp(yOut / max(yIn, 1e-5f), 0.0f, 3.5f);
            graded *= ratio;
            float hiDesat = smoothstep(0.82f, 1.35f, yOut) * 0.18f;
            graded = mix(graded, float3(yOut), hiDesat);

            if (splitStrength > 0.001f) {
                float shW = (1.0f - smoothstep(0.03f, 0.48f, yOut)) * smoothstep(0.003f, 0.045f, yOut);
                float hiW = smoothstep(0.42f, 0.92f, yOut) * (1.0f - smoothstep(0.95f, 1.28f, yOut));
                float3 effShadowTint = u.shadowTint.xyz;
                if (presetKind > 2.5f) {
                    float3 warmSlate = float3(0.018f, 0.008f, -0.012f);
                    effShadowTint = mix(warmSlate, u.shadowTint.xyz * 1.28f, smoothstep(0.15f, 0.85f, palette));
                }
                graded += (effShadowTint * shW + u.highlightTint.xyz * hiW) * splitStrength;
            }

            float blueShCut = u.semanticBoost.w;
            if (blueShCut > 0.005f) {
                float shMidW = 1.0f - smoothstep(0.08f, 0.62f, yOut);
                graded.b *= max(0.72f, 1.0f - blueShCut * 0.28f * shMidW);
            }

            // 5. Perceptual Color / 4-Band Semantic OkLab Grading
            float3 lab = linearSRGBToOkLab(max(graded, float3(-0.08f)));
            float cMag = length(lab.yz);

            if (undertoneStrength > 0.001f) {
                float skinWeight = (0.18f + 0.82f * skinMask) * midtoneMask * nonNeutralMask;
                lab.x += (u.skinShiftLab.x + u.semanticBoost.x * skinMask) * skinWeight * undertoneStrength;
                lab.yz += u.skinShiftLab.yz * skinWeight * undertoneStrength;
            } else if (abs(u.semanticBoost.x) > 0.002f) {
                lab.x += u.semanticBoost.x * skinMask * midtoneMask;
            }

            float foliagePop = u.semanticBoost.y;
            if (abs(foliagePop) > 0.005f) {
                lab.x += foliagePop * 0.018f * foliageMask;
                lab.yz *= (1.0f + foliagePop * 0.45f * foliageMask);
                lab.y -= foliagePop * 0.014f * foliageMask;
            }
            float skyShift = u.semanticBoost.z;
            if (abs(skyShift) > 0.005f) {
                lab.z -= skyShift * 0.026f * skyMask;
                lab.y -= skyShift * 0.008f * skyMask;
                if (skyShift > 0.0f) {
                    lab.x -= skyShift * 0.016f * skyMask * smoothstep(0.55f, 0.90f, lab.x);
                }
            }
            float warmRedPop = u.shadowTint.w;
            if (abs(warmRedPop) > 0.005f) {
                float redW = warmRedMask * (1.0f - skinMask * 0.65f);
                lab.yz *= (1.0f + warmRedPop * 0.42f * redW);
                lab.x += warmRedPop * 0.012f * redW;
            }

            float satRoll = 1.0f - smoothstep(0.068f, 0.245f, cMag);
            float skinProtection = 1.0f - 0.48f * skinMask;
            float chromaScale = baseSaturation + baseVibrance * satRoll * skinProtection;

            if (colorCtrl > 0.001f) {
                chromaScale *= (1.0f + colorCtrl * (0.72f * satRoll + 0.24f) * skinProtection);
            } else if (colorCtrl < -0.001f) {
                chromaScale *= mix(1.0f, 0.08f, -colorCtrl);
            }

            float2 scaledAB = lab.yz * clamp(chromaScale, 0.0f, 2.05f);
            float newChroma = length(scaledAB);
            if (newChroma > 0.21f) {
                float overC = newChroma - 0.21f;
                float softC = 0.21f + (overC * 0.11f) / (overC + 0.11f);
                scaledAB *= (softC / max(newChroma, 1e-5f));
            }
            lab.yz = scaledAB;
            graded = softGamutClampLinear(okLabToLinearSRGB(lab), yOut);
        }

        // 6. True Optical Linear Palette Blend (giữ 100% đơn sắc trên B&W) + Soft Gamut Safety + Re-Premultiply Alpha
        float3 finalLinear = isMono ? graded : mix(origLinear, graded, palette);
        finalLinear = max(finalLinear, float3(-0.22f));
        if (!all(isfinite(finalLinear))) {
            finalLinear = origLinear;
        }
        outTexture.write(float4(finalLinear * alpha, alpha), gid);
    }
    """

    func pipeline(for device: MTLDevice) -> MTLComputePipelineState? {
        let key = ObjectIdentifier(device)
        lock.lock()
        defer { lock.unlock() }
        if let cached = pipelines[key] { return cached }
        if failedDevices.contains(key) { return nil }
        do {
            let library = try device.makeLibrary(source: Self.metalSource, options: nil)
            guard let function = library.makeFunction(name: "photographicStyleGrade") else {
                failedDevices.insert(key)
                return nil
            }
            let state = try device.makeComputePipelineState(function: function)
            pipelines[key] = state
            return state
        } catch {
            failedDevices.insert(key)
            return nil
        }
    }

    var hasDefaultMetalPipeline: Bool {
        guard let dev = MTLCreateSystemDefaultDevice() else { return false }
        return pipeline(for: dev) != nil
    }
}

/// Single-Pass Metal Color Science Kernel bọc trong `CIImageProcessorKernel` (không cần `-fcikernel`).
/// Tự động chạy chung 1 đồ thị GPU cho cả Live Preview 60 FPS (`MTKView`) lẫn Ảnh chụp Full-Res (`CGImage`).
public final class PhotographicStyleMetalKernel: CIImageProcessorKernel {
    private static let styleArgumentKey = "photographicStyleState"

    public static let isMetalAvailable: Bool = PhotographicStylePipelineCache.shared.hasDefaultMetalPipeline

    public override class func formatForInput(at input: Int32) -> CIFormat {
        .RGBAh
    }

    public override class var outputFormat: CIFormat {
        .RGBAh
    }

    public override class var synchronizeInputs: Bool {
        false
    }

    public override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    public override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard let commandBuffer = output.metalCommandBuffer,
              let input = inputs?.first,
              let sourceTexture = input.metalTexture,
              let destTexture = output.metalTexture,
              let style = arguments?[styleArgumentKey] as? PhotographicStyleState,
              let pipeline = PhotographicStylePipelineCache.shared.pipeline(for: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        var uniforms = PhotographicStyleUniforms(style: style)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destTexture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PhotographicStyleUniforms>.stride, index: 0)

        let tgW = max(1, min(pipeline.threadExecutionWidth, 16))
        let tgH = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tgW, 16))
        let threadsPerGroup = MTLSize(width: tgW, height: tgH, depth: 1)
        let threadgroups = MTLSize(
            width: (destTexture.width + tgW - 1) / tgW,
            height: (destTexture.height + tgH - 1) / tgH,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    /// Áp dụng Single-Pass Metal Photographic Style; tự rơi về CoreImage fallback an toàn nếu không có Metal.
    public static func apply(to image: CIImage, style: PhotographicStyleState) -> CIImage {
        guard !style.isIdentity, !image.extent.isEmpty else { return image }

        if isMetalAvailable,
           let graded = try? Self.apply(
               withExtent: image.extent,
               inputs: [image],
               arguments: [styleArgumentKey: style]
           ) {
            return graded
        }
        return applyCoreImageFallback(to: image, style: style)
    }

    /// Fallback thuần CoreImage khi chạy trên môi trường không hỗ trợ Metal compute (ví dụ headless CPU renderer).
    private static func applyCoreImageFallback(to image: CIImage, style: PhotographicStyleState) -> CIImage {
        let p = max(0.0, min(1.0, style.palette))
        guard p >= 0.005 else { return image }

        var out = image
        let r = style.preset.recipe
        let tone = style.tone * p
        let color = style.color * p

        if abs(tone) >= 0.005 || abs(r.baseContrast) >= 0.005 {
            let contrast = max(0.75, min(1.35, 1.0 + r.baseContrast * p * 0.55 - min(0, tone) * 0.22))
            let brightness = tone * 0.06
            out = FilmSimulationCore.applyColorControls(out, contrast: contrast, saturation: 1.0, brightness: brightness)
        }

        if style.preset.isMonochrome {
            out = FilmSimulationCore.applyColorControls(out, contrast: 1.0, saturation: 1.0 - p, brightness: 0.0)
        } else {
            let vib = (r.baseVibrance * p) + (color > 0 ? color * 0.45 : color * 0.30)
            if abs(vib) >= 0.005 {
                out = FilmSimulationCore.applyVibrance(out, amount: max(-0.85, min(0.85, vib)))
            }
            let sat = max(0.08, min(1.45, 1.0 + (r.baseSaturation - 1.0) * p + (color < 0 ? color * 0.72 : color * 0.16)))
            if abs(sat - 1.0) >= 0.005 {
                out = FilmSimulationCore.applyColorControls(out, contrast: 1.0, saturation: sat, brightness: 0.0)
            }
        }
        return out
    }
}
