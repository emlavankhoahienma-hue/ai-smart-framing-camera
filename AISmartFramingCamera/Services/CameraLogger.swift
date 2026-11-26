import Foundation
import os.log
import Darwin
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Hệ thống ghi log chẩn đoán vòng đời & chống văng app (Flush-per-line + POSIX Crash Handler + MetricKit + 1Hz RAM/Thermal).
/// Thiết kế chuyên biệt cho môi trường kiểm thử máy thật qua IPA sideload (không có Xcode debugger):
/// - Mỗi dòng log ghi đồng bộ (`write` + `fsync`) kèm tên thread, Mach TID, `phys_footprint` MB, `availMB` và `thermalState`.
/// - Tự động xoay vòng `alignai_session_current.log` -> `alignai_session_previous.log` mỗi lần mở app, phát hiện thoát bất thường / Jetsam OOM qua cờ `alignai_clean_exit.marker`.
/// - Đăng ký `NSSetUncaughtExceptionHandler`, POSIX signal handler an toàn bất đồng bộ (không cấp phát heap) và `MetricKit` (`MXDiagnosticPayload`).
public enum CameraLogger {
    private static let subsystem = "com.aismartframing.camera"
    private static let maxLogFileSize: UInt64 = 2 * 1024 * 1024
    private static let trimKeepBytes: Int = 1 * 1024 * 1024

    private static let fileLock = NSLock()
    private static var isBootstrapped = false
    private static var sessionFD: Int32 = -1
    private static var crashFD: Int32 = -1
    private static var cleanExitMarkerCPath = [CChar](repeating: 0, count: Int(PATH_MAX))

    private static var heartbeatTimer: DispatchSourceTimer?
    private static let heartbeatQueue = DispatchQueue(label: "com.alignai.diagnostics.heartbeat", qos: .utility)
    private static let peakLock = NSLock()
    private static var peakFootprintBytes: UInt64 = 0
    private static var activeSessionSummaryProvider: (@Sendable () -> String)?

    /// `true` nếu phiên trước kết thúc mà không đi qua `didEnterBackground` / `willTerminate` (ví dụ Jetsam OOM, SIGABRT, SIGSEGV, Watchdog).
    public private(set) static var didPreviousSessionExitUncleanly: Bool = false
    /// Tóm tắt chẩn đoán phiên trước để hiển thị ngay khi mở lại app sau khi văng.
    public private(set) static var previousSessionAbnormalSummary: String? = nil
    private static var didDismissAbnormalBannerThisLaunch: Bool = false

    #if canImport(UIKit)
    private static var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    public static let didReceiveDiagnosticNotification = Notification.Name("com.alignai.logger.didReceiveDiagnostic")

    // MARK: - File URLs

