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
    private let minFrameInterval: CFTimeInterval = 0.5 // Limit to 2 FPS to avoid flooding

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
            self.disconnectInternal()

            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                DispatchQueue.main.async {
                    self.connectionState = .error("API Key trống")
                }
                return
            }

            DispatchQueue.main.async {
                self.connectionState = .connecting
            }

            let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(trimmedKey)"
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
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.disconnectInternal()
        }
    }

    private func disconnectInternal() {
        isRunningReceiveLoop = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
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
                            "text": "Bạn là Giám đốc Nhiếp ảnh & Bố cục AI chuyên nghiệp (AI Cinematography Director). Hãy phân tích nhanh từng khung hình video theo thời gian thực, tự do quyết định 100% tọa độ mục tiêu (target_x, target_y trong [0..1]) và mức zoom phù hợp (suggested_zoom từ 0.5 đến 6.0) cùng lời nhắc ngắn gọn bằng tiếng Việt."
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
            } else {
                DispatchQueue.main.async {
                    self.connectionState = .connected
                }
            }
        }
    }

    // MARK: - Video Frame Streaming (realtimeInput.video)

    public func sendVideoFrame(_ cgImage: CGImage) {
        let now = CACurrentMediaTime()
        guard now - lastFrameSentTime >= minFrameInterval else { return }
        lastFrameSentTime = now

        queue.async { [weak self] in
            guard let self = self, self.connectionState == .connected else { return }

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

            let sendTime = CACurrentMediaTime()
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
                DispatchQueue.main.async {
                    self.connectionState = .error("Mất kết nối Live: \(error.localizedDescription)")
                }
                self.isRunningReceiveLoop = false
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
