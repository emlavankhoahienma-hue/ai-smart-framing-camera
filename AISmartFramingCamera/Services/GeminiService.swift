import Foundation
import UIKit
import CoreGraphics
import QuartzCore

// MARK: - Supported AI Vision Models

public enum AIVisionModel: String, CaseIterable, Identifiable {
    case autoStrongest = "auto"
    case gemini36Flash = "gemini-3.6-flash"
    case gemini25Flash = "gemini-2.5-flash"
    case gemini15Flash = "gemini-1.5-flash"
    case gemini15Pro = "gemini-1.5-pro"
    case gemini20FlashExp = "gemini-2.0-flash-exp"
    case gemini20FlashThinking = "gemini-2.0-flash-thinking-exp-01-21"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .autoStrongest:
            return "⚡ Tự động chọn Vision tốt nhất (Khuyên dùng)"
        case .gemini36Flash:
            return "🔥 Gemini 3.6 Flash (Khuyên dùng theo máy chủ)"
        case .gemini25Flash:
            return "⚡ Gemini 2.5 Flash"
        case .gemini15Flash:
            return "🚀 Gemini 1.5 Flash (Chuẩn chính thức)"
        case .gemini15Pro:
            return "💎 Gemini 1.5 Pro (Phân tích chiều sâu)"
        case .gemini20FlashExp:
            return "🧪 Gemini 2.0 Flash Exp"
        case .gemini20FlashThinking:
            return "🧠 Gemini 2.0 Flash Thinking"
        }
    }
    
    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "gemini-3.6-flash"
        default:
            return rawValue
        }
    }
    
    /// Sequence of standard verified models to try in auto mode
    public static var autoFallbackChain: [String] {
        [
            "gemini-3.6-flash",
            "gemini-2.5-flash",
            "gemini-1.5-flash",
            "gemini-1.5-pro",
            "gemini-2.0-flash-exp",
            "gemini-1.5-flash-8b"
        ]
    }
}

// MARK: - Gemini Response Models

public struct GeminiColorRecipe {
    public let temperatureK: Float     // 5200 - 6800 (tự nhiên chân thực)
    public let saturation: Float       // 0.95 - 1.08 (tươi tắn dịu nhẹ)
    public let contrast: Float         // 0.98 - 1.06 (micro-contrast mượt mà)
    public let shadowLift: Float       // 0.00 - 0.03 (vùng tối mềm mại)
    public let highlightRoll: Float    // 0.96 - 1.00 (giữ chi tiết mây trời)
    public let grain: Float            // 0.00 - 0.02 (sạch sẽ không nhiễu)
    public let vignette: Float         // 0.00 - 0.04 (tự nhiên)
    public let warmthShift: Float      // -0.10 đến +0.10 (vi mô)
    public let colorGrade: AIColorGrade
    
    public var asAIColorParameters: AIColorParameters {
        return AIColorParameters(
            warmthShift: CGFloat(warmthShift),
            saturationBoost: CGFloat(saturation),
            contrastCurve: CGFloat(contrast),
            shadowLift: CGFloat(shadowLift),
            highlightRoll: CGFloat(highlightRoll),
            filmGrain: CGFloat(grain),
            vignetteAmount: CGFloat(vignette),
            colorGrade: colorGrade
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
        colorGrade: .softwarm
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
    case imageConversionFailed
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parseError(String)
    case allModelsFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Chưa cấu hình Gemini API Key. Mở Cài đặt để dán key."
        case .invalidAPIKey(let msg):
            return "API Key không hợp lệ: \(msg). Hãy lấy key mới tại aistudio.google.com"
        case .imageConversionFailed:
            return "Không thể chuyển đổi ảnh để gửi AI."
        case .invalidURL:
            return "URL API không hợp lệ."
        case .networkError(let e):
            return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse:
            return "AI trả về dữ liệu không đúng định dạng."
        case .parseError(let msg):
            return "Lỗi AI: \(msg)"
        case .allModelsFailed(let msg):
            return "Lỗi kết nối Gemini: \(msg)"
        }
    }
}

// MARK: - GeminiService

