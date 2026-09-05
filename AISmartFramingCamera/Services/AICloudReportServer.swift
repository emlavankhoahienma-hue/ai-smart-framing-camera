import Foundation
import Network
import UIKit

// MARK: - AI Cloud Session Report Model

public struct AICloudSessionReport: Codable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let timeFormatted: String
    public let deviceIP: String
    public let modelUsed: String
    public let latencyMs: Int
    public let sentPrompt: String
    public let rawAIResponseText: String
    public let fullImageBase64: String
    public let targetX: CGFloat
    public let targetY: CGFloat
    public let suggestedZoom: CGFloat
    public let sceneType: String
    public let compositionRule: String
    public let explanation: String
    public let colorRecipeSummary: String
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        deviceIP: String,
        modelUsed: String,
        latencyMs: Int,
        sentPrompt: String,
        rawAIResponseText: String,
        fullImageBase64: String,
        targetX: CGFloat,
        targetY: CGFloat,
        suggestedZoom: CGFloat,
        sceneType: String,
        compositionRule: String,
        explanation: String,
        colorRecipeSummary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss - dd/MM/yyyy"
        self.timeFormatted = df.string(from: timestamp)
        self.deviceIP = deviceIP
        self.modelUsed = modelUsed
        self.latencyMs = latencyMs
        self.sentPrompt = sentPrompt
        self.rawAIResponseText = rawAIResponseText
        self.fullImageBase64 = fullImageBase64
        self.targetX = targetX
        self.targetY = targetY
        self.suggestedZoom = suggestedZoom
        self.sceneType = sceneType
        self.compositionRule = compositionRule
        self.explanation = explanation
        self.colorRecipeSummary = colorRecipeSummary
    }
}

// MARK: - Local Wi-Fi Web Report Server

public final class AICloudReportServer: ObservableObject {
    public static let shared = AICloudReportServer()
    
    @Published public var isRunning: Bool = false
    @Published public var deviceIP: String = "127.0.0.1"
    @Published public var serverPort: UInt16 = 8080
    @Published public var latestReport: AICloudSessionReport?
    @Published public var reportHistory: [AICloudSessionReport] = []
    
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.alignai.report.server", qos: .utility)
    
    public var serverURLString: String {
        return "http://\(deviceIP):\(serverPort)"
    }
    
    private init() {
        refreshDeviceIP()
        startServer(port: 8080)
    }
    
    // MARK: - IP Address Detection
    
    public func refreshDeviceIP() {
        if let ip = getWiFiAddress() {
            DispatchQueue.main.async {
                self.deviceIP = ip
            }
        } else {
            DispatchQueue.main.async {
                self.deviceIP = "127.0.0.1"
            }
        }
    }
    
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        
        for ptr in sequence(first: firstAddr, by: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // Standard Wi-Fi interface on iOS
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                } else if address == nil && (name.hasPrefix("en") || name.hasPrefix("pdp_ip")) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    
    // MARK: - Start / Stop Server
    
