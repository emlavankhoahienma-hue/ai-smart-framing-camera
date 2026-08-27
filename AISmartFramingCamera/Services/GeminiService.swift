import Foundation
import UIKit
import CoreGraphics

// MARK: - Supported AI Vision Models

public enum AIVisionModel: String, CaseIterable, Identifiable {
    case autoStrongest = "auto"
    case gemini25Pro = "gemini-2.5-pro"
    case gemini20ProExp = "gemini-2.0-pro-exp-02-05"
    case gemini20FlashThinking = "gemini-2.0-flash-thinking-exp-01-21"
    case gemini20Flash = "gemini-2.0-flash-exp"
    case gemini15Pro = "gemini-1.5-pro"
    case gemini15Flash = "gemini-1.5-flash"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .autoStrongest:
            return "⚡ Tự động chọn Vision mạnh nhất (Khuyên dùng)"
        case .gemini25Pro:
            return "💎 Gemini 2.5 Pro Vision (Mạnh nhất)"
        case .gemini20ProExp:
            return "🎯 Gemini 2.0 Pro Exp (Chuyên thị giác)"
        case .gemini20FlashThinking:
            return "🧠 Gemini 2.0 Flash Thinking (Tư duy bố cục)"
        case .gemini20Flash:
            return "⚡ Gemini 2.0 Flash (Tốc độ cao)"
        case .gemini15Pro:
            return "🏆 Gemini 1.5 Pro Vision"
        case .gemini15Flash:
            return "🚀 Gemini 1.5 Flash (Tiết kiệm)"
        }
    }
    
    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "gemini-2.0-pro-exp-02-05" // Starting candidate
        default:
            return rawValue
        }
    }
    
    /// Sequence of models to try in autoStrongest mode
    public static var autoFallbackChain: [String] {
        [
            "gemini-2.5-pro",
            "gemini-2.0-pro-exp-02-05",
            "gemini-2.0-flash-exp",
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "gemini-1.5-flash"
        ]
    }
}

// MARK: - Gemini Response Models

public struct GeminiColorRecipe {
    public let temperatureK: Float     // 2700 (warm) — 9000 (cool)
    public let saturation: Float       // 0.5 (muted) — 1.8 (vivid)
    public let contrast: Float         // 0.8 (flat) — 1.5 (punchy)
    public let shadowLift: Float       // 0.0 — 0.12 (lifted shadows)
    public let highlightRoll: Float    // 0.85 — 1.0 (highlight rolloff)
    public let grain: Float            // 0.0 — 0.5 (film grain)
    public let vignette: Float         // 0.0 — 0.7 (vignette strength)
    public let warmthShift: Float      // -1.0 cool, +1.0 warm
    public let colorGrade: AIColorGrade
    
    public var asAIColorParameters: AIColorParameters {
        let gradeStr = colorGrade.rawValue.lowercased()
        let grade: AIColorGrade
        switch gradeStr {
        case "softwarm": grade = .softwarm
        case "coolnatural", "cool_natural": grade = .coolnatural
        case "golden": grade = .golden
        case "tealorange", "teal_orange": grade = .tealOrange
        case "moody": grade = .moody
        case "vibrant": grade = .vibrant
        case "classic": grade = .classic
        default: grade = .softwarm
        }
        return AIColorParameters(
            warmthShift: CGFloat(warmthShift),
            saturationBoost: CGFloat(saturation),
            contrastCurve: CGFloat(contrast),
            shadowLift: CGFloat(shadowLift),
            highlightRoll: CGFloat(highlightRoll),
            filmGrain: CGFloat(grain),
            vignetteAmount: CGFloat(vignette),
            colorGrade: grade
        )
    }
    
    public static let defaultRecipe = GeminiColorRecipe(
        temperatureK: 5500,
        saturation: 1.05,
        contrast: 1.05,
        shadowLift: 0.02,
        highlightRoll: 0.97,
        grain: 0.10,
        vignette: 0.15,
        warmthShift: 0.0,
        colorGrade: .softwarm
    )
}

