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
    case gemini37Flash = "gemini-3.7-flash"
    case gemini36Flash = "gemini-3.6-flash"
    case gemini35Flash = "gemini-3.5-flash"
    case gemini31Pro = "gemini-3.1-pro"
    case gemini25Flash = "gemini-2.5-flash"
    case gemini20Flash = "gemini-2.0-flash"

    // Legacy support
    case gemini15Flash = "gemini-1.5-flash"
    case gemini15Pro = "gemini-1.5-pro"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoStrongest:
            return "⚡ Tự động luân chuyển model (Khuyên dùng - Không lo hết Quota)"
        case .gemini37Flash:
            return "🚀 Gemini 3.7 Flash (Mới nhất)"
        case .gemini36Flash:
            return "⚡ Gemini 3.6 Flash"
        case .gemini35Flash:
            return "⚡ Gemini 3.5 Flash"
        case .gemini31Pro:
            return "💎 Gemini 3.1 Pro (Bố cục Studio)"
        case .gemini25Flash:
            return "⚡ Gemini 2.5 Flash"
        case .gemini20Flash:
            return "🔥 Gemini 2.0 Flash (Thị giác thế hệ mới)"
        case .gemini15Flash:
            return "🚀 Gemini 1.5 Flash (Ổn định)"
        case .gemini15Pro:
            return "💎 Gemini 1.5 Pro"
        }
    }

    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "gemini-3.7-flash"
        default:
            return rawValue
        }
    }

    /// Sequence of standard verified models to try in auto mode
    public static var autoFallbackChain: [String] {
        [
            "gemini-3.7-flash",
            "gemini-3.1-pro",
            "gemini-3.6-flash",
            "gemini-3.5-flash",
            "gemini-2.5-flash",
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "gemini-1.5-flash"
        ]
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
            return "Chưa cài API Key. Mở Cài đặt để dán key."
        case .invalidAPIKey(let msg):
            return "API Key không hợp lệ: \(msg)."
        case .rateLimited(let msg):
            return "Hết hạn mức Quota model này: \(msg)."
        case .imageConversionFailed:
            return "Không thể chuyển đổi ảnh gửi AI."
        case .invalidURL:
            return "URL API không hợp lệ."
        case .networkError(let e):
            return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse:
            return "Dữ liệu AI trả về không đúng định dạng."
        case .parseError(let msg):
            return "Lỗi AI (\(msg))"
        case .allModelsFailed(_):
            return "Tất cả model Gemini đều bận hoặc hết hạn mức. Đang dùng AI Neural Engine cục bộ."
        }
    }
}

// MARK: - GeminiService

public final class GeminiService {
    public static let shared = GeminiService()

    // Persistent API Key (Secure Keychain with UserDefaults migration fallback)
    public var apiKey: String {
        get {
            if let keychainVal = KeychainHelper.standard.read(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !keychainVal.isEmpty {
                return keychainVal
            }
            // Auto-migrate from legacy UserDefaults if present
            if let legacyKey = UserDefaults.standard.string(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyKey.isEmpty {
                KeychainHelper.standard.save(legacyKey, forKey: "gemini_api_key")
                UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                return legacyKey
            }
            return ""
        }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                KeychainHelper.standard.delete(forKey: "gemini_api_key")
            } else {
                KeychainHelper.standard.save(clean, forKey: "gemini_api_key")
            }
            UserDefaults.standard.removeObject(forKey: "gemini_api_key")
        }
    }

    public var hasAPIKey: Bool { !apiKey.isEmpty }

    // Selected Model Setting
    public var selectedModel: AIVisionModel {
        get {
            let saved = UserDefaults.standard.string(forKey: "gemini_selected_model") ?? AIVisionModel.autoStrongest.rawValue
            return AIVisionModel(rawValue: saved) ?? .autoStrongest
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
            completion(false, "API Key đang trống. Hãy dán key từ Google AI Studio.")
            return
        }

        var testCandidates = AIVisionModel.autoFallbackChain
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
            completion(false, "❌ Đã thử tất cả model nhưng key bị giới hạn quota hoặc chưa bật. Thử tạo key mới.")
            return
        }

        let testModel = candidates[index]
        let isOpenRouter = key.hasPrefix("sk-or-")

