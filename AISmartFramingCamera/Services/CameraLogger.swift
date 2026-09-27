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
    
    public static var crashLogFileURL: URL? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("alignai_crash_log.txt")
    }

    public static func exportCrashLogFileURL() -> URL? {
        return crashLogFileURL
    }

    public static func readRecentCrashReport() -> String? {
        guard let url = crashLogFileURL, FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else {
            return nil
        }
        return content
    }

    public static func clearAllLogs() {
        if let logUrl = logFileURL { try? FileManager.default.removeItem(at: logUrl) }
        if let crashUrl = crashLogFileURL { try? FileManager.default.removeItem(at: crashUrl) }
    }

    public static func handleUncaughtException(_ exception: NSException) {
        let reason = exception.reason ?? "Khong co ly do chi tiet"
        let name = exception.name.rawValue
        let backtrace = exception.callStackSymbols.joined(separator: "\n")
        let report = """
        =========================================
        ALIGNAI STUDIO CRASH REPORT (EXCEPTION)
        Time: \(ISO8601DateFormatter().string(from: Date()))
        Exception: \(name)
        Reason: \(reason)
        UserInfo: \(String(describing: exception.userInfo))
        Backtrace:
        \(backtrace)
        =========================================
        """
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let crashURL = dir.appendingPathComponent("alignai_crash_log.txt")
            try? report.data(using: .utf8)?.write(to: crashURL, options: .atomic)
            let debugURL = dir.appendingPathComponent("alignai_debug_log.txt")
            if let data = ("\n" + report + "\n").data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: debugURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: debugURL)
                }
            }
        }
    }

    public static func handleCrashSignal(_ sig: Int32) {
        let report = """
        =========================================
        ALIGNAI STUDIO CRASH REPORT (SIGNAL \(sig))
        Time: \(ISO8601DateFormatter().string(from: Date()))
        Backtrace:
        \(Thread.callStackSymbols.joined(separator: "\n"))
        =========================================
        """
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let crashURL = dir.appendingPathComponent("alignai_crash_log.txt")
            try? report.data(using: .utf8)?.write(to: crashURL, options: .atomic)
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    public static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            CameraLogger.handleUncaughtException(exception)
        }
        signal(SIGABRT) { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGSEGV) { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGBUS)  { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGILL)  { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGTRAP) { sig in CameraLogger.handleCrashSignal(sig) }
    }

    public static func exportLogFileURL() -> URL? {
        return logFileURL
    }

    public static func readRecentLogText(maxChars: Int = 1500) -> String {
        guard let url = logFileURL, let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "(Chua co log nao duoc ghi lai trong phien nay)"
        }
        return content.count > maxChars ? String(content.suffix(maxChars)) : content
    }

    private static let captureLog = OSLog(subsystem: subsystem, category: "Capture")
    private static let trackingLog = OSLog(subsystem: subsystem, category: "SpatialTracking")
    private static let photosLog = OSLog(subsystem: subsystem, category: "PhotoKit")
    private static let aiLog = OSLog(subsystem: subsystem, category: "AI_Engine")

    public enum Category: String {
        case capture = "[CAPTURE]"
        case tracking = "[TRACKING_6DOF]"
        case photoKit = "[PHOTOS]"
        case ai = "[AI]"
        case motion = "[MOTION]"
        case general = "[SYSTEM]"
    }

    private static let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    public static func info(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] INFO: \(message)")
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
            let formatted = "[\(timestamp)] [\(category.rawValue)] INFO: \(message)"
            appendToFile(formatted)
        }
    }

    public static func success(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] SUCCESS: \(message)")
        #endif
        os_log("%{public}@", log: .default, type: .default, message)

        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] SUCCESS: \(message)"
            appendToFile(formatted)
        }
    }

    public static func warning(_ message: String, category: Category = .general) {
        #if DEBUG
        print("[\(category.rawValue)] CANH BAO: \(message)")
        #endif
        os_log("%{public}@", log: .default, type: .error, message)

        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] CANH BAO: \(message)"
            appendToFile(formatted)
        }
    }

    public static func error(_ message: String, error: Error? = nil, category: Category = .general) {
        let errDetail = error.map { " | Chi tiet: \($0.localizedDescription)" } ?? ""
        #if DEBUG
        print("[\(category.rawValue)] LOI: \(message)\(errDetail)")
        #endif
        os_log("%{public}@", log: .default, type: .fault, "\(message)\(errDetail)")

        logQueue.async {
            let timestamp = dateFormatter.string(from: Date())
            let formatted = "[\(timestamp)] [\(category.rawValue)] LOI: \(message)\(errDetail)"
            appendToFile(formatted)
        }
    }
}