    public func startServer(port: UInt16 = 8080) {
        guard !isRunning else { return }
        self.serverPort = port
        refreshDeviceIP()
        
        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: parameters, on: nwPort)
            
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.isRunning = true
                        CameraLogger.info("AICloudReportServer: Web Server dang chay tai \(self.serverURLString)", category: .general)
                    case .failed(let error):
                        self.isRunning = false
                        CameraLogger.error("AICloudReportServer: Khoi dong that bai", error: error, category: .general)
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                connection.start(queue: self.serverQueue)
                self.handleIncomingConnection(connection)
            }
            
            listener?.start(queue: serverQueue)
        } catch {
            CameraLogger.error("AICloudReportServer: Loi tao listener", error: error, category: .general)
        }
    }
    
    public func stopServer() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    // MARK: - Record AI Cloud Session
    
    public func recordSession(report: AICloudSessionReport) {
        DispatchQueue.main.async {
            self.latestReport = report
            self.reportHistory.insert(report, at: 0)
            if self.reportHistory.count > 20 {
                self.reportHistory.removeLast()
            }
        }
        _ = saveStandaloneHTMLReport(report: report)
    }
    
    // MARK: - HTTP Request Handling
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self = self, let data = content, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            let requestString = String(data: data, encoding: .utf8) ?? ""
            let firstLine = requestString.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count > 1 ? parts[1] : "/"
            
            self.routeRequest(path: path, connection: connection)
        }
    }
    
    private func routeRequest(path: String, connection: NWConnection) {
        if path == "/api/status" {
            let latestId = latestReport?.id ?? "none"
            let count = reportHistory.count
            let json = "{\"status\":\"ok\",\"latestId\":\"\(latestId)\",\"count\":\(count),\"ip\":\"\(deviceIP)\"}"
            sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "application/json", bodyData: json.data(using: .utf8) ?? Data())
        } else if path == "/api/latest" {
            if let report = latestReport, let data = try? JSONEncoder().encode(report) {
                sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "application/json", bodyData: data)
            } else {
                let empty = "{\"message\":\"Chua co phien chup AI nao\"}".data(using: .utf8) ?? Data()
                sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "application/json", bodyData: empty)
            }
        } else if path == "/image" {
            if let base64 = latestReport?.fullImageBase64, let imageData = Data(base64Encoded: base64) {
                sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "image/jpeg", bodyData: imageData)
            } else {
                sendHTTPResponse(connection: connection, statusCode: "404 Not Found", contentType: "text/plain", bodyData: "No Image".data(using: .utf8) ?? Data())
            }
        } else if path.hasPrefix("/download") {
            let html = generateHTMLDashboard(report: latestReport)
            let data = html.data(using: .utf8) ?? Data()
            sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "text/html; charset=utf-8", bodyData: data, customHeaders: [
                "Content-Disposition": "attachment; filename=\"AlignAI_Report_\(latestReport?.id.prefix(8) ?? "latest").html\""
            ])
        } else {
            // Default HTML Dashboard
            let html = generateHTMLDashboard(report: latestReport)
            let data = html.data(using: .utf8) ?? Data()
            sendHTTPResponse(connection: connection, statusCode: "200 OK", contentType: "text/html; charset=utf-8", bodyData: data)
        }
    }
    
    private func sendHTTPResponse(
        connection: NWConnection,
        statusCode: String,
        contentType: String,
        bodyData: Data,
        customHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(statusCode)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n"
        for (key, val) in customHeaders {
            header += "\(key): \(val)\r\n"
        }
        header += "\r\n"
        
        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    // MARK: - Save Standalone HTML to Documents (For AirDrop / Files)
    
    public func saveStandaloneHTMLReport(report: AICloudSessionReport) -> URL? {
        let html = generateHTMLDashboard(report: report)
        guard let data = html.data(using: .utf8) else { return nil }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let fileURL = docs?.appendingPathComponent("AlignAI_Latest_Report.html")
        if let fileURL = fileURL {
            try? data.write(to: fileURL, options: .atomic)
            return fileURL
        }
        return nil
    }
    
    // MARK: - High-Aesthetic HTML Generator
    
    public func generateHTMLDashboard(report: AICloudSessionReport?) -> String {
        let ip = deviceIP
        let port = serverPort
        let reportId = report?.id ?? "none"
        let timestamp = report?.timeFormatted ?? "Chưa có dữ liệu"
        let model = report?.modelUsed ?? "Gemini Vision"
        let latency = report != nil ? "\(report!.latencyMs) ms" : "--"
        let targetX = report != nil ? String(format: "%.4f", report!.targetX) : "--"
        let targetY = report != nil ? String(format: "%.4f", report!.targetY) : "--"
        let targetXPercent = report != nil ? String(format: "%.1f%%", report!.targetX * 100) : "50%"
        let targetYPercent = report != nil ? String(format: "%.1f%%", report!.targetY * 100) : "50%"
        let zoom = report != nil ? String(format: "%.1fx", report!.suggestedZoom) : "--"
        let scene = report?.sceneType ?? "Chưa xác định"
        let rule = report?.compositionRule ?? "Tự động"
        let explanation = report?.explanation ?? "Đang chờ bạn chụp bức ảnh đầu tiên trên iPhone để AI phân tích..."
        let color = report?.colorRecipeSummary ?? "Chuẩn tự nhiên"
        let rawResponse = report?.rawAIResponseText ?? "{\n  \"status\": \"waiting_for_first_shot\"\n}"
        let prompt = report?.sentPrompt ?? "Prompt hệ thống chuyên nghiệp cho Gemini Vision"
        let imageSrc = report != nil ? "data:image/jpeg;base64,\(report!.fullImageBase64)" : ""
        let hasImage = report != nil && !report!.fullImageBase64.isEmpty
        
        return """
        <!DOCTYPE html>
        <html lang="vi">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>AlignAI Studio — Báo Cáo AI Cloud Trực Tiếp</title>
            <style>
                :root {
                    --bg-main: #0a0e17;
                    --bg-card: rgba(18, 26, 43, 0.85);
                    --border: rgba(255, 255, 255, 0.1);
                    --accent-gold: #ffd166;
                    --accent-cyan: #06d6a0;
                    --accent-blue: #118ab2;
                    --text-primary: #f8f9fa;
                    --text-secondary: #94a3b8;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    background: var(--bg-main);
                    background-image: radial-gradient(circle at 50% 0%, rgba(17, 138, 178, 0.2) 0%, transparent 60%);
                    color: var(--text-primary);
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    padding: 24px 20px 60px;
                    line-height: 1.5;
                }
                .container { max-width: 1280px; margin: 0 auto; }
                header {
                    display: flex;
                    flex-wrap: wrap;
                    justify-content: space-between;
                    align-items: center;
                    padding-bottom: 20px;
                    margin-bottom: 24px;
                    border-bottom: 1px solid var(--border);
                    gap: 16px;
                }
                .logo-box { display: flex; align-items: center; gap: 12px; }
                .logo-icon {
                    width: 44px; height: 44px; border-radius: 12px;
                    background: linear-gradient(135deg, #ffd166, #ff7b00);
                    display: flex; align-items: center; justify-content: center;
                    font-size: 24px; font-weight: bold; color: #000;
                    box-shadow: 0 4px 16px rgba(255, 209, 102, 0.35);
                }
                .title h1 { font-size: 22px; font-weight: 800; letter-spacing: -0.5px; }
                .title p { font-size: 13px; color: var(--text-secondary); }
                .badges { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
                .badge {
                    padding: 6px 14px; border-radius: 20px; font-size: 12px; font-weight: 600;
                    background: rgba(255, 255, 255, 0.06); border: 1px solid var(--border);
                    display: inline-flex; align-items: center; gap: 6px;
                }
                .badge.live { background: rgba(6, 214, 160, 0.15); border-color: rgba(6, 214, 160, 0.4); color: var(--accent-cyan); }
                .badge.live::before {
                    content: ''; width: 8px; height: 8px; border-radius: 50%; background: var(--accent-cyan);
                    box-shadow: 0 0 10px var(--accent-cyan);
                    animation: pulse 1.5s infinite;
                }
                @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
                
                .grid { display: grid; grid-template-columns: 1.15fr 0.85fr; gap: 24px; }
                @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
                
                .card {
                    background: var(--bg-card);
                    border: 1px solid var(--border);
                    border-radius: 16px;
                    padding: 20px;
                    backdrop-filter: blur(16px);
                    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
                    margin-bottom: 20px;
                }
                .card-title {
                    font-size: 15px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;
                    color: var(--accent-gold); margin-bottom: 16px; display: flex; align-items: center; gap: 8px;
                }
                
                /* Image Preview Container */
                .image-container {
                    position: relative; border-radius: 12px; overflow: hidden;
                    background: #000; border: 1px solid var(--border);
                    display: flex; align-items: center; justify-content: center;
                    min-height: 420px;
                }
                .image-container img { width: 100%; height: auto; display: block; max-height: 700px; object-fit: contain; }
                .empty-image { padding: 60px 20px; text-align: center; color: var(--text-secondary); }
                
                /* Overlays */
                .grid-overlay {
                    position: absolute; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none;
                    display: grid; grid-template-columns: 1fr 1fr 1fr; grid-template-rows: 1fr 1fr 1fr;
                    border: 1px dashed rgba(255, 255, 255, 0.2);
                }
                .grid-cell { border: 0.5px dashed rgba(255, 255, 255, 0.15); }
                .target-point {
                    position: absolute; transform: translate(-50%, -50%);
                    width: 40px; height: 40px; border-radius: 50%;
                    border: 2px solid #ffd166;
                    box-shadow: 0 0 16px rgba(255, 209, 102, 0.8), inset 0 0 12px rgba(255, 209, 102, 0.4);
                    pointer-events: none; transition: all 0.3s ease;
                }
                .target-point::after {
                    content: ''; position: absolute; top: 50%; left: 50%;
                    width: 6px; height: 6px; border-radius: 50%; background: #ffd166;
                    transform: translate(-50%, -50%);
                }
                .target-label {
                    position: absolute; bottom: -24px; left: 50%; transform: translateX(-50%);
                    background: rgba(0, 0, 0, 0.8); color: #ffd166; padding: 2px 8px;
                    border-radius: 10px; font-size: 10px; font-weight: 700; white-space: nowrap;
                    border: 1px solid #ffd166;
                }
                
                /* Toolbar */
                .toolbar { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
                .btn {
                    background: rgba(255, 255, 255, 0.08); border: 1px solid var(--border);
                    color: #fff; padding: 8px 16px; border-radius: 8px; font-size: 13px; font-weight: 600;
                    cursor: pointer; display: inline-flex; align-items: center; gap: 6px; text-decoration: none;
                    transition: all 0.2s;
                }
                .btn:hover { background: rgba(255, 255, 255, 0.15); transform: translateY(-1px); }
                .btn.primary { background: linear-gradient(135deg, #ffd166, #ff9e00); color: #000; border: none; }
                
                /* Stats Grid */
                .stats-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 16px; }
                .stat-box {
                    background: rgba(255, 255, 255, 0.04); border: 1px solid var(--border);
                    padding: 12px 14px; border-radius: 10px;
                }
                .stat-label { font-size: 11px; text-transform: uppercase; color: var(--text-secondary); margin-bottom: 4px; }
                .stat-value { font-size: 16px; font-weight: 700; color: #fff; }
                .stat-value.gold { color: var(--accent-gold); }
                .stat-value.cyan { color: var(--accent-cyan); }
                
                /* Explanation Box */
                .explanation-box {
                    background: rgba(6, 214, 160, 0.06); border-left: 4px solid var(--accent-cyan);
                    padding: 14px 16px; border-radius: 0 10px 10px 0; margin-bottom: 16px;
                    font-size: 14px; line-height: 1.6;
                }
                
                /* Code / Pre */
                pre {
                    background: #050811; border: 1px solid rgba(255, 255, 255, 0.08);
                    padding: 14px; border-radius: 10px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
                    font-size: 12px; color: #cbd5e1; overflow-x: auto; max-height: 280px;
                }
                
                footer {
                    margin-top: 40px; text-align: center; font-size: 12px; color: var(--text-secondary);
                    border-top: 1px solid var(--border); padding-top: 20px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <div class="logo-box">
                        <div class="logo-icon">📸</div>
                        <div class="title">
                            <h1>AlignAI Studio — Báo Cáo AI Cloud</h1>
                            <p>Kết nối trực tiếp từ iPhone sang Máy tính qua mạng Wi-Fi nội bộ</p>
                        </div>
                    </div>
                    <div class="badges">
                        <div class="badge live">Web Live Sync</div>
                        <div class="badge">📱 IP iPhone: <strong>\(ip):\(port)</strong></div>
                        <div class="badge">⏰ \(timestamp)</div>
                        <div class="badge">🤖 \(model) (\(latency))</div>
                    </div>
                </header>
                
                <div class="grid">
                    <!-- Left: Full Image & Visual Target Overlay -->
                    <div>
                        <div class="card">
                            <div class="card-title">🖼️ Ảnh Full Gốc Đã Gửi Cho AI (Kèm Tọa Độ Target)</div>
                            <div class="image-container" id="imgContainer">
                                \(hasImage ? """
                                <img id="fullImage" src="\(imageSrc)" alt="Full AI Frame">
                                <div class="grid-overlay" id="gridOverlay">
                                    <div class="grid-cell"></div><div class="grid-cell"></div><div class="grid-cell"></div>
                                    <div class="grid-cell"></div><div class="grid-cell"></div><div class="grid-cell"></div>
                                    <div class="grid-cell"></div><div class="grid-cell"></div><div class="grid-cell"></div>
                                </div>
                                <div class="target-point" id="targetMarker" style="top: \(targetYPercent); left: \(targetXPercent);">
                                    <div class="target-label">AI Target (\(targetX), \(targetY))</div>
                                </div>
                                """ : """
                                <div class="empty-image">
                                    <div style="font-size: 40px; margin-bottom: 10px;">📸</div>
                                    <h3>Chưa có ảnh nào được gửi lên AI Cloud</h3>
                                    <p style="margin-top: 6px; font-size: 13px;">Hãy mở app trên iPhone, bật phân tích AI và hướng camera vào vật thể!</p>
                                </div>
                                """)
                            </div>
                            
                            \(hasImage ? """
                            <div class="toolbar">
                                <button class="btn" onclick="toggleOverlay()">📐 Bật/Tắt Lưới & Tâm Ngắm</button>
                                <a href="/image" target="_blank" class="btn">🔍 Xem Ảnh Gốc Kích Thước Lớn</a>
                                <a href="/download" class="btn primary">📥 Tải Báo Cáo HTML Này Về PC</a>
                            </div>
                            """ : "")
                        </div>
                        
                        <!-- AI Prompt & Input Data -->
                        <div class="card">
                            <div class="card-title">📤 Dữ Liệu & Prompt Đã Gửi Cho AI</div>
                            <pre><code>\(prompt)</code></pre>
                        </div>
                    </div>
                    
                    <!-- Right: Technical Stats, Explanation & Raw Response -->
                    <div>
                        <!-- Key Stats -->
                        <div class="card">
                            <div class="card-title">🎯 Thông Số AI Tính Toán</div>
                            <div class="stats-grid">
                                <div class="stat-box">
                                    <div class="stat-label">Tọa Độ Bố Cục (X, Y)</div>
                                    <div class="stat-value gold">X: \(targetX) | Y: \(targetY)</div>
                                </div>
                                <div class="stat-box">
                                    <div class="stat-label">Zoom Kiến Nghị</div>
                                    <div class="stat-value cyan">\(zoom)</div>
                                </div>
                                <div class="stat-box">
                                    <div class="stat-label">Quy Tắc Bố Cục</div>
                                    <div class="stat-value">\(rule)</div>
                                </div>
                                <div class="stat-box">
                                    <div class="stat-label">Thể Loại Cảnh</div>
                                    <div class="stat-value">\(scene)</div>
                                </div>
                            </div>
                            
                            <div class="stat-box" style="margin-bottom: 16px;">
                                <div class="stat-label">Công Thức Màu AI Đề Xuất</div>
                                <div class="stat-value" style="font-size: 13px; font-weight: normal; color: #cbd5e1;">\(color)</div>
                            </div>
                            
                            <div class="card-title" style="margin-top: 20px;">💬 Lời Nhận Xét Của AI (Explanation)</div>
                            <div class="explanation-box">
                                \(explanation)
                            </div>
                        </div>
                        
                        <!-- Full Raw AI Response -->
                        <div class="card">
                            <div class="card-title" style="justify-content: space-between;">
                                <span>📜 Toàn Bộ Câu Trả Lời Gốc Từ AI</span>
                                <button class="btn" style="padding: 4px 10px; font-size: 11px;" onclick="copyRaw()">📋 Sao Chép</button>
                            </div>
                            <pre id="rawText"><code>\(rawResponse)</code></pre>
                        </div>
                    </div>
                </div>
                
                <footer>
                    <p>AlignAI Studio — Hệ thống Camera AI Nhiếp Ảnh Nghệ Thuật (Vibe Coding 100%)</p>
                    <p style="margin-top: 4px; opacity: 0.7;">Tác giả: VanKhoa (Trần Văn Trình) | Hotline: +84 344197212</p>
                </footer>
            </div>
            
            <script>
                let currentReportId = "\(reportId)";
                
                function toggleOverlay() {
                    const grid = document.getElementById('gridOverlay');
                    const marker = document.getElementById('targetMarker');
                    if (grid && marker) {
                        const isHidden = grid.style.display === 'none';
                        grid.style.display = isHidden ? 'grid' : 'none';
                        marker.style.display = isHidden ? 'block' : 'none';
                    }
                }
                
                function copyRaw() {
                    const text = document.getElementById('rawText').innerText;
                    navigator.clipboard.writeText(text).then(() => {
                        alert('Đã sao chép toàn bộ câu trả lời AI vào bộ nhớ tạm!');
                    });
                }
                
                // Live Polling: Tự động tải lại trang khi có phiên phân tích mới từ iPhone
                setInterval(() => {
                    fetch('/api/status')
                        .then(res => res.json())
                        .then(data => {
                            if (data.latestId && data.latestId !== 'none' && data.latestId !== currentReportId) {
                                console.log('Co phien chup moi, dang cap nhat trang...');
                                window.location.reload();
                            }
                        })
                        .catch(err => console.log('Chua ket noi duoc den iPhone:', err));
                }, 2000);
            </script>
        </body>
        </html>
        """
    }
}