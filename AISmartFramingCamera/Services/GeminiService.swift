import Foundation
import UIKit
import CoreGraphics

// MARK: - 2026 Multi-Provider AI Gateway Architecture
public enum AICloudProvider: String, CaseIterable, Identifiable, Codable {
    case openRouter   = "openrouter"
    case googleGemini = "google_gemini"
    case openAI       = "openai"
    case anthropic    = "anthropic"
    case groq         = "groq"
    case xAI          = "xai"
    case deepSeek     = "deepseek"
    case custom       = "custom_openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter:   return "OpenRouter (Đa Model 2026)"
        case .googleGemini: return "Google Gemini API (Trực tiếp)"
        case .openAI:       return "OpenAI API (GPT-5 / GPT-4.1)"
        case .anthropic:    return "Anthropic API (Claude 4.5 / 4)"
        case .groq:         return "Groq Cloud (LPU Siêu tốc)"
        case .xAI:          return "xAI API (Grok 4 Vision)"
        case .deepSeek:     return "DeepSeek API (VL2 / R2)"
        case .custom:       return "Tùy chỉnh (OpenAI-Compatible)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .openRouter:   return "OpenRouter"
        case .googleGemini: return "Google AI"
        case .openAI:       return "OpenAI"
        case .anthropic:    return "Anthropic"
        case .groq:         return "Groq LPU"
        case .xAI:          return "xAI Grok"
        case .deepSeek:     return "DeepSeek"
        case .custom:       return "Custom API"
        }
    }

    public var defaultChatCompletionsURL: String {
        switch self {
        case .openRouter:   return "https://openrouter.ai/api/v1/chat/completions"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .openAI:       return "https://api.openai.com/v1/chat/completions"
        case .anthropic:    return "https://api.anthropic.com/v1/messages"
        case .groq:         return "https://api.groq.com/openai/v1/chat/completions"
        case .xAI:          return "https://api.x.ai/v1/chat/completions"
        case .deepSeek:     return "https://api.deepseek.com/v1/chat/completions"
        case .custom:       return "https://api.openai.com/v1/chat/completions"
        }
    }

    public var defaultModelsURL: String {
        switch self {
        case .openRouter:   return "https://openrouter.ai/api/v1/models"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/openai/models"
        case .openAI:       return "https://api.openai.com/v1/models"
        case .anthropic:    return "https://api.anthropic.com/v1/models"
        case .groq:         return "https://api.groq.com/openai/v1/models"
        case .xAI:          return "https://api.x.ai/v1/models"
        case .deepSeek:     return "https://api.deepseek.com/v1/models"
        case .custom:       return ""
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .openRouter:   return "Dán OpenRouter Key (sk-or-v1-...)"
        case .googleGemini: return "Dán Google AI Studio Key (AIzaSy...)"
        case .openAI:       return "Dán OpenAI API Key (sk-proj-...)"
        case .anthropic:    return "Dán Anthropic Key (sk-ant-...)"
        case .groq:         return "Dán Groq API Key (gsk_...)"
        case .xAI:          return "Dán xAI API Key (xai-...)"
        case .deepSeek:     return "Dán DeepSeek API Key (sk-...)"
        case .custom:       return "Dán Bearer API Key..."
        }
    }

    public var defaultModelID: String {
        switch self {
        case .openRouter:   return "google/gemma-4-31b-it:free"
        case .googleGemini: return "gemini-2.5-flash"
        case .openAI:       return "gpt-4.1-mini"
        case .anthropic:    return "claude-sonnet-4-20250514"
        case .groq:         return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .xAI:          return "grok-2-vision-1212"
        case .deepSeek:     return "deepseek-chat"
        case .custom:       return "gpt-4.1-mini"
        }
    }
}

// MARK: - Saved Multi-API Connection Profile
public struct AIConnectionProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    public var label: String
    public var provider: AICloudProvider
    public var customEndpoint: String
    public var modelID: String
    public var apiKeyPreview: String

    public init(id: UUID = UUID(), label: String, provider: AICloudProvider, customEndpoint: String = "", modelID: String, apiKeyPreview: String) {
        self.id = id
        self.label = label
        self.provider = provider
        self.customEndpoint = customEndpoint
        self.modelID = modelID
        self.apiKeyPreview = apiKeyPreview
    }
}

// MARK: - 2026 Vision Model Catalog (Built-in + Dynamic Discovery)
public enum AIVisionModel: String, CaseIterable, Identifiable {
    // Free & High-Speed Models
    case freeVision        = "google/gemma-4-31b-it:free"
    case gemini25FlashFree = "google/gemini-2.5-flash-preview:free"
    case qwen3VLFree       = "qwen/qwen3-vl-32b-instruct:free"
    case llama4MaverickFree = "meta-llama/llama-4-maverick:free"

