import Foundation
import UIKit
import CoreGraphics
import QuartzCore
import Security
import Network

// MARK: - Real-time Network Connectivity Monitor (Wifi / 4G / Offline Auto-Routing)
public final class NetworkMonitor: @unchecked Sendable {
    public static let shared = NetworkMonitor()

    public private(set) var isConnected: Bool = true
    public private(set) var isCellular: Bool = false
    public private(set) var isWiFi: Bool = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.alignai.networkMonitor", qos: .utility)
    private let lock = NSLock()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.isConnected = (path.status == .satisfied)
            self.isCellular = path.isExpensive || path.usesInterfaceType(.cellular)
            self.isWiFi = path.usesInterfaceType(.wifi)
            self.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    public func checkConnection() -> (isConnected: Bool, isCellular: Bool, isWiFi: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (isConnected, isCellular, isWiFi)
    }

    deinit {
        monitor.cancel()
    }
}

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

// MARK: - 2026 Multi-Provider AI Gateway Architecture
public enum AICloudProvider: String, CaseIterable, Identifiable, Codable {
    case pollinations = "pollinations"
    case googleGemini = "google_gemini"
    case groq         = "groq"
    case openRouter   = "openrouter"
    case openAI       = "openai"
    case anthropic    = "anthropic"
    case deepSeek     = "deepseek"
    case xAI          = "xai"
    case custom       = "custom_openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pollinations: return "Pollinations AI (enter.pollinations.ai)"
        case .googleGemini: return "Google AI Studio (Gemini 2.0 / 1.5 • Miễn phí cao)"
        case .groq:         return "Groq Cloud (LPU Siêu tốc • Miễn phí)"
        case .openRouter:   return "OpenRouter (Đa Model 2026)"
        case .openAI:       return "OpenAI API (GPT-4o / GPT-4.1)"
        case .anthropic:    return "Anthropic API (Claude 3.7 / 3.5)"
        case .xAI:          return "xAI API (Grok 2 Vision)"
        case .deepSeek:     return "DeepSeek API (VL2 / V3)"
        case .custom:       return "Tùy chỉnh (OpenAI-Compatible)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .pollinations: return "Pollinations"
        case .googleGemini: return "Google Gemini"
        case .groq:         return "Groq LPU"
        case .openRouter:   return "OpenRouter"
        case .openAI:       return "OpenAI"
        case .anthropic:    return "Anthropic"
        case .deepSeek:     return "DeepSeek"
        case .xAI:          return "xAI Grok"
        case .custom:       return "Custom API"
        }
    }

    public var defaultChatCompletionsURL: String {
        switch self {
        case .pollinations: return "https://gen.pollinations.ai/v1/chat/completions"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .groq:         return "https://api.groq.com/openai/v1/chat/completions"
        case .openRouter:   return "https://openrouter.ai/api/v1/chat/completions"
        case .openAI:       return "https://api.openai.com/v1/chat/completions"
        case .anthropic:    return "https://api.anthropic.com/v1/messages"
        case .deepSeek:     return "https://api.deepseek.com/v1/chat/completions"
        case .xAI:          return "https://api.x.ai/v1/chat/completions"
        case .custom:       return "https://api.openai.com/v1/chat/completions"
        }
    }

    public var defaultModelsURL: String {
        switch self {
        case .pollinations: return "https://gen.pollinations.ai/v1/models"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/openai/models"
        case .groq:         return "https://api.groq.com/openai/v1/models"
        case .openRouter:   return "https://openrouter.ai/api/v1/models"
        case .openAI:       return "https://api.openai.com/v1/models"
        case .anthropic:    return "https://api.anthropic.com/v1/models"
        case .deepSeek:     return "https://api.deepseek.com/v1/models"
        case .xAI:          return "https://api.x.ai/v1/models"
        case .custom:       return ""
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .pollinations: return "Dán Pollinations Key (từ enter.pollinations.ai)..."
        case .googleGemini: return "Dán Google AI Studio Key (AIzaSy...)"
        case .groq:         return "Dán Groq API Key (gsk_...)"
        case .openRouter:   return "Dán OpenRouter Key (sk-or-v1-...)"
        case .openAI:       return "Dán OpenAI API Key (sk-proj-...)"
        case .anthropic:    return "Dán Anthropic Key (sk-ant-...)"
        case .deepSeek:     return "Dán DeepSeek API Key (sk-...)"
        case .xAI:          return "Dán xAI API Key (xai-...)"
        case .custom:       return "Dán Bearer API Key..."
        }
    }

    public var defaultModelID: String {
        switch self {
        case .pollinations: return "openai/gpt-4o-mini"
        case .googleGemini: return "gemini-2.0-flash"
        case .groq:         return "llama-3.2-11b-vision-preview"
        case .openRouter:   return "google/gemini-2.0-flash-exp:free"
        case .openAI:       return "gpt-4o-mini"
        case .anthropic:    return "claude-3-5-sonnet-20241022"
        case .deepSeek:     return "deepseek-chat"
        case .xAI:          return "grok-2-vision-1212"
        case .custom:       return "gpt-4o-mini"
        }
    }
}

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

