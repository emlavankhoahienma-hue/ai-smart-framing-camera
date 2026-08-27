import Foundation
import UIKit
import CoreGraphics

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
    
    /// Convert to AIColorParameters for FilmFilterEngine
    public var asAIColorParameters: AIColorParameters {
        let gradeStr = colorGrade.rawValue.lowercased()
        let grade: AIColorGrade
        switch gradeStr {
        case "softwarm": grade = .softwarm
        case "coolnatural": grade = .coolnatural
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
    /// Normalized target X (0.0 — 1.0) — where to place the yellow pin
    public let targetX: CGFloat
    /// Normalized target Y (0.0 — 1.0)
    public let targetY: CGFloat
    public let sceneType: DetectedSceneType
    public let colorRecipe: GeminiColorRecipe
    public let compositionRule: CompositionRule
    public let explanation: String
}

// MARK: - Errors

public enum GeminiError: LocalizedError {
    case noAPIKey
    case imageConversionFailed
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parseError(String)
    
    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Chưa cấu hình Gemini API Key. Vào Settings để nhập key."
        case .imageConversionFailed: return "Không thể chuyển đổi ảnh để gửi Gemini."
        case .invalidURL: return "URL không hợp lệ."
        case .networkError(let e): return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse: return "Gemini trả về dữ liệu không đúng định dạng."
        case .parseError(let msg): return "Lỗi parse JSON: \(msg)"
        }
    }
}

// MARK: - GeminiService

public final class GeminiService {
    public static let shared = GeminiService()
    
    // Persistent API Key stored in UserDefaults
    public var apiKey: String {
        get { UserDefaults.standard.string(forKey: "gemini_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gemini_api_key") }
    }
    
    public var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    
    // Gemini 2.0 Flash (multimodal vision) endpoint
    private let model = "gemini-2.0-flash-exp"
    private var baseURL: String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    }
    
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    
    public init() {}
    
    // MARK: - Main Analysis Call
    
    /// Analyze a captured frame → return framing target coordinates + color recipe
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
                "temperature": 0.25,
                "topK": 32,
                "topP": 1.0,
                "maxOutputTokens": 768,
                "responseMimeType": "application/json"
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
            ]
        ]
        
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else {
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            completion(.failure(.parseError("Cannot serialize request body")))
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
            
            // Parse Gemini API response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let textPart = parts.first,
                  let text = textPart["text"] as? String else {
                
                // Try to get error message
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj = errorJson["error"] as? [String: Any],
                   let message = errObj["message"] as? String {
                    DispatchQueue.main.async { completion(.failure(.parseError(message))) }
                } else {
                    DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                }
                return
            }
            
            // Parse the JSON text returned by Gemini
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let jsonData = cleanText.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.parseError("Cannot parse Gemini JSON: \(text.prefix(200))"))) }
                return
            }
            
            let response = Self.parseGeminiResponse(parsed)
            DispatchQueue.main.async { completion(.success(response)) }
        }.resume()
    }
    
    // MARK: - Prompt
    
    private func buildPrompt() -> String {
        return """
        You are an expert photography composition AI. Analyze this image and return ONLY a valid JSON object.
        
        Analyze:
        1. Main subject/focal point
        2. Best composition target position using photographic rules (Rule of Thirds, Golden Ratio, etc.)
        3. Ideal cinematic color grading for this specific scene
        
        Return this EXACT JSON structure (no markdown, no explanation, just JSON):
        {
          "target_x": 0.618,
          "target_y": 0.382,
          "scene_type": "portrait",
          "composition_rule": "golden_ratio",
          "explanation": "Main subject should be placed at Golden Ratio intersection",
          "color_recipe": {
            "temperature_k": 5500,
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
        
        Field constraints:
        - target_x: 0.0 (left) to 1.0 (right) — X position for optimal framing
        - target_y: 0.0 (top) to 1.0 (bottom) — Y position for optimal framing
        - scene_type: "portrait" | "landscape" | "sunset" | "architecture" | "night" | "food" | "street" | "general"
        - composition_rule: "rule_of_thirds" | "golden_ratio" | "center_symmetry" | "golden_spiral"
        - temperature_k: 2700 (very warm candlelight) to 9000 (very cool blue sky)
        - saturation: 0.50 (desaturated/film) to 1.80 (vivid/HDR)
        - contrast: 0.80 (flat/matte) to 1.50 (punchy/cinematic)
        - shadow_lift: 0.00 (deep blacks) to 0.12 (lifted/faded shadows)
        - highlight_roll: 0.85 (compressed highlights) to 1.00 (preserved highlights)
        - grain: 0.00 (digital clean) to 0.50 (heavy 35mm grain)
        - vignette: 0.00 (no vignette) to 0.70 (heavy vignette)
        - warmth_shift: -1.0 (arctic cool) to 1.0 (golden warm)
        - color_grade: "softwarm" | "coolnatural" | "golden" | "tealOrange" | "moody" | "vibrant" | "classic"
        
        Be precise and creative. Match the color recipe to the actual mood and content of the scene.
        """
    }
    
    // MARK: - Response Parsing
    
    private static func parseGeminiResponse(_ json: [String: Any]) -> GeminiFramingResponse {
        let targetX = parseCGFloat(json["target_x"], defaultVal: 0.618)
        let targetY = parseCGFloat(json["target_y"], defaultVal: 0.382)
        let explanation = (json["explanation"] as? String) ?? "AI composition analysis complete"
        
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
            explanation: explanation
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