    // 2026 Flagship Google Gemini
    case gemini31FlashLite = "google/gemini-3.1-flash-lite-preview"
    case gemini31Pro       = "google/gemini-3.1-pro-preview"
    case gemini25Pro       = "google/gemini-2.5-pro"
    case gemini25Flash     = "google/gemini-2.5-flash"
    case geminiDirect25Flash = "gemini-2.5-flash"
    case geminiDirect25Pro   = "gemini-2.5-pro"

    // 2026 Flagship OpenAI GPT-5 / GPT-4.1 / o4
    case gpt5              = "openai/gpt-5-chat"
    case gpt5Mini          = "openai/gpt-5-mini"
    case gpt41             = "openai/gpt-4.1"
    case gpt41Mini         = "openai/gpt-4.1-mini"
    case o4MiniHigh        = "openai/o4-mini-high"

    // 2026 Flagship Anthropic Claude 4.5 / 4
    case claude45Sonnet    = "anthropic/claude-sonnet-4.5"
    case claude4Sonnet     = "anthropic/claude-sonnet-4"
    case claude37Sonnet    = "anthropic/claude-3.7-sonnet"

    // 2026 Multimodal Open-Weights & xAI
    case llama4Maverick    = "meta-llama/llama-4-maverick"
    case qwen25VL72B       = "qwen/qwen2.5-vl-72b-instruct"
    case grok4Vision       = "x-ai/grok-4"
    case pixtralLarge      = "mistralai/pixtral-large-2411"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .freeVision:          return "Gemma 4 31B Vision (Miễn phí)"
        case .gemini25FlashFree:   return "Gemini 2.5 Flash (Miễn phí)"
        case .qwen3VLFree:         return "Qwen 3 VL 32B (Miễn phí)"
        case .llama4MaverickFree:  return "Llama 4 Maverick 17B (Miễn phí)"
        case .gemini31FlashLite:   return "Gemini 3.1 Flash Lite (2026 Siêu tốc)"
        case .gemini31Pro:         return "Gemini 3.1 Pro (2026 Cao cấp)"
        case .gemini25Pro:         return "Gemini 2.5 Pro Vision"
        case .gemini25Flash:       return "Gemini 2.5 Flash Vision"
        case .geminiDirect25Flash: return "[Google Direct] Gemini 2.5 Flash"
        case .geminiDirect25Pro:   return "[Google Direct] Gemini 2.5 Pro"
        case .gpt5:                return "OpenAI GPT-5 Vision (2026 Flagship)"
        case .gpt5Mini:            return "OpenAI GPT-5 Mini Vision (Nhanh)"
        case .gpt41:               return "OpenAI GPT-4.1 Vision"
        case .gpt41Mini:           return "OpenAI GPT-4.1 Mini (Tiết kiệm)"
        case .o4MiniHigh:          return "OpenAI o4-mini High (Suy luận ảnh)"
        case .claude45Sonnet:      return "Claude 4.5 Sonnet Vision (2026)"
        case .claude4Sonnet:       return "Claude 4 Sonnet Vision"
        case .claude37Sonnet:      return "Claude 3.7 Sonnet Vision"
        case .llama4Maverick:      return "Meta Llama 4 Maverick Multimodal"
        case .qwen25VL72B:         return "Qwen 2.5 VL 72B Instruct"
        case .grok4Vision:         return "xAI Grok 4 Vision (2026)"
        case .pixtralLarge:        return "Mistral Pixtral Large Vision"
        }
    }

    public var subtitle: String {
        switch self {
        case .freeVision, .gemini25FlashFree, .qwen3VLFree, .llama4MaverickFree:
            return "Miễn phí qua OpenRouter — tự động xoay vòng dự phòng khi quá tải"
        case .gemini31FlashLite, .gemini25Flash, .geminiDirect25Flash, .gpt5Mini, .gpt41Mini:
            return "Tốc độ phản hồi cực nhanh (<1.2s), tối ưu tiết kiệm token"
        case .gemini31Pro, .gemini25Pro, .geminiDirect25Pro, .gpt5, .claude45Sonnet, .claude4Sonnet, .o4MiniHigh:
            return "Độ chính xác bố cục & thẩm mỹ nhiếp ảnh đỉnh cao 2026"
        default:
            return "Mô hình thị giác đa phương thức thế hệ mới 2026"
        }
    }

    public var isFreeTier: Bool {
        rawValue.hasSuffix(":free")
    }
}

// MARK: - AI Full Color Parameter Bridge
public struct GeminiColorRecipe: Codable, Equatable {
    public var exposureEV: Double = 0.0
    public var contrast: Double = 1.0
    public var saturation: Double = 1.0
    public var warmth: Double = 6500
    public var tint: Double = 0.0
    public var highlights: Double = 0.0
    public var shadows: Double = 0.0
    public var vibrance: Double = 0.0
    public var filmGrain: Double = 0.0
    public var vignette: Double = 0.0

