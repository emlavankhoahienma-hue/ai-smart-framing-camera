import Foundation
import CoreGraphics
import UIKit
import QuartzCore
import Combine

// MARK: - Gemini Live API Real-Time WebSocket Service (2026 Low-Latency Architecture)
/// Provides bidirectional, low-latency streaming of video frames and text feedback with Gemini 3.8 Live.
/// Complies with official Google Gemini Live API specifications.
public final class GeminiLiveService: ObservableObject, @unchecked Sendable {
    public static let shared = GeminiLiveService()

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case error(String)
    }

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var latestLiveGuidance: String = ""
    @Published public private(set) var liveLatencyMs: Int = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.alignai.geminiLiveQueue", qos: .userInitiated)
    private var isRunningReceiveLoop = false
    private var lastFrameSentTime: CFTimeInterval = 0
    private var lastFrameLumaHash: [UInt8] = []

    // Motion-adaptive dynamic frame interval
    private var currentAdaptiveInterval: CFTimeInterval = 0.35
    private let fastMotionInterval: CFTimeInterval = 0.25  // 4 FPS for panning / moving scenes
    private let staticMotionInterval: CFTimeInterval = 1.80 // 0.55 FPS for static scene to conserve bandwidth

    // Session auto-recovery state
    private var activeApiKey: String?
    private var activeModel: String?
    private var isExplicitDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    public var onLiveGuidanceReceived: ((String) -> Void)?
    public var onLiveFramingReceived: ((CGPoint, CGFloat, String) -> Void)?

    public static let supportedLiveModels: [String] = [
        "gemini-3.8-live",
        "gemini-3.8-live-extended-thinking"
    ]

    public static func normalizeLiveModelID(_ rawModel: String) -> String {
        let lower = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "models/", with: "")
        if lower == "gemini-3.8-live-extended-thinking" || lower.contains("extended-thinking") {
            return "gemini-3.8-live-extended-thinking"
        }
        return "gemini-3.8-live"
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 3600.0
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Connection Management

    public func connect(apiKey: String, model: String = "gemini-3.8-live") {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isExplicitDisconnect = false
            self.reconnectAttempts = 0
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.activeApiKey = trimmedKey
            self.activeModel = model
            self.connectInternal(apiKey: trimmedKey, model: model)
        }
    }

    private func connectInternal(apiKey: String, model: String) {
        disconnectInternal(keepRecoveryState: true)

        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.connectionState = .error("API Key trống")
            }
            return
        }

        DispatchQueue.main.async {
            self.connectionState = (self.reconnectAttempts > 0) ? .reconnecting(attempt: self.reconnectAttempts) : .connecting
        }

        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.connectionState = .error("URL WebSocket không hợp lệ")
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0

        let task = self.urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        self.sendInitialSetup(model: model)
        self.startReceiveLoop()
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isExplicitDisconnect = true
            self.reconnectAttempts = 0
            self.activeApiKey = nil
            self.activeModel = nil
            self.disconnectInternal(keepRecoveryState: false)
        }
    }

    private func disconnectInternal(keepRecoveryState: Bool = false) {
        isRunningReceiveLoop = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        if !keepRecoveryState {
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
        }
    }

    // MARK: - Automatic Session Recovery

    private func scheduleAutoReconnect() {
        guard !isExplicitDisconnect, let key = activeApiKey, !key.isEmpty else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            CameraLogger.error("GeminiLive: Đã thử kết nối lại \(maxReconnectAttempts) lần không thành công.", category: .ai)
            DispatchQueue.main.async {
                self.connectionState = .error("Mất kết nối Live sau \(self.maxReconnectAttempts) lần thử")
            }
            return
        }

        reconnectAttempts += 1
        let delay = min(8.0, 1.0 * pow(1.5, Double(reconnectAttempts)))
        CameraLogger.warning("GeminiLive: Kết nối gián đoạn. Tự động phục hồi lần \(reconnectAttempts)/\(maxReconnectAttempts) sau \(String(format: "%.1f", delay))s...", category: .ai)

        DispatchQueue.main.async {
            self.connectionState = .reconnecting(attempt: self.reconnectAttempts)
        }

        let model = activeModel ?? "gemini-3.8-live"
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isExplicitDisconnect else { return }
            let net = NetworkMonitor.shared.checkConnection()
            guard net.isConnected else {
                CameraLogger.warning("GeminiLive: Mạng chưa sẵn sàng, chờ kiểm tra lại...", category: .ai)
                self.scheduleAutoReconnect()
                return
            }
            self.connectInternal(apiKey: key, model: model)
        }
    }

    // MARK: - Initial Handshake (BidiGenerateContentSetup)

    private func sendInitialSetup(model: String) {
        let normalized = Self.normalizeLiveModelID(model)
        let cleanModel = normalized.hasPrefix("models/") ? normalized : "models/\(normalized)"
        let setupMessage: [String: Any] = [
            "setup": [
                "model": cleanModel,
                "generationConfig": [
                    "responseModalities": ["TEXT"],
                    "temperature": 0.35
                ],
                "systemInstruction": [
                    "parts": [
                        [
                            "text": "Bạn là Giám đốc Nhiếp ảnh & Bố cục AI chuyên nghiệp (AI Cinematography Director & DoP). Hãy phân tích nhanh từng khung hình video theo thời gian thực, tự do quyết định 100% tọa độ mục tiêu (target_x, target_y trong [0..1]), điểm bố cục đích (composition_x, composition_y) và mức zoom phù hợp (suggested_zoom từ 0.5 đến 6.0) cùng lời chỉ đạo ngắn gọn, súc tích bằng tiếng Việt."
                        ]
                    ]
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: setupMessage),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.connectionState = .error("Lỗi gửi Setup WebSocket: \(error.localizedDescription)")
                }
                self.scheduleAutoReconnect()
            } else {
                self.reconnectAttempts = 0
                DispatchQueue.main.async {
                    self.connectionState = .connected
                }
            }
        }
    }

    // MARK: - Video Frame Streaming with Adaptive Motion Throttling

    public func sendVideoFrame(_ cgImage: CGImage) {
        let now = CACurrentMediaTime()
        guard now - lastFrameSentTime >= currentAdaptiveInterval else { return }

        queue.async { [weak self] in
            guard let self = self, self.connectionState == .connected else { return }

            // Đánh giá mức độ biến đổi của khung cảnh để tự động điều tiết tốc độ gửi frame
            let motionScore = self.computeMotionScore(image: cgImage)
            if motionScore > 0.035 {
                // Khung cảnh đang lia máy hoặc chủ thể chuyển động -> Gửi nhanh hơn (4 FPS)
                self.currentAdaptiveInterval = self.fastMotionInterval
            } else {
                // Khung cảnh tĩnh -> Giãn tần số gửi để tiết kiệm băng thông (0.55 FPS)
                self.currentAdaptiveInterval = self.staticMotionInterval
            }

            guard let jpegData = self.compressFrameForLiveStreaming(cgImage) else { return }
            let base64String = jpegData.base64EncodedString()

            let frameMessage: [String: Any] = [
                "realtimeInput": [
                    "video": [
                        "data": base64String,
                        "mimeType": "image/jpeg"
                    ]
                ]
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: frameMessage),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            self.lastFrameSentTime = CACurrentMediaTime()
            let sendTime = self.lastFrameSentTime
            self.webSocketTask?.send(.string(jsonString)) { [weak self] error in
                if let error = error {
                    CameraLogger.warning("GeminiLive: Lỗi gửi frame: \(error.localizedDescription)", category: .ai)
                } else {
                    let lat = Int((CACurrentMediaTime() - sendTime) * 1000)
                    DispatchQueue.main.async {
                        self?.liveLatencyMs = lat
                    }
                }
            }
        }
    }

    /// Tính toán nhanh độ biến đổi luma giữa 2 khung hình liên tiếp để phát hiện chuyển động máy/chủ thể
    private func computeMotionScore(image: CGImage) -> Double {
        let sampleSize = 16
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var currentBytes = [UInt8](repeating: 0, count: sampleSize * sampleSize)
        guard let ctx = CGContext(
            data: &currentBytes,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 1.0 }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        if lastFrameLumaHash.isEmpty {
            lastFrameLumaHash = currentBytes
            return 1.0
        }

        var totalDiff: Double = 0
        let count = Double(currentBytes.count)
        for i in 0..<currentBytes.count {
            totalDiff += abs(Double(currentBytes[i]) - Double(lastFrameLumaHash[i]))
        }
        lastFrameLumaHash = currentBytes
        let avgDiff = (totalDiff / count) / 255.0
        return avgDiff
    }

    private func compressFrameForLiveStreaming(_ image: CGImage) -> Data? {
        let maxDim: CGFloat = 512.0
        let origW = CGFloat(image.width)
        let origH = CGFloat(image.height)
        let maxOrig = max(origW, origH)

        let targetW: Int
        let targetH: Int
        if maxOrig > maxDim {
            let scale = maxDim / maxOrig
            targetW = max(1, Int(origW * scale))
            targetH = max(1, Int(origH * scale))
        } else {
            targetW = Int(origW)
            targetH = Int(origH)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let scaledCG = ctx.makeImage() else { return nil }
        let uiImage = UIImage(cgImage: scaledCG)
        return uiImage.jpegData(compressionQuality: 0.50)
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        isRunningReceiveLoop = true
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        guard isRunningReceiveLoop, let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self = self, self.isRunningReceiveLoop else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingJSON(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingJSON(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNextMessage()

            case .failure(let error):
                CameraLogger.warning("GeminiLive: Lỗi socket nhận thông điệp: \(error.localizedDescription)", category: .ai)
                self.isRunningReceiveLoop = false
                self.scheduleAutoReconnect()
            }
        }
    }

    private func handleIncomingJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var incomingText = ""

        // Gemini 3.8 Live serverContent parsing (modelTurn + outputTranscription)
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let t = part["text"] as? String {
                        incomingText += t
                    }
                }
            }
            if incomingText.isEmpty,
               let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let transText = outputTranscription["text"] as? String {
                incomingText = transText
            }
        }

        if !incomingText.isEmpty {
            let parsedObj = GeminiService.cleanAndParseJSON(from: incomingText)
            var extractedTarget: CGPoint?
            var extractedZoom: CGFloat?
            var cleanGuidance = incomingText
            if let obj = parsedObj, GeminiService.hasUsableFraming(obj) {
                let framed = GeminiService.parseGeminiResponse(obj, modelUsed: "gemini-3.8-live", latencyMs: liveLatencyMs)
                extractedTarget = CGPoint(x: framed.targetX, y: framed.targetY)
                extractedZoom = framed.suggestedZoom
                cleanGuidance = framed.explanation
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.latestLiveGuidance = cleanGuidance
                self.onLiveGuidanceReceived?(cleanGuidance)
                if let pt = extractedTarget, let zm = extractedZoom {
                    self.onLiveFramingReceived?(pt, zm, cleanGuidance)
                }
            }
        }
    }
}