public final class GeminiService {
    public static let shared = GeminiService()
    
    // Persistent API Key
    public var apiKey: String {
        get { (UserDefaults.standard.string(forKey: "gemini_api_key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "gemini_api_key") }
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
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 50
        return URLSession(configuration: config)
    }()
    
    public init() {}
    
    // MARK: - Test API Key Connection (Fast Ping across standard models)
    
    public func testAPIKey(completion: @escaping (Bool, String) -> Void) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(false, "API Key đang trống.")
            return
        }
        
        var testCandidates = ["gemini-3.6-flash", "gemini-2.5-flash", "gemini-1.5-flash", "gemini-1.5-pro", "gemini-2.0-flash-exp"]
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
            completion(false, "❌ Không thể kết nối với các model Gemini tiêu chuẩn.")
            return
        }
        
        let testModel = candidates[index]
        guard let url = buildURL(for: testModel, key: key) else {
            completion(false, "URL không hợp lệ.")
            return
        }
        
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "Hi"]
                    ]
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
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
                DispatchQueue.main.async { completion(false, "Không nhận được phản hồi.") }
                return
            }
            
            if http.statusCode == 200 {
                DispatchQueue.main.async { completion(true, "✅ Đang hoạt động thật với Gemini (\(testModel))! Độ trễ: \(latency)ms") }
            } else if http.statusCode == 404 {
                self.testModelCandidate(candidates: candidates, index: index + 1, key: key, completion: completion)
            } else {
                let msg = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(false, "❌ Lỗi (\(http.statusCode)): \(msg)") }
            }
        }.resume()
    }
    
    // MARK: - Main Analysis Call with Intelligent Chain
    
    public func analyzeForComposition(
        image: CGImage,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(.noAPIKey))
            return
        }
        
        let uiImage = UIImage(cgImage: image)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.70) else {
            completion(.failure(.imageConversionFailed))
            return
        }
        let base64Image = jpegData.base64EncodedString()
        let prompt = buildPrompt()
        
        var chain = AIVisionModel.autoFallbackChain
        if !customModelName.isEmpty {
            chain.insert(customModelName, at: 0)
        }
        
        let startTime = CACurrentMediaTime()
        
        if selectedModel == .autoStrongest {
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
        } else {
            let modelID = !customModelName.isEmpty ? customModelName : selectedModel.technicalModelID
            executeModelCall(
                modelID: modelID,
                base64Image: base64Image,
                prompt: prompt,
                key: key,
                startTime: startTime,
                completion: completion
            )
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
            let finalMsg = lastErrorMsg.isEmpty ? "Không thể kết nối đến Gemini." : lastErrorMsg
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
                if case .invalidAPIKey = error {
                    completion(.failure(error))
                    return
                }
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
        
        let requestBody: [String: Any] = [
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
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            completion(.failure(.parseError("Không thể tạo request JSON")))
            return
        }
        request.httpBody = bodyData
        
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let latency = Int((CACurrentMediaTime() - startTime) * 1000)
            self.lastLatencyMs = latency
            self.lastModelUsed = modelID
            
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
                if httpResponse.statusCode == 400 && (errorDetails.contains("API_KEY_INVALID") || errorDetails.contains("API key not valid")) {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey(errorDetails))) }
                    return
                }
                if httpResponse.statusCode == 403 {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey(errorDetails))) }
                    return
                }
                DispatchQueue.main.async {
                    completion(.failure(.parseError("\(modelID) [HTTP \(httpResponse.statusCode)]: \(errorDetails)")))
                }
                return
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let textPart = parts.first,
                  let text = textPart["text"] as? String else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }
            
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let jsonData = cleanText.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.parseError("JSON không hợp lệ: \(text.prefix(120))"))) }
                return
            }
            
            let result = Self.parseGeminiResponse(parsed, modelUsed: modelID, latencyMs: latency)
            self.lastExplanation = result.explanation
            DispatchQueue.main.async { completion(.success(result)) }
        }.resume()
    }
    
    // MARK: - Helpers
    
    private func buildURL(for modelID: String, key: String) -> URL? {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(encodedKey)")
    }
    
    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any] else {
            return nil
        }
        return errorObj["message"] as? String
    }
    
    // MARK: - Prompt
    
    private func buildPrompt() -> String {
        """
        You are a World-Class Hasselblad & Leica Master Cinematographer AI. Analyze this camera image to optimize composition, focal zoom, and TRUE-TO-LIFE natural studio color science.
        
        CRITICAL COLOR SCIENCE RULES:
        1. Produce NATURAL, TRUE-TO-LIFE, ORGANIC colors (Leica Natural Color Science).
        2. DO NOT apply tacky, cartoonish, oversaturated, or heavy color cast filters.
        3. Protect authentic human skin tones (rosy, natural, healthy — never yellowish or orange).
        4. Suggest optimal focal zoom: 1.0 (for wide landscapes), 1.5 - 2.5 (for portraits, food, macro, text details to eliminate wide-angle lens facial distortion).
        
        Return ONLY valid JSON (no markdown fences, just pure JSON):
        {
          "target_x": 0.618,
          "target_y": 0.382,
          "suggested_zoom": 1.5,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "explanation": "Chân dung tự nhiên: Khóa mắt vào giao điểm tỷ lệ vàng, tự động zoom 1.5x giảm méo góc rộng.",
          "color_recipe": {
            "temperature_k": 5500,
            "saturation": 1.02,
            "contrast": 1.03,
            "shadow_lift": 0.01,
            "highlight_roll": 0.98,
            "grain": 0.00,
            "vignette": 0.00,
            "warmth_shift": 0.00,
            "color_grade": "softwarm"
          }
        }
        
        Constraints:
        - target_x: 0.05 to 0.95
        - target_y: 0.05 to 0.95
        - suggested_zoom: 1.0 to 3.0 (e.g. 1.0 for wide, 1.5 to 2.5 for portrait/macro)
        - temperature_k: 5000 to 6500 (subtle natural range)
        - saturation: 0.95 to 1.08 (gentle and natural)
        - contrast: 0.98 to 1.06 (soft micro-contrast)
        - shadow_lift: 0.00 to 0.03 (soft shadows)
        - highlight_roll: 0.96 to 1.00 (protect highlight detail)
        - grain: 0.00 to 0.02
        - vignette: 0.00 to 0.04
        - warmth_shift: -0.10 to 0.10
        - explanation: Short Vietnamese advice (1 sentence) on composition and why the zoom/framing was chosen
        """
    }
    
    // MARK: - Response Parsing
    
    private static func parseGeminiResponse(_ json: [String: Any], modelUsed: String, latencyMs: Int) -> GeminiFramingResponse {
        let targetX = parseCGFloat(json["target_x"], defaultVal: 0.618)
        let targetY = parseCGFloat(json["target_y"], defaultVal: 0.382)
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
                saturation: clampF(colorJson["saturation"], 0.90, 1.15, 1.02),
                contrast: clampF(colorJson["contrast"], 0.95, 1.10, 1.02),
                shadowLift: clampF(colorJson["shadow_lift"], 0.00, 0.05, 0.01),
                highlightRoll: clampF(colorJson["highlight_roll"], 0.95, 1.00, 0.98),
                grain: clampF(colorJson["grain"], 0.00, 0.03, 0.00),
                vignette: clampF(colorJson["vignette"], 0.00, 0.05, 0.00),
                warmthShift: clampF(colorJson["warmth_shift"], -0.15, 0.15, 0.0),
                colorGrade: grade
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
    
    private static func clampF(_ val: Any?, _ lo: Float, _ hi: Float, _ def: Float) -> Float {
        let f = parseFloat(val, defaultVal: def)
        return max(lo, min(hi, f))
    }
    
    private static func parseSceneType(_ s: String) -> DetectedSceneType {
        switch s.lowercased() {
        case "portrait": return .portrait
        case "landscape": return .landscape
        case "sunset", "sunrise", "golden_hour": return .sunset
        case "architecture", "building": return .architecture
        case "night", "dark": return .night
        case "food", "macro": return .food
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
        default: return .softwarm
        }
    }
}