public struct GeminiFramingResponse {
    public let targetX: CGFloat
    public let targetY: CGFloat
    public let sceneType: DetectedSceneType
    public let colorRecipe: GeminiColorRecipe
    public let compositionRule: CompositionRule
    public let explanation: String
    public let modelUsed: String
}

// MARK: - Errors

public enum GeminiError: LocalizedError {
    case noAPIKey
    case imageConversionFailed
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parseError(String)
    case allModelsFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Chưa cấu hình Gemini API Key. Mở Cài đặt để dán key."
        case .imageConversionFailed: return "Không thể chuyển đổi ảnh để gửi AI."
        case .invalidURL: return "URL API không hợp lệ."
        case .networkError(let e): return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse: return "AI trả về dữ liệu không đúng định dạng."
        case .parseError(let msg): return "Lỗi parse JSON: \(msg)"
        case .allModelsFailed(let msg): return "Tất cả model Vision đều không phản hồi: \(msg)"
        }
    }
}

// MARK: - GeminiService

public final class GeminiService {
    public static let shared = GeminiService()
    
    // Persistent API Key
    public var apiKey: String {
        get { UserDefaults.standard.string(forKey: "gemini_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gemini_api_key") }
    }
    
    public var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    
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
    
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 50
        return URLSession(configuration: config)
    }()
    
    public init() {}
    
    // MARK: - Main Analysis Call with Auto-Fallback Chain
    
    public func analyzeForComposition(
        image: CGImage,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        guard hasAPIKey else {
            completion(.failure(.noAPIKey))
            return
        }
        
        let uiImage = UIImage(cgImage: image)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.72) else {
            completion(.failure(.imageConversionFailed))
            return
        }
        let base64Image = jpegData.base64EncodedString()
        let prompt = buildPrompt()
        
        if selectedModel == .autoStrongest {
            // Auto mode: try the strongest models in sequence until one succeeds
            tryModelChain(
                chain: AIVisionModel.autoFallbackChain,
                index: 0,
                base64Image: base64Image,
                prompt: prompt,
                completion: completion
            )
        } else {
            // Specific model
            executeModelCall(
                modelID: selectedModel.technicalModelID,
                base64Image: base64Image,
                prompt: prompt,
                completion: completion
            )
        }
    }
    
    private func tryModelChain(
        chain: [String],
        index: Int,
        base64Image: String,
        prompt: String,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        guard index < chain.count else {
            completion(.failure(.allModelsFailed("Đã thử toàn bộ danh sách model")))
            return
        }
        
        let currentModelID = chain[index]
        executeModelCall(
            modelID: currentModelID,
            base64Image: base64Image,
            prompt: prompt
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                completion(.success(response))
            case .failure:
                // Fallback to next model in chain
                self.tryModelChain(
                    chain: chain,
                    index: index + 1,
                    base64Image: base64Image,
                    prompt: prompt,
                    completion: completion
                )
            }
        }
    }
    
    private func executeModelCall(
        modelID: String,
        base64Image: String,
        prompt: String,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
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
                "temperature": 0.20,
                "topK": 32,
                "topP": 0.95,
                "maxOutputTokens": 768,
                "responseMimeType": "application/json"
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            completion(.failure(.parseError("Không thể tạo request body")))
            return
        }
        request.httpBody = bodyData
        
        urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.networkError(error))) }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }
            
            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj = errorJson["error"] as? [String: Any],
                   let message = errObj["message"] as? String {
                    DispatchQueue.main.async { completion(.failure(.parseError("\(modelID) [HTTP \(httpResponse.statusCode)]: \(message)"))) }
                } else {
                    DispatchQueue.main.async { completion(.failure(.parseError("\(modelID) failed with HTTP \(httpResponse.statusCode)"))) }
                }
                return
            }
            
            // Parse response
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
            
            let result = Self.parseGeminiResponse(parsed, modelUsed: modelID)
            DispatchQueue.main.async { completion(.success(result)) }
        }.resume()
    }
    
    // MARK: - Prompt
    
    private func buildPrompt() -> String {
        """
        You are an elite master photographer & cinematography AI. Analyze this image with deep visual perception and return ONLY a valid JSON object.
        
        Analyze:
        1. Primary visual focal subject (human face, body, pet, architecture, or salient item)
        2. Optimal framing anchor position based on classical and modern compositional harmony (Rule of Thirds, Golden Ratio, Golden Spiral)
        3. Scene mood & cinematic color grading recipe
        
        Return this EXACT JSON format (no markdown fences, just pure JSON):
        {
          "target_x": 0.618,
          "target_y": 0.382,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "explanation": "Khóa chủ thể tại giao điểm tỷ lệ vàng phía bên phải",
          "color_recipe": {
            "temperature_k": 5600,
            "saturation": 1.08,
            "contrast": 1.06,
            "shadow_lift": 0.03,
            "highlight_roll": 0.95,
            "grain": 0.12,
            "vignette": 0.20,
            "warmth_shift": 0.05,
            "color_grade": "softwarm"
          }
        }
        
        Constraints:
        - target_x: 0.05 to 0.95 (normalized X coordinate for sniper target pin)
        - target_y: 0.05 to 0.95 (normalized Y coordinate for sniper target pin)
        - scene_type: "portrait" | "landscape" | "sunset" | "architecture" | "night" | "food" | "street" | "general"
        - composition_rule: "rule_of_thirds" | "golden_ratio" | "center_symmetry" | "golden_spiral"
        - temperature_k: 2700 to 9000
        - saturation: 0.50 to 1.80
        - contrast: 0.80 to 1.50
        - shadow_lift: 0.00 to 0.12
        - highlight_roll: 0.85 to 1.00
        - grain: 0.00 to 0.50
        - vignette: 0.00 to 0.70
        - warmth_shift: -1.0 to 1.0
        - color_grade: "softwarm" | "coolnatural" | "golden" | "tealOrange" | "moody" | "vibrant" | "classic"
        - explanation: Short Vietnamese advice (1-2 sentences) on how to angle the camera
        """
    }
    
    // MARK: - Response Parsing
    
    private static func parseGeminiResponse(_ json: [String: Any], modelUsed: String) -> GeminiFramingResponse {
        let targetX = parseCGFloat(json["target_x"], defaultVal: 0.618)
        let targetY = parseCGFloat(json["target_y"], defaultVal: 0.382)
        let explanation = (json["explanation"] as? String) ?? "AI phân tích bố cục hoàn tất"
        
        let sceneType = parseSceneType((json["scene_type"] as? String) ?? "general")
        let compositionRule = parseCompositionRule((json["composition_rule"] as? String) ?? "golden_ratio")
        
        var colorRecipe = GeminiColorRecipe.defaultRecipe
        if let colorJson = json["color_recipe"] as? [String: Any] {
            let gradeStr = (colorJson["color_grade"] as? String) ?? "softwarm"
            let grade = parseColorGrade(gradeStr)
            colorRecipe = GeminiColorRecipe(
                temperatureK: parseFloat(colorJson["temperature_k"], defaultVal: 5500),
                saturation: clampF(colorJson["saturation"], 0.50, 1.80, 1.05),
                contrast: clampF(colorJson["contrast"], 0.80, 1.50, 1.05),
                shadowLift: clampF(colorJson["shadow_lift"], 0.00, 0.12, 0.02),
                highlightRoll: clampF(colorJson["highlight_roll"], 0.85, 1.00, 0.97),
                grain: clampF(colorJson["grain"], 0.00, 0.50, 0.10),
                vignette: clampF(colorJson["vignette"], 0.00, 0.70, 0.15),
                warmthShift: clampF(colorJson["warmth_shift"], -1.0, 1.0, 0.0),
                colorGrade: grade
            )
        }
        
        return GeminiFramingResponse(
            targetX: max(0.05, min(0.95, targetX)),
            targetY: max(0.05, min(0.95, targetY)),
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: compositionRule,
            explanation: explanation,
            modelUsed: modelUsed
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
