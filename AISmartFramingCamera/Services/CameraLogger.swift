import Foundation
import os.log

/// Hệ thống ghi log chuẩn đoán chuyên dụng cho AlignAI Studio
/// Giúp theo dõi chi tiết từng mili-giây các tiến trình: Chụp ảnh, Lưu PhotoKit, Tracking Không gian 6DOF, AI Gemini
public enum CameraLogger {
    private static let subsystem = "com.aismartframing.camera"
    
    private static let logQueue = DispatchQueue(label: "com.aismartframing.logFileQueue")
    private static let maxLogFileSize: UInt64 = 2 * 1024 * 1024
    
    private static var logFileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("alignai_debug_log.txt")
    }
    
    private static func appendToFile(_ line: String) {
        guard let url = logFileURL else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: url.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > maxLogFileSize,
               let existing = try? String(contentsOf: url, encoding: .utf8) {
                let half = String(existing.suffix(existing.count / 2))
                try? half.data(using: .utf8)?.write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }
    
    public static func exportLogFileURL() -> URL? {
        return logFileURL
    }
    
    public static func readRecentLogText(maxChars: Int = 1500) -> String {
        guard let url = logFileURL, let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "(Chưa có log nào được ghi lại trong phiên này)"
        }
        return content.count > maxChars ? String(content.suffix(maxChars)) : content
    }
    
    private static let captureLog = OSLog(subsystem: subsystem, category: "Capture")
    private static let trackingLog = OSLog(subsystem: subsystem, category: "SpatialTracking")
    private static let photosLog = OSLog(subsystem: subsystem, category: "PhotoKit")
    private static let aiLog = OSLog(subsystem: subsystem, category: "AI_Engine")
    
    public enum Category: String {
        case capture = "\u{1f4f8} CAPTURE"
        case tracking = "\u{1f3af} TRACKING_6DOF"
        case photoKit = "\u{1f4be} PHOTOS"
        case ai = "\u{1f9e0} AI"
        case motion = "\u{1f9ed} MOTION"
        case general = "\u{2699}\u{fe0f} SYSTEM"
    }
    
    private static let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
    
    public static func info(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] ℹ\u{fe0f} \(message)")
        #endif
        
        switch category {
        case .capture: os_log("%{public}@", log: captureLog, type: .info, message)
        case .tracking: os_log("%{public}@", log: trackingLog, type: .info, message)
        case .photoKit: os_log("%{public}@", log: photosLog, type: .info, message)
        case .ai: os_log("%{public}@", log: aiLog, type: .info, message)
        case .motion: os_log("%{public}@", log: trackingLog, type: .info, message)
        case .general: os_log("%{public}@", log: .default, type: .info, message)
        }
        
        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] ℹ\u{fe0f} \(message)"
            appendToFile(formatted)
        }
    }
    
    public static func success(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] \u{2705} \(message)")
        #endif
        os_log("%{public}@", log: .default, type: .default, message)
        
        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] \u{2705} \(message)"
            appendToFile(formatted)
        }
    }
    
    public static func warning(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] \u{26a0}\u{fe0f} CẢNH BÁO: \(message)")
        #endif
        os_log("%{public}@", log: .default, type: .error, message)
        
        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] \u{26a0}\u{fe0f} CẢNH BÁO: \(message)"
            appendToFile(formatted)
        }
    }
    
    public static func error(_ message: String, error: Error? = nil, category: Category = .general) {
        let errDetail = error.map { " | Chi tiết: \($0.localizedDescription)" } ?? ""
        #if DEBUG
        print("[\(category.rawValue)] \u{274c} LỖI: \(message)\(errDetail)")
        #endif
        os_log("%{public}@", log: .default, type: .fault, "\(message)\(errDetail)")
        
        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] \u{274c} LỖI: \(message)\(errDetail)"
            appendToFile(formatted)
        }
    }
}
