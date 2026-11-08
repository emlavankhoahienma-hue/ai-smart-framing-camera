import Foundation
import ImageIO
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
        case .googleGemini: return "Google AI Studio (Gemini 3.8 / 3.5 Flash • Interactions API)"
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
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/interactions"
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
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/models"
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
        case .pollinations: return "openai/gpt-5.4-nano"
        case .googleGemini: return "gemini-3.5-flash-lite"
        case .groq:         return "qwen/qwen3.8-27b"
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
    case pollinationsGPT54Nano = "pollinations/gpt-5.4-nano"
    case pollinationsGPT54Mini = "pollinations/gpt-5.4-mini"
    case pollinationsOpenAI = "pollinations/gpt-4o-mini"
    // Official 2026 Google Gemini Models (generateContent API - Verified)
    case gemini35FlashLiteDirect = "gemini-3.5-flash-lite"
    case geminiFlashLiteLatest = "gemini-flash-lite-latest"
    case gemini31FlashLiteDirect = "gemini-3.1-flash-lite"
    case gemini31FlashLitePreview = "gemini-3.1-flash-lite-preview"
    case gemini3FlashPreviewDirect = "gemini-3-flash-preview"
    case gemini35FlashDirect = "gemini-3.5-flash"
    case gemini38FlashDirect = "gemini-3.8-flash"
    case gemini4ArgonDirect = "gemini-4-argon"
    case gemini38Live = "gemini-3.8-live"
    case gemini38LiveExtendedThinking = "gemini-3.8-live-extended-thinking"
    case gemini31ProDirect = "gemini-3.1-pro-preview"
    case gemini25ProDirect = "gemini-2.5-pro"
    case gemini25FlashDirect = "gemini-2.5-flash"
    case gemini25FlashLiteStableDirect = "gemini-2.5-flash-lite"
    case gemini25FlashLiteDirect = "gemini-2.5-flash-lite-preview-06-17"
    case gemini20FlashDirect = "gemini-2.0-flash"
    case gemini20FlashLiteDirect = "gemini-2.0-flash-lite-preview-02-05"
    case gemini15ProDirect = "gemini-1.5-pro"
    case gemini15FlashDirect = "gemini-1.5-flash"
    case gemma4_31BDirect = "gemma-4-31b-it"
    case gemma4_26BDirect = "gemma-4-26b-a4b-it"
    case gemma3_27BDirect = "gemma-3-27b-it"
    case gemini20FlashFree = "google/gemini-2.0-flash-exp:free"
    case groqLlama4Scout = "meta-llama/llama-4-scout-17b-16e-instruct"
    case groqLlama4Maverick = "meta-llama/llama-4-maverick-17b-128e-instruct"
    case groqQwen38 = "qwen/qwen3.8-27b"
    case groqLlama32_11BDirect = "llama-3.2-11b-vision-preview"
    case groqLlama32_90BDirect = "llama-3.2-90b-vision-preview"
    case freeVision = "google/gemma-4-31b-it:free"
    case gemini25FlashFree = "google/gemini-2.5-flash-preview:free"
    case qwen25VL72BFree = "qwen/qwen2.5-vl-72b-instruct:free"
    case qwen25VL32BFree = "qwen/qwen2.5-vl-32b-instruct:free"
    case qwen3VLFree = "qwen/qwen3-vl-32b-instruct:free"
    case llama4MaverickFree = "meta-llama/llama-4-maverick:free"
    case llama4ScoutFree = "meta-llama/llama-4-scout:free"
    case pixtral12BFree = "mistralai/pixtral-12b:free"
    case kimiVLThinkingFree = "moonshotai/kimi-vl-a3b-thinking:free"
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
        case .pollinationsGPT54Nano:  return "GPT-5.4 Nano (Pollinations • Miễn phí 100%)"
        case .pollinationsGPT54Mini:  return "GPT-5.4 Mini (Pollinations • Miễn phí 100%)"
        case .pollinationsOpenAI:     return "GPT-4o Mini (Pollinations AI • Cần Pollen)"
        case .gemini35FlashLiteDirect: return "Gemini 3.5 Flash Lite (Google AI • Siêu tốc 1.4s • Khuyên dùng)"
        case .geminiFlashLiteLatest:   return "Gemini Flash Lite Latest (Google AI • Nhanh nhất 1.3s)"
        case .gemini31FlashLiteDirect: return "Gemini 3.1 Flash Lite (Google AI • Tiết kiệm token • 3.1s)"
        case .gemini31FlashLitePreview: return "Gemini 3.1 Flash Lite Preview (Google AI • 1.6s)"
        case .gemini3FlashPreviewDirect: return "Gemini 3 Flash Preview (Google AI • Đa phương thức)"
        case .gemini35FlashDirect:    return "Gemini 3.5 Flash (Google AI • Chuyên sâu)"
        case .gemini38FlashDirect:     return "Gemini 3.8 Flash (Google AI • Nặng/Dự phòng)"
        case .gemini4ArgonDirect:      return "Gemini 4 Argon (Google AI • Đỉnh cao suy luận 2026)"
        case .gemini38Live:            return "Gemini 3.8 Live (Google AI • Realtime WebSocket Video)"
        case .gemini38LiveExtendedThinking: return "Gemini 3.8 Live Extended Thinking (Google AI • Suy luận sâu)"
        case .gemini31ProDirect:       return "Gemini 3.1 Pro Preview (Google AI • Chuyên gia Bố cục 3D)"
        case .gemini25ProDirect:       return "Gemini 2.5 Pro (Google AI • Đã khai tử)"
        case .gemini25FlashDirect:    return "Gemini 2.5 Flash (Google AI • Đã khai tử)"
        case .gemini25FlashLiteStableDirect: return "Gemini 2.5 Flash Lite (Google AI • Đã khai tử)"
        case .gemini25FlashLiteDirect:return "Gemini 2.5 Flash Lite Preview (Google AI • Đã khai tử)"
        case .gemini20FlashDirect:    return "Gemini 2.0 Flash (Trực tiếp Google AI • Đã khai tử)"
        case .gemini20FlashLiteDirect:return "Gemini 2.0 Flash Lite (Google AI • Đã khai tử)"
        case .gemini15ProDirect:      return "Gemini 1.5 Pro (Google AI • Đã khai tử)"
        case .gemini15FlashDirect:    return "Gemini 1.5 Flash (Google AI • Đã khai tử)"
        case .gemma4_31BDirect:       return "Gemma 4 31B Vision IT (Google AI • Open Weights 2026)"
        case .gemma4_26BDirect:       return "Gemma 4 26B A4B MoE Vision (Google AI • Siêu tốc)"
        case .gemma3_27BDirect:       return "Gemma 3 27B Vision IT (Google AI • Nhẹ & Mượt)"
        case .gemini20FlashFree:      return "Gemini 2.0 Flash (OpenRouter • Miễn phí)"
        case .groqLlama4Scout:        return "Llama 4 Scout 17B Vision (Groq LPU • Chuyên Ảnh • Free)"
        case .groqLlama4Maverick:     return "Llama 4 Maverick 17B Vision (Groq LPU • Siêu tốc • Free)"
        case .groqQwen38:             return "Qwen 3.8 27B Vision (Groq LPU Siêu tốc • Free)"
        case .groqLlama32_11BDirect:  return "Llama 3.2 11B Vision (Groq • Cũ/Ngừng hỗ trợ)"
        case .groqLlama32_90BDirect:  return "Llama 3.2 90B Vision (Groq • Cũ/Ngừng hỗ trợ)"
        case .freeVision:         return "Gemma 4 31B Vision (Miễn phí)"
        case .gemini25FlashFree:  return "Gemini 2.5 Flash (OpenRouter • Miễn phí)"
        case .qwen25VL72BFree:    return "Qwen 2.5 VL 72B (Bậc thầy Bố cục & Màu • Miễn phí)"
        case .qwen25VL32BFree:    return "Qwen 2.5 VL 32B (Chuyên gia Nhiếp ảnh • Miễn phí)"
        case .qwen3VLFree:        return "Qwen 3 VL 32B (Miễn phí)"
        case .llama4MaverickFree: return "Llama 4 Maverick 17B (Miễn phí)"
        case .llama4ScoutFree:    return "Llama 4 Scout 17B (OpenRouter • Miễn phí)"
        case .pixtral12BFree:     return "Mistral Pixtral 12B Vision (Nhiếp ảnh • Miễn phí)"
        case .kimiVLThinkingFree: return "Kimi VL Thinking (Suy luận Bố cục 3D • Miễn phí)"
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
        case .pollinationsGPT54Nano:  return "GPT-5.4 Nano"
        case .pollinationsGPT54Mini:  return "GPT-5.4 Mini"
        case .pollinationsOpenAI:     return "GPT-4o Mini"
        case .gemini35FlashLiteDirect:return "Gemini 3.5 Lite"
        case .geminiFlashLiteLatest:  return "Gemini Lite Latest"
        case .gemini31FlashLiteDirect:return "Gemini 3.1 Lite"
        case .gemini31FlashLitePreview: return "Gemini 3.1 Lite Prev"
        case .gemini3FlashPreviewDirect: return "Gemini 3 Flash"
        case .gemini35FlashDirect:    return "Gemini 3.5 Flash"
        case .gemini38FlashDirect:    return "Gemini 3.8 Flash"
        case .gemini4ArgonDirect:     return "Gemini 4 Argon"
        case .gemini38Live:           return "Gemini 3.8 Live"
        case .gemini38LiveExtendedThinking: return "Gemini 3.8 Live Thinking"
        case .gemini31ProDirect:      return "Gemini 3.1 Pro"
        case .gemini25ProDirect:      return "Gemini 2.5 Pro"
        case .gemini25FlashDirect:    return "Gemini 2.5 Flash"
        case .gemini25FlashLiteStableDirect: return "Gemini 2.5 Lite"
        case .gemini25FlashLiteDirect:return "Gemini 2.5 Lite Preview"
        case .gemini20FlashDirect:    return "Gemini 2.0 Flash"
        case .gemini20FlashLiteDirect:return "Gemini 2.0 Lite"
        case .gemini15ProDirect:      return "Gemini 1.5 Pro"
        case .gemini15FlashDirect:    return "Gemini 1.5 Flash"
        case .gemma4_31BDirect:       return "Gemma 4 31B"
        case .gemma4_26BDirect:       return "Gemma 4 26B MoE"
        case .gemma3_27BDirect:       return "Gemma 3 27B"
        case .gemini20FlashFree:      return "Gemini 2.0 Free"
        case .groqLlama4Scout:        return "Llama 4 Scout"
        case .groqLlama4Maverick:     return "Llama 4 Maverick"
        case .groqQwen38:             return "Qwen 3.8 27B"
        case .groqLlama32_11BDirect:  return "Llama 3.2 11B (Groq)"
        case .groqLlama32_90BDirect:  return "Llama 3.2 90B (Groq)"
        case .freeVision:             return "Gemma 4 31B"
        case .gemini25FlashFree:      return "Gemini 2.5 Free"
        case .qwen25VL72BFree:        return "Qwen 2.5 VL 72B"
        case .qwen25VL32BFree:        return "Qwen 2.5 VL 32B"
        case .qwen3VLFree:            return "Qwen 3 VL"
        case .llama4MaverickFree:     return "Llama 4 Maverick"
        case .llama4ScoutFree:        return "Llama 4 Scout"
        case .pixtral12BFree:         return "Pixtral 12B"
        case .kimiVLThinkingFree:     return "Kimi VL 3D"
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
        case .pollinationsGPT54Nano, .pollinationsGPT54Mini:
            return "Phân tích ảnh trực tiếp từ Pollinations AI — Miễn phí 100%, không tốn Pollen"
        case .pollinationsOpenAI:
            return "Phân tích ảnh qua GPT-4o Mini trên Pollinations AI (yêu cầu tài khoản có Pollen)"
        case .gemini35FlashDirect, .gemini38FlashDirect, .gemini35FlashLiteDirect, .geminiFlashLiteLatest, .gemini31FlashLiteDirect, .gemini31FlashLitePreview, .gemini3FlashPreviewDirect, .gemini4ArgonDirect, .gemini38Live, .gemini38LiveExtendedThinking, .gemini31ProDirect, .gemini25FlashDirect, .gemini25FlashLiteDirect, .gemini20FlashDirect, .gemini20FlashLiteDirect, .gemini15FlashDirect:
            return "Trực tiếp Google AI Studio — Chuyên gia Bố cục & Ánh sáng, miễn phí 1.500 lượt/ngày"
        case .groqLlama4Scout, .groqLlama4Maverick, .groqQwen38:
            return "Groq LPU chip chuyên dụng — Nhận diện thị giác siêu tốc < 0.6 giây hoàn toàn miễn phí"
        case .groqLlama32_11BDirect, .groqLlama32_90BDirect:
            return "Groq LPU chip chuyên dụng — Model cũ (khuyến nghị dùng Llama 4 Scout / Qwen)"
        case .gemini20FlashFree, .freeVision, .gemini25FlashFree, .qwen25VL72BFree, .qwen25VL32BFree, .qwen3VLFree, .llama4MaverickFree, .llama4ScoutFree, .pixtral12BFree, .kimiVLThinkingFree:
            return "Model chuyên Nhiếp ảnh & Thị giác miễn phí qua OpenRouter — tự động xoay vòng dự phòng"
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
            return "google/gemini-3.7-flash"
        case .qwen25VL72BFree:
            return "qwen/qwen2.5-vl-72b-instruct"
        case .qwen25VL32BFree:
            return "qwen/qwen2.5-vl-72b-instruct"
        case .qwen3VLFree:
            return "qwen/qwen3-vl-30b-a3b-instruct"
        case .pollinationsGPT54Nano:
            return "openai/gpt-4o-mini"
        case .pollinationsGPT54Mini:
            return "gemini"
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
                .pollinationsGPT54Nano,
                .pollinationsGPT54Mini,
                .pollinationsOpenAI,
                .freeVision
            ]
        case .googleGemini:
            return [
                .autoStrongest,
                .gemini35FlashLiteDirect,
                .geminiFlashLiteLatest,
                .gemini31FlashLiteDirect,
                .gemini31FlashLitePreview,
                .gemini3FlashPreviewDirect,
                .gemma4_26BDirect,
                .gemini35FlashDirect,
                .gemini38FlashDirect,
                .gemini4ArgonDirect
            ]
        case .groq:
            return [
                .autoStrongest,
                .groqLlama4Scout,
                .groqLlama4Maverick,
                .groqQwen38,
                .groqLlama33,
                .groqLlama32_11BDirect,
                .groqLlama32_90BDirect
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
        case .pollinations: return .pollinationsGPT54Nano
        case .googleGemini: return .gemini35FlashLiteDirect
        case .groq: return .groqQwen38
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
            "gemini-3.5-flash-lite",
            "gemini-flash-lite-latest",
            "gemini-3.1-flash-lite-preview",
            "google/gemini-3.7-flash"
        ]
    }

    public static var freeFallbackChain: [String] {
        [
            "google/gemma-4-31b-it:free",
            "google/gemma-4-26b-a4b-it:free",
            "nvidia/nemotron-3.5-super-vl:free",
            "openrouter/free"
        ]
    }

    public static func normalizeModelID(_ raw: String, provider: AICloudProvider) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .openRouter else { return clean }
        let lower = clean.lowercased()

        if lower.contains("qwen") && (lower.contains("72b") || lower.contains("73b") || lower.contains("2.5") || lower.contains("vl")) {
            return "qwen/qwen2.5-vl-72b-instruct"
        }
        if lower == "qwen" || lower == "qwen2.5" || lower == "qwen-vl" {
            return "qwen/qwen2.5-vl-72b-instruct"
        }
        if lower.contains("qwen3") || lower.contains("qwen-3") {
            return "qwen/qwen3-vl-30b-a3b-instruct"
        }
        return clean
    }

    public static func fallbackChain(selected: AIVisionModel, customModelName: String, provider: AICloudProvider = .openRouter) -> [String] {
        let custom = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var preferred = custom.isEmpty ? selected.technicalModelID : custom

        if provider == .pollinations {
            var cleanModel = preferred.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "auto" || cleanModel.isEmpty || cleanModel.contains("5.4") {
                cleanModel = "openai/gpt-4o-mini"
            } else if cleanModel == "openai/4omini" || cleanModel == "4omini" {
                cleanModel = "openai/gpt-4o-mini"
            } else if cleanModel == "pollinations/gpt-4o-mini" {
                cleanModel = "openai/gpt-4o-mini"
            } else if cleanModel == "pollinations/gpt-5.4-nano" {
                cleanModel = "openai/gpt-4o-mini"
            } else if cleanModel == "pollinations/gpt-5.4-mini" {
                cleanModel = "gemini"
            } else if cleanModel.contains("gemma-4") {
                cleanModel = "google/gemma-4-31b-it"
            }

            var chain = [cleanModel]
            let candidates = ["openai/gpt-4o-mini", "openai", "gemini", "google/gemma-4-31b-it"]
            for cand in candidates {
                if !chain.contains(cand) {
                    chain.append(cand)
                }
            }
            return chain
        }

        if provider == .googleGemini {
            var cleanModel = preferred
            if cleanModel.hasPrefix("models/") {
                cleanModel = String(cleanModel.dropFirst("models/".count))
            }
            if cleanModel.hasPrefix("google/") {
                cleanModel = String(cleanModel.dropFirst("google/".count))
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            // Tự động chuyển các model đã bị Google khai tử (1.5, 2.0, 2.5) hoặc "auto" sang Gemini 3.5 Flash Lite
            if cleanModel.contains("1.5") || cleanModel.contains("2.0") || cleanModel.contains("2.5") || cleanModel == "auto" || cleanModel.isEmpty {
                cleanModel = "gemini-3.5-flash-lite"
            }

            // Chuỗi dự phòng các model Google AI Studio chuẩn 2026 đã được kiểm chứng hoạt động siêu tốc (< 2s) và trả JSON hợp lệ
            var chain = [cleanModel]
            let fallbacks = [
                "gemini-3.5-flash-lite",
                "gemini-flash-lite-latest",
                "gemini-3.1-flash-lite-preview",
                "gemini-3.1-flash-lite",
                "gemma-4-26b-a4b-it",
                "gemini-3-flash-preview",
                "gemini-3.5-flash"
            ]
            for fb in fallbacks {
                if !chain.contains(fb) {
                    chain.append(fb)
                }
            }
            return chain
        } else if provider == .groq {
            var cleanModel = preferred
            if cleanModel.hasPrefix("groq/") {
                cleanModel = String(cleanModel.dropFirst("groq/".count))
            }
            cleanModel = cleanModel.replacingOccurrences(of: ":free", with: "")
            if cleanModel == "auto" || cleanModel == "llama-3.2-11b-vision-preview" || cleanModel == "llama-3.2-90b-vision-preview" || cleanModel.isEmpty {
                cleanModel = "qwen/qwen3.8-27b"
            }
            if selected != .autoStrongest && cleanModel != "llama-3.2-11b-vision-preview" && cleanModel != "llama-3.2-90b-vision-preview" {
                return [cleanModel]
            }
            return [cleanModel, "qwen/qwen3.8-27b"]
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

        if selected == .autoStrongest && custom.isEmpty {
            return autoFallbackChain
        }

        preferred = normalizeModelID(preferred, provider: .openRouter)

        if selected != .autoStrongest && !custom.isEmpty {
            if preferred.contains("qwen") {
                let candidates = [preferred, "google/gemma-4-31b-it:free", "google/gemini-2.5-flash", "openai/gpt-4o-mini"]
                var chain: [String] = []
                for cand in candidates {
                    if !chain.contains(cand) { chain.append(cand) }
                }
                return chain
            }
            return [preferred]
        }

        let freeOnly = (selected == .freeVision) || (preferred.hasSuffix(":free") || preferred == "openrouter/free")
        if freeOnly {
            var chain = [preferred]
            for cand in freeFallbackChain {
                if !chain.contains(cand) {
                    chain.append(cand)
                }
            }
            return chain
        }

        if preferred.contains("qwen") {
            let candidates = [preferred, "google/gemma-4-31b-it:free", "google/gemini-2.5-flash", "openai/gpt-4o-mini"]
            var chain: [String] = []
            for cand in candidates {
                if !chain.contains(cand) {
                    chain.append(cand)
                }
            }
            return chain
        }

        var chain = [preferred]
        for cand in autoFallbackChain {
            if !chain.contains(cand) {
                chain.append(cand)
            }
        }
        return chain
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

// MARK: - Gemini Structured Output Models (Codable)
public struct GeminiStructuredFramingOutput: Codable {
    public let target_x: Double
    public let target_y: Double
    public let suggested_zoom: Double
    public let composition_rule: String
    public let scene_type: String
    public let explanation: String
    public let recommended_preset: String
    public let preset_explanation: String?
    public let recommended_ev_bias: Double?
    public let lighting_scene: String?
    public let subject_x: Double?
    public let subject_y: Double?
    public let subject_w: Double?
    public let subject_h: Double?
    public let subject_box_2d: [Double]?
    public let composition_anchor_x: Double?
    public let composition_anchor_y: Double?
    public let composition_x: Double?
    public let composition_y: Double?
    public let shot_scale: String?
    public let color_recipe: GeminiStructuredColorRecipe?

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "target_x": target_x,
            "target_y": target_y,
            "suggested_zoom": suggested_zoom,
            "composition_rule": composition_rule,
            "scene_type": scene_type,
            "explanation": explanation,
            "recommended_preset": recommended_preset
        ]
        if let pExp = preset_explanation { dict["preset_explanation"] = pExp }
        if let ev = recommended_ev_bias { dict["exposure_bias"] = ev }
        if let light = lighting_scene { dict["lighting_scene"] = light }
        if let box = subject_box_2d, box.count == 4 {
            dict["subject_box_2d"] = box
            let scale: Double = (box.max() ?? 0) > 1.5 ? 1000.0 : 1.0
            let ymin = max(0.0, min(1.0, box[0] / scale))
            let xmin = max(0.0, min(1.0, box[1] / scale))
            let ymax = max(ymin, min(1.0, box[2] / scale))
            let xmax = max(xmin, min(1.0, box[3] / scale))
            let bw = max(0.04, xmax - xmin)
            let bh = max(0.04, ymax - ymin)
            dict["subject_w"] = bw
            dict["subject_h"] = bh
            if subject_x == nil { dict["subject_x"] = xmin + bw * 0.5 }
            if subject_y == nil { dict["subject_y"] = ymin + bh * 0.38 }
        }
        if let sx = subject_x { dict["subject_x"] = sx }
        if let sy = subject_y { dict["subject_y"] = sy }
        if let sw = subject_w { dict["subject_w"] = sw }
        if let sh = subject_h { dict["subject_h"] = sh }
        if let cax = composition_x ?? composition_anchor_x { dict["composition_x"] = cax }
        if let cay = composition_y ?? composition_anchor_y { dict["composition_y"] = cay }
        if let scale = shot_scale { dict["shot_scale"] = scale }
        if let cr = color_recipe {
            dict["color_recipe"] = cr.toDictionary()
        }
        return dict
    }

    public func toFramingResponse(modelUsed: String, latencyMs: Int) -> GeminiFramingResponse {
        return GeminiService.parseGeminiResponse(toDictionary(), modelUsed: modelUsed, latencyMs: latencyMs)
    }
}

public struct GeminiStructuredColorRecipe: Codable {
    public let exposure_ev: Double?
    public let contrast: Double?
    public let highlights: Double?
    public let shadows: Double?
    public let warmth: Double?
    public let tint: Double?
    public let saturation: Double?
    public let vibrance: Double?
    public let sharpness: Double?
    public let vignette: Double?

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = exposure_ev { dict["exposure_bias"] = v }
        if let v = contrast { dict["contrast"] = v }
        if let v = highlights { dict["highlight_roll"] = v }
        if let v = shadows { dict["shadow_lift"] = v }
        if let v = warmth { dict["temperature_k"] = v }
        if let v = tint { dict["tint_shift"] = v }
        if let v = saturation { dict["saturation"] = v }
        if let v = vignette { dict["vignette"] = v }
        return dict
    }
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
    public let subjectX: CGFloat
    public let subjectY: CGFloat
    public let compositionAnchorX: CGFloat
    public let compositionAnchorY: CGFloat
    public let estimatedSubjectSize: CGSize?
    public let shotScale: String

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
        lightingScene: String? = nil,
        subjectX: CGFloat? = nil,
        subjectY: CGFloat? = nil,
        compositionAnchorX: CGFloat = 0.5,
        compositionAnchorY: CGFloat = 0.5,
        estimatedSubjectSize: CGSize? = nil,
        shotScale: String = "medium_portrait"
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
        self.subjectX = subjectX ?? targetX
        self.subjectY = subjectY ?? targetY
        self.compositionAnchorX = compositionAnchorX
        self.compositionAnchorY = compositionAnchorY
        self.estimatedSubjectSize = estimatedSubjectSize
        self.shotScale = shotScale
    }

    public func toScanResp(isPlan2: Bool = false) -> ScanResp {
        let focalLengthStr: String
        if suggestedZoom <= 1.15 {
            focalLengthStr = "26mm"
        } else if suggestedZoom <= 1.65 {
            focalLengthStr = "35mm"
        } else if suggestedZoom <= 2.2 {
            focalLengthStr = "50mm"
        } else {
            focalLengthStr = "70mm"
        }
        let width = estimatedSubjectSize?.width ?? 0.28
        let height = estimatedSubjectSize?.height ?? 0.38
        let normX = max(0.0, min(1.0 - width, targetX - width / 2.0))
        let normY = max(0.0, min(1.0 - height, targetY - height / 2.0))
        let subArea = SubAreaRectNormModel(x: normX, y: normY, w: width, h: height)
        let filter = AiCameraFilterModel(
            filterName: recommendedPreset.displayName,
            reason: presetExplanation
        )
        let data = ScanRespData(
            subAreaRectNorm: subArea,
            exifFocalLength: focalLengthStr,
            recommendedZoom: suggestedZoom,
            bodyRange: shotScale,
            composeReason: compositionRule.displayName,
            aiCameraFilter: filter,
            recommendedEVBias: recommendedEVBias ?? colorRecipe.exposureBias,
            isTargetMatch: true,
            isPlan2Telephoto: isPlan2
        )
        return ScanResp(code: 200, msg: "success", data: data)
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
    @Published public var discoveredModelDescriptions: [String: String] = [:]
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
                if selectedProvider != .pollinations {
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
        if !custom.isEmpty {
            if selectedProvider == .groq && (custom == "llama-3.2-11b-vision-preview" || custom == "llama-3.2-90b-vision-preview") {
                return "qwen/qwen3.8-27b"
            }
            return custom
        }
        if selectedProvider == .pollinations {
            return selectedModel.technicalModelID
        }
        let raw = selectedModel.technicalModelID
        if selectedProvider == .googleGemini {
            var clean = raw
            if clean.hasPrefix("models/") {
                clean = String(clean.dropFirst("models/".count))
            }
            if clean.hasPrefix("google/") {
                clean = String(clean.dropFirst("google/".count))
            }
            clean = clean.replacingOccurrences(of: ":free", with: "")
            if clean.contains("1.5") || clean.contains("2.0") || clean.contains("2.5") || clean == "auto" || clean.isEmpty {
                clean = "gemini-3.5-flash-lite"
            }
            return clean
        }
        if selectedProvider == .groq {
            if raw == "llama-3.2-11b-vision-preview" || raw == "llama-3.2-90b-vision-preview" || raw == "auto" {
                return "qwen/qwen3.8-27b"
            }
            if raw.hasPrefix("groq/") {
                return String(raw.dropFirst("groq/".count)).replacingOccurrences(of: ":free", with: "")
            }
            return raw.replacingOccurrences(of: ":free", with: "")
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

    // MARK: - HTTP Request Headers Configuration
    private func configureHeaders(for request: inout URLRequest, key: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard !key.isEmpty else { return }

        switch selectedProvider {
        case .googleGemini:
            // Google AI Studio expects x-goog-api-key (and/or ?key= query parameter).
            // NEVER set "Authorization: Bearer" because Google evaluates it as an OAuth2 token and rejects API keys with HTTP 401.
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        case .anthropic:
            // Anthropic expects x-api-key and anthropic-version
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("https://alignai.studio", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("AlignAI Studio", forHTTPHeaderField: "X-Title")
        case .pollinations, .groq, .openAI, .deepSeek, .xAI, .custom:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
                .replacingOccurrences(of: "/interactions", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            modelsURLStr = normalized + "/models"
        }
        if selectedProvider == .googleGemini {
            if var components = URLComponents(string: modelsURLStr) {
                var items = components.queryItems ?? []
                if !items.contains(where: { $0.name == "pageSize" }) {
                    items.append(URLQueryItem(name: "pageSize", value: "200"))
                }
                if !key.isEmpty && !items.contains(where: { $0.name == "key" }) {
                    items.append(URLQueryItem(name: "key", value: key))
                }
                components.queryItems = items
                if let u = components.url {
                    modelsURLStr = u.absoluteString
                }
            }
        }
        guard let url = URL(string: modelsURLStr) else {
            return (false, "URL danh sách model không hợp lệ")
        }

        await MainActor.run { self.isFetchingModels = true }
        defer { Task { @MainActor in self.isFetchingModels = false } }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        configureHeaders(for: &request, key: key)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return (false, "HTTP \(code) khi tải danh sách model")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Định dạng danh sách model không khớp")
            }
            var ids: [String] = []
            var descriptions: [String: String] = [:]
            if let arr = json["data"] as? [[String: Any]] {
                for item in arr {
                    guard let id = item["id"] as? String else { continue }
                    ids.append(id)
                    if let name = item["name"] as? String, !name.isEmpty {
                        descriptions[id] = name
                    }
                }
            } else if let modelsArr = json["models"] as? [[String: Any]] {
                for m in modelsArr {
                    guard let rawName = m["name"] as? String else { continue }
                    let id = rawName.replacingOccurrences(of: "models/", with: "")
                    let lower = id.lowercased()
                    // Exclude embedding-only, AQA, TTS, transcribe, and deprecated/unavailable models that do not accept multimodal image analysis
                    if selectedProvider == .googleGemini {
                        if lower.contains("embedding") || lower.contains("aqa") || lower.contains("imagen") || lower.contains("veo") || lower.contains("tts") || lower.contains("whisper") || lower.contains("transcribe") || lower.contains("deep-research") || lower.contains("lyria") || lower.hasPrefix("gemini-2.5") || lower.hasPrefix("gemini-2.0") || lower.hasPrefix("gemini-1.5") || lower.contains("banana") || lower.contains("computer-use") {
                            continue
                        }
                    } else if lower.contains("embedding") || lower.contains("aqa") || lower.contains("imagen") || lower.contains("veo") || lower.contains("tts") || lower.contains("whisper") {
                        continue
                    }
                    if let methods = m["supportedGenerationMethods"] as? [String], !methods.isEmpty {
                        let supportsGen = methods.contains("generateContent") || methods.contains("createInteraction") || methods.contains("streamGenerateContent")
                        if !supportsGen { continue }
                    }
                    ids.append(id)
                    if let displayName = m["displayName"] as? String, !displayName.isEmpty {
                        descriptions[id] = displayName
                    }
                }
            }
            if selectedProvider == .googleGemini {
                let builtInGemini = [
                    "gemini-3.5-flash-lite",
                    "gemini-flash-lite-latest",
                    "gemini-3.1-flash-lite-preview",
                    "gemini-3.1-flash-lite",
                    "gemini-3-flash-preview",
                    "gemma-4-26b-a4b-it",
                    "gemini-3.5-flash",
                    "gemini-3.8-flash",
                    "gemini-4-argon"
                ]
                for b in builtInGemini where !ids.contains(b) {
                    ids.append(b)
                }
            }
            guard !ids.isEmpty else {
                return (false, "Không tìm thấy model nào từ danh sách trả về")
            }
            let prioritized = ids.sorted { a, b in
                let al = a.lowercased(), bl = b.lowercased()
                func rank(_ s: String) -> Int {
                    if s.contains("flash-lite") || s.contains("lite") { return 0 }
                    if s.hasPrefix("gemini-3.5") { return 1 }
                    if s.hasPrefix("gemini-3.1") || s.hasPrefix("gemini-3") { return 2 }
                    if s.contains("gemma-4") || s.contains("gemma-3") { return 3 }
                    if s.hasPrefix("gemini-3.8") || s.hasPrefix("gemini-4") { return 4 }
                    if s.hasPrefix("gemini-2.5") || s.hasPrefix("gemini-2.0") || s.hasPrefix("gemini-1.5") { return 10 }
                    if s.contains("vl") || s.contains("gpt-5") || s.contains("gpt-4") || s.contains("claude") || s.contains("vision") || s.contains("llama-4") || s.contains("grok") { return 5 }
                    return 6
                }
                let ra = rank(al), rb = rank(bl)
                if ra != rb { return ra < rb }
                return a < b
            }
            var seen = Set<String>()
            let uniqueCapped = prioritized.filter { seen.insert($0).inserted }.prefix(200)
            let capped = Array(uniqueCapped)
            let finalDescriptions = descriptions
            await MainActor.run {
                self.discoveredModels = capped
                self.discoveredModelDescriptions = finalDescriptions
            }
            return (true, "Đã tải \(capped.count) model từ \(selectedProvider.shortBadge) API")
        } catch {
            return (false, "Lỗi tải model: \(error.localizedDescription)")
        }
    }

    public var cloudAnalysisDeadline: TimeInterval {
        if selectedProvider == .pollinations { return 25.0 }
        let custom = customModelName.lowercased()
        if custom.contains("qwen") || custom.contains("72b") || custom.contains("73b") || custom.hasSuffix(":free") || custom == "openrouter/free" {
            return 38.0
        }
        switch selectedModel {
        case .freeVision, .gemini25FlashFree, .qwen25VL72BFree, .qwen25VL72B, .qwen25VL32BFree, .qwen3VLFree, .llama4MaverickFree:
            return 38.0
        default:
            return selectedProvider == .openRouter ? 35.0 : 20.0
        }
    }

    // Selected Model Setting
    public var selectedModel: AIVisionModel {
        get {
            guard let saved = UserDefaults.standard.string(forKey: "gemini_selected_model") else {
                return AIVisionModel.defaultModel(for: selectedProvider)
            }
            if let model = AIVisionModel(rawValue: saved) {
                if selectedProvider == .groq && (model == .groqLlama32_11BDirect || model == .groqLlama32_90BDirect) {
                    return .groqQwen38
                }
                if selectedProvider == .googleGemini && (model.rawValue.contains("2.5") || model.rawValue.contains("2.0") || model.rawValue.contains("1.5")) {
                    return .gemini35FlashLiteDirect
                }
                return model
            }
            return AIVisionModel.defaultModel(for: selectedProvider)
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
        forceGenerateContent: Bool = false,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard index < candidates.count else {
            completion(false, "Đã thử các model của \(selectedProvider.displayName) nhưng kết nối không thành công. Hãy kiểm tra API key hoặc hạn mức của tài khoản.")
            return
        }

        let testModel = candidates[index]
        let useInteractions = selectedProvider == .googleGemini && Self.usesInteractionsEndpoint(for: testModel) && !forceGenerateContent
        guard let url = buildURL(for: testModel, key: key, forceGenerateContent: forceGenerateContent) else {
            completion(false, "URL không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if testModel.hasSuffix(":free") || testModel == "openrouter/free" {
            request.timeoutInterval = 45
        }
        configureHeaders(for: &request, key: key)

        let body: [String: Any]
        if selectedProvider == .googleGemini {
            if useInteractions {
                body = [
                    "model": testModel,
                    "input": "Hi"
                ]
            } else {
                body = [
                    "contents": [
                        [
                            "parts": [
                                ["text": "Hi"]
                            ]
                        ]
                    ],
                    "generationConfig": [
                        "maxOutputTokens": 10
                    ]
                ]
            }
        } else {
            body = [
                "model": testModel,
                "messages": [
                    ["role": "user", "content": "Hi"]
                ],
                "max_tokens": 10
            ]
        }
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

            if (200...299).contains(http.statusCode) {
                DispatchQueue.main.async {
                    self.lastModelUsed = testModel
                    self.lastLatencyMs = latency
                    completion(true, "✅ Kết nối thành công! [\(self.selectedProvider.displayName)] Đang dùng: \(testModel) (Độ trễ: \(latency)ms)")
                }
            } else if useInteractions && (http.statusCode == 404 || http.statusCode == 400) {
                self.testModelCandidate(candidates: candidates, index: index, key: key, forceGenerateContent: true, completion: completion)
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
        var totalLumaSq: Float = 0

        let totalPixels = Float(width * height)
        let inv255: Float = 1.0 / 255.0
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Float(rawBytes[offset]) * inv255
            let g = Float(rawBytes[offset + 1]) * inv255
            let b = Float(rawBytes[offset + 2]) * inv255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            totalR += r
            totalG += g
            totalB += b
            totalLuma += luma
            totalLumaSq += luma * luma
        }

        let avgR = totalR / totalPixels
        let avgG = totalG / totalPixels
        let avgB = totalB / totalPixels
        let avgLuma = totalLuma / totalPixels

        let warmthCast = (avgR - avgB) / max(0.01, (avgR + avgB))
        let tintCast = (avgG - (avgR + avgB) * 0.5) / max(0.01, avgG)

        let variance = max(0, (totalLumaSq / totalPixels) - (avgLuma * avgLuma))
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

    // MARK: - Image Downscaling & Optimization for AI Vision Analysis with ImageIO & Visual Grid (Set-of-Mark)
    public static func prepareImageForAnalysis(
        _ image: CGImage,
        maxDimension: CGFloat = 1280,
        compressionQuality: CGFloat = 0.60,
        overlayVisualGrid: Bool = true
    ) -> Data? {
        let net = NetworkMonitor.shared.checkConnection()
        let effectiveMaxDimension: CGFloat
        let effectiveQuality: CGFloat
        if !net.isConnected || net.isCellular {
            effectiveMaxDimension = min(maxDimension, 960)
            effectiveQuality = min(compressionQuality, 0.50)
        } else {
            effectiveMaxDimension = maxDimension
            effectiveQuality = compressionQuality
        }

        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let maxOrig = max(originalWidth, originalHeight)

        let targetWidth: Int
        let targetHeight: Int
        if maxOrig > effectiveMaxDimension {
            let scale = effectiveMaxDimension / maxOrig
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
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            if overlayVisualGrid {
                drawVisualGridOverlay(in: context, width: targetWidth, height: targetHeight)
            }

            if let scaledCG = context.makeImage() {
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) {
                    let options: [CFString: Any] = [
                        kCGImageDestinationLossyCompressionQuality: effectiveQuality
                    ]
                    CGImageDestinationAddImage(destination, scaledCG, options as CFDictionary)
                    if CGImageDestinationFinalize(destination) {
                        return data as Data
                    }
                }
                let uiImage = UIImage(cgImage: scaledCG)
                return uiImage.jpegData(compressionQuality: effectiveQuality)
            }
        }

        let uiImage = UIImage(cgImage: image)
        return uiImage.jpegData(compressionQuality: effectiveQuality)
    }

    /// Vẽ lưới ô thị giác Set-of-Mark (Visual Grid Prompting) siêu mảnh, tinh tế, không làm mờ chi tiết chủ thể
    private static func drawVisualGridOverlay(in context: CGContext, width: Int, height: Int) {
        context.saveGState()
        let w = CGFloat(width)
        let h = CGFloat(height)

        // 1. Lưới 10x10 ô chuẩn (10% increments) với đường nét hairline siêu mảnh (alpha 0.18)
        context.setLineWidth(1.0)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)

        for i in 1...9 {
            let fraction = CGFloat(i) * 0.10
            context.move(to: CGPoint(x: w * fraction, y: 0))
            context.addLine(to: CGPoint(x: w * fraction, y: h))

            context.move(to: CGPoint(x: 0, y: h * fraction))
            context.addLine(to: CGPoint(x: w, y: h * fraction))
        }
        context.strokePath()

        // 2. Vạch chia phụ 20x20 (5% increments) ở viền biên để AI định vị cận cảnh
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        for i in 1...19 where i % 2 != 0 {
            let fraction = CGFloat(i) * 0.05
            context.move(to: CGPoint(x: w * fraction, y: 0))
            context.addLine(to: CGPoint(x: w * fraction, y: 5))
            context.move(to: CGPoint(x: w * fraction, y: h - 5))
            context.addLine(to: CGPoint(x: w * fraction, y: h))

            context.move(to: CGPoint(x: 0, y: h * fraction))
            context.addLine(to: CGPoint(x: 5, y: h * fraction))
            context.move(to: CGPoint(x: w - 5, y: h * fraction))
            context.addLine(to: CGPoint(x: w, y: h * fraction))
        }
        context.strokePath()

        // 3. Đánh dấu chữ thập (+) tại các điểm mạnh bố cục Tỷ lệ vàng, 1/3 và Tâm khung hình
        let powerPoints: [CGPoint] = [
            CGPoint(x: 0.333, y: 0.333), CGPoint(x: 0.667, y: 0.333),
            CGPoint(x: 0.333, y: 0.667), CGPoint(x: 0.667, y: 0.667),
            CGPoint(x: 0.382, y: 0.382), CGPoint(x: 0.618, y: 0.382),
            CGPoint(x: 0.382, y: 0.618), CGPoint(x: 0.618, y: 0.618),
            CGPoint(x: 0.500, y: 0.500)
        ]
        context.setStrokeColor(UIColor.cyan.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1.2)
        let crossSize: CGFloat = 6.0
        for p in powerPoints {
            let cx = w * p.x
            let cy = h * p.y
            context.move(to: CGPoint(x: cx - crossSize, y: cy))
            context.addLine(to: CGPoint(x: cx + crossSize, y: cy))
            context.move(to: CGPoint(x: cx, y: cy - crossSize))
            context.addLine(to: CGPoint(x: cx, y: cy + crossSize))
        }
        context.strokePath()

        // 4. Ký hiệu chữ - số (A..J ở mép trên, 1..10 ở mép trái) định danh 100 ô thị giác SoM
        let fontSize = max(8.0, min(11.0, w * 0.015))
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.50)
        ]
        let colLetters = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
        UIGraphicsPushContext(context)
        for i in 0..<10 {
            let colText = colLetters[i] as NSString
            let colX = w * (CGFloat(i) * 0.10 + 0.05) - (fontSize * 0.3)
            colText.draw(at: CGPoint(x: colX, y: 2), withAttributes: textAttributes)

            let rowText = "\(i + 1)" as NSString
            let rowY = h * (CGFloat(i) * 0.10 + 0.05) - (fontSize * 0.5)
            rowText.draw(at: CGPoint(x: 2, y: rowY), withAttributes: textAttributes)
        }
        UIGraphicsPopContext()

        context.restoreGState()
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

        let chain = AIVisionModel.fallbackChain(selected: selectedModel, customModelName: customModelName, provider: selectedProvider)
        let startTime = CACurrentMediaTime()

        // Thực hiện nén ảnh JPEG 1280px sắc nét và trích xuất quang phổ màu trên luồng nền để không bao giờ gây khựng Main UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let jpegData = Self.prepareImageForAnalysis(image, maxDimension: 1280, compressionQuality: 0.78, overlayVisualGrid: false) else {
                DispatchQueue.main.async {
                    completion(.failure(.imageConversionFailed))
                }
                return
            }
            let base64Image = jpegData.base64EncodedString()
            let metrics = colorMetrics ?? Self.extractColorMetrics(from: image)
            let prompt = self.buildPrompt(sceneContext: sceneContext, colorMetrics: metrics, subjectRect: subjectRect, faceRects: faceRects)

            self.tryModelChain(
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
        let useInteractions = selectedProvider == .googleGemini && Self.usesInteractionsEndpoint(for: currentModelID)
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
        request.timeoutInterval = 15.0
        if currentModelID.hasSuffix(":free") || currentModelID == "openrouter/free" {
            request.timeoutInterval = 40.0
        }
        configureHeaders(for: &request, key: key)

        var requestBody: [String: Any]
        if selectedProvider == .googleGemini {
            let videoGuidanceSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "shot_style": ["type": "string", "description": "Cinematic shot style title in Vietnamese"],
                    "movement_direction": ["type": "string", "description": "Movement guidance instruction in Vietnamese"],
                    "suggested_pacing_seconds": ["type": "number", "description": "Recommended pacing duration in seconds"],
                    "suggested_zoom": ["type": "number", "description": "Optimal zoom level 1.0 to 3.0"],
                    "director_tip": ["type": "string", "description": "Professional tip for holding and moving camera in Vietnamese"],
                    "waypoints": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "integer"],
                                "x": ["type": "number", "description": "Normalized waypoint X [0.0..1.0]"],
                                "y": ["type": "number", "description": "Normalized waypoint Y [0.0..1.0]"],
                                "label": ["type": "string"],
                                "action_tip": ["type": "string"],
                                "duration": ["type": "number"]
                            ],
                            "required": ["id", "x", "y", "label", "action_tip", "duration"]
                        ]
                    ]
                ],
                "required": ["shot_style", "movement_direction", "suggested_pacing_seconds", "suggested_zoom", "director_tip", "waypoints"]
            ]

            if useInteractions {
                requestBody = [
                    "model": currentModelID,
                    "input": [
                        [
                            "type": "image",
                            "mime_type": "image/jpeg",
                            "data": base64Image
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ],
                    "response_format": [
                        "type": "text",
                        "mime_type": "application/json",
                        "schema": videoGuidanceSchema
                    ]
                ]
            } else {
                requestBody = [
                    "contents": [
                        [
                            "parts": [
                                [
                                    "inlineData": [
                                        "mimeType": "image/jpeg",
                                        "data": base64Image
                                    ]
                                ],
                                [
                                    "text": prompt
                                ]
                            ]
                        ]
                    ],
                    "generationConfig": [
                        "responseMimeType": "application/json",
                        "responseSchema": videoGuidanceSchema,
                        "temperature": 0.35
                    ]
                ]
            }
        } else {
            requestBody = [
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
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let steps = json["steps"] as? [[String: Any]] {
                    for step in steps {
                        if step["type"] as? String == "model_output",
                           let content = step["content"] as? [[String: Any]] {
                            for item in content {
                                if item["type"] as? String == "text", let text = item["text"] as? String, !text.isEmpty {
                                    responseText = text
                                    break
                                }
                            }
                        }
                    }
                }
                if responseText == nil, let candidates = json["candidates"] as? [[String: Any]],
                   let firstCand = candidates.first,
                   let content = firstCand["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    responseText = parts.compactMap { $0["text"] as? String }.joined()
                }
                if responseText == nil, let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let text = message["content"] as? String {
                    responseText = text
                }
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

    // MARK: - Dynamic Model Health & Circuit Breaker
    private static var modelHealthScores: [String: Double] = [:]
    private static var modelBackoffs: [String: Double] = [:]
    private static let healthLock = NSLock()

    public static func isModelHealthy(_ modelID: String) -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        let now = CACurrentMediaTime()
        if let backoffUntil = modelBackoffs[modelID], now < backoffUntil {
            return false
        }
        let score = modelHealthScores[modelID] ?? 1.0
        return score >= 0.3
    }

    public static func recordModelSuccess(_ modelID: String, latencyMs: Int) {
        healthLock.lock()
        defer { healthLock.unlock() }
        let current = modelHealthScores[modelID] ?? 1.0
        let latencyBonus = latencyMs < 2500 ? 0.2 : (latencyMs > 5000 ? -0.1 : 0.05)
        modelHealthScores[modelID] = min(1.0, current + latencyBonus)
        modelBackoffs.removeValue(forKey: modelID)
    }

    public static func recordModelFailure(_ modelID: String, statusCode: Int, errorMsg: String) {
        healthLock.lock()
        defer { healthLock.unlock() }
        let current = modelHealthScores[modelID] ?? 1.0
        modelHealthScores[modelID] = max(0.0, current - 0.4)
        let duration: Double
        if statusCode == 429 || statusCode == 503 {
            duration = 30.0
        } else if statusCode == 404 {
            duration = 300.0
        } else {
            duration = 15.0
        }
        modelBackoffs[modelID] = CACurrentMediaTime() + duration
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

        // Fast circuit breaker: Nếu model hiện tại đang trong thời gian backoff và vẫn còn model khác dự phòng, ưu tiên nhảy tiếp ngay
        if !Self.isModelHealthy(currentModelID) && index + 1 < chain.count {
            CameraLogger.warning("GeminiService: Model \(currentModelID) đang trong thời gian backoff/suy giảm sức khỏe, tự động nhảy sang model kế tiếp", category: .ai)
            self.tryModelChain(
                chain: chain,
                index: index + 1,
                base64Image: base64Image,
                prompt: prompt,
                key: key,
                lastErrorMsg: lastErrorMsg,
                startTime: startTime,
                completion: completion
            )
            return
        }

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
                let latencyMs = Int((CACurrentMediaTime() - startTime) * 1000)
                Self.recordModelSuccess(currentModelID, latencyMs: latencyMs)
                completion(.success(response))
            case .failure(let error):
                let statusCode: Int
                switch error {
                case .rateLimited: statusCode = 429
                case .invalidAPIKey: statusCode = 401
                case .insufficientCredits: statusCode = 402
                case .freeQuotaReached: statusCode = 429
                case .parseError: statusCode = 422
                case .invalidResponse: statusCode = 502
                case .invalidURL: statusCode = 404
                case .networkError: statusCode = 503
                case .noAPIKey: statusCode = 400
                case .imageConversionFailed: statusCode = 400
                case .allModelsFailed: statusCode = 503
                }
                Self.recordModelFailure(currentModelID, statusCode: statusCode, errorMsg: error.localizedDescription)
                CameraLogger.warning("GeminiService: Model \(currentModelID) thất bại (status: \(statusCode)): \(error.localizedDescription)", category: .ai)

                // Nếu là lỗi sai API Key hoàn toàn (401/403) và không còn model dự phòng khác
                if case .invalidAPIKey = error, index >= chain.count - 1 {
                    CameraLogger.error("GeminiService: Sai API Key cho \(self.selectedProvider.displayName)", category: .ai)
                    completion(.failure(error))
                    return
                }

                // Tự động chuyển sang model dự phòng tiếp theo trong chuỗi nếu còn model (hết quota 429, hết credit 402, lỗi model...)
                if index + 1 < chain.count {
                    let nextModel = chain[index + 1]
                    CameraLogger.info("GeminiService: Tự động chuyển fallback sang model: \(nextModel)", category: .ai)
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
                } else {
                    CameraLogger.error("GeminiService: Toàn bộ model trong chuỗi đều không khả dụng", category: .ai)
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
        forceGenerateContent: Bool = false,
        completion: @escaping (Result<GeminiFramingResponse, GeminiError>) -> Void
    ) {
        let useInteractions = selectedProvider == .googleGemini && Self.usesInteractionsEndpoint(for: modelID) && !forceGenerateContent
        guard let url = buildURL(for: modelID, key: key, forceGenerateContent: forceGenerateContent) else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0
        if modelID.hasSuffix(":free") || modelID == "openrouter/free" || modelID.contains("qwen") || modelID.contains("72b") || selectedProvider == .openRouter {
            request.timeoutInterval = 40.0
        }
        configureHeaders(for: &request, key: key)

        var requestBody: [String: Any]
        if selectedProvider == .googleGemini {
            let structuredSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "subject_box_2d": [
                        "type": "array",
                        "items": ["type": "number"],
                        "description": "Exact 2D bounding box of the primary hero subject in [ymin, xmin, ymax, xmax] normalized to 0..1000"
                    ],
                    "subject_x": ["type": "number", "description": "Normalized hero subject anchor X [0.0..1.0] (eye/face for person/animal, focal center for object/scene)"],
                    "subject_y": ["type": "number", "description": "Normalized hero subject anchor Y [0.0..1.0] (eye/face for person/animal, focal center for object/scene)"],
                    "subject_w": ["type": "number", "description": "Normalized hero subject width [0.0..1.0]"],
                    "subject_h": ["type": "number", "description": "Normalized hero subject height [0.0..1.0]"],
                    "composition_x": ["type": "number", "description": "Desired artistic placement X of the hero subject in the final composed frame [0.0..1.0] (e.g. 0.382, 0.618, 0.333, 0.667, 0.500)"],
                    "composition_y": ["type": "number", "description": "Desired artistic placement Y of the hero subject in the final composed frame [0.0..1.0] (e.g. 0.382, 0.618, 0.333, 0.667, 0.500)"],
                    "shot_scale": ["type": "string", "description": "extreme_wide, wide, full_body, medium_portrait, close_up, macro"],
                    "suggested_zoom": ["type": "number", "description": "Optimal unconstrained continuous zoom multiplier from 0.5 to 6.0 decided 100% by AI"],
                    "target_x": ["type": "number", "description": "Optical aim point X [0.0..1.0]: subject_x - (composition_x - 0.5) / suggested_zoom"],
                    "target_y": ["type": "number", "description": "Optical aim point Y [0.0..1.0]: subject_y - (composition_y - 0.5) / suggested_zoom"],
                    "composition_rule": ["type": "string", "description": "golden_ratio, rule_of_thirds, center_symmetry, golden_spiral, leading_lines, negative_space, framing, diagonal"],
                    "scene_type": ["type": "string", "description": "portrait, landscape, street, macro, architecture, night, pet, food"],
                    "lighting_scene": ["type": "string", "description": "normal, backlit, golden_hour, night, high_contrast, overcast, indoor_warm"],
                    "recommended_ev_bias": ["type": "number", "description": "Recommended EV exposure bias [-2.0..2.0]"],
                    "recommended_preset": ["type": "string", "description": "Exact preset name selected from the 65+ available film presets catalog"],
                    "preset_explanation": ["type": "string", "description": "Vietnamese explanation of why this film preset matches the lighting and mood"],
                    "explanation": ["type": "string", "description": "Vietnamese Director of Photography explanation of subject, composition placement, and zoom choice"],
                    "color_recipe": [
                        "type": "object",
                        "properties": [
                            "exposure_ev": ["type": "number"],
                            "contrast": ["type": "number"],
                            "highlights": ["type": "number"],
                            "shadows": ["type": "number"],
                            "warmth": ["type": "number"],
                            "tint": ["type": "number"],
                            "saturation": ["type": "number"],
                            "vibrance": ["type": "number"],
                            "sharpness": ["type": "number"],
                            "vignette": ["type": "number"]
                        ],
                        "required": ["exposure_ev", "contrast", "highlights", "shadows", "warmth", "tint", "saturation"]
                    ]
                ],
                "propertyOrdering": [
                    "subject_box_2d", "subject_x", "subject_y", "subject_w", "subject_h",
                    "scene_type", "shot_scale", "composition_rule", "composition_x", "composition_y",
                    "suggested_zoom", "target_x", "target_y",
                    "lighting_scene", "recommended_ev_bias", "recommended_preset", "preset_explanation",
                    "color_recipe", "explanation"
                ],
                "required": [
                    "subject_box_2d", "subject_x", "subject_y", "subject_w", "subject_h",
                    "composition_x", "composition_y", "shot_scale", "suggested_zoom",
                    "target_x", "target_y", "composition_rule", "scene_type",
                    "lighting_scene", "recommended_ev_bias", "recommended_preset",
                    "preset_explanation", "explanation", "color_recipe"
                ]
            ]

            if useInteractions {
                requestBody = [
                    "model": modelID,
                    "input": [
                        [
                            "type": "image",
                            "mime_type": "image/jpeg",
                            "data": base64Image
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ],
                    "response_format": [
                        "type": "text",
                        "mime_type": "application/json",
                        "schema": structuredSchema
                    ]
                ]
            } else {
                requestBody = [
                    "contents": [
                        [
                            "parts": [
                                [
                                    "inlineData": [
                                        "mimeType": "image/jpeg",
                                        "data": base64Image
                                    ]
                                ],
                                [
                                    "text": prompt
                                ]
                            ]
                        ]
                    ],
                    "generationConfig": [
                        "responseMimeType": "application/json",
                        "responseSchema": structuredSchema,
                        "temperature": 0.20,
                        "topP": 0.90
                    ]
                ]
            }
        } else {
            requestBody = [
                "model": modelID,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": prompt
                            ],
                            [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:image/jpeg;base64,\(base64Image)"
                                ]
                            ]
                        ]
                    ]
                ],
                "temperature": 0.20,
                "top_p": 0.90,
                "max_tokens": 1000
            ]
            let lowerModel = modelID.lowercased()
            if (selectedProvider == .openAI || selectedProvider == .groq) &&
               (lowerModel.contains("gpt-") || lowerModel.contains("gemini-") || lowerModel.contains("o1") || lowerModel.contains("o3") || lowerModel.contains("o4") || lowerModel.contains("qwen")) {
                requestBody["response_format"] = ["type": "json_object"]
            }
            if selectedProvider == .openRouter {
                requestBody["reasoning"] = ["exclude": true]
            }
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
                // If an Interactions API call returned 404 or 400 on this endpoint/key, automatically retry the same model on standard generateContent before rotating!
                if useInteractions && (httpResponse.statusCode == 404 || httpResponse.statusCode == 400) {
                    self.executeModelCall(
                        modelID: modelID,
                        base64Image: base64Image,
                        prompt: prompt,
                        key: key,
                        startTime: startTime,
                        forceGenerateContent: true,
                        completion: completion
                    )
                    return
                }

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

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 1. Google Gemini Interactions API (steps -> model_output -> content -> text)
                if let steps = json["steps"] as? [[String: Any]] {
                    for step in steps {
                        if step["type"] as? String == "model_output",
                           let content = step["content"] as? [[String: Any]] {
                            for item in content {
                                if item["type"] as? String == "text", let text = item["text"] as? String, !text.isEmpty {
                                    responseText = text
                                    break
                                }
                            }
                        }
                    }
                }
                // 2. Google Gemini generateContent API (candidates -> content -> parts -> text)
                if responseText == nil, let candidates = json["candidates"] as? [[String: Any]],
                   let firstCand = candidates.first,
                   let content = firstCand["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    responseText = parts.compactMap { $0["text"] as? String }.joined()
                }
                // 3. OpenAI-compatible choices (OpenRouter, Groq, Pollinations, OpenAI, Anthropic, Custom)
                if responseText == nil, let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any] {
                    if let text = message["content"] as? String, !text.isEmpty {
                        responseText = text
                    } else if let contentArr = message["content"] as? [[String: Any]] {
                        responseText = contentArr.compactMap { $0["text"] as? String }.joined()
                    } else if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                        responseText = reasoning
                    }
                } else if responseText == nil, let content = json["content"] as? String, !content.isEmpty {
                    responseText = content
                } else if responseText == nil, let contentArr = json["content"] as? [[String: Any]] {
                    responseText = contentArr.compactMap { $0["text"] as? String }.joined()
                } else if responseText == nil, let text = json["text"] as? String, !text.isEmpty {
                    responseText = text
                }
            } else if let rawString = String(data: data, encoding: .utf8), !rawString.isEmpty {
                responseText = rawString
            }

            guard let text = responseText, !text.isEmpty else {
                CameraLogger.error("GeminiService: Không thể đọc content từ phản hồi của model \(modelID)", category: .ai)
                DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
                return
            }

            // Attempt 0: Direct Structured Output Codable decoding (Guaranteed 100% precision for Interactions API)
            if let textData = text.data(using: .utf8),
               let structured = try? JSONDecoder().decode(GeminiStructuredFramingOutput.self, from: textData) {
                let result = structured.toFramingResponse(modelUsed: modelID, latencyMs: latency)
                DispatchQueue.main.async {
                    self.lastLatencyMs = latency
                    self.lastModelUsed = modelID
                    self.lastExplanation = result.explanation
                    completion(.success(result))
                }
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

    public static func usesInteractionsEndpoint(for modelID: String) -> Bool {
        // Disabled: Google AI Studio API keys do not support /v1beta/interactions (hangs or times out).
        // All models use the universal, official, ultra-fast /v1beta/models/{model}:generateContent endpoint.
        return false
    }

    private func buildURL(for modelID: String, key: String, forceGenerateContent: Bool = false) -> URL? {
        var endpoint = activeEndpointURLString
        if selectedProvider == .googleGemini {
            let cleanModel = modelID.replacingOccurrences(of: "models/", with: "")
            let custom = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if custom.isEmpty {
                endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent"
            }
            if !key.isEmpty, var components = URLComponents(string: endpoint) {
                var queryItems = components.queryItems ?? []
                if !queryItems.contains(where: { $0.name == "key" }) {
                    queryItems.append(URLQueryItem(name: "key", value: key))
                }
                components.queryItems = queryItems
                return components.url
            }
        }
        return URL(string: endpoint)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                return msg
            }
            if let msg = json["message"] as? String {
                return msg
            }
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first {
            if let errorObj = first["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                return msg
            }
            if let msg = first["message"] as? String {
                return msg
            }
        }
        return nil
    }

    public static func hasUsableFraming(_ json: [String: Any]) -> Bool {
        var x = parseCGFloat(json["subject_x"], defaultVal: parseCGFloat(json["target_x"], defaultVal: .nan))
        var y = parseCGFloat(json["subject_y"], defaultVal: parseCGFloat(json["target_y"], defaultVal: .nan))

        if !x.isFinite || !y.isFinite {
            if let box = json["subject_box_2d"] as? [Any], box.count == 4 {
                let rawVals = box.map { parseCGFloat($0, defaultVal: 0) }
                let scale: CGFloat = (rawVals.max() ?? 0) > 1.5 ? 1000.0 : 1.0
                let ymin = rawVals[0] / scale
                let xmin = rawVals[1] / scale
                let ymax = rawVals[2] / scale
                let xmax = rawVals[3] / scale
                x = (xmin + xmax) * 0.5
                y = ymin + (ymax - ymin) * 0.38
            } else if let rect = json["sub_area_rect_norm"] as? [Any], rect.count == 4 {
                let rx = parseCGFloat(rect[0], defaultVal: 0)
                let ry = parseCGFloat(rect[1], defaultVal: 0)
                let rw = parseCGFloat(rect[2], defaultVal: 0)
                let rh = parseCGFloat(rect[3], defaultVal: 0)
                x = rx + rw / 2.0
                y = ry + rh / 2.0
            } else if let rect = json["SubAreaRectNorm"] as? [Any], rect.count == 4 {
                let rx = parseCGFloat(rect[0], defaultVal: 0)
                let ry = parseCGFloat(rect[1], defaultVal: 0)
                let rw = parseCGFloat(rect[2], defaultVal: 0)
                let rh = parseCGFloat(rect[3], defaultVal: 0)
                x = rx + rw / 2.0
                y = ry + rh / 2.0
            } else if let targetArr = json["target"] as? [Any], targetArr.count >= 2 {
                x = parseCGFloat(targetArr[0], defaultVal: .nan)
                y = parseCGFloat(targetArr[1], defaultVal: .nan)
            }
        }

        if x > 1.5 || y > 1.5 {
            x /= 1000.0
            y /= 1000.0
        }

        var zoom = parseCGFloat(json["suggested_zoom"], defaultVal: parseCGFloat(json["recommended_zoom"], defaultVal: parseCGFloat(json["zoom"], defaultVal: .nan)))
        if !zoom.isFinite, let focalMm = json["ExifFocalLength"] {
            let mm = parseCGFloat(focalMm, defaultVal: .nan)
            if mm.isFinite && mm > 0 {
                zoom = mm / 24.0
            }
        }
        if !zoom.isFinite && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) {
            zoom = 1.0
        }

        return x.isFinite && y.isFinite && zoom.isFinite &&
            (0...1).contains(x) && (0...1).contains(y) && (0.5...8.0).contains(zoom)
    }

    // MARK: - Self-Healing JSON Cleaner & Fallback Extractor

    private static let thinkTagRegex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>", options: [])
    private static let thoughtTagRegex = try? NSRegularExpression(pattern: "(?s)<thought>.*?</thought>", options: [])
    private static let jsonFenceRegex = try? NSRegularExpression(pattern: "(?s)```(?:json)?\\s*(\\{.*?\\})\\s*```", options: [])
    private static let trailingCommaRegex = try? NSRegularExpression(pattern: ",\\s*([}\\]])", options: [])

    public static func cleanAndParseJSON(from rawText: String) -> [String: Any]? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip reasoning/thinking tags (DeepSeek R1 / Qwen thinking / Kimi / Ollama)
        if let thinkRegex = thinkTagRegex {
            let range = NSRange(location: 0, length: text.utf16.count)
            text = thinkRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        if let thoughtRegex = thoughtTagRegex {
            let range = NSRange(location: 0, length: text.utf16.count)
            text = thoughtRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Search for ```json ... ``` or ``` ... ``` markdown code block first
        if let fenceRegex = jsonFenceRegex {
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = fenceRegex.firstMatch(in: text, options: [], range: range),
               let r = Range(match.range(at: 1), in: text) {
                let candidate = String(text[r])
                if let data = candidate.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
        }

        // 3. Strip markdown code fences if present
        if text.hasPrefix("```json") {
            text = String(text.dropFirst(7))
        } else if text.hasPrefix("```") {
            text = String(text.dropFirst(3))
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Locate outermost braces
        if let firstBrace = text.firstIndex(of: "{") {
            if let lastBrace = text.lastIndex(of: "}"), lastBrace >= firstBrace {
                text = String(text[firstBrace...lastBrace])
            } else {
                text = String(text[firstBrace...])
            }
        }

        // 5. Direct parse
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // 6. Trailing comma sanitation: e.g. `, }` or `, ]`
        var sanitized = text
        if let regex = trailingCommaRegex {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "$1")
            if let data = sanitized.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }

        // 7. Self-repair unclosed quotes and brackets if truncated by token limits
        var openBraces = 0
        var openBrackets = 0
        var inQuotes = false
        var isEscaped = false

        for char in sanitized {
            if isEscaped {
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes {
                if char == "{" { openBraces += 1 }
                else if char == "}" { openBraces = max(0, openBraces - 1) }
                else if char == "[" { openBrackets += 1 }
                else if char == "]" { openBrackets = max(0, openBrackets - 1) }
            }
        }

        if inQuotes {
            sanitized.append("\"")
        }
        while openBrackets > 0 {
            sanitized.append("]")
            openBrackets -= 1
        }
        while openBraces > 0 {
            sanitized.append("}")
            openBraces -= 1
        }

        if let data = sanitized.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // 8. Fallback to regex token extraction if JSON syntax is damaged
        if let fallback = regexExtractFallbackFraming(from: text, modelUsed: "self-repair", latencyMs: 0) {
            var dict: [String: Any] = [
                "subject_x": fallback.subjectX,
                "subject_y": fallback.subjectY,
                "composition_x": fallback.compositionAnchorX,
                "composition_y": fallback.compositionAnchorY,
                "target_x": fallback.targetX,
                "target_y": fallback.targetY,
                "suggested_zoom": fallback.suggestedZoom,
                "composition_rule": fallback.compositionRule.rawValue,
                "scene_type": fallback.sceneType.rawValue,
                "explanation": fallback.explanation,
                "recommended_preset": fallback.recommendedPreset.displayName,
                "preset_explanation": fallback.presetExplanation
            ]
            if let ev = fallback.recommendedEVBias {
                dict["recommended_ev_bias"] = ev
            }
            return dict
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

        guard let rawX = extractNumber(forKey: "target_x") ?? extractNumber(forKey: "subject_x"),
              let rawY = extractNumber(forKey: "target_y") ?? extractNumber(forKey: "subject_y"),
              let rawZoom = extractNumber(forKey: "suggested_zoom"),
              rawX.isFinite, rawY.isFinite, rawZoom.isFinite,
              (0...1).contains(rawX), (0...1).contains(rawY),
              (0.5...8.0).contains(rawZoom) else { return nil }
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

        let rawSubjX = extractNumber(forKey: "subject_x")
        let rawSubjY = extractNumber(forKey: "subject_y")
        let subjX = CGFloat(rawSubjX ?? Double(targetX))
        let subjY = CGFloat(rawSubjY ?? Double(targetY))
        let compX = CGFloat(extractNumber(forKey: "composition_x") ?? extractNumber(forKey: "composition_anchor_x") ?? 0.5)
        let compY = CGFloat(extractNumber(forKey: "composition_y") ?? extractNumber(forKey: "composition_anchor_y") ?? 0.5)
        let shotScale = extractString(forKey: "shot_scale") ?? "medium_portrait"
        var estSize: CGSize? = nil
        if let sw = extractNumber(forKey: "subject_w"), let sh = extractNumber(forKey: "subject_h"), sw > 0, sh > 0 {
            estSize = CGSize(width: CGFloat(sw), height: CGFloat(sh))
        }

        return GeminiFramingResponse(
            targetX: max(0.02, min(0.98, targetX)),
            targetY: max(0.02, min(0.98, targetY)),
            suggestedZoom: max(0.5, min(8.0, zoom)),
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: parseCompositionRule(compRuleStr),
            explanation: explanation,
            modelUsed: modelUsed,
            latencyMs: latencyMs,
            recommendedPreset: recPreset,
            presetExplanation: presetExpl,
            recommendedEVBias: Float(exp),
            lightingScene: nil,
            subjectX: subjX,
            subjectY: subjY,
            compositionAnchorX: compX,
            compositionAnchorY: compY,
            estimatedSubjectSize: estSize,
            shotScale: shotScale
        )
    }

    // MARK: - Prompt with Native 2D Spatial Grounding & 100% Autonomous DoP Decision

    private func buildPrompt(
        sceneContext: DetectedSceneType? = nil,
        colorMetrics: ImageColorMetrics? = nil,
        subjectRect: CGRect? = nil,
        faceRects: [CGRect] = []
    ) -> String {
        var telemetryParts: [String] = []
        if let m = colorMetrics {
            telemetryParts.append(String(format: "luma=%.2f, warmth=%.2f, tint=%.2f, contrast=%.2f (%@)", m.averageLuma, m.warmthCast, m.tintCast, m.contrastScore, m.lightingSummary))
        }
        if let scene = sceneContext {
            telemetryParts.append("sensor_scene_hint=\(scene.rawValue)")
        }
        if let rect = subjectRect, rect.width > 0.01, rect.height > 0.01 {
            telemetryParts.append(String(format: "sensor_subject_hint=[x:%.2f, y:%.2f, w:%.2f, h:%.2f]", rect.minX, rect.minY, rect.width, rect.height))
        }
        if let firstFace = faceRects.first, firstFace.width > 0.01, firstFace.height > 0.01 {
            telemetryParts.append(String(format: "sensor_face_hint=[x:%.2f, y:%.2f, w:%.2f, h:%.2f]", firstFace.minX, firstFace.minY, firstFace.width, firstFace.height))
        }
        let telemetry = telemetryParts.isEmpty ? "standard daylight" : telemetryParts.joined(separator: " | ")

        let presetsCatalog = """
        AVAILABLE FILM & COLOR PRESETS (Choose the single best match for the scene lighting, skin tone, and mood):
        - Fuji: Classic Chrome (muted documentary tone), Fuji Pro 400H (soft cool pastel greens, flattering skintones), Fuji Velvia 50 (ultra vivid landscape saturation), Classic Neg (nostalgic high-contrast street film), Astia 100F (soft portrait gradation), Neopan Acros (rich monochrome, fine grain)
        - Kodak: Kodak Portra 400 (warm golden skintones, smooth highlight rolloff), Kodak Gold 200 (warm summer amber warmth), Kodak ColorPlus (everyday warm vintage tint), Kodak Ektar 100 (ultra-fine grain, saturated blues & reds), Kodak Tri-X 400 (iconic gritty black & white journalism), Kodak 500D (cinematic movie film Vision3 latitude)
        - CCD Digicam: CCD1 (early 2000s Sony Cyber-shot punchy colors), D-CCD (warm flash party digicam), BlueSK (cool Nordic CCD daylight highlights), MangaCam (Japanese anime bright pastel tones), G-CCD (golden hour sunset glow), InstaLite (party flash direct high contrast)
        - Vintage Cam: 1998 (disposable 90s snapshot), LOMO LC-A (strong vignette, quirky saturation), 120LG (medium format dreamy blur), FXN 35 (sharp 70s rangefinder), Toy K (plastic toy camera charm), CineStill 800T (night street cine film with tungsten halation), 1998 Street (gritty 90s street snap), Cyanotype (historic Prussian blue monochrome)
        - Vintage Phone: Nokia Symbian (early Carl Zeiss N-series smartphone), Motorola V3 (Y2K Razr metallic warmth), iPhone 3GS (2009 soft analog-like phone aesthetic), Blackberry Q10 (cool corporate business tone), Keitai 88 (Japanese flip phone porcelain skin), Sony K800 (Cyber-shot phone natural crisp tone)
        - Ricoh: GR3 Positive (high contrast, vivid sky blues), GR Negative (street film negative, deep shadows), GR High-B&W (dramatic high-contrast black & white street), GR F (legendary 28mm street snapshot tone), GR Street (urban candid snapshot), Caplio R (raw early digicam), Theta Doc (documentary everyday warmth)
        - Canon: PowerShot G (prosumer CCD warm rosy skin), Canon IXUS (trendy Y2K pocket digicam), Canon EOS 5D (legendary 5D classic queen skin rendition), Canon SureShot (joyful family point-and-shoot 35mm), Canon F-1 (accurate professional mechanical SLR colors), Canon Pro1 (L-lens red-ring rich CCD tone)
        - DV Video: MiniDV 4:3 (2000s consumer camcorder video), Hi8 (90s analog home video tape warmth), DCR-DVD (early family DVD camcorder), DVX100 (24p indie cinema broadcast tone), VHS-C (warm 80s tape texture), HDV 1080i (early HD television broadcast)
        - Instant: POLA 600 (classic Polaroid 600 contrast), SX-70 (warm artistic buttery highlights), MINI 7 (Instax Mini bright glowing skin), WIDE 300 (natural wide format instant film), SQ10 (sharp hybrid instant contrast), Spectra (rich widescreen Polaroid depth)
        - Clean & Modern: Original Clean (neutral true-to-life maximum dynamic range), Studio Natural (soft balanced natural studio contrast), Teal & Orange (Hollywood cinematic complementary contrast), Sunset Glow (warm golden hour magic), Tokyo Clean (airy minimalist Japanese highlight glow), HK Cinema 90s (moody emerald green shadows and warm tungsten practicals), Leica Monochrom (pure silver grayscale gradation), Noir High Contrast (dramatic artistic shadows)
        - Trending: FUJI X (modern Fuji X-series film simulation), NOKIA (retro green matrix LCD aesthetic), 8800 (warm premium titanium metal contrast), Kambo (Japanese toy camera clarity), CPM35 (Canon 35mm everyday travel film), Bleach Bypass (desaturated silver retention high contrast film process)
        """

        return """
        You are an autonomous Academy-Award-Winning Director of Photography (DoP) and Spatial Vision Architect.
        Analyze the raw camera frame directly using your own visual intelligence. Sensor hints (\(telemetry)) are non-binding references only—you have 100% aesthetic authority to decide:
        1. HERO SUBJECT & 2D SPATIAL GROUNDING:
           - Identify the true hero subject or visual focal center of the story.
           - Output its exact 2D bounding box `subject_box_2d: [ymin, xmin, ymax, xmax]` in 0..1000 coordinates, normalized `subject_w, subject_h` in [0.04..0.98], and `subject_x, subject_y` in [0.0..1.0] (top-left is 0.0,0.0; bottom-right is 1.0,1.0).
           - For portraits/people/animals: anchor `(subject_x, subject_y)` on the dominant eye or upper-face focal point (inside `subject_box_2d`). For objects/food/architecture/landscapes: anchor on the primary structural focal point.
        2. 3D GAZE, LEAD ROOM & ARTISTIC COMPOSITION DESTINATION (`composition_x, composition_y`):
           - Evaluate the subject's 3D gaze/facing direction, movement vectors, body posture, horizon lines, leading lines, negative space, and framing elements.
           - Choose the optimal aesthetic composition rule:
             * golden_ratio (0.382 or 0.618)
             * rule_of_thirds (0.333 or 0.667)
             * center_symmetry (0.500)
             * golden_spiral
             * leading_lines
             * diagonal
             * frame_in_frame
             * negative_space
             * looking_room
           - Place `composition_x, composition_y` in [0.05..0.95] so the hero subject lands at this artistic anchor after framing. Ensure generous Lead Room in front of their gaze and ample headroom.
        3. UNCONSTRAINED CONTINUOUS OPTICAL ZOOM (`suggested_zoom`):
           - Choose any continuous float from `0.5` (ultra-wide) to `6.0` (telephoto), e.g. `0.6`, `0.8`, `1.0`, `1.25`, `1.5`, `1.8`, `2.2`, `2.8`, `3.5`, `4.5`.
           - Zoom in decisively when the hero subject is distant, small, or surrounded by edge clutter; use 1.0x or wide (< 1.0x) when grand architecture, interior depth, or vast landscape context is essential.
        4. COLOR HARMONY & EXPOSURE:
           - Select the single best `recommended_preset` from the catalog below matching scene mood and skin tones.
           - Provide `recommended_ev_bias` (-1.5 to +1.5) and a tailored `color_recipe`.
           (Note: Target aim point projection is calculated automatically by the camera's high-precision optical engine; you do not need to perform floating-point arithmetic).

        \(presetsCatalog)

        Return ONLY ONE valid JSON object (Vietnamese explanations, NO complex calculations needed):
        {"subject_box_2d":[210,340,680,620],"subject_x":0.48,"subject_y":0.36,"subject_w":0.28,"subject_h":0.47,"composition_x":0.382,"composition_y":0.382,"target_x":0.534,"target_y":0.348,"shot_scale":"medium_portrait","suggested_zoom":1.8,"recommended_ev_bias":0.0,"lighting_scene":"normal","scene_type":"portrait","composition_rule":"golden_ratio","recommended_preset":"Classic Chrome","preset_explanation":"Tôn da tự nhiên, giữ chi tiết vùng sáng và chiều sâu điện ảnh","explanation":"Khóa nét mắt chủ thể chính, mở khoảng thở Lead Room theo hướng nhìn về điểm mạnh Tỷ lệ vàng 0.382 với mức zoom 1.8x","color_recipe":{"exposure_ev":0.0,"contrast":1.04,"highlights":0.92,"shadows":0.04,"warmth":5500,"tint":0.0,"saturation":1.04,"vibrance":1.03,"sharpness":1.02,"vignette":0.02}}
        """
    }

    // MARK: - 100% Gemini-Driven Framing & Zoom Geometry (No Local Clamping or Overriding)
    public static func computeOptimalFramingGeometry(
        rawSubjectPoint: CGPoint,
        rawCompositionPoint: CGPoint?,
        rawTargetPoint: CGPoint,
        rawZoom: CGFloat,
        shotScale: String,
        compositionRule: CompositionRule,
        sensorSubjectRect: CGRect?,
        sensorFaceRects: [CGRect],
        aiEstimatedSize: CGSize?
    ) -> (subjectAnchor: CGPoint, compositionAnchor: CGPoint, cameraAimPoint: CGPoint, optimalZoom: CGFloat) {
        // 1. Giữ nguyên 100% tọa độ chủ thể do Gemini quyết định
        let sPoint = CGPoint(
            x: max(0.02, min(0.98, rawSubjectPoint.x.isFinite ? rawSubjectPoint.x : 0.5)),
            y: max(0.02, min(0.98, rawSubjectPoint.y.isFinite ? rawSubjectPoint.y : 0.5))
        )

        // 2. Giữ nguyên 100% điểm bố cục đích G do Gemini quyết định
        let gPoint: CGPoint
        if let comp = rawCompositionPoint,
           comp.x.isFinite, comp.y.isFinite,
           (0.05...0.95).contains(comp.x), (0.05...0.95).contains(comp.y) {
            gPoint = comp
        } else {
            gPoint = sPoint
        }

        // 3. Giữ nguyên 100% mức zoom liên tục (continuous zoom) do Gemini quyết định
        let finalZoom: CGFloat
        if rawZoom.isFinite && rawZoom >= 0.5 {
            finalZoom = max(0.5, min(8.0, (rawZoom * 100.0).rounded() / 100.0))
        } else {
            finalZoom = 1.0
        }

        // 4. Giải bài toán chiếu quang học chính xác C_aim = S - (G - 0.5) / Z:
        // Khi Gemini chỉ định điểm bố cục G, dùng công thức chiếu quang học chuẩn xác để khi người dùng đưa tâm màn hình (0.5, 0.5)
        // trùng vào Vòng vàng C_aim và zoom Z, chủ thể S luôn rơi đúng vào điểm nghệ thuật đích G:
        let effZ = max(0.5, finalZoom)
        let opticalAimX = sPoint.x - (gPoint.x - 0.5) / effZ
        let opticalAimY = sPoint.y - (gPoint.y - 0.5) / effZ

        var rawAimX: CGFloat = opticalAimX
        var rawAimY: CGFloat = opticalAimY
        if rawTargetPoint.x.isFinite && rawTargetPoint.y.isFinite {
            // Tôn trọng target AI tính toán nếu nằm trong khoảng dung sai quang học hợp lý (<= 0.05)
            if hypot(rawTargetPoint.x - opticalAimX, rawTargetPoint.y - opticalAimY) <= 0.05 {
                rawAimX = rawTargetPoint.x
                rawAimY = rawTargetPoint.y
            }
        }

        // 5. Bảo vệ Headroom khi zoom lớn (không để cắt đỉnh đầu chủ thể trừ khi chụp macro/extreme close-up)
        let scaleLower = shotScale.lowercased()
        let isTightMacroOrCloseUp = scaleLower.contains("macro") || scaleLower.contains("close")
        if !isTightMacroOrCloseUp, let size = aiEstimatedSize, size.height > 0.04, effZ > 1.05 {
            let estimatedTopY = max(0.01, sPoint.y - size.height * 0.38)
            let projectedTopInCrop = 0.5 + (estimatedTopY - rawAimY) * effZ
            if projectedTopInCrop < 0.04 {
                rawAimY = estimatedTopY - (0.04 - 0.5) / effZ
            }
        }

        let aimPoint = CGPoint(
            x: max(0.05, min(0.95, rawAimX)),
            y: max(0.05, min(0.95, rawAimY))
        )

        return (
            subjectAnchor: sPoint,
            compositionAnchor: gPoint,
            cameraAimPoint: aimPoint,
            optimalZoom: finalZoom
        )
    }

    public static func computeOptimalFramingGeometry(
        subjectPoint: CGPoint,
        compositionAnchor: CGPoint,
        currentZoom: CGFloat,
        suggestedZoom: CGFloat,
        shotScale: String,
        subjectSize: CGSize
    ) -> (cameraAimPoint: CGPoint, optimalZoom: CGFloat) {
        let res = computeOptimalFramingGeometry(
            rawSubjectPoint: subjectPoint,
            rawCompositionPoint: compositionAnchor,
            rawTargetPoint: subjectPoint,
            rawZoom: suggestedZoom,
            shotScale: shotScale,
            compositionRule: .goldenRatio,
            sensorSubjectRect: nil,
            sensorFaceRects: [],
            aiEstimatedSize: subjectSize
        )
        return (cameraAimPoint: res.cameraAimPoint, optimalZoom: res.optimalZoom)
    }

    // MARK: - Response Parsing

    public static func parseGeminiResponse(_ json: [String: Any], modelUsed: String, latencyMs: Int) -> GeminiFramingResponse {
        var boxCenterX: CGFloat = .nan
        var boxCenterY: CGFloat = .nan
        var boxWidth: CGFloat = .nan
        var boxHeight: CGFloat = .nan
        var boxMinX: CGFloat = .nan
        var boxMaxX: CGFloat = .nan
        var boxMinY: CGFloat = .nan
        var boxMaxY: CGFloat = .nan

        if let box = json["subject_box_2d"] as? [Any], box.count == 4 {
            let rawVals = box.map { parseCGFloat($0, defaultVal: .nan) }
            if rawVals.allSatisfy({ $0.isFinite }) {
                let scale: CGFloat = (rawVals.max() ?? 0) > 1.5 ? 1000.0 : 1.0
                let ymin = max(0.0, min(1.0, rawVals[0] / scale))
                let xmin = max(0.0, min(1.0, rawVals[1] / scale))
                let ymax = max(ymin, min(1.0, rawVals[2] / scale))
                let xmax = max(xmin, min(1.0, rawVals[3] / scale))
                boxMinX = xmin
                boxMaxX = xmax
                boxMinY = ymin
                boxMaxY = ymax
                boxWidth = max(0.04, xmax - xmin)
                boxHeight = max(0.04, ymax - ymin)
                boxCenterX = xmin + boxWidth * 0.5
                boxCenterY = ymin + boxHeight * 0.38
            }
        }

        var rawTargetX = parseCGFloat(json["target_x"], defaultVal: .nan)
        var rawTargetY = parseCGFloat(json["target_y"], defaultVal: .nan)
        if rawTargetX.isFinite && rawTargetY.isFinite && (rawTargetX > 1.5 || rawTargetY > 1.5) {
            rawTargetX /= 1000.0
            rawTargetY /= 1000.0
        }

        if !rawTargetX.isFinite || !rawTargetY.isFinite {
            if boxCenterX.isFinite && boxCenterY.isFinite {
                rawTargetX = boxCenterX
                rawTargetY = boxCenterY
            } else if let rect = json["sub_area_rect_norm"] as? [Any], rect.count == 4 {
                let rx = parseCGFloat(rect[0], defaultVal: 0)
                let ry = parseCGFloat(rect[1], defaultVal: 0)
                let rw = parseCGFloat(rect[2], defaultVal: 0)
                let rh = parseCGFloat(rect[3], defaultVal: 0)
                rawTargetX = rx + rw / 2.0
                rawTargetY = ry + rh / 2.0
            } else if let rect = json["SubAreaRectNorm"] as? [Any], rect.count == 4 {
                let rx = parseCGFloat(rect[0], defaultVal: 0)
                let ry = parseCGFloat(rect[1], defaultVal: 0)
                let rw = parseCGFloat(rect[2], defaultVal: 0)
                let rh = parseCGFloat(rect[3], defaultVal: 0)
                rawTargetX = rx + rw / 2.0
                rawTargetY = ry + rh / 2.0
            } else if let targetArr = json["target"] as? [Any], targetArr.count >= 2 {
                rawTargetX = parseCGFloat(targetArr[0], defaultVal: 0.5)
                rawTargetY = parseCGFloat(targetArr[1], defaultVal: 0.5)
            } else {
                rawTargetX = parseCGFloat(json["subject_x"], defaultVal: 0.5)
                rawTargetY = parseCGFloat(json["subject_y"], defaultVal: 0.5)
            }
        }
        var subjectX = parseCGFloat(json["subject_x"], defaultVal: boxCenterX.isFinite ? boxCenterX : rawTargetX)
        var subjectY = parseCGFloat(json["subject_y"], defaultVal: boxCenterY.isFinite ? boxCenterY : rawTargetY)
        if subjectX > 1.5 || subjectY > 1.5 {
            subjectX /= 1000.0
            subjectY /= 1000.0
        }
        // Nếu có subject_box_2d hợp lệ mà subject_x/y bị lệch ra ngoài khung bao chủ thể, neo lại vào trong subject_box_2d
        if boxCenterX.isFinite && boxCenterY.isFinite && boxMinX.isFinite && boxMaxX.isFinite && boxMinY.isFinite && boxMaxY.isFinite {
            let marginX = max(0.01, boxWidth * 0.08)
            let marginY = max(0.01, boxHeight * 0.08)
            if subjectX < boxMinX - marginX || subjectX > boxMaxX + marginX {
                subjectX = boxCenterX
            }
            if subjectY < boxMinY - marginY || subjectY > boxMaxY + marginY {
                subjectY = boxCenterY
            }
        }
        var compX = parseCGFloat(json["composition_x"], defaultVal: parseCGFloat(json["composition_anchor_x"], defaultVal: subjectX))
        var compY = parseCGFloat(json["composition_y"], defaultVal: parseCGFloat(json["composition_anchor_y"], defaultVal: subjectY))
        if compX > 1.5 || compY > 1.5 {
            compX /= 1000.0
            compY /= 1000.0
        }
        let shotScale = (json["shot_scale"] as? String) ?? "medium_portrait"

        var estSize: CGSize? = nil
        var sw = parseCGFloat(json["subject_w"], defaultVal: boxWidth)
        var sh = parseCGFloat(json["subject_h"], defaultVal: boxHeight)
        if sw > 1.5 || sh > 1.5 {
            sw /= 1000.0
            sh /= 1000.0
        }
        if sw.isFinite, sh.isFinite, sw > 0, sh > 0 {
            estSize = CGSize(width: max(0.04, min(0.98, sw)), height: max(0.04, min(0.98, sh)))
        }

        var suggestedZoom = parseCGFloat(json["suggested_zoom"], defaultVal: parseCGFloat(json["recommended_zoom"], defaultVal: parseCGFloat(json["zoom"], defaultVal: 1.0)))
        if let focalMm = json["ExifFocalLength"] {
            let mm = parseCGFloat(focalMm, defaultVal: .nan)
            if mm.isFinite && mm > 0 {
                suggestedZoom = mm / 24.0
            }
        }
        let explanation = (json["explanation"] as? String) ?? "AI phân tích bố cục hoàn tất"

        let sceneType = parseSceneType((json["scene_type"] as? String) ?? "general")
        let compositionRule = parseCompositionRule((json["composition_rule"] as? String) ?? "golden_ratio")

        var colorRecipe = GeminiColorRecipe.defaultRecipe
        if let colorJson = json["color_recipe"] as? [String: Any] {
            let gradeStr = (colorJson["color_grade"] as? String) ?? "softwarm"
            let grade = parseColorGrade(gradeStr)
            colorRecipe = GeminiColorRecipe(
                temperatureK: parseFloat(colorJson["temperature_k"] ?? colorJson["warmth"], defaultVal: 5500),
                saturation: clampF(colorJson["saturation"], 0.70, 1.40, 1.04),
                contrast: clampF(colorJson["contrast"], 0.85, 1.30, 1.04),
                shadowLift: clampF(colorJson["shadow_lift"] ?? colorJson["shadows"], 0.00, 0.25, 0.02),
                highlightRoll: clampF(colorJson["highlight_roll"] ?? colorJson["highlights"], 0.70, 1.00, 0.95),
                grain: clampF(colorJson["grain"], 0.00, 0.05, 0.00),
                vignette: clampF(colorJson["vignette"], 0.00, 0.35, 0.00),
                warmthShift: clampF(colorJson["warmth_shift"], -0.40, 0.40, 0.0),
                tintShift: clampF(colorJson["tint_shift"] ?? colorJson["tint"], -0.30, 0.30, 0.0),
                exposureBias: clampF(colorJson["exposure_bias"] ?? colorJson["exposure_ev"], -1.5, 1.5, 0.0),
                colorGrade: grade,
                diagnosis: (colorJson["diagnosis"] as? String) ?? "Đã cân chỉnh màu sắc thích ứng bối cảnh"
            )
        }

        let presetRaw = (json["recommended_film_preset"] as? String) ?? (json["recommended_preset"] as? String) ?? ""
        let recPreset = FilmPreset.match(from: presetRaw) ?? sceneType.recommendedFilter
        let presetExpl = (json["preset_explanation"] as? String) ?? "\(recPreset.displayName) — Tối ưu cho bối cảnh \(sceneType.localizedName)"

        let evRaw = (json["recommended_ev_bias"] as? NSNumber)?.floatValue ?? (json["ev_bias"] as? NSNumber)?.floatValue ?? (json["exposure_bias"] as? NSNumber)?.floatValue
        let lightingScene = (json["lighting_scene"] as? String) ?? (json["lighting"] as? String)

        let effZ = max(0.5, min(8.0, suggestedZoom))
        let derivedAimX = subjectX - (compX - 0.5) / effZ
        let derivedAimY = subjectY - (compY - 0.5) / effZ
        let finalTargetX = (rawTargetX.isFinite && abs(rawTargetX - derivedAimX) <= 0.05) ? rawTargetX : derivedAimX
        let finalTargetY = (rawTargetY.isFinite && abs(rawTargetY - derivedAimY) <= 0.05) ? rawTargetY : derivedAimY

        return GeminiFramingResponse(
            targetX: max(0.05, min(0.95, finalTargetX)),
            targetY: max(0.05, min(0.95, finalTargetY)),
            suggestedZoom: effZ,
            sceneType: sceneType,
            colorRecipe: colorRecipe,
            compositionRule: compositionRule,
            explanation: explanation,
            modelUsed: modelUsed,
            latencyMs: latencyMs,
            recommendedPreset: recPreset,
            presetExplanation: presetExpl,
            recommendedEVBias: evRaw ?? colorRecipe.exposureBias,
            lightingScene: lightingScene,
            subjectX: max(0.02, min(0.98, subjectX)),
            subjectY: max(0.02, min(0.98, subjectY)),
            compositionAnchorX: max(0.02, min(0.98, compX)),
            compositionAnchorY: max(0.02, min(0.98, compY)),
            estimatedSubjectSize: estSize,
            shotScale: shotScale
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
            var clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.lowercased().hasSuffix("x") {
                clean = String(clean.dropLast()).trimmingCharacters(in: .whitespaces)
            } else if clean.lowercased().hasSuffix("mm") {
                if let mm = Double(clean.dropLast(2).trimmingCharacters(in: .whitespaces)) {
                    clean = String(mm / 26.0)
                }
            }
            parsed = Double(clean)
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
        return CompositionRule.match(from: s)
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