    public init(
        exposureEV: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0,
        warmth: Double = 6500,
        tint: Double = 0.0,
        highlights: Double = 0.0,
        shadows: Double = 0.0,
        vibrance: Double = 0.0,
        filmGrain: Double = 0.0,
        vignette: Double = 0.0
    ) {
        self.exposureEV = exposureEV
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.vibrance = vibrance
        self.filmGrain = filmGrain
        self.vignette = vignette
    }

    public var asAIColorParameters: AIColorParameters {
        AIColorParameters(
            exposureEV: Float(exposureEV),
            contrast: Float(contrast),
            saturation: Float(saturation),
            temperatureKelvin: Float(warmth),
            tint: Float(tint),
            highlights: Float(highlights),
            shadows: Float(shadows),
            vibrance: Float(vibrance),
            grainIntensity: Float(filmGrain),
            vignetteIntensity: Float(vignette)
        )
    }
}

public struct GeminiFramingResponse {
    public let targetX: CGFloat
    public let targetY: CGFloat
    public let compositionRule: CompositionRule
    public let sceneType: SceneCategory
    public let suggestedZoom: CGFloat
    public let explanation: String
    public let colorRecipe: GeminiColorRecipe
    public let recommendedPreset: FilmPreset
    public let presetExplanation: String
    public let modelUsed: String
    public let latencyMs: Int
}

public enum GeminiServiceError: LocalizedError {
    case missingAPIKey
    case imageEncodingFailed
    case invalidEndpoint
    case networkError(Error)
    case httpError(Int, String)
    case emptyResponse
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Chưa cấu hình API Key. Đã tự động chuyển sang AI trên máy."
        case .imageEncodingFailed:
            return "Không thể nén khung hình gửi Cloud AI."
        case .invalidEndpoint:
            return "Địa chỉ Endpoint API không hợp lệ."
        case .networkError(let err):
            return "Lỗi kết nối mạng (\(err.localizedDescription)) — đã chuyển sang AI trên máy."
        case .httpError(let code, let detail):
            return "Cloud API HTTP \(code): \(detail)"
        case .emptyResponse:
            return "Cloud AI trả về phản hồi rỗng."
        case .invalidJSON(let raw):
            return "Không đọc được JSON từ Cloud AI: \(raw.prefix(90))"
        }
    }
}

// MARK: - Main Cloud AI Service (Multi-Provider + Token-Optimized 2026)
public final class GeminiService: ObservableObject {
    public static let shared = GeminiService()

    public var onActiveKeyConfigured: ((Bool) -> Void)?

    private let keychainAccount = "openrouter_api_key"
    private let profilesStorageKey = "ai_cloud_connection_profiles_v2026"

