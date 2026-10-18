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
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                #if DEBUG
                print("[SYSTEM] FileHandle error: \(error.localizedDescription)")
                #endif
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
        for url in [logFileURL, crashLogFileURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { os_log("Cannot clear log: %{public}@", log: aiLog, type: .error, error.localizedDescription) }
        }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let checkpoint = directory.appendingPathComponent("last_ai_stage.txt")
            if FileManager.default.fileExists(atPath: checkpoint.path) {
                do { try FileManager.default.removeItem(at: checkpoint) }
                catch { os_log("Cannot clear AI checkpoint: %{public}@", log: aiLog, type: .error, error.localizedDescription) }
            }
        }
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
                do {
                    let handle = try FileHandle(forWritingTo: debugURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
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
        let revision = Bundle.main.object(forInfoDictionaryKey: "AIFramingBuildRevision") as? String ?? "development"
        CameraLogger.info("App build revision: \(revision)", category: .general)
        if let stage = lastInferenceCheckpoint {
            CameraLogger.info("Previous persisted AI checkpoint (not a crash diagnosis): \(stage)", category: .ai)
        }
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
        let stage = lastInferenceCheckpoint
        // Also flush pending writes before the share sheet reads the log.
        logQueue.sync {
            if let stage { appendToFile("Last persisted AI checkpoint (not a crash diagnosis): " + stage) }
        }
        return logFileURL
    }

    private static var lastInferenceCheckpoint: String? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = directory.appendingPathComponent("last_ai_stage.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch {
            os_log("Cannot read persisted AI checkpoint: %{public}@", log: aiLog, type: .error, error.localizedDescription)
            return nil
        }
    }

    public static func readRecentLogText(maxChars: Int = 1500) -> String {
        guard let url = logFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return "(Chua co log nao duoc ghi lai trong phien nay)"
        }
        let content: String
        do { content = try String(contentsOf: url, encoding: .utf8) }
        catch {
            os_log("Cannot read debug log: %{public}@", log: aiLog, type: .error, error.localizedDescription)
            return "Không đọc được log: " + error.localizedDescription
        }
        let recent = content.count > maxChars ? String(content.suffix(maxChars)) : content
        return lastInferenceCheckpoint.map { recent + "\nLast persisted AI checkpoint: " + $0 } ?? recent
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
