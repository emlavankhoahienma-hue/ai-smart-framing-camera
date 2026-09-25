import Foundation
import UIKit
import CoreGraphics
import QuartzCore
import Security

// MARK: - Keychain Security Helper
public struct KeychainHelper {
    public static let standard = KeychainHelper()
    private let service = "com.alignai.camera.keychain"

    public func save(_ string: String, forKey key: String) {
        guard let data = string.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData] = data
        SecItemAdd(newQuery as CFDictionary, nil)
    }

    public func read(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    public func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Supported AI Vision Models

public enum AIVisionModel: String, CaseIterable, Identifiable {
    case autoStrongest = "auto"
    case gemini37Flash = "google/gemini-3.7-flash"
    case gemini36Flash = "google/gemini-3.6-flash"
    case gemini35Flash = "google/gemini-3.5-flash"
    case gemini25Flash = "google/gemini-2.5-flash"
    case gemini25Pro = "google/gemini-2.5-pro"
    case gemini20Flash = "google/gemini-2.0-flash-001"
    case geminiFlash15 = "google/gemini-flash-1.5"
    case geminiPro15 = "google/gemini-pro-1.5"
    case gpt4oMini = "openai/gpt-4o-mini"
    case claude35Haiku = "anthropic/claude-3.5-haiku"
    case llamaVision = "meta-llama/llama-3.2-11b-vision-instruct"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoStrongest:
            return "\u{26a1} Tự động (Gemini 3.5 Flash)"
        case .gemini35Flash:
            return "\u{1f3af} Gemini 3.5 Flash (Khuyên dùng)"
        case .gemini25Flash:
            return "\u{2728} Gemini 2.5 Flash (Tốc độ cao)"
        case .gemini36Flash:
            return "\u{26a1} Gemini 3.6 Flash (Tốc độ cao)"
        case .gemini37Flash:
            return "\u{1f680} Gemini 3.7 Flash (Mới nhất)"
        case .gemini25Pro:
            return "\u{1f48e} Gemini 2.5 Pro (Chi tiết)"
        case .gemini20Flash:
            return "\u{1f525} Gemini 2.0 Flash (Siêu tốc)"
        case .geminiFlash15:
            return "\u{1f31f} Gemini 1.5 Flash (Ổn định)"
        case .geminiPro15:
            return "\u{1f52e} Gemini 1.5 Pro (Deep Reasoning)"
        case .gpt4oMini:
            return "\u{1f7e2} GPT-4o Mini (OpenAI)"
        case .claude35Haiku:
            return "\u{1f7e3} Claude 3.5 Haiku (Anthropic)"
        case .llamaVision:
            return "\u{1f999} Llama 3.2 Vision (Meta)"
        }
    }

    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "google/gemini-3.5-flash"
        default:
            return rawValue
        }
    }

    /// Sequence of standard verified models to try in auto mode on OpenRouter
    public static var autoFallbackChain: [String] {
        [
            "google/gemini-3.5-flash",
            "google/gemini-2.5-flash",
            "google/gemini-2.0-flash-001"
        ]
    }

    public static func fallbackChain(for key: String) -> [String] {
        return autoFallbackChain
    }
}

// MARK: - Gemini Response Models

public struct ImageColorMetrics {
    public let averageLuma: Float
    public let avgRed: Float
    public let avgGreen: Float
    public let avgBlue: Float
    public let warmthCast: Float
    public let tintCast: Float
    public let contrastScore: Float
    public let lightingSummary: String
}

public struct GeminiColorRecipe {
    public let temperatureK: Float     // 3500 - 8500
    public let saturation: Float       // 0.70 - 1.40
    public let contrast: Float         // 0.85 - 1.30
    public let shadowLift: Float       // 0.00 - 0.25
    public let highlightRoll: Float    // 0.70 - 1.00
    public let grain: Float            // 0.00 - 0.05
    public let vignette: Float         // 0.00 - 0.35
    public let warmthShift: Float      // -0.40 đến +0.40
    public let tintShift: Float        // -0.30 đến +0.30
    public let exposureBias: Float     // -1.2 đến +1.2 EV
    public let colorGrade: AIColorGrade
    public let diagnosis: String       // Lời giải thích và chẩn đoán bối cảnh màu

    public var asAIColorParameters: AIColorParameters {
        return AIColorParameters(
            warmthShift: CGFloat(warmthShift),
            saturationBoost: CGFloat(saturation),
            contrastCurve: CGFloat(contrast),
            shadowLift: CGFloat(shadowLift),
            highlightRoll: CGFloat(highlightRoll),
            filmGrain: CGFloat(grain),
            vignetteAmount: CGFloat(vignette),
            colorGrade: colorGrade,
            exposureBias: CGFloat(exposureBias),
            tintShift: CGFloat(tintShift)
        )
    }

    public static let defaultRecipe = GeminiColorRecipe(
        temperatureK: 5500,
        saturation: 1.02,
        contrast: 1.02,
        shadowLift: 0.01,
        highlightRoll: 0.98,
        grain: 0.00,
        vignette: 0.00,
        warmthShift: 0.0,
        tintShift: 0.0,
        exposureBias: 0.0,
        colorGrade: .softwarm,
        diagnosis: "Màu sắc tự nhiên cân bằng"
    )
}

public struct GeminiFramingResponse {
    public let targetX: CGFloat
    public let targetY: CGFloat
    public let suggestedZoom: CGFloat
    public let sceneType: DetectedSceneType
    public let colorRecipe: GeminiColorRecipe
    public let compositionRule: CompositionRule
    public let explanation: String
    public let modelUsed: String
    public let latencyMs: Int
    public let recommendedPreset: FilmPreset
    public let presetExplanation: String
}

// MARK: - Errors

public enum GeminiError: LocalizedError {
    case noAPIKey
    case invalidAPIKey(String)
    case rateLimited(String)
    case imageConversionFailed
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parseError(String)
    case allModelsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Chưa cài OpenRouter API Key. Mở Cài đặt để dán key (sk-or-...)."
        case .invalidAPIKey(let msg):
            return "OpenRouter API Key không hợp lệ: \(msg)."
        case .rateLimited(let msg):
            return "Model OpenRouter tạm thời bận hoặc hết hạn mức/credits: \(msg)."
        case .imageConversionFailed:
            return "Không thể chuyển đổi ảnh gửi AI."
        case .invalidURL:
            return "URL API không hợp lệ."
        case .networkError(let e):
            return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse:
            return "Dữ liệu OpenRouter trả về không đúng định dạng."
        case .parseError(let msg):
            return "Lỗi AI (\(msg))"
        case .allModelsFailed(let msg):
            if msg.isEmpty || msg == "Tất cả model OpenRouter đều bận." {
                return "Tất cả model OpenRouter đều bận hoặc hết hạn mức/credits. Đang dùng AI Neural Engine cục bộ."
            }
            return "Tất cả model OpenRouter đều bận: \(msg)"
        }
    }
}

// MARK: - GeminiService

public final class GeminiService {
    public static let shared = GeminiService()

