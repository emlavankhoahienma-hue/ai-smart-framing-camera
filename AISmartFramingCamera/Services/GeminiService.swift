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
            return "⚡ Tự động luân chuyển (Khuyên dùng - Auto Fallback)"
        case .gemini37Flash:
            return "🚀 Gemini 3.7 Flash (OpenRouter - Mới nhất & Suy nghĩ)"
        case .gemini36Flash:
            return "⚡ Gemini 3.6 Flash (OpenRouter - Tốc độ cao)"
        case .gemini35Flash:
            return "🎯 Gemini 3.5 Flash (OpenRouter - Bố cục thông minh)"
        case .gemini25Flash:
            return "✨ Gemini 2.5 Flash (OpenRouter - Tối ưu thị giác)"
        case .gemini25Pro:
            return "💎 Gemini 2.5 Pro (OpenRouter - Phân tích chi tiết)"
        case .gemini20Flash:
            return "🔥 Gemini 2.0 Flash (OpenRouter - Siêu tốc)"
        case .geminiFlash15:
            return "🌟 Gemini 1.5 Flash (OpenRouter - Ổn định)"
        case .geminiPro15:
            return "🔮 Gemini 1.5 Pro (OpenRouter - Deep Reasoning)"
        case .gpt4oMini:
            return "🟢 GPT-4o Mini (OpenRouter - OpenAI Vision)"
        case .claude35Haiku:
            return "🟣 Claude 3.5 Haiku (OpenRouter - Tinh tế)"
        case .llamaVision:
            return "🦙 Llama 3.2 Vision (OpenRouter - Open Source)"
        }
    }

    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "google/gemini-3.7-flash"
        default:
            return rawValue
        }
    }

    /// Sequence of standard verified models to try in auto mode on OpenRouter
    public static var autoFallbackChain: [String] {
        [
            "google/gemini-3.7-flash",
            "google/gemini-3.5-flash",
            "google/gemini-3.6-flash",
            "google/gemini-2.5-flash",
            "google/gemini-2.0-flash-001",
            "openai/gpt-4o-mini",
            "google/gemini-2.5-pro",
            "google/gemini-flash-1.5"
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
            completion(false, "❌ Đã thử tất cả model OpenRouter nhưng key bị giới hạn quota hoặc hết credits. Hãy kiểm tra số dư trên openrouter.ai.")
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
            ]
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
                self.lastModelUsed = testModel
                DispatchQueue.main.async {
                    completion(true, "✅ Kết nối thành công! [OpenRouter] Đang dùng: \(testModel) (Độ trễ: \(latency)ms)")
                }
            } else if http.statusCode == 404 || http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 502 {
                self.testModelCandidate(candidates: candidates, index: index + 1, key: key, completion: completion)
            } else {
                let msg = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(false, "❌ Lỗi OpenRouter (\(http.statusCode)): \(msg)") }
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
            "temperature": 0.70,
            "top_p": 0.95,
            "max_tokens": 800
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

            guard let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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

            var responseText: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let text = message["content"] as? String {
                responseText = text
            }

            guard let text = responseText else {
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

            var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanText.hasPrefix("```json") {
                cleanText = cleanText.replacingOccurrences(of: "```json", with: "")
            } else if cleanText.hasPrefix("```") {
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
            }
            if cleanText.hasSuffix("```") {
                cleanText = String(cleanText.dropLast(3))
            }
            cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

            if let firstBrace = cleanText.firstIndex(of: "{"),
               let lastBrace = cleanText.lastIndex(of: "}") {
                cleanText = String(cleanText[firstBrace...lastBrace])
            }

            guard let jsonData = cleanText.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
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
                // If invalid API key completely, stop
                if case .invalidAPIKey = error {
                    completion(.failure(error))
                    return
                }

                // On 429 quota or 404 or server error, immediately rotate to next model
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
            "temperature": 0.15,
            "top_p": 0.95,
            "max_tokens": 768
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

                DispatchQueue.main.async {
                    completion(.failure(.parseError("\(modelID) [HTTP \(httpResponse.statusCode)]: \(errorDetails)")))
                }
                return
            }

            var responseText: String?

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let text = message["content"] as? String {
                    responseText = text
                }
            }

            guard let text = responseText else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }

            // Clean markdown fences if present
            var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanText.hasPrefix("```json") {
                cleanText = cleanText.replacingOccurrences(of: "```json", with: "")
                if cleanText.hasSuffix("```") {
                    cleanText = String(cleanText.dropLast(3))
                }
            } else if cleanText.hasPrefix("```") {
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
                if cleanText.hasSuffix("```") {
                    cleanText = String(cleanText.dropLast(3))
                }
            }
            cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

            // Trích xuất chuỗi JSON thuần nếu mô hình sinh thêm giải thích bên ngoài
            if let firstBrace = cleanText.firstIndex(of: "{"),
               let lastBrace = cleanText.lastIndex(of: "}") {
                cleanText = String(cleanText[firstBrace...lastBrace])
            }

            guard let jsonData = cleanText.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.parseError("JSON không hợp lệ: \(cleanText.prefix(80))"))) }
                return
            }

            self.lastLatencyMs = latency
            self.lastModelUsed = modelID
            let result = Self.parseGeminiResponse(parsed, modelUsed: modelID, latencyMs: latency)
            self.lastExplanation = result.explanation

            DispatchQueue.main.async { completion(.success(result)) }
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

    // MARK: - Prompt

    private func buildPrompt(
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = []
    ) -> String {
        var contextInfo = ""
        if let scene = sceneContext {
            contextInfo += "\nBối cảnh khung cảnh nhận diện: \(scene.localizedName)"
        }
        if let rect = subjectRect {
            contextInfo += "\n- Tọa độ chủ thể chính phát hiện trên cảm biến: tâm x=\(String(format: "%.2f", rect.midX)), y=\(String(format: "%.2f", rect.midY)), rộng=\(String(format: "%.2f", rect.width)), cao=\(String(format: "%.2f", rect.height))"
        }
        if !faceRects.isEmpty {
            contextInfo += "\n- Số lượng khuôn mặt phát hiện: \(faceRects.count)"
        }
        if let metrics = colorMetrics {
            contextInfo += """
            \nThông số đo sáng & màu sắc thực tế từ cảm biến ảnh:
            - Tình trạng ánh sáng: \(metrics.lightingSummary)
            - Độ sáng trung bình (Luma): \(String(format: "%.2f", metrics.averageLuma)) (0.0=tối đen, 1.0=cháy trắng)
            - Kênh màu trung bình: R: \(String(format: "%.2f", metrics.avgRed)), G: \(String(format: "%.2f", metrics.avgGreen)), B: \(String(format: "%.2f", metrics.avgBlue))
            - Độ lệch ấm/lạnh (Warmth): \(String(format: "%.2f", metrics.warmthCast)) (-1.0=lạnh/xanh, +1.0=ấm/vàng)
            - Độ tương phản thực tế: \(String(format: "%.2f", metrics.contrastScore))
            """
        }

        return """
        Bạn là Đạo diễn Hình ảnh & Chuyên gia Chỉnh màu Điện ảnh (Master Colorist & Cinematographer) của Leica và Hasselblad.
        Hãy phân tích bức ảnh này cùng với bối cảnh và các thông số đo sáng thực tế dưới đây để đưa ra điểm bố cục tối ưu và bộ công thức cân chỉnh màu sắc chuyên nghiệp nhất.
        \(contextInfo)

        CHỈ THỊ BỐ CỤC & TIÊU ĐIỂM CHỦ THỂ (ZERO-CENTER DEFAULT DIRECTIVES):
        1. Nhận diện CHỦ THỂ CHÍNH (người, khuôn mặt, vật thể, thú cưng):
           - Tọa độ target_x, target_y là vị trí tiêu điểm của chủ thể chính để khóa nét và căn bố cục.
           - Nếu có chủ thể phát hiện ở tọa độ trên: đặt target_x, target_y gắn liền với chủ thể đó (hoặc điểm vàng chứa chủ thể).
           - TUYỆT ĐỐI KHÔNG mặc định trả về (0.5, 0.5) trừ khi cảnh là kiến trúc đối xứng hoàn toàn ở chính giữa.
        2. Mức zoom đề xuất (suggested_zoom: 1.0 đến 3.0):
           - Nếu chủ thể ở xa hoặc nhỏ trong khung hình (< 15% diện tích): đề xuất zoom 1.6x đến 2.5x để đặc tả chủ thể đẹp mắt.
           - Nếu chụp chân dung trung cảnh: đề xuất zoom 1.4x đến 1.8x để tiêu cự tương đương ống kính chân dung 50-85mm tôn dáng.
           - Nếu cảnh đại cảnh hoặc nhiều người: giữ 1.0x đến 1.2x.
        3. Phản ứng chuẩn xác theo điều kiện ánh sáng thực tế:
           - Nếu thiếu sáng: nâng shadow (+0.08 đến +0.22), bù sáng exposure (+0.2 đến +0.6 EV), giữ contrast dịu.
           - Nếu ngược sáng / chói: giảm highlight roll (0.75 đến 0.90), bù sáng nhẹ để làm rõ chủ thể mà không làm cháy phông nền.
           - Nếu ám vàng hoặc ám xanh: tự động điều chỉnh nhiệt độ màu (warmth_shift) và sắc độ (tint_shift) để trả lại màu trắng trung tính và sắc màu chân thực.
        4. Bảo vệ tuyệt đối màu da người: giữ da trắng hồng, tự nhiên, khỏe khoắn, không bị ám vàng nghệ hay đỏ gắt.
        5. Chọn phong cách màu (color_grade) điện ảnh phù hợp nhất: ["softwarm", "vibrant", "coolnatural", "golden", "tealOrange", "moody", "classic", "cinematic"].

        Trả về DUY NHẤT một chuỗi JSON hợp lệ (không chứa markdown fences ```):
        {
          "target_x": 0.38,
          "target_y": 0.40,
          "suggested_zoom": 1.6,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "explanation": "Chân dung điểm vàng: Đặt mắt chủ thể tại giao điểm 0.38 để tạo chiều sâu và zoom 1.6x tôn dáng.",
          "color_recipe": {
            "temperature_k": 5600,
            "warmth_shift": 0.04,
            "tint_shift": -0.02,
            "exposure_bias": 0.15,
            "saturation": 1.06,
            "contrast": 1.04,
            "shadow_lift": 0.06,
            "highlight_roll": 0.92,
            "grain": 0.00,
            "vignette": 0.04,
            "color_grade": "softwarm",
            "diagnosis": "Bối cảnh ngược sáng: bù sáng +0.15EV, nâng chi tiết bóng tối và giữ mây trời tự nhiên."
          }
        }

        Giới hạn thông số:
        - target_x, target_y: 0.05 đến 0.95
        - suggested_zoom: 1.0 đến 3.0
        - temperature_k: 3500 đến 8500
        - warmth_shift: -0.40 đến 0.40
        - tint_shift: -0.30 đến 0.30
        - exposure_bias: -1.2 đến 1.2
        - saturation: 0.70 đến 1.40
        - contrast: 0.85 đến 1.30
        - shadow_lift: 0.00 đến 0.25
        - highlight_roll: 0.70 đến 1.00
        - vignette: 0.00 đến 0.35
        - explanation: 1 câu tư vấn bố cục tiếng Việt ngắn gọn
        - diagnosis: 1 câu tóm tắt chẩn đoán ánh sáng và tinh chỉnh màu tiếng Việt
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

        return GeminiFramingResponse(
            targetX: max(0.05, min(0.95, targetX)),
            targetY: max(0.05, min(0.95, targetY)),
            suggestedZoom: max(1.0, min(5.0, suggestedZoom)),
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: compositionRule,
            explanation: explanation,
            modelUsed: modelUsed,
            latencyMs: latencyMs
        )
    }

    // MARK: - Parse Helpers

    private static func parseFloat(_ val: Any?, defaultVal: Float) -> Float {
        if let num = val as? NSNumber { return num.floatValue }
        if let d = val as? Double { return Float(d) }
        if let f = val as? Float { return f }
        if let s = val as? String, let f = Float(s) { return f }
        return defaultVal
    }

    private static func parseCGFloat(_ val: Any?, defaultVal: CGFloat) -> CGFloat {
        if let num = val as? NSNumber { return CGFloat(num.doubleValue) }
        if let d = val as? Double { return CGFloat(d) }
        if let f = val as? Float { return CGFloat(f) }
        if let s = val as? String, let d = Double(s) { return CGFloat(d) }
        return defaultVal
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
        var contextInfo = ""
        if let scene = sceneContext {
            contextInfo += "\n- Bối cảnh khung cảnh nhận diện: \(scene.localizedName)"
        }
        if let rect = subjectRect {
            contextInfo += "\n- Tọa độ chủ thể chính phát hiện: tâm (x: \(String(format: "%.2f", rect.midX)), y: \(String(format: "%.2f", rect.midY))), rộng: \(String(format: "%.2f", rect.width)), cao: \(String(format: "%.2f", rect.height))"
        }
        if !faceRects.isEmpty {
            contextInfo += "\n- Số lượng khuôn mặt phát hiện: \(faceRects.count)"
        }
        if abs(lookingDirection.dx) > 0.05 {
            let dir = lookingDirection.dx > 0 ? "sang phải" : "sang trái"
            contextInfo += "\n- Hướng mắt/hướng nhìn chủ thể: \(dir)"
        }

        return """
        Bạn là Đạo diễn Hình ảnh Quay phim Điện ảnh (Cinematography Director) chuyên nghiệp từng đạt giải Oscar.
        Hãy phân tích khung hình video trực tiếp này và vị trí của chủ thể để thiết kế cú máy quay (camera movement) ĐỘC ĐÁO, ĐẸP MẮT và ĐA DẠNG NHẤT.
        \(contextInfo)

        YÊU CẦU QUAN TRỌNG VỀ SỰ ĐA DẠNG VÀ TÍNH ĐIỆN ẢNH (ZERO-REPETITION):
        1. KHÔNG ĐƯỢC chỉ chọn cú lia ngang cơ bản lặp đi lặp lại. Hãy chọn 1 trong các cú máy điện ảnh đỉnh cao sau đây sao cho phù hợp nhất với vị trí chủ thể và bối cảnh:
           - "Lia bán nguyệt quanh chủ thể (Cinematic Orbit / Arc 180°)": Di chuyển camera theo đường cong bán nguyệt quanh chủ thể chính để tạo hiệu ứng thị sai (parallax) và chiều sâu 3D điện ảnh.
           - "Đẩy máy tiến tới cận cảnh (Dolly In / Push-In)": Bắt đầu từ góc trung cảnh bao quát rồi tiến dần máy mượt mà vào cận cảnh gương mặt hoặc chi tiết chủ thể để tăng kịch tính.
           - "Nâng máy hé lộ từ dưới lên (Pedestal / Tilt-Up Reveal)": Bắt đầu góc thấp (low-angle) từ tiền cảnh/chân chủ thể rồi nâng máy mượt mà lên để hé lộ thần thái chủ thể và hậu cảnh khoáng đạt.
           - "Lia đón đầu theo hướng nhìn (Gaze / Subject Lead Pan)": Bắt đầu tại ánh mắt/chủ thể rồi lia máy mở rộng theo hướng nhìn của chủ thể để tạo không gian thở và sự tò mò.
           - "Trượt ngang toàn cảnh (Cinematic Slider / Tracking Pan)": Trượt máy ngang song song với chủ thể, tạo cảm giác chuyển động mượt mà như đặt trên ray trượt dolly chuyên nghiệp.

        2. ĐỊNH VỊ CÁC TÂM ĐÁNH DẤU (WAYPOINTS) DỰA TRÊN TỌA ĐỘ CHỦ THỂ THỰC TẾ:
           - Tạo từ 2 đến 4 tâm đánh dấu (waypoints).
           - Tọa độ (x, y) của các tâm PHẢI gắn liền với vị trí chủ thể đã nhận diện ở trên.
           - Ví dụ nếu cú máy Orbit quanh chủ thể ở giữa: Tâm 1 lệch trái (0.28, 0.48) -> Tâm 2 vào chủ thể (0.50, 0.44) -> Tâm 3 lệch phải (0.72, 0.48).
           - Nếu cú Dolly In: Tâm 1 (0.40, 0.45) -> Tâm 2 (0.47, 0.48) -> Tâm 3 khóa chặt chủ thể (0.52, 0.50) kèm zoom tăng dần.
           - Nếu cú Tilt Up: Tâm 1 ở dưới thấp (0.50, 0.72) -> Tâm 2 ở giữa (0.50, 0.52) -> Tâm 3 ở trên khuôn mặt/chân trời (0.50, 0.32).

        3. Mức zoom đề xuất (suggested_zoom: 1.0x đến 2.2x) phù hợp với cú máy.
        4. Nhịp độ (suggested_pacing_seconds: 4.0 đến 8.0 giây).

        Trả về DUY NHẤT một chuỗi JSON hợp lệ (không chứa markdown fences ```):
        {
          "shot_style": "<Tên kiểu cú máy đã chọn>",
          "movement_direction": "<Mô tả hướng lia/di chuyển máy chi tiết>",
          "suggested_pacing_seconds": 6.0,
          "suggested_zoom": 1.4,
          "director_tip": "<Lời khuyên tư thế cầm máy, bước chân, khử rung>",
          "waypoints": [
            {
              "id": 1,
              "x": 0.30,
              "y": 0.50,
              "label": "Tâm 1: Bắt đầu góc máy",
              "action_tip": "Khóa nét chủ thể 1.5s",
              "duration": 2.0
            },
            {
              "id": 2,
              "x": 0.50,
              "y": 0.45,
              "label": "Tâm 2: Trọng tâm chuyển động",
              "action_tip": "Lướt máy mượt mà qua tâm",
              "duration": 2.0
            },
            {
              "id": 3,
              "x": 0.70,
              "y": 0.50,
              "label": "Tâm 3: Kết thúc khung hình",
              "action_tip": "Dừng êm và giữ khung",
              "duration": 2.0
            }
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