// MARK: - Supported AI Vision Models (2026 Full Catalog)
public enum AIVisionModel: String, CaseIterable, Identifiable {
    case pollinationsOpenAI = "pollinations/gpt-4o-mini"
    case gemini20FlashDirect = "gemini-2.0-flash"
    case gemini20FlashLiteDirect = "gemini-2.0-flash-lite-preview-02-05"
    case gemini15FlashDirect = "gemini-1.5-flash"
    case gemini20FlashFree = "google/gemini-2.0-flash-exp:free"
    case groqLlama32_11BDirect = "llama-3.2-11b-vision-preview"
    case groqLlama32_90BDirect = "llama-3.2-90b-vision-preview"
    case freeVision = "google/gemma-4-31b-it:free"
    case gemini25FlashFree = "google/gemini-2.5-flash-preview:free"
    case qwen3VLFree = "qwen/qwen3-vl-32b-instruct:free"
    case llama4MaverickFree = "meta-llama/llama-4-maverick:free"
    case autoStrongest = "auto"
    case gemini31FlashLite = "google/gemini-3.1-flash-lite-preview"
    case gemini31Pro = "google/gemini-3.1-pro-preview"
    case gemini37Flash = "google/gemini-3.7-flash"
    case gemini36Flash = "google/gemini-3.6-flash"
    case gemini35Flash = "google/gemini-3.5-flash"
    case gemini25Flash = "google/gemini-2.5-flash"
    case gemini25Pro = "google/gemini-2.5-pro"
    case gemini20Flash = "google/gemini-2.0-flash-001"
    case geminiFlash15 = "google/gemini-flash-1.5"
    case geminiPro15 = "google/gemini-pro-1.5"
    case gpt5 = "openai/gpt-5-chat"
    case gpt5Mini = "openai/gpt-5-mini"
    case gpt41 = "openai/gpt-4.1"
    case gpt41Mini = "openai/gpt-4.1-mini"
    case o4MiniHigh = "openai/o4-mini-high"
    case gpt4oMini = "openai/gpt-4o-mini"
    case claude45Sonnet = "anthropic/claude-sonnet-4.5"
    case claude4Sonnet = "anthropic/claude-sonnet-4"
    case claude37Sonnet = "anthropic/claude-3.7-sonnet"
    case claude35Haiku = "anthropic/claude-3.5-haiku"
    case grok4Vision = "x-ai/grok-4"
    case qwen25VL72B = "qwen/qwen2.5-vl-72b-instruct"
    case llamaVision = "meta-llama/llama-3.2-11b-vision-instruct"
    // Bổ sung Model mới nhất 2026 (Giữ nguyên 100% model cũ)
    case gemini20ProExp = "google/gemini-2.0-pro-exp-02-05"
    case gemini15Flash8B = "google/gemini-1.5-flash-8b"
    case gpt45 = "openai/gpt-4.5-preview"
    case gpt4o = "openai/gpt-4o"
    case o1 = "openai/o1"
    case o3Mini = "openai/o3-mini"
    case claude35Sonnet = "anthropic/claude-3.5-sonnet"
    case groqLlama33 = "groq/llama-3.3-70b-versatile"
    case groqLlama32_90B = "groq/llama-3.2-90b-vision-preview"
    case deepseekChat = "deepseek/deepseek-chat"
    case deepseekReasoner = "deepseek/deepseek-reasoner"
    case deepseekVL2 = "deepseek/deepseek-vl2"
    case grok2Vision = "x-ai/grok-2-vision-1212"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pollinationsOpenAI:     return "GPT-4o Mini (Pollinations AI)"
        case .gemini20FlashDirect:    return "Gemini 2.0 Flash (Trực tiếp Google AI • Miễn phí cao)"
        case .gemini20FlashLiteDirect:return "Gemini 2.0 Flash Lite (Google AI • Siêu tốc)"
        case .gemini15FlashDirect:    return "Gemini 1.5 Flash (Google AI • 1500 lượt/ngày free)"
        case .gemini20FlashFree:      return "Gemini 2.0 Flash (OpenRouter • Miễn phí)"
        case .groqLlama32_11BDirect:  return "Llama 3.2 11B Vision (Groq LPU Siêu tốc • Free)"
        case .groqLlama32_90BDirect:  return "Llama 3.2 90B Vision (Groq LPU Chất lượng cao • Free)"
        case .freeVision:         return "Gemma 4 31B Vision (Miễn phí)"
        case .gemini25FlashFree:  return "Gemini 2.5 Flash (Miễn phí)"
        case .qwen3VLFree:        return "Qwen 3 VL 32B (Miễn phí)"
        case .llama4MaverickFree: return "Llama 4 Maverick 17B (Miễn phí)"
        case .autoStrongest:      return "Tự động chọn Model 2026 mạnh nhất"
        case .gemini31FlashLite:  return "Gemini 3.1 Flash Lite (2026 Siêu tốc)"
        case .gemini31Pro:        return "Gemini 3.1 Pro (2026 Cao cấp)"
        case .gemini37Flash:      return "Gemini 3.7 Flash"
        case .gemini36Flash:      return "Gemini 3.6 Flash"
        case .gemini35Flash:      return "Gemini 3.5 Flash"
        case .gemini25Flash:      return "Gemini 2.5 Flash Vision"
        case .gemini25Pro:        return "Gemini 2.5 Pro Vision"
        case .gemini20Flash:      return "Gemini 2.0 Flash"
        case .gemini20ProExp:     return "Gemini 2.0 Pro Exp (Google)"
        case .geminiFlash15:      return "Gemini 1.5 Flash"
        case .geminiPro15:        return "Gemini 1.5 Pro"
        case .gemini15Flash8B:    return "Gemini 1.5 Flash 8B (Google)"
        case .gpt5:               return "OpenAI GPT-5 Vision (2026 Flagship)"
        case .gpt5Mini:           return "OpenAI GPT-5 Mini Vision (Nhanh)"
        case .gpt45:              return "OpenAI GPT-4.5 Preview (2026)"
        case .gpt4o:              return "OpenAI GPT-4o Omni Vision"
        case .gpt41:              return "OpenAI GPT-4.1 Vision"
        case .gpt41Mini:          return "OpenAI GPT-4.1 Mini (Tiết kiệm)"
        case .o1:                 return "OpenAI o1 Reasoning Vision"
        case .o3Mini:             return "OpenAI o3-mini Vision (2026)"
        case .o4MiniHigh:         return "OpenAI o4-mini High (Suy luận ảnh)"
        case .gpt4oMini:          return "OpenAI GPT-4o Mini"
        case .claude45Sonnet:     return "Claude 4.5 Sonnet Vision (2026)"
        case .claude4Sonnet:      return "Claude 4 Sonnet Vision"
        case .claude37Sonnet:     return "Claude 3.7 Sonnet Vision"
        case .claude35Sonnet:     return "Claude 3.5 Sonnet Vision"
        case .claude35Haiku:      return "Claude 3.5 Haiku"
        case .groqLlama33:        return "Groq Llama 3.3 70B Versatile"
        case .groqLlama32_90B:    return "Groq Llama 3.2 90B Vision"
        case .deepseekChat:       return "DeepSeek V3 Chat (DeepSeek)"
        case .deepseekReasoner:   return "DeepSeek R1 Reasoner (DeepSeek)"
        case .deepseekVL2:        return "DeepSeek VL2 Vision (DeepSeek)"
        case .grok2Vision:        return "xAI Grok 2 Vision"
        case .grok4Vision:        return "xAI Grok 4 Vision (2026)"
        case .qwen25VL72B:        return "Qwen 2.5 VL 72B Instruct"
        case .llamaVision:        return "Llama 3.2 11B Vision"
        }
    }

    public var shortName: String {
        switch self {
        case .pollinationsOpenAI:     return "GPT-4o Mini (Pollinations)"
        case .gemini20FlashDirect:    return "Gemini 2.0 Flash"
        case .gemini20FlashLiteDirect:return "Gemini 2.0 Lite"
        case .gemini15FlashDirect:    return "Gemini 1.5 Flash"
        case .gemini20FlashFree:      return "Gemini 2.0 Free"
        case .groqLlama32_11BDirect:  return "Llama 3.2 11B (Groq)"
        case .groqLlama32_90BDirect:  return "Llama 3.2 90B (Groq)"
        case .freeVision:             return "Gemma 4 31B"
        case .gemini25FlashFree:      return "Gemini 2.5 Free"
        case .qwen3VLFree:            return "Qwen 3 VL"
        case .llama4MaverickFree:     return "Llama 4 Maverick"
        case .autoStrongest:          return "Auto Mạnh Nhất"
        case .gemini31FlashLite:      return "Gemini 3.1 Lite"
        case .gemini31Pro:            return "Gemini 3.1 Pro"
        case .gemini37Flash:          return "Gemini 3.7 Flash"
        case .gemini36Flash:          return "Gemini 3.6 Flash"
        case .gemini35Flash:          return "Gemini 3.5 Flash"
        case .gemini25Flash:          return "Gemini 2.5 Flash"
        case .gemini25Pro:            return "Gemini 2.5 Pro"
        case .gemini20Flash:          return "Gemini 2.0 Flash"
        case .gemini20ProExp:         return "Gemini 2.0 Pro"
        case .geminiFlash15:          return "Gemini 1.5 Flash"
        case .geminiPro15:            return "Gemini 1.5 Pro"
        case .gemini15Flash8B:        return "Gemini 1.5 8B"
        case .gpt5:                   return "GPT-5 Vision"
        case .gpt5Mini:               return "GPT-5 Mini"
        case .gpt45:                  return "GPT-4.5 Preview"
        case .gpt4o:                  return "GPT-4o"
        case .gpt41:                  return "GPT-4.1"
        case .gpt41Mini:              return "GPT-4.1 Mini"
        case .o1:                     return "o1 Vision"
        case .o3Mini:                 return "o3-mini"
        case .o4MiniHigh:             return "o4-mini High"
        case .gpt4oMini:              return "GPT-4o Mini"
        case .claude45Sonnet:         return "Claude 4.5 Sonnet"
        case .claude4Sonnet:          return "Claude 4 Sonnet"
        case .claude37Sonnet:         return "Claude 3.7 Sonnet"
        case .claude35Sonnet:         return "Claude 3.5 Sonnet"
        case .claude35Haiku:          return "Claude 3.5 Haiku"
        case .groqLlama33:            return "Llama 3.3 70B"
        case .groqLlama32_90B:        return "Llama 3.2 90B"
        case .deepseekChat:           return "DeepSeek V3"
        case .deepseekReasoner:       return "DeepSeek R1"
        case .deepseekVL2:            return "DeepSeek VL2"
        case .grok2Vision:            return "Grok 2 Vision"
        case .grok4Vision:            return "Grok 4 Vision"
        case .qwen25VL72B:            return "Qwen 2.5 VL"
        case .llamaVision:            return "Llama 3.2 11B"
        }
    }

    public var subtitle: String {
        switch self {
        case .pollinationsOpenAI:
            return "Hỗ trợ phân tích ảnh qua endpoint chính thức gen.pollinations.ai"
        case .gemini20FlashDirect, .gemini20FlashLiteDirect, .gemini15FlashDirect:
            return "Trực tiếp Google AI Studio — Hạn mức miễn phí 1.500 lượt/ngày cực lớn"
        case .groqLlama32_11BDirect, .groqLlama32_90BDirect:
            return "Groq LPU chip chuyên dụng — Tốc độ xử lý siêu tốc < 0.8 giây hoàn toàn miễn phí"
        case .gemini20FlashFree, .freeVision, .gemini25FlashFree, .qwen3VLFree, .llama4MaverickFree:
            return "Miễn phí qua OpenRouter — tự động xoay vòng dự phòng khi quá tải"
        case .gemini31FlashLite, .gemini25Flash, .gemini20Flash, .gemini15Flash8B, .gpt5Mini, .gpt41Mini, .gpt4oMini, .o3Mini:
            return "Tốc độ phản hồi cực nhanh (<1.2s), tối ưu tiết kiệm token"
        case .gemini31Pro, .gemini25Pro, .gemini20ProExp, .gpt5, .gpt45, .gpt4o, .claude45Sonnet, .claude4Sonnet, .claude37Sonnet, .o1, .o4MiniHigh:
            return "Độ chính xác bố cục & thẩm mỹ nhiếp ảnh đỉnh cao 2026"
        default:
            return "Mô hình thị giác đa phương thức thế hệ mới 2026"
        }
    }

    public var technicalModelID: String {
        switch self {
        case .autoStrongest:
            return "google/gemini-2.5-flash"
        case .pollinationsOpenAI:
            return "openai/gpt-4o-mini"
        default:
            return rawValue
        }
    }

    /// Lọc danh sách Model phù hợp theo đúng Hãng API được chọn
    public static func models(for provider: AICloudProvider) -> [AIVisionModel] {
        switch provider {
        case .pollinations:
            return [
                .autoStrongest,
                .pollinationsOpenAI
            ]
        case .googleGemini:
            return [
                .autoStrongest,
                .gemini20FlashDirect,
                .gemini15FlashDirect,
                .gemini20FlashLiteDirect,
                .gemini20ProExp,
                .gemini15Flash8B,
                .gemini25Flash,
                .gemini25Pro,
                .gemini20Flash,
                .geminiFlash15,
                .geminiPro15,
                .gemini31FlashLite,
                .gemini31Pro,
                .gemini37Flash,
                .gemini36Flash,
                .gemini35Flash,
                .gemini25FlashFree
            ]
        case .groq:
            return [
                .autoStrongest,
                .groqLlama32_11BDirect,
                .groqLlama32_90BDirect,
                .llamaVision,
                .groqLlama33,
                .groqLlama32_90B,
                .llama4MaverickFree
            ]
        case .openAI:
            return [
                .autoStrongest,
                .gpt4oMini,
                .gpt4o,
                .gpt45,
                .gpt5,
                .gpt5Mini,
                .gpt41,
                .gpt41Mini,
                .o1,
                .o3Mini,
                .o4MiniHigh
            ]
        case .anthropic:
            return [
                .autoStrongest,
                .claude37Sonnet,
                .claude35Sonnet,
                .claude35Haiku,
                .claude4Sonnet,
                .claude45Sonnet
            ]
        case .deepSeek:
            return [
                .autoStrongest,
                .deepseekChat,
                .deepseekReasoner,
                .deepseekVL2
            ]
        case .xAI:
            return [
                .autoStrongest,
                .grok2Vision,
                .grok4Vision
            ]
        case .openRouter, .custom:
            return allCases
        }
    }

    /// Model mặc định tối ưu theo từng Hãng
    public static func defaultModel(for provider: AICloudProvider) -> AIVisionModel {
        switch provider {
        case .pollinations: return .pollinationsOpenAI
        case .googleGemini: return .gemini20FlashDirect
        case .groq: return .groqLlama32_11BDirect
        case .openAI: return .gpt4oMini
        case .anthropic: return .claude37Sonnet
        case .deepSeek: return .deepseekChat
        case .xAI: return .grok2Vision
        case .openRouter: return .gemini20FlashFree
        case .custom: return .autoStrongest
        }
    }

    public static var autoFallbackChain: [String] {
        [
            "google/gemini-2.0-flash-exp:free",
            "google/gemma-4-31b-it:free",
            "openai/gpt-4.1-mini"
        ]
    }

    public static var freeFallbackChain: [String] {
        [
            "google/gemini-2.0-flash-exp:free",
            "google/gemma-4-31b-it:free",
            "google/gemini-2.5-flash-preview:free",
            "qwen/qwen3-vl-32b-instruct:free",
            "meta-llama/llama-4-maverick:free"
        ]
    }

    public static func fallbackChain(selected: AIVisionModel, customModelName: String, provider: AICloudProvider = .openRouter) -> [String] {
        let custom = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var preferred = custom.isEmpty ? selected.technicalModelID : custom

        if provider == .pollinations {
            var cleanModel = preferred
            if cleanModel == "auto" || cleanModel.isEmpty || cleanModel == "openai" || cleanModel.hasPrefix("pollinations/") {
                cleanModel = "openai/gpt-4o-mini"
            }
            if selected != .autoStrongest && !custom.isEmpty {
                return [cleanModel]
            }
            return [cleanModel, "openai/gpt-4o-mini"]
        }

        if provider == .googleGemini {
            var cleanModel = preferred
            if cleanModel.hasPrefix("google/") {
                cleanModel = String(cleanModel.dropFirst("google/".count))
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "gemini-flash-1.5" { cleanModel = "gemini-1.5-flash" }
            if cleanModel == "gemini-pro-1.5" { cleanModel = "gemini-1.5-pro" }
            if cleanModel == "gemini-2.0-flash-001" { cleanModel = "gemini-2.0-flash" }
            if cleanModel == "auto" { cleanModel = "gemini-2.0-flash" }

            // Người dùng chọn model nào -> chạy trực tiếp model đó, chỉ fallback 1 lần nếu không trả về gì
            if selected != .autoStrongest && !custom.isEmpty {
                return [cleanModel]
            }
            if cleanModel == "gemini-1.5-flash" {
                return ["gemini-1.5-flash", "gemini-2.0-flash"]
            } else {
                return [cleanModel, "gemini-1.5-flash"]
            }
        } else if provider == .groq {
            var cleanModel = preferred
            if cleanModel.hasPrefix("groq/") || cleanModel.hasPrefix("meta-llama/") {
                let parts = cleanModel.split(separator: "/")
                if parts.count == 2 { cleanModel = String(parts[1]) }
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "auto" { cleanModel = "llama-3.2-11b-vision-preview" }
            if selected != .autoStrongest {
                return [cleanModel]
            }
            return [cleanModel, "llama-3.2-11b-vision-preview"]
        } else if provider == .openAI {
            var cleanModel = preferred
            if cleanModel.hasPrefix("openai/") {
                cleanModel = String(cleanModel.dropFirst("openai/".count))
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "auto" { cleanModel = "gpt-4o-mini" }
            if selected != .autoStrongest {
                return [cleanModel]
            }
            return [cleanModel, "gpt-4o-mini"]
        } else if provider == .anthropic {
            var cleanModel = preferred
            if cleanModel.hasPrefix("anthropic/") {
                cleanModel = String(cleanModel.dropFirst("anthropic/".count))
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "auto" { cleanModel = "claude-3-7-sonnet-20250219" }
            if selected != .autoStrongest {
                return [cleanModel]
            }
            return [cleanModel, "claude-3-5-haiku-20241022"]
        } else if provider != .openRouter && preferred.contains("/") {
            let parts = preferred.split(separator: "/")
            if parts.count == 2 {
                preferred = String(parts[1]).replacingOccurrences(of: ":free", with: "")
            }
            return [preferred]
        }
        guard provider == .openRouter else {
            return [preferred]
        }
        if selected != .autoStrongest && !custom.isEmpty {
            return [preferred]
        }
        let freeOnly = preferred.hasSuffix(":free") || preferred == "openrouter/free"
        let fallback = freeOnly ? ["google/gemini-2.0-flash-exp:free", "google/gemma-4-31b-it:free"] : ["google/gemini-2.0-flash-exp:free", "openai/gpt-4o-mini"]
        return [preferred] + fallback.filter { $0 != preferred }
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
    public let recommendedEVBias: Float?
    public let lightingScene: String?

    public init(
        targetX: CGFloat,
        targetY: CGFloat,
        suggestedZoom: CGFloat,
        sceneType: DetectedSceneType,
        colorRecipe: GeminiColorRecipe,
        compositionRule: CompositionRule,
        explanation: String,
        modelUsed: String,
        latencyMs: Int,
        recommendedPreset: FilmPreset,
        presetExplanation: String,
        recommendedEVBias: Float? = nil,
        lightingScene: String? = nil
    ) {
        self.targetX = targetX
        self.targetY = targetY
        self.suggestedZoom = suggestedZoom
        self.sceneType = sceneType
        self.colorRecipe = colorRecipe
        self.compositionRule = compositionRule
        self.explanation = explanation
        self.modelUsed = modelUsed
        self.latencyMs = latencyMs
        self.recommendedPreset = recommendedPreset
        self.presetExplanation = presetExplanation
        self.recommendedEVBias = recommendedEVBias
        self.lightingScene = lightingScene
    }
}

// MARK: - Errors

public enum GeminiError: LocalizedError {
    case noAPIKey
    case invalidAPIKey(String)
    case insufficientCredits
    case freeQuotaReached
    case rateLimited(String)
    case imageConversionFailed
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parseError(String)
    case allModelsFailed(String)

    public var errorDescription: String? {
        let providerName = GeminiService.shared.selectedProvider.displayName
        switch self {
        case .noAPIKey:
            return "Chưa cài đặt API Key. Mở Cài đặt để nhập key cho \(providerName)."
        case .invalidAPIKey(let msg):
            return "API Key không hợp lệ (\(providerName)): \(msg)."
        case .insufficientCredits:
            return "Tài khoản \(providerName) không đủ số dư/credits. Đã chuyển sang AI Neural Engine cục bộ."
        case .freeQuotaReached:
            return "\(providerName) đang giới hạn lượt yêu cầu. Đang dùng AI Neural Engine cục bộ."
        case .rateLimited(let msg):
            return "Model \(providerName) tạm thời bận hoặc hết hạn mức/quota: \(msg)."
        case .imageConversionFailed:
            return "Không thể chuyển đổi ảnh gửi AI."
        case .invalidURL:
            return "URL API không hợp lệ."
        case .networkError(let e):
            return "Lỗi mạng: \(e.localizedDescription)"
        case .invalidResponse:
            return "Dữ liệu \(providerName) trả về không đúng định dạng."
        case .parseError(let msg):
            return "Lỗi AI (\(msg))"
        case .allModelsFailed(let msg):
            if msg.isEmpty || msg.contains("đều bận") {
                return "Tất cả model của \(providerName) đều bận hoặc hết hạn mức. Đang dùng AI Neural Engine cục bộ."
            }
            return "Các model \(providerName) đều bận: \(msg)"
        }
    }
}

// MARK: - GeminiService

public final class GeminiService: ObservableObject {
    public static let shared = GeminiService()

    public var onActiveKeyConfigured: ((Bool) -> Void)?
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

    public final class VideoCinematographyRequest {
        private let lock = NSLock()
        private var currentTask: URLSessionDataTask?
        private var isCancelled = false
        private var hasCompleted = false

        public func cancel() {
            lock.lock()
            isCancelled = true
            let task = currentTask
            currentTask = nil
            lock.unlock()
            task?.cancel()
        }

        fileprivate var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !isCancelled && !hasCompleted
        }

        fileprivate func start(_ task: URLSessionDataTask) {
            lock.lock()
            if !isCancelled && !hasCompleted {
                currentTask = task
                task.resume()
                lock.unlock()
            } else {
                lock.unlock()
                task.cancel()
            }
        }

        fileprivate func finish(_ deliver: () -> Void) {
            lock.lock()
            guard !isCancelled && !hasCompleted else {
                lock.unlock()
                return
            }
            hasCompleted = true
            currentTask = nil
            lock.unlock()
            deliver()
        }
    }

    private func keychainKeyForProvider(_ provider: AICloudProvider, profileID: UUID? = nil) -> String {
        if let pid = profileID {
            return "ai_profile_key_\(pid.uuidString)"
        }
        if provider == .openRouter {
            return "openrouter_api_key"
        }
        return "ai_provider_key_\(provider.rawValue)"
    }

    // Persistent API Key (Secure Keychain with Multi-Provider & Profile support)
    public var apiKey: String {
        get {
            if let pid = activeProfileID,
               let profileVal = KeychainHelper.standard.read(forKey: keychainKeyForProvider(selectedProvider, profileID: pid))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !profileVal.isEmpty {
                return profileVal
            }
            if let provVal = KeychainHelper.standard.read(forKey: keychainKeyForProvider(selectedProvider))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provVal.isEmpty {
                return provVal
            }
            if selectedProvider == .openRouter {
                if let keychainVal = KeychainHelper.standard.read(forKey: "openrouter_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !keychainVal.isEmpty {
                    return keychainVal
                }
                if let legacyKey = UserDefaults.standard.string(forKey: "openrouter_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyKey.isEmpty {
                    KeychainHelper.standard.save(legacyKey, forKey: "openrouter_api_key")
                    UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
                    return legacyKey
                }
            } else if selectedProvider == .googleGemini {
                if let keychainVal = KeychainHelper.standard.read(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !keychainVal.isEmpty {
                    return keychainVal
                }
                if let legacyKey = UserDefaults.standard.string(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyKey.isEmpty {
                    KeychainHelper.standard.save(legacyKey, forKey: "ai_provider_key_google_gemini")
                    UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                    return legacyKey
                }
            }
            return ""
        }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                KeychainHelper.standard.delete(forKey: keychainKeyForProvider(selectedProvider, profileID: activeProfileID))
                KeychainHelper.standard.delete(forKey: keychainKeyForProvider(selectedProvider))
                if selectedProvider == .openRouter {
                    KeychainHelper.standard.delete(forKey: "openrouter_api_key")
                } else if selectedProvider == .googleGemini {
                    KeychainHelper.standard.delete(forKey: "gemini_api_key")
                }
                onActiveKeyConfigured?(hasAPIKey)
            } else {
                if clean.hasPrefix("sk-or-v1-") && selectedProvider != .openRouter && selectedProvider != .custom {
                    selectedProvider = .openRouter
                } else if clean.hasPrefix("AIzaSy") && selectedProvider != .googleGemini && selectedProvider != .custom {
                    selectedProvider = .googleGemini
                } else if clean.hasPrefix("sk-ant-") && selectedProvider != .anthropic && selectedProvider != .custom {
                    selectedProvider = .anthropic
                } else if clean.hasPrefix("gsk_") && selectedProvider != .groq && selectedProvider != .custom {
                    selectedProvider = .groq
                } else if clean.hasPrefix("xai-") && selectedProvider != .xAI && selectedProvider != .custom {
                    selectedProvider = .xAI
                }
                KeychainHelper.standard.save(clean, forKey: keychainKeyForProvider(selectedProvider, profileID: activeProfileID))
                KeychainHelper.standard.save(clean, forKey: keychainKeyForProvider(selectedProvider))
                if selectedProvider == .openRouter {
                    KeychainHelper.standard.save(clean, forKey: "openrouter_api_key")
                } else if selectedProvider == .googleGemini {
                    KeychainHelper.standard.save(clean, forKey: "gemini_api_key")
                }
                onActiveKeyConfigured?(true)
            }
            UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
            UserDefaults.standard.removeObject(forKey: "gemini_api_key")
            objectWillChange.send()
        }
    }

    public var hasAPIKey: Bool {
        return !apiKey.isEmpty
    }

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
        if selectedProvider == .pollinations {
            return selectedModel.technicalModelID
        }
        let raw = selectedModel.technicalModelID
        if selectedProvider == .googleGemini && raw.hasPrefix("google/") {
            return String(raw.dropFirst("google/".count)).replacingOccurrences(of: ":free", with: "")
        }
        if selectedProvider != .openRouter && raw.contains("/") {
            let parts = raw.split(separator: "/")
            if parts.count == 2 {
                return String(parts[1]).replacingOccurrences(of: ":free", with: "")
            }
        }
        return raw
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
        KeychainHelper.standard.save(trimmedKey, forKey: keychainKeyForProvider(provider, profileID: profile.id))
        KeychainHelper.standard.save(trimmedKey, forKey: keychainKeyForProvider(provider))
        if provider == .openRouter {
            KeychainHelper.standard.save(trimmedKey, forKey: "openrouter_api_key")
        }
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
        KeychainHelper.standard.delete(forKey: keychainKeyForProvider(profile.provider, profileID: profile.id))
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
            let (data, response) = try await urlSession.data(for: request)
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
                let al = a.lowercased(), bl = b.lowercased()
                let aVis = al.contains("vl") || al.contains("gemini") || al.contains("gpt-4") || al.contains("gpt-5") || al.contains("claude") || al.contains("vision") || al.contains("gemma-4") || al.contains("llama-4") || al.contains("grok")
                let bVis = bl.contains("vl") || bl.contains("gemini") || bl.contains("gpt-4") || bl.contains("gpt-5") || bl.contains("claude") || bl.contains("vision") || bl.contains("gemma-4") || bl.contains("llama-4") || bl.contains("grok")
                if aVis != bVis { return aVis }
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

    public var cloudAnalysisDeadline: TimeInterval {
        let custom = customModelName
        if custom.hasSuffix(":free") || custom == "openrouter/free" { return 15 }
        switch selectedModel {
        case .freeVision, .gemini25FlashFree, .qwen3VLFree, .llama4MaverickFree:
            return 15
        default:
            return 10
        }
    }

    // Selected Model Setting
    public var selectedModel: AIVisionModel {
        get {
            guard let saved = UserDefaults.standard.string(forKey: "gemini_selected_model") else {
                return .freeVision
            }
            if let model = AIVisionModel(rawValue: saved) {
                return model
            }
            return .freeVision
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "gemini_selected_model")
            objectWillChange.send()
        }
    }

    // Custom Model Name (if specified)
    public var customModelName: String {
        get { (UserDefaults.standard.string(forKey: "gemini_custom_model_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "gemini_custom_model_name")
            objectWillChange.send()
        }
    }

    // Live Inspection Observables
    public private(set) var lastLatencyMs: Int = 0
    public private(set) var lastModelUsed: String = ""
    public private(set) var lastExplanation: String = ""

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    public init() {
        if let savedProv = UserDefaults.standard.string(forKey: "ai_selected_provider_2026"),
           let prov = AICloudProvider(rawValue: savedProv) {
            self.selectedProvider = prov
        }
        if let savedEndpoint = UserDefaults.standard.string(forKey: "ai_custom_endpoint_url_2026") {
            self.customEndpointURL = savedEndpoint
        }
        loadProfiles()
        if let idStr = UserDefaults.standard.string(forKey: "ai_active_profile_id_2026"),
           let uuid = UUID(uuidString: idStr) {
            self.activeProfileID = uuid
        }
    }

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
            completion(false, "API Key cho \(selectedProvider.displayName) đang trống. Hãy nhập API Key trong Cài đặt.")
            return
        }

        let testCandidates = AIVisionModel.fallbackChain(selected: selectedModel, customModelName: customModelName, provider: selectedProvider)
        guard let testModel = testCandidates.first else {
            completion(false, "Không tìm thấy model phù hợp.")
            return
        }

        // Test đúng 1 model chính do người dùng chọn để phản hồi siêu tốc, không test chuỗi gây hao tốn quota và lag
        testModelCandidate(candidates: [testModel], index: 0, key: key, completion: completion)
    }

    private func testModelCandidate(
        candidates: [String],
        index: Int,
        key: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard index < candidates.count else {
            completion(false, "Đã thử các model của \(selectedProvider.displayName) nhưng kết nối không thành công. Hãy kiểm tra API key hoặc hạn mức của tài khoản.")
            return
        }

        let testModel = candidates[index]
        guard let url = buildURL(for: testModel, key: key) else {
            completion(false, "URL không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if testModel.hasSuffix(":free") || testModel == "openrouter/free" {
            request.timeoutInterval = 45
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if selectedProvider == .googleGemini && !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else if selectedProvider == .anthropic && !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if selectedProvider == .openRouter {
            request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")
        }

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
                DispatchQueue.main.async { completion(false, "Không nhận được phản hồi từ \(self.selectedProvider.displayName).") }
                return
            }

            if http.statusCode == 200 {
                DispatchQueue.main.async {
                    self.lastModelUsed = testModel
                    self.lastLatencyMs = latency
                    completion(true, "✅ Kết nối thành công! [\(self.selectedProvider.displayName)] Đang dùng: \(testModel) (Độ trễ: \(latency)ms)")
                }
            } else if http.statusCode == 429,
                      testModel.hasSuffix(":free") || testModel == "openrouter/free" {
                DispatchQueue.main.async {
                    completion(false, "❌ \(self.selectedProvider.displayName) đang giới hạn lượt miễn phí. Kiểm tra này cũng tính là một yêu cầu API.")
                }
            } else if http.statusCode == 404 || http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 502 {
                self.testModelCandidate(candidates: candidates, index: index + 1, key: key, completion: completion)
            } else {
                let msg = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(false, "❌ Lỗi \(self.selectedProvider.displayName) (\(http.statusCode)): \(msg)") }
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
    public static func prepareImageForAnalysis(
        _ image: CGImage,
        maxDimension: CGFloat = 1280,
        compressionQuality: CGFloat = 0.60
    ) -> Data? {
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
                return uiImage.jpegData(compressionQuality: compressionQuality)
            }
        }

        let uiImage = UIImage(cgImage: image)
        return uiImage.jpegData(compressionQuality: compressionQuality)
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
        guard hasAPIKey else {
            completion(.failure(.noAPIKey))
            return
        }

        // Keep enough detail for scene-wide analysis without uploading a full-resolution photo.
        // Token-saving fast compression: 768px maxDimension @ 0.58 quality saves >70% image tokens & 2.5x faster
        guard let jpegData = Self.prepareImageForAnalysis(image, maxDimension: 768, compressionQuality: 0.58) else {
            completion(.failure(.imageConversionFailed))
            return
        }
        let base64Image = jpegData.base64EncodedString()
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        let prompt = buildPrompt(sceneContext: sceneContext, colorMetrics: metrics, subjectRect: subjectRect, faceRects: faceRects)

        let chain = AIVisionModel.fallbackChain(selected: selectedModel, customModelName: customModelName, provider: selectedProvider)

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
        allowCloud: Bool = true,
        completion: @escaping (Result<(preset: FilmPreset, recipe: GeminiColorRecipe, explanation: String, latencyMs: Int), GeminiError>) -> Void
    ) {
        let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
        let effectiveScene = sceneContext ?? .general

        guard allowCloud && hasAPIKey else {
            // Offline mode or no API key: use local engine and scene intelligence.
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

    @discardableResult
    public func analyzeVideoCinematography(
        image: CGImage,
        sceneContext: DetectedSceneType? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = [],
        lookingDirection: CGVector = .zero,
        completion: @escaping (Result<AIVideoDirectorGuidance, GeminiError>) -> Void
    ) -> VideoCinematographyRequest {
        let request = VideoCinematographyRequest()
        let key = apiKey
        let chain = AIVisionModel.fallbackChain(selected: selectedModel, customModelName: customModelName, provider: selectedProvider)
        let completeOnMain: (Result<AIVideoDirectorGuidance, GeminiError>) -> Void = { result in
            if Thread.isMainThread {
                request.finish { completion(result) }
            } else {
                DispatchQueue.main.async { request.finish { completion(result) } }
            }
        }

        guard hasAPIKey else {
            let fallback = Self.generateLocalVideoGuidance(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )
            completeOnMain(.success(fallback))
            return request
        }

        // Scaling, JPEG encoding, base64 conversion and request JSON are all
        // performed off the UI thread. Key and model choices belong to this
        // request even if the user changes settings before encoding finishes.
        DispatchQueue.global(qos: .userInitiated).async {
            guard request.isActive else { return }
            guard let jpegData = Self.prepareImageForAnalysis(image, maxDimension: 1280) else {
                let fallback = Self.generateLocalVideoGuidance(
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection
                )
                completeOnMain(.success(fallback))
                return
            }

            guard request.isActive else { return }
            let base64Image = jpegData.base64EncodedString()
            let prompt = Self.buildVideoCinematographyPrompt(
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection
            )

            self.tryVideoCinematographyChain(
                chain: chain,
                index: 0,
                base64Image: base64Image,
                prompt: prompt,
                key: key,
                sceneContext: sceneContext,
                subjectRect: subjectRect,
                faceRects: faceRects,
                lookingDirection: lookingDirection,
                request: request,
                completion: completeOnMain
            )
        }
        return request
    }

    private func tryVideoCinematographyChain(
        chain: [String],
        index: Int,
        base64Image: String,
        prompt: String,
        key: String,
        sceneContext: DetectedSceneType?,
        subjectRect: CGRect?,
        faceRects: [CGRect],
        lookingDirection: CGVector,
        request requestHandle: VideoCinematographyRequest,
        completion: @escaping (Result<AIVideoDirectorGuidance, GeminiError>) -> Void
    ) {
        guard requestHandle.isActive else { return }
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
        if selectedProvider == .googleGemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else if selectedProvider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if selectedProvider == .openRouter {
            request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Video Director", forHTTPHeaderField: "X-Title")
        }
        if currentModelID.hasSuffix(":free") || currentModelID == "openrouter/free" {
            request.timeoutInterval = 45
        }

        var requestBody: [String: Any] = [
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
            "temperature": 0.40,
            "top_p": 0.90,
            "max_tokens": 1024
        ]
        if selectedProvider == .openRouter {
            requestBody["reasoning"] = ["exclude": true]
        }

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

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard requestHandle.isActive else { return }

            if error != nil {
                self.tryVideoCinematographyChain(
                    chain: chain,
                    index: index + 1,
                    base64Image: base64Image,
                    prompt: prompt,
                    key: key,
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection,
                    request: requestHandle,
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

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                let details = Self.extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                DispatchQueue.main.async { completion(.failure(.invalidAPIKey(details))) }
                return
            }

            if httpResponse.statusCode == 402 {
                DispatchQueue.main.async { completion(.failure(.insufficientCredits)) }
                return
            }

            if httpResponse.statusCode == 429,
               currentModelID.hasSuffix(":free") || currentModelID == "openrouter/free" {
                DispatchQueue.main.async { completion(.failure(.freeQuotaReached)) }
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
                    sceneContext: sceneContext,
                    subjectRect: subjectRect,
                    faceRects: faceRects,
                    lookingDirection: lookingDirection,
                    request: requestHandle,
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
        }
        requestHandle.start(task)
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
            let finalMsg = lastErrorMsg.isEmpty ? "Tất cả model của \(selectedProvider.displayName) đều bận." : lastErrorMsg
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
                if case .insufficientCredits = error {
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
        if modelID.hasSuffix(":free") || modelID == "openrouter/free" {
            request.timeoutInterval = 45
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if selectedProvider == .googleGemini && !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else if selectedProvider == .anthropic && !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if selectedProvider == .openRouter {
            request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")
        }

        var requestBody: [String: Any] = [
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
            "temperature": 0.20,
            "top_p": 0.90,
            "max_tokens": 420
        ]
        if selectedProvider == .openRouter {
            requestBody["reasoning"] = ["exclude": true]
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
                let errorDetails = Self.extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    DispatchQueue.main.async { completion(.failure(.invalidAPIKey("\(self.selectedProvider.displayName): \(errorDetails)"))) }
                    return
                }
                if httpResponse.statusCode == 402 {
                    DispatchQueue.main.async { completion(.failure(.insufficientCredits)) }
                    return
                }
                if httpResponse.statusCode == 429 {
                    let error: GeminiError = (modelID.hasSuffix(":free") || modelID == "openrouter/free")
                        ? .freeQuotaReached : .rateLimited("\(modelID) hết quota (429)")
                    DispatchQueue.main.async { completion(.failure(error)) }
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
            if let parsed = Self.cleanAndParseJSON(from: text), Self.hasUsableFraming(parsed) {
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

            // Do not present a fabricated centre point as a successful cloud analysis.
            DispatchQueue.main.async {
                completion(.failure(.parseError("Model không trả về tọa độ chủ thể và zoom hợp lệ")))
            }
        }.resume()
    }

    // MARK: - Helpers

    private func buildURL(for modelID: String, key: String) -> URL? {
        return URL(string: activeEndpointURLString)
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

    public static func hasUsableFraming(_ json: [String: Any]) -> Bool {
        let x = parseCGFloat(json["target_x"], defaultVal: .nan)
        let y = parseCGFloat(json["target_y"], defaultVal: .nan)
        let zoom = parseCGFloat(json["suggested_zoom"], defaultVal: .nan)
        return x.isFinite && y.isFinite && zoom.isFinite &&
            (0...1).contains(x) && (0...1).contains(y) && (1...5).contains(zoom)
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

        guard let rawX = extractNumber(forKey: "target_x"),
              let rawY = extractNumber(forKey: "target_y"),
              let rawZoom = extractNumber(forKey: "suggested_zoom"),
              rawX.isFinite, rawY.isFinite, rawZoom.isFinite,
              (0...1).contains(rawX), (0...1).contains(rawY),
              (1...5).contains(rawZoom) else { return nil }
        let targetX = CGFloat(rawX)
        let targetY = CGFloat(rawY)
        let zoom = CGFloat(rawZoom)
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
        var hints = ""
        if let scene = sceneContext { hints += "scene_type=\(scene.rawValue); " }
        if let r = subjectRect {
            hints += String(format: "subject_box=[x:%.2f,y:%.2f,w:%.2f,h:%.2f]; ", r.midX, r.midY, r.width, r.height)
        }
        if !faceRects.isEmpty { hints += "detected_faces=\(faceRects.count); " }
        if let m = colorMetrics {
            hints += String(format: "luma=%.2f,warmth=%.2f,contrast=%.2f; ", m.averageLuma, m.warmthCast, m.contrastScore)
        }
        return """
        You are an elite Director of Photography (DoP) and Master Cinematographer.
        Analyze this camera viewfinder image with professional artistic precision.
        Sensor cues: \(hints)
        MANDATORY INSTRUCTIONS:
        1. Pinpoint the exact optical focal center of the primary visual subject (target_x, target_y in [0.05..0.95], where top-left is 0.0,0.0 and bottom-right is 1.0,1.0). If a person or face exists, lock onto the dominant eye or face center. Never return center 0.5,0.5 if subject is off-center.
        2. Determine optimal framing optical zoom: choose from [1.0, 1.5, 2.0, 2.5, 3.0] to remove clutter and flatter subject proportions.
        3. Determine smart scene exposure bias: ev_bias from -2.0 to +2.0 (e.g. -0.7 for backlit silhouette, +0.5 for underexposed face/night, 0.0 for balanced).
        4. Classify lighting_scene: "backlit", "night", "sunset", "harsh_sun", "indoor_warm", or "normal".
        5. Recommend the ideal film look preset and color recipe.

        Respond with ONLY ONE valid, raw JSON object (no markdown, no quotes, no extra text):
        {"target_x":0.42,"target_y":0.36,"suggested_zoom":1.5,"ev_bias":0.0,"lighting_scene":"normal","scene_type":"portrait","composition_rule":"golden_ratio","recommended_film_preset":"Classic Chrome","preset_explanation":"Tôn da sáng tự nhiên và giữ tương phản trung tính","explanation":"Khóa nét vào mắt chủ thể và căn chỉnh điểm mạnh 1/3 điện ảnh","color_recipe":{"temperature_k":5500,"warmth_shift":0.0,"tint_shift":0.0,"exposure_bias":0.0,"saturation":1.04,"contrast":1.03,"shadow_lift":0.02,"highlight_roll":0.95,"grain":0.0,"vignette":0.02,"color_grade":"softwarm","diagnosis":"Cân bằng ánh sáng tự nhiên"}}
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

        let evRaw = (json["ev_bias"] as? NSNumber)?.floatValue ?? (json["exposure_bias"] as? NSNumber)?.floatValue
        let lightingScene = (json["lighting_scene"] as? String) ?? (json["lighting"] as? String)

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
            presetExplanation: presetExpl,
            recommendedEVBias: evRaw ?? colorRecipe.exposureBias,
            lightingScene: lightingScene
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

    private static func buildVideoCinematographyPrompt(
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
