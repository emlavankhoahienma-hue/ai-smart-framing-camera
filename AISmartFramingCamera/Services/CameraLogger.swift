import Foundation
import os.log

/// Hệ thống ghi log chuẩn đoán chuyên dụng cho AlignAI Studio
/// Giúp theo dõi chi tiết từng mili-giây các tiến trình: Chụp ảnh, Lưu PhotoKit, Tracking Không gian 6DOF, AI Gemini
public enum CameraLogger {
    private static let subsystem = "com.aismartframing.camera"
    
    private static let captureLog = OSLog(subsystem: subsystem, category: "Capture")
    private static let trackingLog = OSLog(subsystem: subsystem, category: "SpatialTracking")
    private static let photosLog = OSLog(subsystem: subsystem, category: "PhotoKit")
    private static let aiLog = OSLog(subsystem: subsystem, category: "AI_Engine")
    
    public enum Category: String {
        case capture = "📸 CAPTURE"
        case tracking = "🎯 TRACKING_6DOF"
        case photoKit = "💾 PHOTOS"
        case ai = "🧠 AI"
        case general = "⚙️ SYSTEM"
    }
    
    public static func info(_ message: String, category: Category = .general) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] [\(category.rawValue)] ℹ️ \(message)"
        print(formatted)
        
        switch category {
        case .capture: os_log("%{public}@", log: captureLog, type: .info, message)
        case .tracking: os_log("%{public}@", log: trackingLog, type: .info, message)
        case .photoKit: os_log("%{public}@", log: photosLog, type: .info, message)
        case .ai: os_log("%{public}@", log: aiLog, type: .info, message)
        case .general: os_log("%{public}@", log: .default, type: .info, message)
        }
    }
    
    public static func success(_ message: String, category: Category = .general) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] [\(category.rawValue)] ✅ \(message)"
        print(formatted)
        os_log("%{public}@", log: .default, type: .default, message)
    }
    
    public static func warning(_ message: String, category: Category = .general) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] [\(category.rawValue)] ⚠️ CẢNH BÁO: \(message)"
        print(formatted)
        os_log("%{public}@", log: .default, type: .error, message)
    }
    
    public static func error(_ message: String, error: Error? = nil, category: Category = .general) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let errDetail = error != nil ? " | Chi tiết: \(error!.localizedDescription)" : ""
        let formatted = "[\(timestamp)] [\(category.rawValue)] ❌ LỖI: \(message)\(errDetail)"
        print(formatted)
        os_log("%{public}@", log: .default, type: .fault, formatted)
    }
}