    // Persistent API Key (Secure Keychain with UserDefaults migration fallback)
    public var apiKey: String {
        get {
            if let keychainVal = KeychainHelper.standard.read(forKey: "openrouter_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !keychainVal.isEmpty {
                return keychainVal
            }
            if let keychainVal = KeychainHelper.standard.read(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !keychainVal.isEmpty {
                return keychainVal
            }
            // Auto-migrate from legacy UserDefaults if present
            if let legacyKey = UserDefaults.standard.string(forKey: "openrouter_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyKey.isEmpty {
                KeychainHelper.standard.save(legacyKey, forKey: "openrouter_api_key")
                UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
                return legacyKey
            }
            if let legacyKey = UserDefaults.standard.string(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyKey.isEmpty {
                KeychainHelper.standard.save(legacyKey, forKey: "openrouter_api_key")
                UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                return legacyKey
            }
            return ""
        }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                KeychainHelper.standard.delete(forKey: "openrouter_api_key")
                KeychainHelper.standard.delete(forKey: "gemini_api_key")
            } else {
                KeychainHelper.standard.save(clean, forKey: "openrouter_api_key")
            }
            UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
            UserDefaults.standard.removeObject(forKey: "gemini_api_key")
        }
    }

    public var hasAPIKey: Bool { !apiKey.isEmpty }