    @Published public var selectedProvider: AICloudProvider = .openRouter {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "ai_selected_provider_2026")
        }
    }

    @Published public var customEndpointURL: String = "" {
        didSet {
            UserDefaults.standard.set(customEndpointURL, forKey: "ai_custom_endpoint_url_2026")
        }
    }

    @Published public var selectedModel: AIVisionModel = .freeVision {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "openrouter_selected_model")
        }
    }

    @Published public var customModelName: String = "" {
        didSet {
            UserDefaults.standard.set(customModelName, forKey: "openrouter_custom_model")
        }
    }

    @Published public var savedProfiles: [AIConnectionProfile] = []
    @Published public var activeProfileID: UUID? = nil {
        didSet {
            if let id = activeProfileID {
                UserDefaults.standard.set(id.uuidString, forKey: "ai_active_profile_id_2026")
            } else {
                UserDefaults.standard.removeObject(forKey: "ai_active_profile_id_2026")
            }
        }
    }

    @Published public var discoveredModels: [String] = []
    @Published public var isFetchingModels: Bool = false

    /// Free fallback chain on OpenRouter
    private let freeFallbackModels: [String] = [
        "google/gemma-4-31b-it:free",
        "google/gemini-2.5-flash-preview:free",
        "qwen/qwen3-vl-32b-instruct:free",
        "meta-llama/llama-4-maverick:free",
        "google/gemma-3-27b-it:free"
    ]

    public var cloudAnalysisDeadline: TimeInterval {
        let custom = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return 9.5 }
        return selectedModel.isFreeTier ? 12.0 : 8.5
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.5
        config.timeoutIntervalForResource = 12.0
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        if let savedProv = UserDefaults.standard.string(forKey: "ai_selected_provider_2026"),
           let prov = AICloudProvider(rawValue: savedProv) {
            self.selectedProvider = prov
        }
        if let savedEndpoint = UserDefaults.standard.string(forKey: "ai_custom_endpoint_url_2026") {
            self.customEndpointURL = savedEndpoint
        }
        if let savedModel = UserDefaults.standard.string(forKey: "openrouter_selected_model"),
           let model = AIVisionModel(rawValue: savedModel) {
            self.selectedModel = model
        }
        if let savedCustom = UserDefaults.standard.string(forKey: "openrouter_custom_model") {
            self.customModelName = savedCustom
        }
        loadProfiles()
        if let idStr = UserDefaults.standard.string(forKey: "ai_active_profile_id_2026"),
           let uuid = UUID(uuidString: idStr) {
            self.activeProfileID = uuid
        }
    }

    // MARK: - Keychain & Multi-Profile Management
    private func keychainAccountForProvider(_ provider: AICloudProvider, profileID: UUID? = nil) -> String {
        if let pid = profileID {
            return "ai_profile_key_\(pid.uuidString)"
        }
        if provider == .openRouter {
            return keychainAccount
        }
        return "ai_provider_key_\(provider.rawValue)"
    }

    public var apiKey: String {
        get {
            if let pid = activeProfileID,
               let key = KeychainHelper.shared.readString(account: keychainAccountForProvider(selectedProvider, profileID: pid)),
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let key = KeychainHelper.shared.readString(account: keychainAccountForProvider(selectedProvider)),
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let fallback = KeychainHelper.shared.readString(account: keychainAccount),
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let acct = keychainAccountForProvider(selectedProvider, profileID: activeProfileID)
            if trimmed.isEmpty {
                KeychainHelper.shared.delete(account: acct)
                if selectedProvider == .openRouter {
                    KeychainHelper.shared.delete(account: keychainAccount)
                }
                onActiveKeyConfigured?(hasAPIKey)
            } else {
                // Auto-detect provider from key prefix if user pasted directly
                if trimmed.hasPrefix("sk-or-v1-") && selectedProvider != .openRouter && selectedProvider != .custom {
                    selectedProvider = .openRouter
                } else if trimmed.hasPrefix("AIzaSy") && selectedProvider != .googleGemini && selectedProvider != .custom {
                    selectedProvider = .googleGemini
                } else if trimmed.hasPrefix("sk-ant-") && selectedProvider != .anthropic && selectedProvider != .custom {
                    selectedProvider = .anthropic
                } else if trimmed.hasPrefix("gsk_") && selectedProvider != .groq && selectedProvider != .custom {
                    selectedProvider = .groq
                } else if trimmed.hasPrefix("xai-") && selectedProvider != .xAI && selectedProvider != .custom {
                    selectedProvider = .xAI
                }
                let finalAcct = keychainAccountForProvider(selectedProvider, profileID: activeProfileID)
                KeychainHelper.shared.saveString(trimmed, account: finalAcct)
                if selectedProvider == .openRouter {
                    KeychainHelper.shared.saveString(trimmed, account: keychainAccount)
                }
                onActiveKeyConfigured?(true)
            }
            objectWillChange.send()
        }
    }

    public var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    public func addOrUpdateProfile(label: String, provider: AICloudProvider, apiKey: String, customEndpoint: String, modelID: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let suffix = String(trimmedKey.suffix(4))
        let prefix = String(trimmedKey.prefix(min(6, trimmedKey.count)))
        let preview = "\(prefix)••••\(suffix)"
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultModelID : modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AIConnectionProfile(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(provider.shortBadge) (\(cleanModel))" : label,
            provider: provider,
            customEndpoint: customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: cleanModel,
            apiKeyPreview: preview
        )
        KeychainHelper.shared.saveString(trimmedKey, account: keychainAccountForProvider(provider, profileID: profile.id))
        savedProfiles.insert(profile, at: 0)
        saveProfiles()
        activateProfile(profile)
    }

    public func activateProfile(_ profile: AIConnectionProfile) {
        activeProfileID = profile.id
        selectedProvider = profile.provider
        customEndpointURL = profile.customEndpoint
        if let known = AIVisionModel(rawValue: profile.modelID) {
            selectedModel = known
            customModelName = ""
        } else {
            customModelName = profile.modelID
        }
        onActiveKeyConfigured?(hasAPIKey)
        objectWillChange.send()
    }

    public func deleteProfile(_ profile: AIConnectionProfile) {
        KeychainHelper.shared.delete(account: keychainAccountForProvider(profile.provider, profileID: profile.id))
        savedProfiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = savedProfiles.first?.id
            if let first = savedProfiles.first {
                activateProfile(first)
            }
        }
        saveProfiles()
        onActiveKeyConfigured?(hasAPIKey)
        objectWillChange.send()
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: profilesStorageKey),
              let decoded = try? JSONDecoder().decode([AIConnectionProfile].self, from: data) else { return }
        self.savedProfiles = decoded
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(savedProfiles) {
            UserDefaults.standard.set(data, forKey: profilesStorageKey)
        }
    }

    // MARK: - Resolved Endpoint & Active Model ID
    public var activeEndpointURLString: String {
        let custom = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            if custom.hasSuffix("/chat/completions") || custom.hasSuffix("/messages") {
                return custom
            }
            return custom.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }
        return selectedProvider.defaultChatCompletionsURL
    }

    public var activeModelID: String {
        let custom = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if selectedProvider == .googleGemini {
            let raw = selectedModel.rawValue
            return raw.hasPrefix("google/") ? String(raw.dropFirst("google/".count)).replacingOccurrences(of: ":free", with: "") : raw
        }
        if selectedProvider != .openRouter && selectedModel.rawValue.contains("/") {
            let parts = selectedModel.rawValue.split(separator: "/")
            if parts.count == 2 {
                return String(parts[1]).replacingOccurrences(of: ":free", with: "")
            }
        }
        return selectedModel.rawValue
    }

    // MARK: - Live Model Discovery from Provider API (2026 Models)
    public func fetchAvailableModels() async -> (Bool, String) {
        let key = apiKey
        var modelsURLStr = selectedProvider.defaultModelsURL
        let customBase = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customBase.isEmpty {
            let normalized = customBase
                .replacingOccurrences(of: "/chat/completions", with: "")
                .replacingOccurrences(of: "/messages", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            modelsURLStr = normalized + "/models"
        }
        guard let url = URL(string: modelsURLStr) else {
            return (false, "URL danh sách model không hợp lệ")
        }

        await MainActor.run { self.isFetchingModels = true }
        defer { Task { @MainActor in self.isFetchingModels = false } }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0
        if !key.isEmpty {
            if selectedProvider == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return (false, "HTTP \(code) khi tải danh sách model")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]] else {
                return (false, "Định dạng danh sách model không khớp")
            }
            let ids: [String] = arr.compactMap { $0["id"] as? String }
            let prioritized = ids.sorted { a, b in
                let aVision = a.lowercased().contains("vl") || a.lowercased().contains("gemini") || a.lowercased().contains("gpt-4") || a.lowercased().contains("gpt-5") || a.lowercased().contains("claude") || a.lowercased().contains("vision") || a.lowercased().contains("gemma-4") || a.lowercased().contains("llama-4") || a.lowercased().contains("grok")
                let bVision = b.lowercased().contains("vl") || b.lowercased().contains("gemini") || b.lowercased().contains("gpt-4") || b.lowercased().contains("gpt-5") || b.lowercased().contains("claude") || b.lowercased().contains("vision") || b.lowercased().contains("gemma-4") || b.lowercased().contains("llama-4") || b.lowercased().contains("grok")
                if aVision != bVision { return aVision }
                return a < b
            }
            let capped = Array(prioritized.prefix(200))
            await MainActor.run {
                self.discoveredModels = capped
            }
            return (true, "Đã tải \(capped.count) model mới nhất từ \(selectedProvider.shortBadge)")
        } catch {
            return (false, "Lỗi tải model: \(error.localizedDescription)")
        }
    }

    // MARK: - Token-Saving Fast Image Compression (768px max, 0.58 JPEG quality)
    private func encodeOptimizedJPEG(from cgImage: CGImage, maxDimension: CGFloat = 768, quality: CGFloat = 0.58) -> String? {
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let dstW = max(1, Int(round(srcW * scale)))
        let dstH = max(1, Int(round(srcH * scale)))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: dstW, height: dstH), format: format)
        let resizedImage = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        }
        guard let jpegData = resizedImage.jpegData(compressionQuality: quality) else { return nil }
        return jpegData.base64EncodedString()
    }

    // MARK: - Async Ping / Connection Test
    public func testAPIKey() async -> (Bool, String) {
        let key = apiKey
        guard !key.isEmpty else {
            return (false, "Vui lòng nhập và bấm Lưu API Key trước khi kiểm tra.")
        }
        guard let url = URL(string: activeEndpointURLString) else {
            return (false, "Địa chỉ Endpoint không hợp lệ.")
        }

        let startTime = CACurrentMediaTime()
        let modelToTest = activeModelID

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any]
        if selectedProvider == .anthropic && activeEndpointURLString.hasSuffix("/messages") {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            payload = [
                "model": modelToTest,
                "max_tokens": 12,
                "messages": [["role": "user", "content": "Reply OK"]]
            ]
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if selectedProvider == .openRouter {
                request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("AlignAI Studio Camera", forHTTPHeaderField: "X-Title")
            }
            payload = [
                "model": modelToTest,
                "max_tokens": 12,
                "temperature": 0.0,
                "messages": [["role": "user", "content": "Reply OK"]]
            ]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (false, "Lỗi tạo gói tin kiểm tra.")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int((CACurrentMediaTime() - startTime) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Không nhận được phản hồi HTTP.")
            }
            if (200...299).contains(http.statusCode) {
                return (true, "Kết nối thành công • \(selectedProvider.shortBadge) • \(modelToTest) (\(latency)ms)")
            } else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                return (false, "Lỗi HTTP \(http.statusCode): \(raw.prefix(120))")
            }
        } catch {
            return (false, "Lỗi kết nối: \(error.localizedDescription)")
        }
    }

    // MARK: - Ultra-Compact & High-Precision Photographic Composition Analysis
    public func analyzeForComposition(
        image: CGImage,
        sceneContext: SceneCategory,
        subjectRect: CGRect?,
        faceRects: [CGRect],
        completion: @escaping (Result<GeminiFramingResponse, Error>) -> Void
    ) {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(GeminiServiceError.missingAPIKey))
            return
        }

        // Downscale to 768px & JPEG 0.58 -> saves >70% image tokens & 2.5x faster upload
        guard let base64JPEG = encodeOptimizedJPEG(from: image, maxDimension: 768, quality: 0.58) else {
            completion(.failure(GeminiServiceError.imageEncodingFailed))
            return
        }

        var visionHints: [String] = ["scene=\(sceneContext.rawValue)"]
        if let s = subjectRect {
            visionHints.append(String(format: "subjBox=[%.2f,%.2f,%.2f,%.2f]", s.minX, s.minY, s.width, s.height))
        }
        if let f = faceRects.first {
            visionHints.append(String(format: "faceBox=[%.2f,%.2f,%.2f,%.2f] faces=%d", f.minX, f.minY, f.width, f.height, faceRects.count))
        }
        let hintStr = visionHints.joined(separator: " ")

        // Ultra-compact system+user prompt saving >65% input/output tokens while enforcing exact subject anchor coordinates
        let compactPrompt = """
        Role: Master Photography Director. Sensor hints: \(hintStr).
        Task: Find the exact main subject focal anchor (eyes/face for portrait/pet, main focal center for object/architecture/landscape) in normalized upright image coordinates [0.00..1.00] (top-left=0,0; bottom-right=1,1) and best optical zoom (1.0, 1.5, 2.0, or 3.0).
        CRITICAL: target_x and target_y MUST be the exact current position of the subject's primary focal point in THIS image (NEVER output 0.5,0.5 unless the subject is truly dead-center).
        Output ONLY valid JSON:
        {"target_x":0.42,"target_y":0.36,"rule":"Golden Ratio","scene":"Chân dung","zoom":1.5,"preset":"fujiPro400H","why":"Ngắn gọn <12 từ tiếng Việt","color":{"ev":0.0,"contrast":1.04,"sat":1.05,"temp":6300}}
        """

        let modelsToTry: [String]
        let custom = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            modelsToTry = [custom]
        } else if selectedProvider == .openRouter && selectedModel.isFreeTier {
            var chain = [selectedModel.rawValue]
            for m in freeFallbackModels where !chain.contains(m) { chain.append(m) }
            modelsToTry = chain
        } else {
            modelsToTry = [activeModelID]
        }

        attemptModelChain(
            models: modelsToTry,
            index: 0,
            apiKey: key,
            base64JPEG: base64JPEG,
            prompt: compactPrompt,
            fallbackSubjectRect: subjectRect,
            fallbackFaceRects: faceRects,
            fallbackScene: sceneContext,
            startTime: CACurrentMediaTime(),
            completion: completion
        )
    }

    private func attemptModelChain(
        models: [String],
        index: Int,
        apiKey: String,
        base64JPEG: String,
        prompt: String,
        fallbackSubjectRect: CGRect?,
        fallbackFaceRects: [CGRect],
        fallbackScene: SceneCategory,
        startTime: CFTimeInterval,
        completion: @escaping (Result<GeminiFramingResponse, Error>) -> Void
    ) {
        guard index < models.count else {
            completion(.failure(GeminiServiceError.emptyResponse))
            return
        }
        guard let url = URL(string: activeEndpointURLString) else {
            completion(.failure(GeminiServiceError.invalidEndpoint))
            return
        }

        let currentModel = models[index]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isAnthropicNative = (selectedProvider == .anthropic && activeEndpointURLString.hasSuffix("/messages"))
        let payload: [String: Any]

        if isAnthropicNative {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            payload = [
                "model": currentModel,
                "max_tokens": 220,
                "temperature": 0.15,
                "messages": [[
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64JPEG
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]]
            ]
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if selectedProvider == .openRouter {
                request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("AlignAI Studio Camera", forHTTPHeaderField: "X-Title")
            }
            payload = [
                "model": currentModel,
                "max_tokens": 220,
                "temperature": 0.15,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64JPEG)", "detail": "low"]]
                    ]
                ]]
            ]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(GeminiServiceError.imageEncodingFailed))
            return
        }
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                if index + 1 < models.count {
                    self.attemptModelChain(models: models, index: index + 1, apiKey: apiKey, base64JPEG: base64JPEG, prompt: prompt, fallbackSubjectRect: fallbackSubjectRect, fallbackFaceRects: fallbackFaceRects, fallbackScene: fallbackScene, startTime: startTime, completion: completion)
                } else {
                    completion(.failure(GeminiServiceError.networkError(error)))
                }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode), let data else {
                if index + 1 < models.count {
                    self.attemptModelChain(models: models, index: index + 1, apiKey: apiKey, base64JPEG: base64JPEG, prompt: prompt, fallbackSubjectRect: fallbackSubjectRect, fallbackFaceRects: fallbackFaceRects, fallbackScene: fallbackScene, startTime: startTime, completion: completion)
                } else {
                    let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(statusCode)"
                    completion(.failure(GeminiServiceError.httpError(statusCode, String(msg.prefix(120)))))
                }
                return
            }

            let latencyMs = Int((CACurrentMediaTime() - startTime) * 1000)
            if let parsed = self.parseFramingResponse(
                data: data,
                isAnthropicNative: isAnthropicNative,
                modelUsed: currentModel,
                latencyMs: latencyMs,
                fallbackSubjectRect: fallbackSubjectRect,
                fallbackFaceRects: fallbackFaceRects,
                fallbackScene: fallbackScene
            ) {
                completion(.success(parsed))
            } else if index + 1 < models.count {
                self.attemptModelChain(models: models, index: index + 1, apiKey: apiKey, base64JPEG: base64JPEG, prompt: prompt, fallbackSubjectRect: fallbackSubjectRect, fallbackFaceRects: fallbackFaceRects, fallbackScene: fallbackScene, startTime: startTime, completion: completion)
            } else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(GeminiServiceError.invalidJSON(raw)))
            }
        }.resume()
    }

    private func parseFramingResponse(
        data: Data,
        isAnthropicNative: Bool,
        modelUsed: String,
        latencyMs: Int,
        fallbackSubjectRect: CGRect?,
        fallbackFaceRects: [CGRect],
        fallbackScene: SceneCategory
    ) -> GeminiFramingResponse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var contentText: String?
        if isAnthropicNative {
            if let contentArr = root["content"] as? [[String: Any]] {
                contentText = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        } else if let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] {
            if let str = message["content"] as? String {
                contentText = str
            } else if let arr = message["content"] as? [[String: Any]] {
                contentText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }

        guard let rawText = contentText, !rawText.isEmpty,
              let jsonDict = Self.extractJSONObject(from: rawText) else {
            return nil
        }

        var tx = Self.readCGFloat(jsonDict["target_x"] ?? jsonDict["targetX"] ?? jsonDict["x"]) ?? 0.5
        var ty = Self.readCGFloat(jsonDict["target_y"] ?? jsonDict["targetY"] ?? jsonDict["y"]) ?? 0.5
        if tx > 1.0 && tx <= 1000.0 { tx /= 1000.0 }
        if ty > 1.0 && ty <= 1000.0 { ty /= 1000.0 }
        tx = min(0.95, max(0.05, tx))
        ty = min(0.95, max(0.05, ty))

        // Refine with sensor face/subject anchor if model returned dead-center
        if abs(tx - 0.5) < 0.04 && abs(ty - 0.5) < 0.04 {
            if let face = fallbackFaceRects.first {
                tx = face.midX
                ty = face.minY + face.height * 0.38
            } else if let subj = fallbackSubjectRect {
                tx = subj.midX
                ty = subj.minY + subj.height * 0.35
            }
        }

        let zoomRaw = Self.readCGFloat(jsonDict["zoom"] ?? jsonDict["suggested_zoom"] ?? jsonDict["suggestedZoom"]) ?? 1.0
        let zoom = min(3.0, max(1.0, zoomRaw))

        let ruleStr = (jsonDict["rule"] ?? jsonDict["composition_rule"]) as? String ?? ""
        let rule = Self.mapRule(from: ruleStr)

        let sceneStr = (jsonDict["scene"] ?? jsonDict["scene_type"]) as? String ?? ""
        let scene = Self.mapScene(from: sceneStr, fallback: fallbackScene)

        let presetStr = (jsonDict["preset"] ?? jsonDict["recommended_preset"]) as? String ?? ""
        let preset = FilmPreset(rawValue: presetStr) ?? scene.recommendedFilter

        let explanation = (jsonDict["why"] ?? jsonDict["explanation"]) as? String ?? "Bố cục \(rule.displayNameVietnamese) tối ưu cho \(scene.localizedName)"

        var recipe = GeminiColorRecipe()
        if let colorDict = jsonDict["color"] as? [String: Any] {
            recipe.exposureEV = Double(Self.readCGFloat(colorDict["ev"] ?? colorDict["exposureEV"]) ?? 0.0)
            recipe.contrast = Double(Self.readCGFloat(colorDict["contrast"]) ?? 1.02)
            recipe.saturation = Double(Self.readCGFloat(colorDict["sat"] ?? colorDict["saturation"]) ?? 1.04)
            recipe.warmth = Double(Self.readCGFloat(colorDict["temp"] ?? colorDict["warmth"]) ?? 6500)
        }

        return GeminiFramingResponse(
            targetX: tx,
            targetY: ty,
            compositionRule: rule,
            sceneType: scene,
            suggestedZoom: zoom,
            explanation: explanation,
            colorRecipe: recipe,
            recommendedPreset: preset,
            presetExplanation: "\(preset.displayName) — Tối ưu bởi \(modelUsed)",
            modelUsed: modelUsed,
            latencyMs: latencyMs
        )
    }

    // MARK: - AI Video Cinematography Director (Cloud Multi-Provider)
    public final class VideoCinematographyRequest {
        private var task: URLSessionDataTask?
        public func cancel() { task?.cancel() }
        fileprivate init(task: URLSessionDataTask?) { self.task = task }
    }

    @discardableResult
    public func analyzeVideoCinematography(
        image: CGImage,
        sceneContext: SceneCategory,
        currentZoom: CGFloat,
        completion: @escaping (Result<AIVideoDirectorGuidance, Error>) -> Void
    ) -> VideoCinematographyRequest {
        let key = apiKey
        guard !key.isEmpty else {
            completion(.failure(GeminiServiceError.missingAPIKey))
            return VideoCinematographyRequest(task: nil)
        }
        guard let base64JPEG = encodeOptimizedJPEG(from: image, maxDimension: 640, quality: 0.55),
              let url = URL(string: activeEndpointURLString) else {
            completion(.failure(GeminiServiceError.imageEncodingFailed))
            return VideoCinematographyRequest(task: nil)
        }

        let prompt = """
        Cinematography Director. Scene: \(sceneContext.rawValue), zoom: \(String(format: "%.1fx", currentZoom)).
        Return ONLY valid JSON for a smooth 2-waypoint camera movement:
        {"movementType":"Push In","directorTip":"Đẩy máy nhẹ vào chủ thể giữ khung vững","recommendedZoom":\(String(format: "%.1f", min(3.0, max(1.0, currentZoom)))),"recommendedLUT":"kodakPortra400","subjectAnchorX":0.5,"subjectAnchorY":0.45,"waypoints":[{"id":0,"targetX":0.45,"targetY":0.42,"targetZoom":1.0,"holdSeconds":2.0,"instruction":"Khóa nét chủ thể"},{"id":1,"targetX":0.38,"targetY":0.38,"targetZoom":1.5,"holdSeconds":2.5,"instruction":"Đưa vào điểm mạnh 1/3"}]}
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": activeModelID,
            "max_tokens": 280,
            "temperature": 0.2,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64JPEG)", "detail": "low"]]
                ]
            ]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(GeminiServiceError.networkError(error)))
                return
            }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String,
                  let obj = Self.extractJSONObject(from: text),
                  let objData = try? JSONSerialization.data(withJSONObject: obj),
                  let guidance = try? JSONDecoder().decode(AIVideoDirectorGuidance.self, from: objData) else {
                completion(.failure(GeminiServiceError.emptyResponse))
                return
            }
            completion(.success(guidance))
        }
        task.resume()
        return VideoCinematographyRequest(task: task)
    }

    // MARK: - Helpers
    private static func extractJSONObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func readCGFloat(_ any: Any?) -> CGFloat? {
        if let n = any as? NSNumber { return CGFloat(n.doubleValue) }
        if let d = any as? Double { return CGFloat(d) }
        if let s = any as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return CGFloat(d)
        }
        return nil
    }

    private static func mapRule(from raw: String) -> CompositionRule {
        let l = raw.lowercased()
        if l.contains("third") || l.contains("1/3") { return .ruleOfThirds }
        if l.contains("center") || l.contains("symmetr") || l.contains("đối xứng") { return .centerSymmetry }
        if l.contains("triangle") || l.contains("tam giác") { return .goldenTriangle }
        if l.contains("spiral") || l.contains("xoắn") { return .goldenSpiral }
        if l.contains("diagonal") || l.contains("chéo") { return .diagonalLead }
        return .goldenRatio
    }

    private static func mapScene(from raw: String, fallback: SceneCategory) -> SceneCategory {
        for cat in SceneCategory.allCases {
            if raw.localizedCaseInsensitiveContains(cat.rawValue) || raw.localizedCaseInsensitiveContains(cat.localizedName) {
                return cat
            }
        }
        let l = raw.lowercased()
        if l.contains("portrait") || l.contains("person") || l.contains("chân dung") { return .portrait }
        if l.contains("group") || l.contains("nhóm") { return .groupPortrait }
        if l.contains("landscape") || l.contains("nature") || l.contains("phong cảnh") { return .landscape }
        if l.contains("arch") || l.contains("building") || l.contains("kiến trúc") { return .architecture }
        if l.contains("food") || l.contains("ẩm thực") { return .food }
        if l.contains("pet") || l.contains("animal") || l.contains("thú cưng") { return .pet }
        if l.contains("night") || l.contains("đêm") { return .nightCity }
        return fallback
    }
}