        guard let url = buildURL(for: testModel, key: key) else {
            completion(false, "URL không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if isOpenRouter {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")

            let body: [String: Any] = [
                "model": testModel,
                "messages": [
                    ["role": "user", "content": "Hi"]
                ]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let body: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": "Hi"]
                        ]
                    ]
                ]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let startTime = CACurrentMediaTime()
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let latency = Int((CACurrentMediaTime() - startTime) * 1000)

            if let error = error {
                DispatchQueue.main.async { completion(false, "Lỗi mạng: \(error.localizedDescription)") }
                return
            }

            guard let data = data, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(false, "Không nhận được phản hồi.") }
                return
            }

            if http.statusCode == 200 {
                self.lastModelUsed = testModel
                DispatchQueue.main.async {
                    let provider = isOpenRouter ? "OpenRouter" : "Gemini"
                    completion(true, "✅ Kết nối thành công! [\(provider)] Đang dùng: \(testModel) (Độ trễ: \(latency)ms)")
                }
            } else if http.statusCode == 404 || http.statusCode == 429 || http.statusCode == 503 {
                self.testModelCandidate(candidates: candidates, index: index + 1, key: key, completion: completion)
            } else {
                let msg = Self.extractErrorMessage(from: data, isOpenRouter: isOpenRouter) ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(false, "❌ Lỗi (\(http.statusCode)): \(msg)") }
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

    // MARK: - Main Analysis Call with Intelligent Multi-Model Auto-Rotation

    public func analyzeForComposition(
        image: CGImage,
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(.noAPIKey))
            return
        }

        let uiImage = UIImage(cgImage: image)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.65) else {
            completion(.failure(.imageConversionFailed))
            return
        }
        let base64Image = jpegData.base64EncodedString()
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        let prompt = buildPrompt(sceneContext: sceneContext, colorMetrics: metrics)

        var chain = AIVisionModel.autoFallbackChain
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
        completion: @escaping (Result<GeminiColorRecipe, GeminiError>) -> Void
    ) {
        let metrics = Self.extractColorMetrics(from: image)
        analyzeForComposition(image: image, sceneContext: sceneType, colorMetrics: metrics) { result in
            switch result {
            case .success(let response):
                completion(.success(response.colorRecipe))
            case .failure(let error):
                completion(.failure(error))
            }
        }
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

        let isOpenRouter = key.hasPrefix("sk-or-")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var requestBody: [String: Any] = [:]
        if isOpenRouter {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")

            requestBody = [
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
                "max_tokens": 768,
                "response_format": ["type": "json_object"]
            ]
        } else {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            requestBody = [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            [
                                "inline_data": [
                                    "mime_type": "image/jpeg",
                                    "data": base64Image
                                ]
                            ],
                            ["text": prompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.15,
                    "topK": 32,
                    "topP": 0.95,
                    "maxOutputTokens": 768,
                    "responseMimeType": "application/json"
                ]
            ]
        }

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
                let errorDetails = Self.extractErrorMessage(from: data, isOpenRouter: isOpenRouter) ?? "HTTP \(httpResponse.statusCode)"

                if httpResponse.statusCode == 400 && (errorDetails.contains("API_KEY_INVALID") || errorDetails.contains("API key not valid")) {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey(errorDetails))) }
                    return
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey(errorDetails))) }
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
                if isOpenRouter {
                    if let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let text = message["content"] as? String {
                        responseText = text
                    }
                } else {
                    if let candidates = json["candidates"] as? [[String: Any]],
                       let firstCandidate = candidates.first,
                       let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let textPart = parts.first,
                       let text = textPart["text"] as? String {
                        responseText = text
                    }
                }
            }

            guard let text = responseText else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }

            // Clean markdown if present
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
        let isOpenRouter = key.hasPrefix("sk-or-")
        if isOpenRouter {
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")
        }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(encodedKey)")
    }

    private static func extractErrorMessage(from data: Data, isOpenRouter: Bool = false) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if isOpenRouter {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                return msg
            }
        }

        guard let errorObj = json["error"] as? [String: Any] else { return nil }
        return errorObj["message"] as? String
    }

    // MARK: - Prompt

    private func buildPrompt(sceneContext: DetectedSceneType? = nil, colorMetrics: ImageColorMetrics? = nil) -> String {
        var contextInfo = ""
        if let scene = sceneContext {
            contextInfo += "\nBối cảnh khung cảnh nhận diện: \(scene.localizedName)"
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

        CHỈ THỊ CÂN CHỈNH MÀU SẮC (COLOR SCIENCE DIRECTIVES):
        1. Phản ứng chuẩn xác theo điều kiện ánh sáng thực tế:
           - Nếu thiếu sáng: nâng shadow (+0.08 đến +0.22), bù sáng exposure (+0.2 đến +0.6 EV), giữ contrast dịu.
           - Nếu ngược sáng / chói: giảm highlight roll (0.75 đến 0.90), bù sáng nhẹ để làm rõ chủ thể mà không làm cháy phông nền.
           - Nếu ám vàng hoặc ám xanh: tự động điều chỉnh nhiệt độ màu (warmth_shift) và sắc độ (tint_shift) để trả lại màu trắng trung tính và sắc màu chân thực.
        2. Bảo vệ tuyệt đối màu da người: giữ da trắng hồng, tự nhiên, khỏe khoắn, không bị ám vàng nghệ hay đỏ gắt.
        3. Chọn phong cách màu (color_grade) điện ảnh phù hợp nhất: ["softwarm", "vibrant", "coolnatural", "golden", "tealOrange", "moody", "classic", "cinematic"].

        Trả về DUY NHẤT một chuỗi JSON hợp lệ (không chứa markdown fences ```):
        {
          "target_x": 0.5,
          "target_y": 0.5,
          "suggested_zoom": 1.0,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "explanation": "Chân dung tự nhiên: Khóa mắt vào giao điểm tỷ lệ vàng, tự động zoom nhẹ giảm méo viền.",
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
}