    // Selected Model Setting
    public var selectedModel: AIVisionModel {
        get {
            guard let saved = UserDefaults.standard.string(forKey: "gemini_selected_model") else {
                return .autoStrongest
            }
            if let model = AIVisionModel(rawValue: saved) {
                return model
            }
            if saved.contains("3.7") { return .gemini37Flash }
            if saved.contains("3.6") { return .gemini36Flash }
            if saved.contains("3.5") { return .gemini35Flash }
            if saved.contains("2.5") && saved.contains("pro") { return .gemini25Pro }
            if saved.contains("2.5") { return .gemini25Flash }
            if saved.contains("flash") { return .gemini20Flash }
            if saved.contains("pro") { return .geminiPro15 }
            return .autoStrongest
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "gemini_selected_model")
        }
    }

    // Custom Model Name (if specified)
    public var customModelName: String {
        get { (UserDefaults.standard.string(forKey: "gemini_custom_model_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "gemini_custom_model_name") }
    }

    // Live Inspection Observables
    public private(set) var lastLatencyMs: Int = 0
    public private(set) var lastModelUsed: String = ""
    public private(set) var lastExplanation: String = ""

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    public init() {}

    // MARK: - Test API Key Connection (Fast Multi-Model Ping & Auto-Discovery)

    public func testAPIKey() async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            testAPIKey { success, message in
                continuation.resume(returning: (success, message))
            }
        }
    }

    public func testAPIKey(completion: @escaping (Bool, String) -> Void) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(false, "API Key đang trống. Hãy dán OpenRouter API Key (sk-or-...).")
            return
        }

        var testCandidates = AIVisionModel.fallbackChain(for: key)
        if !customModelName.isEmpty {
            testCandidates.insert(customModelName, at: 0)
        }

        testModelCandidate(candidates: testCandidates, index: 0, key: key, completion: completion)
    }

    private func testModelCandidate(
        candidates: [String],
        index: Int,
        key: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard index < candidates.count else {
            completion(false, "\u{274c} Đã thử tất cả model OpenRouter nhưng key bị giới hạn quota hoặc hết credits. Hãy kiểm tra số dư trên openrouter.ai.")
            return
        }

        let testModel = candidates[index]
        guard let url = buildURL(for: testModel, key: key) else {
            completion(false, "URL không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": testModel,
            "messages": [
                ["role": "user", "content": "Hi"]
            ],
            "max_tokens": 10
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startTime = CACurrentMediaTime()
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let latency = Int((CACurrentMediaTime() - startTime) * 1000)

            if let error = error {
                DispatchQueue.main.async { completion(false, "Lỗi mạng: \(error.localizedDescription)") }
                return
            }

            guard let data = data, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(false, "Không nhận được phản hồi từ OpenRouter.") }
                return
            }

            if http.statusCode == 200 {
                DispatchQueue.main.async {
                    self.lastModelUsed = testModel
                    self.lastLatencyMs = latency
                    completion(true, "\u{2705} Kết nối thành công! [OpenRouter] Đang dùng: \(testModel) (Độ trễ: \(latency)ms)")
                }
            } else if http.statusCode == 404 || http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 502 {
                self.testModelCandidate(candidates: candidates, index: index + 1, key: key, completion: completion)
            } else {
                let msg = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(false, "\u{274c} Lỗi OpenRouter (\(http.statusCode)): \(msg)") }
            }
        }.resume()
    }

    // MARK: - Color Metrics & Scene Lighting Extraction
    public static func extractColorMetrics(from image: CGImage) -> ImageColorMetrics {
        let width = 48
        let height = 48
        var rawBytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &rawBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: Float = 0
        var totalG: Float = 0
        var totalB: Float = 0
        var totalLuma: Float = 0
        var lumas: [Float] = []
        lumas.reserveCapacity(width * height)

        let totalPixels = Float(width * height)
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Float(rawBytes[offset]) / 255.0
            let g = Float(rawBytes[offset + 1]) / 255.0
            let b = Float(rawBytes[offset + 2]) / 255.0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            totalR += r
            totalG += g
            totalB += b
            totalLuma += luma
            lumas.append(luma)
        }

        let avgR = totalR / totalPixels
        let avgG = totalG / totalPixels
        let avgB = totalB / totalPixels
        let avgLuma = totalLuma / totalPixels

        let warmthCast = (avgR - avgB) / max(0.01, (avgR + avgB))
        let tintCast = (avgG - (avgR + avgB) * 0.5) / max(0.01, avgG)

        let variance = lumas.reduce(0) { $0 + pow($1 - avgLuma, 2) } / totalPixels
        let contrastScore = sqrt(variance)

        let summary: String
        if avgLuma < 0.25 {
            summary = "Thiếu sáng / Chụp đêm (Low-light)"
        } else if avgLuma > 0.75 {
            summary = "Thừa sáng / Chói nắng (Overexposed)"
        } else if contrastScore > 0.28 {
            summary = "Tương phản mạnh / Ngược sáng (High Contrast / Backlit)"
        } else if warmthCast > 0.25 {
            summary = "Ám vàng / Ánh sáng ấm hoàng hôn hoặc đèn sợi đốt (Warm Cast)"
        } else if warmthCast < -0.25 {
            summary = "Ám xanh / Ánh sáng lạnh hoặc bóng râm (Cool Cast)"
        } else {
            summary = "Ánh sáng tự nhiên cân bằng (Balanced Daylight)"
        }

        return ImageColorMetrics(
            averageLuma: avgLuma,
            avgRed: avgR,
            avgGreen: avgG,
            avgBlue: avgB,
            warmthCast: warmthCast,
            tintCast: tintCast,
            contrastScore: contrastScore,
            lightingSummary: summary
        )
    }

    // MARK: - Image Downscaling & Optimization for AI Vision Analysis
    public static func prepareImageForAnalysis(_ image: CGImage, maxDimension: CGFloat = 1280) -> Data? {
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let maxOrig = max(originalWidth, originalHeight)

        let targetWidth: Int
        let targetHeight: Int
        if maxOrig > maxDimension {
            let scale = maxDimension / maxOrig
            targetWidth = max(1, Int(originalWidth * scale))
            targetHeight = max(1, Int(originalHeight * scale))
        } else {
            targetWidth = Int(originalWidth)
            targetHeight = Int(originalHeight)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = targetWidth * 4
        if let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            if let scaledCG = context.makeImage() {
                let uiImage = UIImage(cgImage: scaledCG)
                return uiImage.jpegData(compressionQuality: 0.60)
            }
        }

        let uiImage = UIImage(cgImage: image)
        return uiImage.jpegData(compressionQuality: 0.50)
    }

    // MARK: - Local Neural/Hardware Color Recipe Fallback (Offline & Zero-Quota Safety)
    public static func generateLocalColorRecipe(from metrics: ImageColorMetrics, sceneType: DetectedSceneType) -> GeminiColorRecipe {
        let exposureBias: Float
        if metrics.averageLuma < 0.25 {
            exposureBias = min(0.60, max(0.20, (0.45 - metrics.averageLuma) * 1.5))
        } else if metrics.averageLuma > 0.72 {
            exposureBias = max(-0.55, min(-0.15, (0.60 - metrics.averageLuma) * 1.2))
        } else {
            exposureBias = 0.08
        }

        let warmthShift = -metrics.warmthCast * 0.30
        let tintShift = -metrics.tintCast * 0.20

        let shadowLift: Float = (metrics.contrastScore > 0.22 || metrics.averageLuma < 0.35) ? 0.10 : 0.04
        let highlightRoll: Float = (metrics.contrastScore > 0.22 || metrics.averageLuma > 0.65) ? 0.88 : 0.95

        let saturation: Float
        let contrast: Float
        let colorGrade: AIColorGrade

        switch sceneType {
        case .portrait:
            saturation = 1.04
            contrast = 1.02
            colorGrade = .softwarm
        case .landscape, .foliage, .water, .sky, .sunset:
            saturation = 1.10
            contrast = 1.06
            colorGrade = .vibrant
        case .street:
            saturation = 1.02
            contrast = 1.08
            colorGrade = .classic
        case .night:
            saturation = 1.05
            contrast = 1.04
            colorGrade = .moody
        default:
            saturation = 1.06
            contrast = 1.04
            colorGrade = .softwarm
        }

        let diagnosis = "AI Cục bộ: Tự động cân bằng sáng tối (\(String(format: "%+.2f", exposureBias))EV) & sắc độ cảm biến"

        return GeminiColorRecipe(
            temperatureK: 5500,
            saturation: saturation,
            contrast: contrast,
            shadowLift: shadowLift,
            highlightRoll: highlightRoll,
            grain: 0.0,
            vignette: 0.02,
            warmthShift: warmthShift,
            tintShift: tintShift,
            exposureBias: exposureBias,
            colorGrade: colorGrade,
            diagnosis: diagnosis
        )
    }

    // MARK: - Main Analysis Call with Intelligent Multi-Model Auto-Rotation

    public func analyzeForComposition(
        image: CGImage,
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = [],
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(.noAPIKey))
            return
        }

        // Tối ưu hóa dung lượng ảnh gửi AI: Downscale về chuẩn phân tích thị giác (max 1280px)
        // Tránh lỗi 413 Payload Too Large / Request Entity Too Large trên ảnh chụp gốc 12MP-48MP
        guard let jpegData = Self.prepareImageForAnalysis(image, maxDimension: 1280) else {
            completion(.failure(.imageConversionFailed))
            return
        }
        let base64Image = jpegData.base64EncodedString()
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        let prompt = buildPrompt(sceneContext: sceneContext, colorMetrics: metrics, subjectRect: subjectRect, faceRects: faceRects)

        var chain = AIVisionModel.fallbackChain(for: key)
        if !customModelName.isEmpty {
            chain.insert(customModelName, at: 0)
        } else if selectedModel != .autoStrongest {
            chain.removeAll(where: { $0 == selectedModel.technicalModelID })
            chain.insert(selectedModel.technicalModelID, at: 0)
        }

        let startTime = CACurrentMediaTime()

        tryModelChain(
            chain: chain,
            index: 0,
            base64Image: base64Image,
            prompt: prompt,
            key: key,
            lastErrorMsg: "",
            startTime: startTime,
            completion: completion
        )
    }

    public func analyzeSceneColorAndGrade(
        image: CGImage,
        sceneType: DetectedSceneType = .general,
        colorMetrics: ImageColorMetrics? = nil,
        completion: @escaping (Result<GeminiColorRecipe, GeminiError>) -> Void
    ) {
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        analyzeForComposition(image: image, sceneContext: sceneType, colorMetrics: metrics) { result in
            switch result {
            case .success(let response):
                completion(.success(response.colorRecipe))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Post-Capture AI Color & Preset Matcher (AI Color Director)
    public func analyzeAndSelectBestFilmPreset(
        image: CGImage,
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        completion: @escaping (Result<(preset: FilmPreset, recipe: GeminiColorRecipe, explanation: String, latencyMs: Int), GeminiError>) -> Void
    ) {
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        let effectiveScene = sceneContext ?? .general

        guard hasAPIKey else {
            // Offline / No API Key: use local engine & scene intelligence
            let localPreset = effectiveScene.recommendedFilter
            let localRecipe = Self.generateLocalColorRecipe(from: metrics, sceneType: effectiveScene)
            let explanation = "\(localPreset.displayName): Phù hợp bối cảnh \(effectiveScene.localizedName) (AI Cục bộ)"
            completion(.success((preset: localPreset, recipe: localRecipe, explanation: explanation, latencyMs: 25)))
            return
        }

        analyzeForComposition(image: image, sceneContext: effectiveScene, colorMetrics: metrics) { result in
            switch result {
            case .success(let framing):
                let preset = framing.recommendedPreset
                let explanation = framing.presetExplanation.isEmpty ? "\(preset.displayName): Phù hợp nhất với bối cảnh ánh sáng" : framing.presetExplanation
                completion(.success((preset: preset, recipe: framing.colorRecipe, explanation: explanation, latencyMs: framing.latencyMs)))
            case .failure:
                // Fallback gracefully to local intelligence
                let localPreset = effectiveScene.recommendedFilter
                let localRecipe = Self.generateLocalColorRecipe(from: metrics, sceneType: effectiveScene)
                let explanation = "\(localPreset.displayName): Phù hợp bối cảnh \(effectiveScene.localizedName) (AI Cục bộ)"
                completion(.success((preset: localPreset, recipe: localRecipe, explanation: explanation, latencyMs: 30)))
            }
        }
    }

    // MARK: - AI Video Cinematography Director (OpenRouter Cloud)

    public func analyzeVideoCinematography(
        image: CGImage,
        sceneContext: DetectedSceneType? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = [],
        lookingDirection: CGVector = .zero,
        completion: @escaping (Result<AIVideoDirectorGuidance, GeminiError>) -> Void
    ) {
        let key = apiKey
        guard !key.isEmpty else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completion(.success(fallback))
            return
        }

        guard let jpegData = Self.prepareImageForAnalysis(image, maxDimension: 1280) else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completion(.success(fallback))
            return
        }

        let base64Image = jpegData.base64EncodedString()
        let prompt = buildVideoCinematographyPrompt(
            sceneContext: sceneContext,
            subjectRect: subjectRect,
            faceRects: faceRects,
            lookingDirection: lookingDirection
        )

        var chain = AIVisionModel.fallbackChain(for: key)
        if !customModelName.isEmpty {
            chain.insert(customModelName, at: 0)
        } else if selectedModel != .autoStrongest {
            chain.removeAll(where: { $0 == selectedModel.technicalModelID })
            chain.insert(selectedModel.technicalModelID, at: 0)
        }

        let startTime = CACurrentMediaTime()
        tryVideoCinematographyChain(
            chain: chain,
            index: 0,
            base64Image: base64Image,
            prompt: prompt,
            key: key,
            startTime: startTime,
            sceneContext: sceneContext,
            subjectRect: subjectRect,
            faceRects: faceRects,
            lookingDirection: lookingDirection,
            completion: completion
        )
    }

    private func tryVideoCinematographyChain(
        chain: [String],
        index: Int,
        base64Image: String,
        prompt: String,
        key: String,
        startTime: Double,
        sceneContext: DetectedSceneType?,
        subjectRect: CGRect?,
        faceRects: [CGRect],
        lookingDirection: CGVector,
        completion: @escaping (Result<AIVideoDirectorGuidance, GeminiError>) -> Void
    ) {
        guard index < chain.count else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completion(.success(fallback))
            return
        }

        let currentModelID = chain[index]
        guard let url = buildURL(for: currentModelID, key: key) else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completion(.success(fallback))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("AlignAI Video Director", forHTTPHeaderField: "X-Title")

        let requestBody: [String: Any] = [
            "model": currentModelID,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "response_format": ["type": "json_object"],
            "reasoning": ["exclude": true],
            "temperature": 0.40,
            "top_p": 0.90,
            "max_tokens": 1024
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completion(.success(fallback))
            return
        }
        request.httpBody = bodyData

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if error != nil {
                self.tryVideoCinematographyChain(
                    chain: chain,
                    index: index + 1,
                    base64Image: base64Image,
                    prompt: prompt,
                    key: key,
                    startTime: startTime,
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection,
                    completion: completion
                )
                return
            }

            guard let data = data, let httpResponse = response as? HTTPURLResponse else {
                let fallback = Self.generateLocalVideoGuidance(
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection
                )
                completion(.success(fallback))
                return
            }

            // Only rotate on rate-limit (429), model unavailable (404), or server down (5xx)
            if httpResponse.statusCode == 429 || httpResponse.statusCode == 404 || httpResponse.statusCode >= 500 {
                self.tryVideoCinematographyChain(
                    chain: chain,
                    index: index + 1,
                    base64Image: base64Image,
                    prompt: prompt,
                    key: key,
                    startTime: startTime,
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection,
                    completion: completion
                )
                return
            }

            // If HTTP status is not 200, use local fallback without burning another API call
            guard httpResponse.statusCode == 200 else {
                let fallback = Self.generateLocalVideoGuidance(
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection
                )
                completion(.success(fallback))
                return
            }

            var responseText: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let text = message["content"] as? String {
                responseText = text
            }

            // Parse cleanly with self-healing parser; fallback to local guidance if malformed without cascading
            guard let text = responseText,
                  let parsed = Self.cleanAndParseJSON(from: text) else {
                let fallback = Self.generateLocalVideoGuidance(
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection
                )
                completion(.success(fallback))
                return
            }

            let guidance = Self.parseVideoDirectorResponse(parsed, modelUsed: currentModelID)
            DispatchQueue.main.async { completion(.success(guidance)) }
        }.resume()
    }

    private func tryModelChain(
        chain: [String],
        index: Int,
        base64Image: String,
        prompt: String,
        key: String,
        lastErrorMsg: String,
        startTime: Double,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        guard index < chain.count else {
            let finalMsg = lastErrorMsg.isEmpty ? "Tất cả model Gemini đều bận." : lastErrorMsg
            completion(.failure(.allModelsFailed(finalMsg)))
            return
        }

        let currentModelID = chain[index]
        executeModelCall(
            modelID: currentModelID,
            base64Image: base64Image,
            prompt: prompt,
            key: key,
            startTime: startTime
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                completion(.success(response))
            case .failure(let error):
                // Stop immediately if invalid key
                if case .invalidAPIKey = error {
                    completion(.failure(error))
                    return
                }

                // ONLY rotate to the next model on genuine quota exhaustion (429) or transient network errors
                // DO NOT rotate on parse errors or completed requests (prevents costly cascading requests!)
                switch error {
                case .rateLimited, .networkError:
                    self.tryModelChain(
                        chain: chain,
                        index: index + 1,
                        base64Image: base64Image,
                        prompt: prompt,
                        key: key,
                        lastErrorMsg: error.localizedDescription,
                        startTime: startTime,
                        completion: completion
                    )
                default:
                    completion(.failure(error))
                }
            }
        }
    }

    private func executeModelCall(
        modelID: String,
        base64Image: String,
        prompt: String,
        key: String,
        startTime: Double,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        guard let url = buildURL(for: modelID, key: key) else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")

        let requestBody: [String: Any] = [
            "model": modelID,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "response_format": ["type": "json_object"],
            "reasoning": ["exclude": true],
            "temperature": 0.20,
            "top_p": 0.90,
            "max_tokens": 1024
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            completion(.failure(.parseError("Không thể tạo JSON")))
            return
        }
        request.httpBody = bodyData

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let latency = Int((CACurrentMediaTime() - startTime) * 1000)

            if let error = error {
                DispatchQueue.main.async { completion(.failure(.networkError(error))) }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let errorDetails = Self.extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey("OpenRouter: \(errorDetails)"))) }
                    return
                }
                if httpResponse.statusCode == 402 {
                    DispatchQueue.main.async { completion(.failure(.rateLimited("Tài khoản OpenRouter hết credits (402)"))) }
                    return
                }
                if httpResponse.statusCode == 429 {
                    DispatchQueue.main.async { completion(.failure(.rateLimited("\(modelID) hết quota (429)"))) }
                    return
                }
                if httpResponse.statusCode == 404 || httpResponse.statusCode >= 500 {
                    DispatchQueue.main.async { completion(.failure(.rateLimited("\(modelID) không khả dụng (\(httpResponse.statusCode))"))) }
                    return
                }

                DispatchQueue.main.async {
                    completion(.failure(.parseError("\(modelID) [HTTP \(httpResponse.statusCode)]: \(errorDetails)")))
                }
                return
            }

            var responseText: String?

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let text = message["content"] as? String {
                responseText = text
            }

            guard let text = responseText, !text.isEmpty else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }

            // Attempt 1: Self-healing JSON parsing
            if let parsed = Self.cleanAndParseJSON(from: text) {
                let result = Self.parseGeminiResponse(parsed, modelUsed: modelID, latencyMs: latency)
                DispatchQueue.main.async {
                    self.lastLatencyMs = latency
                    self.lastModelUsed = modelID
                    self.lastExplanation = result.explanation
                    completion(.success(result))
                }
                return
            }

            // Attempt 2: Regex extraction for any partially malformed JSON
            if let regexResult = Self.regexExtractFallbackFraming(from: text, modelUsed: modelID, latencyMs: latency) {
                DispatchQueue.main.async {
                    self.lastLatencyMs = latency
                    self.lastModelUsed = modelID
                    self.lastExplanation = regexResult.explanation
                    completion(.success(regexResult))
                }
                return
            }

            // Attempt 3: Safe fallback using model latency - never fail and cascade when HTTP 200 was billed!
            let fallbackResult = GeminiFramingResponse(
                targetX: 0.50,
                targetY: 0.45,
                suggestedZoom: 1.2,
                sceneType: .general,
                colorRecipe: .defaultRecipe,
                compositionRule: .goldenRatio,
                explanation: "Đã phân tích bố cục hình ảnh thành công",
                modelUsed: modelID,
                latencyMs: latency,
                recommendedPreset: .classicChrome,
                presetExplanation: "Classic Chrome — Màu phim phóng sự tài liệu trung thực"
            )
            DispatchQueue.main.async {
                self.lastLatencyMs = latency
                self.lastModelUsed = modelID
                self.lastExplanation = fallbackResult.explanation
                completion(.success(fallbackResult))
            }
        }.resume()
    }

    // MARK: - Helpers

    private func buildURL(for modelID: String, key: String) -> URL? {
        return URL(string: "https://openrouter.ai/api/v1/chat/completions")
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
            return msg
        }
        if let msg = json["message"] as? String {
            return msg
        }
        return nil
    }

    // MARK: - Self-Healing JSON Cleaner & Fallback Extractor

    public static func cleanAndParseJSON(from rawText: String) -> [String: Any]? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if text.hasPrefix("```json") {
            text = String(text.dropFirst(7))
        } else if text.hasPrefix("```") {
            text = String(text.dropFirst(3))
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Locate outermost braces
        if let firstBrace = text.firstIndex(of: "{"),
           let lastBrace = text.lastIndex(of: "}") {
            text = String(text[firstBrace...lastBrace])
        }

        // Direct parse
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // Trailing comma sanitation: e.g. `, }` or `, ]`
        if let regex = try? NSRegularExpression(pattern: ",\\s*([}\\]])", options: []) {
            let range = NSRange(location: 0, length: text.utf16.count)
            let sanitized = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
            if let data = sanitized.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        return nil
    }

    public static func regexExtractFallbackFraming(from text: String, modelUsed: String, latencyMs: Int) -> GeminiFramingResponse? {
        func extractNumber(forKey key: String) -> Double? {
            let pattern = "\"\(key)\"\\s*:\\s*(-?[0-9.]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }

        func extractString(forKey key: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }

        let targetX = CGFloat(extractNumber(forKey: "target_x") ?? 0.50)
        let targetY = CGFloat(extractNumber(forKey: "target_y") ?? 0.45)
        let zoom = CGFloat(extractNumber(forKey: "suggested_zoom") ?? 1.2)
        let explanation = extractString(forKey: "explanation") ?? "Đã căn chỉnh tiêu điểm và bố cục ảnh"
        let sceneTypeStr = extractString(forKey: "scene_type") ?? "general"
        let compRuleStr = extractString(forKey: "composition_rule") ?? "golden_ratio"
        let colorGradeStr = extractString(forKey: "color_grade") ?? "softwarm"
        let tempK = Float(extractNumber(forKey: "temperature_k") ?? 5500)
        let sat = Float(extractNumber(forKey: "saturation") ?? 1.05)
        let con = Float(extractNumber(forKey: "contrast") ?? 1.04)
        let shadow = Float(extractNumber(forKey: "shadow_lift") ?? 0.04)
        let hl = Float(extractNumber(forKey: "highlight_roll") ?? 0.95)
        let exp = Float(extractNumber(forKey: "exposure_bias") ?? 0.0)
        let warmth = Float(extractNumber(forKey: "warmth_shift") ?? 0.0)
        let tint = Float(extractNumber(forKey: "tint_shift") ?? 0.0)
        let diag = extractString(forKey: "diagnosis") ?? "Cân bằng màu sắc tự nhiên"

        let hasAnyUsefulData = extractNumber(forKey: "target_x") != nil ||
                               extractNumber(forKey: "suggested_zoom") != nil ||
                               extractString(forKey: "explanation") != nil

        guard hasAnyUsefulData else { return nil }

        let colorRecipe = GeminiColorRecipe(
            temperatureK: tempK,
            saturation: sat,
            contrast: con,
            shadowLift: shadow,
            highlightRoll: hl,
            grain: 0.0,
            vignette: 0.02,
            warmthShift: warmth,
            tintShift: tint,
            exposureBias: exp,
            colorGrade: parseColorGrade(colorGradeStr),
            diagnosis: diag
        )

        let presetRaw = extractString(forKey: "recommended_film_preset") ?? extractString(forKey: "recommended_preset") ?? ""
        let sceneType = parseSceneType(sceneTypeStr)
        let recPreset = FilmPreset.match(from: presetRaw) ?? sceneType.recommendedFilter
        let presetExpl = extractString(forKey: "preset_explanation") ?? "\(recPreset.displayName) — Tối ưu cho bối cảnh \(sceneType.localizedName)"

        return GeminiFramingResponse(
            targetX: max(0.05, min(0.95, targetX)),
            targetY: max(0.05, min(0.95, targetY)),
            suggestedZoom: max(1.0, min(3.0, zoom)),
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: parseCompositionRule(compRuleStr),
            explanation: explanation,
            modelUsed: modelUsed,
            latencyMs: latencyMs,
            recommendedPreset: recPreset,
            presetExplanation: presetExpl
        )
    }

    // MARK: - Prompt

    private func buildPrompt(
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = []
    ) -> String {
        var context = ""
        if let scene = sceneContext {
            context += "Bối cảnh: \(scene.localizedName). "
        }
        if let rect = subjectRect {
            context += String(format: "Chủ thể cảm biến: [tâmX: %.2f, tâmY: %.2f, w: %.2f, h: %.2f]. ", rect.midX, rect.midY, rect.width, rect.height)
        }
        if !faceRects.isEmpty {
            context += "Khuôn mặt: \(faceRects.count). "
        }
        if let m = colorMetrics {
            context += String(format: "Ánh sáng: Luma=%.2f, Warmth=%.2f, Contrast=%.2f (%@). ", m.averageLuma, m.warmthCast, m.contrastScore, m.lightingSummary)
        }

        return """
        Phân tích bố cục và chỉ định bộ màu film điện ảnh tối ưu cho bức ảnh (Trả về duy nhất JSON object):
        \(context)

        \(FilmPreset.aiCatalogDescription)

        Yêu cầu bắt buộc:
        1. target_x, target_y (0.05-0.95): Tiêu điểm khóa vào chủ thể chính. Không để mặc định (0.5, 0.5) nếu chủ thể lệch tâm.
        2. suggested_zoom (1.0-3.0): Zoom đặc tả chủ thể (chân dung 1.4-1.8x, chủ thể xa 1.8-2.5x, cảnh rộng 1.0-1.2x).
        3. recommended_film_preset: Chọn CHÍNH XÁC 1 preset từ danh mục 18 bộ màu trên phù hợp nhất với ánh sáng, chủ thể và cảm xúc bức ảnh.
        4. preset_explanation: Giải thích ngắn gọn (1 câu tiếng Việt) lý do chọn preset này cho cảnh ảnh.
        5. Cân bằng sáng tối (exposure_bias, shadow_lift, highlight_roll) và bảo vệ màu da người tự nhiên.
        6. color_grade chọn 1 trong: ["softwarm", "vibrant", "coolnatural", "golden", "tealOrange", "moody", "classic", "cinematic"].
        7. explanation & diagnosis: Tiếng Việt súc tích (1 câu).

        JSON Schema:
        {
          "target_x": 0.40,
          "target_y": 0.38,
          "suggested_zoom": 1.5,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "recommended_film_preset": "Fuji Pro 400H",
          "preset_explanation": "Fuji Pro 400H tone xanh pastel trong trẻo tôn sáng làn da tự nhiên trong ánh sáng ngày",
          "explanation": "Căn mắt chủ thể theo tỷ lệ vàng và zoom 1.5x tôn dáng",
          "color_recipe": {
            "temperature_k": 5500,
            "warmth_shift": 0.0,
            "tint_shift": 0.0,
            "exposure_bias": 0.1,
            "saturation": 1.05,
            "contrast": 1.04,
            "shadow_lift": 0.04,
            "highlight_roll": 0.95,
            "grain": 0.0,
            "vignette": 0.02,
            "color_grade": "softwarm",
            "diagnosis": "Cân bằng sáng tự nhiên và giữ màu da hồng hào"
          }
        }
        """
    }

    // MARK: - Response Parsing

    private static func parseGeminiResponse(_ json: [String: Any], modelUsed: String, latencyMs: Int) -> GeminiFramingResponse {
        let targetX = parseCGFloat(json["target_x"], defaultVal: 0.5)
        let targetY = parseCGFloat(json["target_y"], defaultVal: 0.5)
        let suggestedZoom = parseCGFloat(json["suggested_zoom"], defaultVal: 1.0)
        let explanation = (json["explanation"] as? String) ?? "AI phân tích bố cục hoàn tất"

        let sceneType = parseSceneType((json["scene_type"] as? String) ?? "general")
        let compositionRule = parseCompositionRule((json["composition_rule"] as? String) ?? "golden_ratio")

        var colorRecipe = GeminiColorRecipe.defaultRecipe
        if let colorJson = json["color_recipe"] as? [String: Any] {
            let gradeStr = (colorJson["color_grade"] as? String) ?? "softwarm"
            let grade = parseColorGrade(gradeStr)
            colorRecipe = GeminiColorRecipe(
                temperatureK: parseFloat(colorJson["temperature_k"], defaultVal: 5500),
                saturation: clampF(colorJson["saturation"], 0.70, 1.40, 1.04),
                contrast: clampF(colorJson["contrast"], 0.85, 1.30, 1.04),
                shadowLift: clampF(colorJson["shadow_lift"], 0.00, 0.25, 0.02),
                highlightRoll: clampF(colorJson["highlight_roll"], 0.70, 1.00, 0.95),
                grain: clampF(colorJson["grain"], 0.00, 0.05, 0.00),
                vignette: clampF(colorJson["vignette"], 0.00, 0.35, 0.00),
                warmthShift: clampF(colorJson["warmth_shift"], -0.40, 0.40, 0.0),
                tintShift: clampF(colorJson["tint_shift"], -0.30, 0.30, 0.0),
                exposureBias: clampF(colorJson["exposure_bias"], -1.2, 1.2, 0.0),
                colorGrade: grade,
                diagnosis: (colorJson["diagnosis"] as? String) ?? "Đã cân chỉnh màu sắc thích ứng bối cảnh"
            )
        }

        let presetRaw = (json["recommended_film_preset"] as? String) ?? (json["recommended_preset"] as? String) ?? ""
        let recPreset = FilmPreset.match(from: presetRaw) ?? sceneType.recommendedFilter
        let presetExpl = (json["preset_explanation"] as? String) ?? "\(recPreset.displayName) — Tối ưu cho bối cảnh \(sceneType.localizedName)"

        return GeminiFramingResponse(
            targetX: max(0.05, min(0.95, targetX)),
            targetY: max(0.05, min(0.95, targetY)),
            suggestedZoom: max(1.0, min(5.0, suggestedZoom)),
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: compositionRule,
            explanation: explanation,
            modelUsed: modelUsed,
            latencyMs: latencyMs,
            recommendedPreset: recPreset,
            presetExplanation: presetExpl
        )
    }

    // MARK: - Parse Helpers

    private static func parseFloat(_ val: Any?, defaultVal: Float) -> Float {
        let parsed: Float?
        if let num = val as? NSNumber {
            parsed = num.floatValue
        } else if let d = val as? Double {
            parsed = Float(d)
        } else if let f = val as? Float {
            parsed = f
        } else if let s = val as? String {
            parsed = Float(s)
        } else {
            parsed = nil
        }
        guard let parsed = parsed, parsed.isFinite else { return defaultVal }
        return parsed
    }

    private static func parseCGFloat(_ val: Any?, defaultVal: CGFloat) -> CGFloat {
        let parsed: Double?
        if let num = val as? NSNumber {
            parsed = num.doubleValue
        } else if let d = val as? Double {
            parsed = d
        } else if let f = val as? Float {
            parsed = Double(f)
        } else if let s = val as? String {
            parsed = Double(s)
        } else {
            parsed = nil
        }
        guard let parsed = parsed, parsed.isFinite else { return defaultVal }
        return CGFloat(parsed)
    }

    private static func clampF(_ val: Any?, _ minV: Float, _ maxV: Float, _ defV: Float) -> Float {
        let v = parseFloat(val, defaultVal: defV)
        return max(minV, min(maxV, v))
    }

    private static func parseSceneType(_ s: String) -> DetectedSceneType {
        switch s.lowercased() {
        case "portrait", "person", "human", "face": return .portrait
        case "pet", "animal", "dog", "cat": return .pet
        case "landscape", "nature", "outdoor": return .landscape
        case "sunset", "sunrise", "golden_hour": return .sunset
        case "architecture", "building": return .architecture
        case "sky", "cloud": return .sky
        case "water", "sea", "ocean", "river": return .water
        case "foliage", "plant", "flower", "tree": return .foliage
        case "night", "dark": return .night
        case "food": return .food
        case "macro": return .macro
        case "street", "urban": return .street
        default: return .general
        }
    }

    private static func parseCompositionRule(_ s: String) -> CompositionRule {
        switch s.lowercased() {
        case "rule_of_thirds", "ruleofthirds": return .ruleOfThirds
        case "golden_ratio", "goldenratio": return .goldenRatio
        case "golden_spiral", "goldenspiral": return .goldenSpiral
        case "center_symmetry", "center": return .centerSymmetry
        default: return .goldenRatio
        }
    }

    private static func parseColorGrade(_ s: String) -> AIColorGrade {
        switch s.lowercased() {
        case "softwarm": return .softwarm
        case "coolnatural", "cool_natural": return .coolnatural
        case "golden": return .golden
        case "tealorange", "teal_orange": return .tealOrange
        case "moody": return .moody
        case "vibrant": return .vibrant
        case "classic": return .classic
        case "cinematic", "cinematic_film": return .cinematic
        default: return .softwarm
        }
    }

    // MARK: - Video Cinematography Director Helpers

    private func buildVideoCinematographyPrompt(
        sceneContext: DetectedSceneType? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = [],
        lookingDirection: CGVector = .zero
    ) -> String {
        var context = ""
        if let scene = sceneContext { context += "Bối cảnh: \(scene.localizedName). " }
        if let rect = subjectRect {
            context += String(format: "Chủ thể: [tâmX: %.2f, tâmY: %.2f, w: %.2f, h: %.2f]. ", rect.midX, rect.midY, rect.width, rect.height)
        }
        if !faceRects.isEmpty { context += "Khuôn mặt: \(faceRects.count). " }
        if abs(lookingDirection.dx) > 0.05 {
            context += lookingDirection.dx > 0 ? "Hướng nhìn sang phải. " : "Hướng nhìn sang trái. "
        }

        return """
        Đạo diễn góc quay video điện ảnh (Trả về duy nhất JSON object):
        \(context)
        Yêu cầu:
        1. Chọn cú máy (Orbit, Dolly In, Tilt-Up Reveal, Lead Pan, Arc Shot). Tránh lặp lại một kiểu cú máy.
        2. Tạo 2 đến 4 waypoints (x, y từ 0.08 đến 0.92) bám sát vị trí chủ thể.
        3. suggested_zoom (1.0 - 2.2), suggested_pacing_seconds (4.0 - 8.0).
        4. director_tip: Lời khuyên tư thế cầm máy và bước chân tiếng Việt ngắn gọn.

        JSON Schema:
        {
          "shot_style": "Lia bán nguyệt chân dung (Portrait Orbit)",
          "movement_direction": "Lia máy cong nhẹ quanh nhân vật tạo chiều sâu parallax",
          "suggested_pacing_seconds": 5.5,
          "suggested_zoom": 1.4,
          "director_tip": "Xoay thân người mượt mà, khép khuỷu tay vào sườn để chống rung",
          "waypoints": [
            {"id": 1, "x": 0.30, "y": 0.48, "label": "Tâm 1: Bắt đầu", "action_tip": "Khóa nét chủ thể", "duration": 1.8},
            {"id": 2, "x": 0.50, "y": 0.45, "label": "Tâm 2: Trọng tâm", "action_tip": "Lướt mượt qua tâm", "duration": 1.8},
            {"id": 3, "x": 0.70, "y": 0.48, "label": "Tâm 3: Kết thúc", "action_tip": "Dừng máy êm", "duration": 1.9}
          ]
        }
        """
    }

    private static func parseVideoDirectorResponse(_ json: [String: Any], modelUsed: String) -> AIVideoDirectorGuidance {
        let shotStyle = (json["shot_style"] as? String) ?? "Lia máy điện ảnh (Cinematic Move)"
        let direction = (json["movement_direction"] as? String) ?? "Lia máy đều tay qua các tâm đánh dấu"
        let pacing = parseCGFloat(json["suggested_pacing_seconds"], defaultVal: 5.0)
        let zoom = parseCGFloat(json["suggested_zoom"], defaultVal: 1.0)
        let tip = (json["director_tip"] as? String) ?? "Giữ thân máy ổn định, xoay đều eo"

        var waypoints: [CinematicWaypoint] = []
        if let rawWaypoints = json["waypoints"] as? [[String: Any]], !rawWaypoints.isEmpty {
            for (idx, item) in rawWaypoints.enumerated() {
                let id = (item["id"] as? Int) ?? (idx + 1)
                let x = parseCGFloat(item["x"], defaultVal: 0.5)
                let y = parseCGFloat(item["y"], defaultVal: 0.5)
                let label = (item["label"] as? String) ?? "Tâm \(id)"
                let actionTip = (item["action_tip"] as? String) ?? "Lia máy qua tâm"
                let duration = Double(parseCGFloat(item["duration"], defaultVal: 2.0))
                let clampedX = max(0.08, min(0.92, x))
                let clampedY = max(0.08, min(0.92, y))
                waypoints.append(
                    CinematicWaypoint(
                        id: id,
                        point: CGPoint(x: clampedX, y: clampedY),
                        label: label,
                        actionTip: actionTip,
                        recommendedDuration: duration
                    )
                )
            }
        }

        if waypoints.isEmpty {
            waypoints = [
                CinematicWaypoint(id: 1, point: CGPoint(x: 0.25, y: 0.50), label: "Tâm 1: Bắt đầu", actionTip: "Khóa nét chủ thể"),
                CinematicWaypoint(id: 2, point: CGPoint(x: 0.50, y: 0.45), label: "Tâm 2: Trọng tâm", actionTip: "Lướt đều tay"),
                CinematicWaypoint(id: 3, point: CGPoint(x: 0.75, y: 0.50), label: "Tâm 3: Kết thúc", actionTip: "Dừng máy êm")
            ]
        }

        return AIVideoDirectorGuidance(
            shotStyleTitle: shotStyle,
            movementDirectionDescription: direction,
            suggestedPacingSeconds: Double(pacing),
            waypoints: waypoints,
            suggestedZoom: max(1.0, min(3.0, zoom)),
            directorTip: tip,
            modelUsed: modelUsed
        )
    }

    public static func generateLocalVideoGuidance(
        sceneContext: DetectedSceneType? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = [],
        lookingDirection: CGVector = .zero
    ) -> AIVideoDirectorGuidance {
        let scene = sceneContext ?? .general
        let subjectX = subjectRect?.midX ?? 0.50
        let subjectY = subjectRect?.midY ?? 0.48

        // Phân loại và tạo cú máy đa dạng dựa trên chủ thể và bối cảnh thực tế:
        if !faceRects.isEmpty || scene == .portrait {
            let hasLeadRoom = abs(lookingDirection.dx) > 0.08
            if hasLeadRoom {
                // Lia máy đón đầu hướng nhìn (Gaze Lead Pan)
                let startX = max(0.20, min(0.80, subjectX))
                let endX = lookingDirection.dx > 0 ? min(0.85, startX + 0.35) : max(0.15, startX - 0.35)
                let midX = (startX + endX) / 2.0
                return AIVideoDirectorGuidance(
                    shotStyleTitle: "Lia theo hướng nhìn (Gaze Lead Pan)",
                    movementDirectionDescription: "Khóa nét chân dung, sau đó lia máy mở rộng theo hướng nhìn để tạo chiều sâu",
                    suggestedPacingSeconds: 5.5,
                    waypoints: [
                        CinematicWaypoint(id: 1, point: CGPoint(x: startX, y: subjectY), label: "Tâm 1: Ánh mắt chủ thể", actionTip: "Khóa nét chủ thể 1.5s", recommendedDuration: 1.8),
                        CinematicWaypoint(id: 2, point: CGPoint(x: midX, y: subjectY - 0.03), label: "Tâm 2: Trọng tâm chuyển động", actionTip: "Lia máy đều tay", recommendedDuration: 1.8),
                        CinematicWaypoint(id: 3, point: CGPoint(x: endX, y: subjectY), label: "Tâm 3: Không gian hướng nhìn", actionTip: "Giữ khung hình tĩnh", recommendedDuration: 1.9)
                    ],
                    suggestedZoom: 1.3,
                    directorTip: "Xoay nhẹ phần eo, bước chân mềm kiểu Ninja để khung hình mượt mà không rung",
                    modelUsed: "AI Neural Engine (Offline)"
                )
            } else {
                // Cú máy Orbit bán nguyệt quanh chủ thể
                let leftX = max(0.18, subjectX - 0.28)
                let rightX = min(0.82, subjectX + 0.28)
                return AIVideoDirectorGuidance(
                    shotStyleTitle: "Lia bán nguyệt chân dung (Portrait Orbit)",
                    movementDirectionDescription: "Lia máy cong nhẹ quanh nhân vật từ trái sang phải, tạo hiệu ứng thị sai điện ảnh",
                    suggestedPacingSeconds: 5.5,
                    waypoints: [
                        CinematicWaypoint(id: 1, point: CGPoint(x: leftX, y: subjectY - 0.04), label: "Tâm 1: Mở đầu góc 45°", actionTip: "Khóa nét chủ thể 1.5s", recommendedDuration: 1.8),
                        CinematicWaypoint(id: 2, point: CGPoint(x: subjectX, y: subjectY), label: "Tâm 2: Chính diện nhân vật", actionTip: "Xoay thân người mượt mà", recommendedDuration: 1.8),
                        CinematicWaypoint(id: 3, point: CGPoint(x: rightX, y: subjectY + 0.04), label: "Tâm 3: Kết thúc góc nghiêng", actionTip: "Dừng máy êm ái", recommendedDuration: 1.9)
                    ],
                    suggestedZoom: 1.4,
                    directorTip: "Khuỷu tay khép sát sườn, xoay toàn bộ thân trên để giữ chủ thể luôn ở trục xoay",
                    modelUsed: "AI Neural Engine (Offline)"
                )
            }
        } else if scene == .architecture || scene == .food || scene == .macro {
            // Đẩy máy cận cảnh (Dolly In / Push-In)
            let startY = min(0.75, subjectY + 0.20)
            let endY = max(0.25, subjectY - 0.08)
            return AIVideoDirectorGuidance(
                shotStyleTitle: "Đẩy máy tiến tới cận cảnh (Dolly Push-In)",
                movementDirectionDescription: "Tiến máy dần vào chủ thể từ góc bao quát sang đặc tả chi tiết",
                suggestedPacingSeconds: 5.0,
                waypoints: [
                    CinematicWaypoint(id: 1, point: CGPoint(x: subjectX, y: startY), label: "Tâm 1: Góc toàn cảnh", actionTip: "Khóa nét chủ thể 1.5s", recommendedDuration: 1.6),
                    CinematicWaypoint(id: 2, point: CGPoint(x: subjectX, y: subjectY), label: "Tâm 2: Tiếp cận chi tiết", actionTip: "Tiến bước chân chậm rãi", recommendedDuration: 1.7),
                    CinematicWaypoint(id: 3, point: CGPoint(x: subjectX, y: endY), label: "Tâm 3: Cận cảnh đặc tả", actionTip: "Dừng máy và giữ chắc", recommendedDuration: 1.7)
                ],
                suggestedZoom: 1.6,
                directorTip: "Hạ thấp trọng tâm, di chuyển chân chậm đều từng bước để chống rung tự nhiên",
                modelUsed: "AI Neural Engine (Offline)"
            )
        } else if scene == .landscape || scene == .foliage || scene == .sky || scene == .sunset || scene == .water {
            // Lia toàn cảnh điện ảnh
            let startX = max(0.15, subjectX - 0.32)
            let endX = min(0.85, subjectX + 0.32)
            return AIVideoDirectorGuidance(
                shotStyleTitle: "Lia toàn cảnh điện ảnh (Cinematic Panorama Pan)",
                movementDirectionDescription: "Lia máy ngang bao quát từ góc tiền cảnh mở rộng ra đường chân trời",
                suggestedPacingSeconds: 6.5,
                waypoints: [
                    CinematicWaypoint(id: 1, point: CGPoint(x: startX, y: subjectY + 0.04), label: "Tâm 1: Tiền cảnh khoáng đạt", actionTip: "Bắt đầu bối cảnh 1.5s", recommendedDuration: 2.0),
                    CinematicWaypoint(id: 2, point: CGPoint(x: subjectX, y: subjectY - 0.02), label: "Tâm 2: Đường chân trời", actionTip: "Lia đều tay qua tâm", recommendedDuration: 2.2),
                    CinematicWaypoint(id: 3, point: CGPoint(x: endX, y: subjectY), label: "Tâm 3: Hậu cảnh hùng vĩ", actionTip: "Ổn định máy 2.0s", recommendedDuration: 2.3)
                ],
                suggestedZoom: 1.0,
                directorTip: "Xoay toàn bộ phần hông thay vì chỉ xoay cổ tay để có cú lia mượt như dolly ray",
                modelUsed: "AI Neural Engine (Offline)"
            )
        } else {
            // Đa dạng hóa cho general: Dùng cú máy Arc / Orbit quanh chủ thể phát hiện
            let leftX = max(0.20, subjectX - 0.25)
            let rightX = min(0.80, subjectX + 0.25)
            return AIVideoDirectorGuidance(
                shotStyleTitle: "Lia máy quỹ đạo cung tròn (Arc Tracking Shot)",
                movementDirectionDescription: "Lia máy mượt mà theo hình vòng cung quanh chủ thể để tạo độ sâu trường ảnh",
                suggestedPacingSeconds: 5.8,
                waypoints: [
                    CinematicWaypoint(id: 1, point: CGPoint(x: leftX, y: subjectY + 0.03), label: "Tâm 1: Mở đầu quỹ đạo", actionTip: "Khóa nét chủ thể 1.5s", recommendedDuration: 1.9),
                    CinematicWaypoint(id: 2, point: CGPoint(x: subjectX, y: subjectY - 0.02), label: "Tâm 2: Trọng tâm khung hình", actionTip: "Lướt mượt mà qua tâm", recommendedDuration: 2.0),
                    CinematicWaypoint(id: 3, point: CGPoint(x: rightX, y: subjectY + 0.02), label: "Tâm 3: Điểm kết thúc", actionTip: "Dừng máy êm và giữ khung", recommendedDuration: 1.9)
                ],
                suggestedZoom: 1.2,
                directorTip: "Tựa khuỷu tay vào hông để chống rung, giữ nhịp thở đều khi lia máy",
                modelUsed: "AI Neural Engine (Offline)"
            )
        }
    }
}