    private static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    public static var currentSessionLogURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_session_current.log")
    }

    public static var previousSessionLogURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_session_previous.log")
    }

    public static var crashLogFileURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_crash_log.txt")
    }

    public static var metricKitLogFileURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_metrickit_diagnostics.log")
    }

    private static var cleanExitMarkerURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_clean_exit.marker")
    }

    private static var legacyDebugLogURL: URL? {
        documentsDirectory?.appendingPathComponent("alignai_debug_log.txt")
    }

    // MARK: - Memory & Thread Telemetry

    /// Dung lượng bộ nhớ vật lý thực tế của tiến trình (`phys_footprint` tính bằng byte — đúng chỉ số iOS Jetsam dùng để kill app).
    public static func currentMemoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        let bytes = UInt64(info.phys_footprint)
        peakLock.lock()
        if bytes > peakFootprintBytes {
            peakFootprintBytes = bytes
        }
        peakLock.unlock()
        return bytes
    }

    public static func currentMemoryFootprintMB() -> Double {
        Double(currentMemoryFootprintBytes()) / (1024.0 * 1024.0)
    }

    public static func peakMemoryFootprintMB() -> Double {
        _ = currentMemoryFootprintBytes()
        peakLock.lock()
        let p = peakFootprintBytes
        peakLock.unlock()
        return Double(p) / (1024.0 * 1024.0)
    }

    public static func availableMemoryMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / (1024 * 1024))
        #else
        return -1
        #endif
    }

    public static func currentAvailableMemoryMB() -> Int {
        availableMemoryMB()
    }

    public static func thermalStateName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func currentThreadLabel() -> String {
        let tid = pthread_mach_thread_np(pthread_self())
        if Thread.isMainThread {
            return String(format: "main:0x%x", tid)
        }
        if let name = Thread.current.name, !name.isEmpty {
            return String(format: "%@:0x%x", name, tid)
        }
        let qPtr = __dispatch_queue_get_label(nil)
        let qName = String(cString: qPtr)
        if !qName.isEmpty {
            let short = qName.split(separator: ".").suffix(2).joined(separator: ".")
            return String(format: "%@:0x%x", short.isEmpty ? qName : short, tid)
        }
        return String(format: "bg:0x%x", tid)
    }

    private static func utcTimestampMillis() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var sec = tv.tv_sec
        var tmVal = tm()
        gmtime_r(&sec, &tmVal)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(tmVal.tm_year + 1900),
            Int(tmVal.tm_mon + 1),
            Int(tmVal.tm_mday),
            Int(tmVal.tm_hour),
            Int(tmVal.tm_min),
            Int(tmVal.tm_sec),
            Int(tv.tv_usec / 1000)
        )
    }

    // MARK: - Bootstrap, Rotation & Crash / MetricKit Registration

    public static func registerSessionStateProvider(_ provider: @escaping @Sendable () -> String) {
        fileLock.lock()
        activeSessionSummaryProvider = provider
        fileLock.unlock()
    }

    public static func shouldShowAbnormalExitBanner() -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        return didPreviousSessionExitUncleanly && !didDismissAbnormalBannerThisLaunch
    }

    public static func acknowledgeAbnormalExitBanner() {
        fileLock.lock()
        didDismissAbnormalBannerThisLaunch = true
        fileLock.unlock()
    }

    public static func installCrashHandlers() {
        bootstrapIfNeeded()

        NSSetUncaughtExceptionHandler { exception in
            CameraLogger.handleUncaughtException(exception)
        }
        signal(SIGABRT) { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGSEGV) { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGBUS)  { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGILL)  { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGTRAP) { sig in CameraLogger.handleCrashSignal(sig) }
        signal(SIGFPE)  { sig in CameraLogger.handleCrashSignal(sig) }

        #if canImport(MetricKit) && os(iOS)
        if #available(iOS 14.0, *) {
            CameraMetricKitSubscriber.shared.register()
        }
        #endif

        #if canImport(UIKit)
        installAppLifecycleObserversIfNeeded()
        startHeartbeatMonitor()
        #endif

        let prevState = didPreviousSessionExitUncleanly ? "UNCLEAN_EXIT_OR_CRASH" : "CLEAN"
        lifecycle(
            "APP_LAUNCH",
            detail: "prevSession=\(prevState) physRAM=\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))MB os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            category: .general
        )
    }

    private static func bootstrapIfNeeded() {
        fileLock.lock()
        if isBootstrapped {
            fileLock.unlock()
            return
        }
        isBootstrapped = true

        let fm = FileManager.default
        if let dir = documentsDirectory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if let markerURL = cleanExitMarkerURL {
            _ = markerURL.path.withCString { src in
                strncpy(&cleanExitMarkerCPath, src, Int(PATH_MAX - 1))
            }
        }

        let hadCurrentLog: Bool = {
            guard let cur = currentSessionLogURL, fm.fileExists(atPath: cur.path),
                  let attrs = try? fm.attributesOfItem(atPath: cur.path),
                  let size = attrs[.size] as? UInt64 else { return false }
            return size > 0
        }()
        let hadCleanMarker = cleanExitMarkerURL.map { fm.fileExists(atPath: $0.path) } ?? true

        // Rotate previous current log -> alignai_session_previous.log before truncating for new session
        if hadCurrentLog, let curURL = currentSessionLogURL, let prevURL = previousSessionLogURL {
            if let data = try? Data(contentsOf: curURL) {
                let tailData = data.count > 262_144 ? data.suffix(262_144) : data
                let statusBanner: String
                if !hadCleanMarker {
                    statusBanner = "=== [PHÁT HIỆN PHIÊN TRƯỚC BỊ VĂNG / JETSAM KILL (KHÔNG CÓ CLEAN-EXIT MARKER)] ===\n"
                } else {
                    statusBanner = "=== [PHIÊN TRƯỚC KẾT THÚC BÌNH THƯỜNG] ===\n"
                }
                var combined = Data(statusBanner.utf8)
                combined.append(tailData)
                try? combined.write(to: prevURL, options: .atomic)
            }
        }

        // Remove clean-exit marker while running active foreground session
        if let markerURL = cleanExitMarkerURL {
            try? fm.removeItem(at: markerURL)
        }

        if hadCurrentLog && !hadCleanMarker {
            didPreviousSessionExitUncleanly = true
            previousSessionAbnormalSummary = "Phiên trước bị văng hoặc bị iOS đóng cưỡng bức (Jetsam/Crash). Bấm để xem những dòng log cuối cùng ngay trước thời điểm văng."
        }

        if let curURL = currentSessionLogURL {
            sessionFD = Darwin.open(curURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if let crashURL = crashLogFileURL {
            crashFD = Darwin.open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        fileLock.unlock()
    }

    private static func markCleanExitOnDisk() {
        guard let markerURL = cleanExitMarkerURL else { return }
        let stamp = "clean_exit=\(utcTimestampMillis())\n"
        if let data = stamp.data(using: .utf8) {
            try? data.write(to: markerURL, options: .atomic)
        }
    }

    private static func clearCleanExitOnDisk() {
        guard let markerURL = cleanExitMarkerURL else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    #if canImport(UIKit)
    private static func installAppLifecycleObserversIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        let nc = NotificationCenter.default

        let memWarn = nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.warning(
                "MEMORY_WARNING nhận từ iOS! phys=\(String(format: "%.1f", currentMemoryFootprintMB()))MB avail=\(availableMemoryMB())MB peak=\(String(format: "%.1f", peakMemoryFootprintMB()))MB",
                category: .general
            )
        }

        let didBg = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.lifecycle("APP_DID_ENTER_BACKGROUND", category: .general)
            CameraLogger.stopHeartbeatMonitor()
            CameraLogger.markCleanExitOnDisk()
        }

        let willFg = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.clearCleanExitOnDisk()
            CameraLogger.lifecycle("APP_WILL_ENTER_FOREGROUND", category: .general)
            CameraLogger.startHeartbeatMonitor()
        }

        let didActive = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.clearCleanExitOnDisk()
            CameraLogger.lifecycle("APP_DID_BECOME_ACTIVE", category: .general)
            CameraLogger.startHeartbeatMonitor()
        }

        let willTerm = nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.lifecycle("APP_WILL_TERMINATE", category: .general)
            CameraLogger.stopHeartbeatMonitor()
            CameraLogger.markCleanExitOnDisk()
        }

        let thermalObs = nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.lifecycle("THERMAL_STATE_CHANGED", detail: "state=\(thermalStateName())", category: .general)
        }

        lifecycleObservers = [memWarn, didBg, willFg, didActive, willTerm, thermalObs]
    }
    #endif

    // MARK: - 1 Hz Memory & Thermal Heartbeat

    public static func startHeartbeatMonitor() {
        fileLock.lock()
        if heartbeatTimer != nil {
            fileLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(120))
        timer.setEventHandler {
            let provider = fileLock.withLock { activeSessionSummaryProvider }
            let stateText = provider?() ?? "ready"
            let phys = currentMemoryFootprintMB()
            let peak = peakMemoryFootprintMB()
            let avail = availableMemoryMB()
            let therm = thermalStateName()
            let msg = String(
                format: "HEARTBEAT phys=%.1fMB peak=%.1fMB avail=%dMB thermal=%@ %@",
                phys, peak, avail, therm, stateText
            )
            writeFormattedLine(level: "BEAT", category: .general, message: msg, mirrorToOSLog: false)
        }
        heartbeatTimer = timer
        fileLock.unlock()
        timer.resume()
    }

    public static func stopHeartbeatMonitor() {
        fileLock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        fileLock.unlock()
        timer?.cancel()
    }

    // MARK: - Synchronous Flush-Per-Line File Writer

    private static func writeAllBytes(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) {
        guard fd >= 0, count > 0 else { return }
        var written = 0
        while written < count {
            let n = Darwin.write(fd, ptr.advanced(by: written), count - written)
            if n <= 0 { break }
            written += n
        }
    }

    private static func writeFormattedLine(
        level: String,
        category: Category,
        message: String,
        mirrorToOSLog: Bool = true
    ) {
        bootstrapIfNeeded()
        let ts = utcTimestampMillis()
        let thr = currentThreadLabel()
        let phys = currentMemoryFootprintMB()
        let avail = availableMemoryMB()
        let therm = thermalStateName()
        let line = String(
            format: "[%@] [thr=%@] [mem=%.1fMB avail=%dMB therm=%@] %@ %@: %@\n",
            ts, thr, phys, avail, therm, category.rawValue, level, message
        )

        if mirrorToOSLog {
            #if DEBUG
            print(line, terminator: "")
            #endif
            switch category {
            case .capture: os_log("%{public}@", log: captureLog, type: .info, message)
            case .tracking, .motion: os_log("%{public}@", log: trackingLog, type: .info, message)
            case .photoKit: os_log("%{public}@", log: photosLog, type: .info, message)
            case .ai: os_log("%{public}@", log: aiLog, type: .info, message)
            case .general: os_log("%{public}@", log: .default, type: .info, message)
            }
        }

        fileLock.lock()
        defer { fileLock.unlock() }
        guard sessionFD >= 0 else { return }

        line.withUTF8 { utf8 in
            guard let base = utf8.baseAddress else { return }
            writeAllBytes(sessionFD, base, utf8.count)
        }
        _ = Darwin.fsync(sessionFD)

        // Bound current log size so multi-hour runs never bloat disk
        let pos = Darwin.lseek(sessionFD, 0, SEEK_END)
        if pos > off_t(maxLogFileSize), let curURL = currentSessionLogURL {
            Darwin.close(sessionFD)
            if let data = try? Data(contentsOf: curURL), data.count > trimKeepBytes {
                let kept = data.suffix(trimKeepBytes)
                try? kept.write(to: curURL, options: .atomic)
            }
            sessionFD = Darwin.open(curURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
    }

    // MARK: - Crash & Exception Handlers

    public static func handleUncaughtException(_ exception: NSException) {
        let reason = exception.reason ?? "Không có lý do chi tiết"
        let name = exception.name.rawValue
        let backtrace = exception.callStackSymbols.joined(separator: "\n")
        let report = """
        =========================================
        ALIGNAI STUDIO CRASH REPORT (NSException)
        Time: \(utcTimestampMillis())
        Thread: \(currentThreadLabel())
        Memory: phys=\(String(format: "%.1f", currentMemoryFootprintMB()))MB peak=\(String(format: "%.1f", peakMemoryFootprintMB()))MB avail=\(availableMemoryMB())MB thermal=\(thermalStateName())
        Exception: \(name)
        Reason: \(reason)
        UserInfo: \(String(describing: exception.userInfo))
        Backtrace:
        \(backtrace)
        =========================================

        """
        clearCleanExitOnDisk()
        fileLock.lock()
        report.withUTF8 { utf8 in
            guard let base = utf8.baseAddress else { return }
            if crashFD >= 0 {
                writeAllBytes(crashFD, base, utf8.count)
                _ = Darwin.fsync(crashFD)
            }
            if sessionFD >= 0 {
                writeAllBytes(sessionFD, base, utf8.count)
                _ = Darwin.fsync(sessionFD)
            }
        }
        fileLock.unlock()
    }

    /// Async-signal-safe POSIX crash handler: zero heap allocation, zero ObjC/Swift runtime locks.
    public static func handleCrashSignal(_ sig: Int32) {
        if cleanExitMarkerCPath[0] != 0 {
            _ = Darwin.unlink(&cleanExitMarkerCPath)
        }
        var buf: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0x0A, 0x3D, 0x3D, 0x3D, 0x20, 0x46, 0x41, 0x54, // \n=== FAT
            0x41, 0x4C, 0x20, 0x53, 0x49, 0x47, 0x4E, 0x41, // AL SIGNA
            0x4C, 0x20, 0x30, 0x30, 0x20, 0x3D, 0x3D, 0x3D, // L 00 ===
            0x0A, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        let s = max(0, min(99, Int(sig)))
        buf.18 = UInt8(0x30 + (s / 10))
        buf.19 = UInt8(0x30 + (s % 10))
        withUnsafePointer(to: &buf) { ptr in
            let raw = UnsafeRawPointer(ptr)
            if sessionFD >= 0 {
                _ = Darwin.write(sessionFD, raw, 25)
                _ = Darwin.fsync(sessionFD)
            }
            if crashFD >= 0 {
                _ = Darwin.write(crashFD, raw, 25)
                _ = Darwin.fsync(crashFD)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    fileprivate static func appendMetricKitDiagnostic(_ report: String) {
        fileLock.lock()
        didPreviousSessionExitUncleanly = true
        if previousSessionAbnormalSummary == nil {
            previousSessionAbnormalSummary = "MetricKit ghi nhận báo cáo Crash / Jetsam / CPU từ iOS cho phiên trước."
        }
        if let mkURL = metricKitLogFileURL, let data = report.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: mkURL.path),
               let fh = try? FileHandle(forWritingTo: mkURL) {
                try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            } else {
                try? data.write(to: mkURL, options: .atomic)
            }
        }
        if crashFD >= 0 {
            report.withUTF8 { utf8 in
                if let base = utf8.baseAddress {
                    writeAllBytes(crashFD, base, utf8.count)
                    _ = Darwin.fsync(crashFD)
                }
            }
        }
        fileLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didReceiveDiagnosticNotification, object: nil)
        }
    }

    // MARK: - Reading & Sharing Previous / Current Session Logs

    public static func exportLogFileURL() -> URL? {
        exportCombinedDiagnosticsFileURL() ?? currentSessionLogURL
    }

    public static func exportCrashLogFileURL() -> URL? {
        crashLogFileURL
    }

    public static func readRecentCrashReport() -> String? {
        var sections: [String] = []
        if let url = crashLogFileURL, FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(String(content.suffix(12_000)))
        }
        if let mkURL = metricKitLogFileURL, FileManager.default.fileExists(atPath: mkURL.path),
           let mkContent = try? String(contentsOf: mkURL, encoding: .utf8),
           !mkContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("--- METRICKIT DIAGNOSTICS ---\n" + String(mkContent.suffix(12_000)))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Đọc những dòng cuối của `alignai_session_previous.log` kèm báo cáo crash/MetricKit (nếu có).
    public static func readPreviousSessionLogTail(maxLines: Int = 140) -> String {
        var output: [String] = []
        if let crash = readRecentCrashReport() {
            output.append("=== BÁO CÁO CRASH / SIGNAL / METRICKIT ===\n" + crash)
        }
        if let prevURL = previousSessionLogURL,
           FileManager.default.fileExists(atPath: prevURL.path),
           let text = try? String(contentsOf: prevURL, encoding: .utf8),
           !text.isEmpty {
            let lines = text.components(separatedBy: .newlines)
            let tail = lines.suffix(max(20, maxLines)).joined(separator: "\n")
            output.append("=== DÒNG CUỐI LOG PHIÊN TRƯỚC (\(min(lines.count, maxLines))/\(lines.count) dòng) ===\n" + tail)
        } else {
            output.append("(Chưa có log phiên trước — đây là lần mở đầu tiên hoặc log đã được xóa)")
        }
        return output.joined(separator: "\n\n")
    }

    public static func readRecentLogText(maxChars: Int = 6000) -> String {
        guard let url = currentSessionLogURL, let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else {
            return "(Chưa có log nào được ghi trong phiên hiện tại)"
        }
        return content.count > maxChars ? String(content.suffix(maxChars)) : content
    }

    /// Đóng gói một file `.txt` đầy đủ (Thông tin máy + Crash/MetricKit + Log phiên trước + Log phiên hiện tại) để bấm nút Chia sẻ ngay trong App.
    public static func exportCombinedDiagnosticsFileURL() -> URL? {
        guard let dir = documentsDirectory else { return nil }
        let outURL = dir.appendingPathComponent("AlignAI_Previous_And_Current_Logs.txt")
        let header = """
        ====================================================
        ALIGNAI DIAGNOSTIC BUNDLE
        Exported: \(utcTimestampMillis())
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Physical RAM: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) MB
        Current Footprint: \(String(format: "%.1f", currentMemoryFootprintMB())) MB (Peak: \(String(format: "%.1f", peakMemoryFootprintMB())) MB)
        Available Headroom: \(availableMemoryMB()) MB
        Thermal State: \(thermalStateName())
        Previous Session Unclean Exit: \(didPreviousSessionExitUncleanly ? "YES" : "NO")
        ====================================================

        """
        let prevSection = readPreviousSessionLogTail(maxLines: 400)
        let currSection = "\n\n=== LOG PHIÊN HIỆN TẠI (CUỐI) ===\n" + readRecentLogText(maxChars: 48_000)
        let fullText = header + prevSection + currSection
        try? fullText.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }

    public static var hasPreviousSessionLog: Bool {
        if let prev = previousSessionLogURL, FileManager.default.fileExists(atPath: prev.path) {
            return true
        }
        return readRecentCrashReport() != nil
    }

    public static func readCurrentSessionLogTail(maxLines: Int = 180) -> String {
        guard let url = currentSessionLogURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return "(Chưa có log nào được ghi trong phiên hiện tại)"
        }
        let lines = text.components(separatedBy: .newlines)
        let tail = lines.suffix(max(20, maxLines)).joined(separator: "\n")
        return "=== DÒNG CUỐI LOG PHIÊN HIỆN TẠI (\(min(lines.count, maxLines))/\(lines.count) dòng) ===\n" + tail
    }

    public static func clearLogs() {
        clearAllLogs()
    }

    public static func clearAllLogs() {
        fileLock.lock()
        if sessionFD >= 0 { Darwin.close(sessionFD); sessionFD = -1 }
        if crashFD >= 0 { Darwin.close(crashFD); crashFD = -1 }
        if let cur = currentSessionLogURL { try? FileManager.default.removeItem(at: cur) }
        if let prev = previousSessionLogURL { try? FileManager.default.removeItem(at: prev) }
        if let crash = crashLogFileURL { try? FileManager.default.removeItem(at: crash) }
        if let mk = metricKitLogFileURL { try? FileManager.default.removeItem(at: mk) }
        if let legacy = legacyDebugLogURL { try? FileManager.default.removeItem(at: legacy) }
        didPreviousSessionExitUncleanly = false
        previousSessionAbnormalSummary = nil
        if let curURL = currentSessionLogURL {
            sessionFD = Darwin.open(curURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if let crashURL = crashLogFileURL {
            crashFD = Darwin.open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        fileLock.unlock()
        info("Đã xóa toàn bộ nhật ký phiên trước & hiện tại", category: .general)
    }

    // MARK: - Public Logging Entry Points

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

    public static func lifecycle(_ event: String, detail: String = "", category: Category = .general) {
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        writeFormattedLine(level: "LIFECYCLE", category: category, message: "\(event)\(suffix)")
    }

    public static func info(_ message: String, category: Category = .general) {
        writeFormattedLine(level: "INFO", category: category, message: message)
    }

    public static func success(_ message: String, category: Category = .general) {
        writeFormattedLine(level: "SUCCESS", category: category, message: message)
    }

    public static func warning(_ message: String, category: Category = .general) {
        writeFormattedLine(level: "WARN", category: category, message: message)
    }

    public static func error(_ message: String, error: Error? = nil, category: Category = .general) {
        let errDetail = error.map { " | Chi tiet: \($0.localizedDescription)" } ?? ""
        writeFormattedLine(level: "ERROR", category: category, message: "\(message)\(errDetail)")
    }
}

#if canImport(MetricKit) && os(iOS)
@available(iOS 14.0, *)
private final class CameraMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CameraMetricKitSubscriber()
    private var isRegistered = false

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let jsonData = payload.jsonRepresentation()
            let jsonText = String(data: jsonData, encoding: .utf8) ?? "(binary payload \(jsonData.count) bytes)"
            let header = """
            =========================================
            METRICKIT DIAGNOSTIC PAYLOAD (\(payload.timeStampBegin) -> \(payload.timeStampEnd))
            \(jsonText)
            =========================================

            """
            CameraLogger.appendMetricKitDiagnostic(header)
        }
    }
}
#endif
