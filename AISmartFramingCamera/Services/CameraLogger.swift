import Foundation
import os.log
import Darwin
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Hệ thống ghi log chẩn đoán pháp y (Forensic Flush-per-Line + Mach VM Breakdown + POSIX Backtrace +
/// Main-Thread Watchdog + Burst 4Hz Telemetry + Lưu trữ Crash không bị ghi đè + MetricKit).
/// Thiết kế chuyên biệt cho môi trường kiểm thử máy thật qua IPA sideload (không có Xcode debugger):
/// - Mỗi dòng log ghi đồng bộ (`write` + `fsync`) kèm tên thread, Mach TID, `phys_footprint` MB,
///   `internal` MB (heap bẩn CPU), `comp` MB, `ext` MB (IOSurface/GPU/ANE), `availMB` và `thermalState`.
/// - Ghi dấu `[ENTER]` / `[EXIT]` / `[STEP]` quanh từng bước nhỏ (Vision, từng model CoreML, Metal, Capture, Zoom)
///   và cập nhật buffer C cố định `lastCheckpointCString` để kể cả lúc dính POSIX signal hoặc Jetsam SIGKILL
///   vẫn xác định chính xác dòng/bước cuối cùng trước khi tiến trình chết.
/// - Tự động lưu bản sao bất biến vào `Documents/CrashLogs/crash_YYYYMMDD_HHMMSS.log` (hiện ngay trong app Tệp/Files)
///   để mở lại app nhiều lần không bao giờ bị ghi đè mất bằng chứng crash.
public enum CameraLogger {
    private static let subsystem = "com.aismartframing.camera"
    private static let maxLogFileSize: UInt64 = 4 * 1024 * 1024
    private static let trimKeepBytes: Int = 2 * 1024 * 1024
    private static let maxArchivedCrashFiles: Int = 10

    private static let fileLock = NSLock()
    private static var isBootstrapped = false
    private static var sessionFD: Int32 = -1
    private static var crashFD: Int32 = -1
    private static var cleanExitMarkerCPath = [CChar](repeating: 0, count: Int(PATH_MAX))

    // Fixed raw C buffer (never reallocated, zero Swift COW/ARC) updated on every trace/lifecycle event
    // so POSIX signal handlers can dump the exact last active step with zero heap/runtime locks.
    private static let checkpointLock = NSLock()
    private static let lastCheckpointRawBuf: UnsafeMutablePointer<UInt8> = {
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        ptr.initialize(repeating: 0, count: 256)
        return ptr
    }()
    private static var lastCheckpointLen: Int = 0

    private static var heartbeatTimer: DispatchSourceTimer?
    private static var heartbeatIntervalMs: Int = 1000
    private static let heartbeatQueue = DispatchQueue(label: "com.alignai.diagnostics.heartbeat", qos: .utility)

    private static var watchdogTimer: DispatchSourceTimer?
    private static let watchdogQueue = DispatchQueue(label: "com.alignai.diagnostics.watchdog", qos: .utility)
    private static let watchdogLock = NSLock()
    private static var watchdogLastAckUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private static var watchdogPingInFlight: Bool = false
    private static var watchdogLastLoggedBucket: Int = 0

    private static let peakLock = NSLock()
    private static var peakFootprintBytes: UInt64 = 0
    private static var minAvailableBytesObserved: UInt64 = UInt64.max
    private static var traceSeqCounter: UInt64 = 0
    private static var activeSessionSummaryProvider: (@Sendable () -> String)?
    private static var latestSessionStateSummary: String = "ready"

    /// `true` nếu phiên trước kết thúc mà không đi qua `didEnterBackground` / `willTerminate` (Jetsam OOM, SIGABRT, SIGSEGV, Watchdog).
    public private(set) static var didPreviousSessionExitUncleanly: Bool = false
    /// Tóm tắt chẩn đoán phiên trước để hiển thị ngay khi mở lại app sau khi văng.
    public private(set) static var previousSessionAbnormalSummary: String? = nil
    /// URL bản sao crash mới nhất trong `Documents/CrashLogs/` (không bị ghi đè khi mở lại app).
    public private(set) static var latestArchivedCrashLogURL: URL? = nil
    private static var didDismissAbnormalBannerThisLaunch: Bool = false

    #if canImport(UIKit)
    private static var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    public static let didReceiveDiagnosticNotification = Notification.Name("com.alignai.logger.didReceiveDiagnostic")

    public struct MemorySnapshot: Sendable {
        public let physMB: Double
        public let internalMB: Double
        public let compressedMB: Double
        public let externalMB: Double
        public let residentMB: Double
        public let peakMB: Double
        public let availMB: Int
    }

    public struct TraceToken: Sendable {
        public let seq: UInt64
        public let step: String
        public let category: Category
        public let startUptime: TimeInterval
        public let startPhysMB: Double
        public let startAvailMB: Int
    }

    // MARK: - File URLs

    private static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    public static var crashLogsDirectoryURL: URL? {
        documentsDirectory?.appendingPathComponent("CrashLogs", isDirectory: true)
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

    // MARK: - Detailed Memory & Thread Telemetry

    public static func currentMemorySnapshot() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        var physBytes: UInt64 = 0
        var intBytes: UInt64 = 0
        var compBytes: UInt64 = 0
        var extBytes: UInt64 = 0
        var resBytes: UInt64 = 0
        if kerr == KERN_SUCCESS {
            physBytes = UInt64(info.phys_footprint)
            intBytes = UInt64(info.internal)
            compBytes = UInt64(info.compressed)
            extBytes = UInt64(info.external)
            resBytes = UInt64(info.resident_size)
        }
        let availBytes: UInt64 = {
            #if os(iOS)
            return UInt64(os_proc_available_memory())
            #else
            return 0
            #endif
        }()
        peakLock.lock()
        if physBytes > peakFootprintBytes {
            peakFootprintBytes = physBytes
        }
        if availBytes > 0 && availBytes < minAvailableBytesObserved {
            minAvailableBytesObserved = availBytes
        }
        let peakBytes = peakFootprintBytes
        peakLock.unlock()
        let availMB = availBytes > 0 ? Int(availBytes / (1024 * 1024)) : -1
        return MemorySnapshot(
            physMB: Double(physBytes) / mb,
            internalMB: Double(intBytes) / mb,
            compressedMB: Double(compBytes) / mb,
            externalMB: Double(extBytes) / mb,
            residentMB: Double(resBytes) / mb,
            peakMB: Double(peakBytes) / mb,
            availMB: availMB
        )
    }

    /// Dung lượng bộ nhớ vật lý thực tế của tiến trình (`phys_footprint` tính bằng byte — đúng chỉ số iOS Jetsam dùng để kill app).
    public static func currentMemoryFootprintBytes() -> UInt64 {
        let snap = currentMemorySnapshot()
        return UInt64(max(0.0, snap.physMB) * 1024.0 * 1024.0)
    }

    public static func currentMemoryFootprintMB() -> Double {
        currentMemorySnapshot().physMB
    }

    public static func peakMemoryFootprintMB() -> Double {
        currentMemorySnapshot().peakMB
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
        case .nominal: return "nom"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "unk"
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

    private static func fileSafeTimestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var sec = tv.tv_sec
        var tmVal = tm()
        localtime_r(&sec, &tmVal)
        return String(
            format: "%04d%02d%02d_%02d%02d%02d",
            Int(tmVal.tm_year + 1900),
            Int(tmVal.tm_mon + 1),
            Int(tmVal.tm_mday),
            Int(tmVal.tm_hour),
            Int(tmVal.tm_min),
            Int(tmVal.tm_sec)
        )
    }

    private static func updateLastCheckpointBuffer(_ text: String) {
        let utf8 = Array(text.utf8.prefix(250))
        checkpointLock.lock()
        let count = utf8.count
        for i in 0..<count {
            lastCheckpointRawBuf[i] = utf8[i]
        }
        lastCheckpointRawBuf[count] = 0x0A // '\n'
        lastCheckpointLen = count + 1
        checkpointLock.unlock()
    }

    private static func currentLastCheckpointString() -> String {
        checkpointLock.lock()
        let len = max(0, min(250, lastCheckpointLen - 1))
        var bytes = [UInt8](repeating: 0, count: len)
        for i in 0..<len {
            bytes[i] = lastCheckpointRawBuf[i]
        }
        checkpointLock.unlock()
        return String(bytes: bytes, encoding: .utf8) ?? "none"
    }

    // MARK: - Forensic Micro-Step Trace API

    @discardableResult
    public static func beginTrace(_ step: String, detail: String = "", category: Category = .ai) -> TraceToken {
        let seq: UInt64 = peakLock.withLock {
            traceSeqCounter &+= 1
            return traceSeqCounter
        }
        let snap = currentMemorySnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        let payload = "[ENTER #\(seq)] \(step)\(suffix)"
        updateLastCheckpointBuffer(payload)
        writeFormattedLine(level: "TRACE", category: category, message: payload, snapshot: snap, mirrorToOSLog: false)
        return TraceToken(
            seq: seq,
            step: step,
            category: category,
            startUptime: now,
            startPhysMB: snap.physMB,
            startAvailMB: snap.availMB
        )
    }

    public static func endTrace(_ token: TraceToken, detail: String = "") {
        let snap = currentMemorySnapshot()
        let dtMs = max(0.0, (ProcessInfo.processInfo.systemUptime - token.startUptime) * 1000.0)
        let dPhys = snap.physMB - token.startPhysMB
        let dAvail = (token.startAvailMB >= 0 && snap.availMB >= 0) ? (snap.availMB - token.startAvailMB) : 0
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        let payload = String(
            format: "[EXIT #%llu] %@ | dt=%.0fms dPhys=%+.1fMB dAvail=%+dMB%@",
            token.seq, token.step, dtMs, dPhys, dAvail, suffix
        )
        updateLastCheckpointBuffer(payload)
        writeFormattedLine(level: "TRACE", category: token.category, message: payload, snapshot: snap, mirrorToOSLog: false)
    }

    public static func checkpoint(_ step: String, detail: String = "", category: Category = .ai) {
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        let payload = "[STEP] \(step)\(suffix)"
        updateLastCheckpointBuffer(payload)
        writeFormattedLine(level: "TRACE", category: category, message: payload, mirrorToOSLog: false)
    }

    // MARK: - Bootstrap, Rotation, Immutable Crash Archiving & Handlers

    public static func registerSessionStateProvider(_ provider: @escaping @Sendable () -> String) {
        fileLock.lock()
        activeSessionSummaryProvider = provider
        fileLock.unlock()
    }

    public static func updateSessionStateSummary(_ summary: String) {
        fileLock.lock()
        latestSessionStateSummary = summary
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
        startHeartbeatMonitor(intervalMs: 1000)
        startMainThreadWatchdog()
        #endif

        let prevState = didPreviousSessionExitUncleanly ? "UNCLEAN_EXIT_OR_CRASH" : "CLEAN"
        let buildVer = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        lifecycle(
            "APP_LAUNCH",
            detail: "ver=\(shortVer)(\(buildVer)) prevSession=\(prevState) physRAM=\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))MB os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
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
        if let crashDir = crashLogsDirectoryURL {
            try? fm.createDirectory(at: crashDir, withIntermediateDirectories: true)
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
                let tailData = data.count > 524_288 ? data.suffix(524_288) : data
                let statusBanner: String
                if !hadCleanMarker {
                    statusBanner = "=== [PHÁT HIỆN PHIÊN TRƯỚC BỊ VĂNG / JETSAM KILL (KHÔNG CÓ CLEAN-EXIT MARKER)] ===\n"
                } else {
                    statusBanner = "=== [PHIÊN TRƯỚC KẾT THÚC BÌNH THƯỜNG] ===\n"
                }
                var combined = Data(statusBanner.utf8)
                combined.append(tailData)
                try? combined.write(to: prevURL, options: .atomic)

                // Lưu bản sao bất biến vào Documents/CrashLogs/ nếu phiên trước thoát bất thường
                if !hadCleanMarker, let crashDir = crashLogsDirectoryURL {
                    let archiveURL = crashDir.appendingPathComponent("crash_\(fileSafeTimestamp()).log")
                    try? combined.write(to: archiveURL, options: .atomic)
                    latestArchivedCrashLogURL = archiveURL
                    pruneOldCrashArchivesLocked(in: crashDir)
                }
            }
        }

        // Remove clean-exit marker while running active foreground session
        if let markerURL = cleanExitMarkerURL {
            try? fm.removeItem(at: markerURL)
        }

        if hadCurrentLog && !hadCleanMarker {
            didPreviousSessionExitUncleanly = true
            previousSessionAbnormalSummary = extractCrashHeadlineLocked()
        }

        if let curURL = currentSessionLogURL {
            sessionFD = Darwin.open(curURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if let crashURL = crashLogFileURL {
            crashFD = Darwin.open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        fileLock.unlock()
    }

    private static func pruneOldCrashArchivesLocked(in dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = urls
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        if sorted.count > maxArchivedCrashFiles {
            for old in sorted.dropFirst(maxArchivedCrashFiles) {
                try? fm.removeItem(at: old)
            }
        }
    }

    public static func archivedCrashLogURLs() -> [URL] {
        guard let dir = crashLogsDirectoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// Phân tích tự động những dòng cuối của phiên vừa văng để hiển thị tóm tắt 1 dòng ngay trên màn hình Camera.
    private static func extractCrashHeadlineLocked() -> String {
        guard let prevURL = previousSessionLogURL,
              let text = try? String(contentsOf: prevURL, encoding: .utf8),
              !text.isEmpty else {
            return "Phiên trước bị văng (chưa có dữ liệu chi tiết). Bấm để xem log."
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = Array(lines.suffix(120))
        let signalLine = tail.last(where: { $0.contains("FATAL SIGNAL") || $0.contains("CRASH REPORT (NSException)") || $0.contains("MAIN_THREAD_STALL") })
        let memWarnLine = tail.last(where: { $0.contains("MEMORY_WARNING") })
        let lastStepLine = tail.last(where: { $0.contains("[ENTER") || $0.contains("[EXIT") || $0.contains("[STEP]") || $0.contains("LIFECYCLE:") })
        let lastAnyLine = tail.last ?? ""

        // Extract last mem=... avail=... snippet
        func extractBracketMem(_ line: String) -> String? {
            guard let r1 = line.range(of: "[mem="), let r2 = line.range(of: "]", range: r1.upperBound..<line.endIndex) else {
                return nil
            }
            return String(line[r1.lowerBound..<r2.upperBound])
        }
        let lastMemTag = tail.reversed().compactMap(extractBracketMem).first ?? ""

        let shortStep: String = {
            guard let s = lastStepLine ?? (lastAnyLine.isEmpty ? nil : lastAnyLine) else { return "không rõ" }
            if let r = s.range(of: "TRACE: ") { return String(s[r.upperBound...]).prefix(72).description }
            if let r = s.range(of: "LIFECYCLE: ") { return String(s[r.upperBound...]).prefix(72).description }
            return String(s.suffix(72))
        }()

        if let sig = signalLine {
            return "Dấu vết: \(sig.prefix(58)) · Bước cuối: \(shortStep) \(lastMemTag)"
        }
        if memWarnLine != nil {
            return "Cảnh báo RAM + nghi Jetsam kill · Bước cuối: \(shortStep) \(lastMemTag)"
        }
        return "Nghi Jetsam SIGKILL / đột tử · Bước cuối: \(shortStep) \(lastMemTag)"
    }

    public static func lastCrashHeadlineSummary() -> String {
        fileLock.lock()
        let summary = previousSessionAbnormalSummary
        fileLock.unlock()
        return summary ?? "Phiên trước kết thúc bình thường"
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
            let snap = currentMemorySnapshot()
            CameraLogger.warning(
                String(
                    format: "MEMORY_WARNING nhận từ iOS! phys=%.1fMB (int=%.1f comp=%.1f ext=%.1f) peak=%.1fMB avail=%dMB lastStep=%@",
                    snap.physMB, snap.internalMB, snap.compressedMB, snap.externalMB,
                    snap.peakMB, snap.availMB, currentLastCheckpointString()
                ),
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
            CameraLogger.stopMainThreadWatchdog()
            CameraLogger.markCleanExitOnDisk()
        }

        let willFg = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.clearCleanExitOnDisk()
            CameraLogger.lifecycle("APP_WILL_ENTER_FOREGROUND", category: .general)
            CameraLogger.startHeartbeatMonitor(intervalMs: 1000)
            CameraLogger.startMainThreadWatchdog()
        }

        let didActive = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.clearCleanExitOnDisk()
            CameraLogger.lifecycle("APP_DID_BECOME_ACTIVE", category: .general)
            CameraLogger.startHeartbeatMonitor(intervalMs: 1000)
            CameraLogger.startMainThreadWatchdog()
        }

        let willTerm = nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            CameraLogger.lifecycle("APP_WILL_TERMINATE", category: .general)
            CameraLogger.stopHeartbeatMonitor()
            CameraLogger.stopMainThreadWatchdog()
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

    // MARK: - Adaptive Heartbeat (1 Hz idle / 4 Hz burst during AI Compose & Capture)

    public static func setHighFrequencyTelemetry(_ active: Bool) {
        #if canImport(UIKit)
        let targetMs = active ? 250 : 1000
        let needsReschedule: Bool = fileLock.withLock {
            guard heartbeatTimer != nil else { return false }
            if heartbeatIntervalMs == targetMs { return false }
            heartbeatIntervalMs = targetMs
            return true
        }
        if needsReschedule {
            stopHeartbeatMonitor()
            startHeartbeatMonitor(intervalMs: targetMs)
        }
        #endif
    }

    public static func startHeartbeatMonitor(intervalMs: Int = 1000) {
        fileLock.lock()
        if heartbeatTimer != nil {
            fileLock.unlock()
            return
        }
        heartbeatIntervalMs = max(150, intervalMs)
        let interval = heartbeatIntervalMs
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval), leeway: .milliseconds(30))
        timer.setEventHandler {
            let (provider, cachedSummary) = fileLock.withLock { (activeSessionSummaryProvider, latestSessionStateSummary) }
            let stateText = provider?() ?? cachedSummary
            let snap = currentMemorySnapshot()
            let msg = String(
                format: "HEARTBEAT peak=%.1fMB %@ last=%@",
                snap.peakMB, stateText, currentLastCheckpointString()
            )
            writeFormattedLine(level: "BEAT", category: .general, message: msg, snapshot: snap, mirrorToOSLog: false)
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

    // MARK: - Main-Thread Stall / Deadlock Watchdog

    public static func startMainThreadWatchdog() {
        watchdogLock.lock()
        if watchdogTimer != nil {
            watchdogLock.unlock()
            return
        }
        watchdogLastAckUptime = ProcessInfo.processInfo.systemUptime
        watchdogPingInFlight = false
        watchdogLastLoggedBucket = 0
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            var shouldPing = false
            var stallSeconds: TimeInterval = 0
            var shouldEmitStall = false
            watchdogLock.lock()
            if !watchdogPingInFlight {
                watchdogPingInFlight = true
                shouldPing = true
            } else {
                stallSeconds = now - watchdogLastAckUptime
                let bucket: Int
                if stallSeconds >= 5.0 { bucket = 4 }
                else if stallSeconds >= 3.0 { bucket = 3 }
                else if stallSeconds >= 1.5 { bucket = 2 }
                else if stallSeconds >= 0.8 { bucket = 1 }
                else { bucket = 0 }
                if bucket > watchdogLastLoggedBucket {
                    watchdogLastLoggedBucket = bucket
                    shouldEmitStall = true
                }
            }
            watchdogLock.unlock()

            if shouldPing {
                DispatchQueue.main.async {
                    watchdogLock.lock()
                    watchdogLastAckUptime = ProcessInfo.processInfo.systemUptime
                    watchdogPingInFlight = false
                    watchdogLastLoggedBucket = 0
                    watchdogLock.unlock()
                }
            } else if shouldEmitStall {
                let snap = currentMemorySnapshot()
                let msg = String(
                    format: "MAIN_THREAD_STALL blocked=%.2fs lastStep=%@",
                    stallSeconds, currentLastCheckpointString()
                )
                writeFormattedLine(level: "WATCHDOG", category: .general, message: msg, snapshot: snap, mirrorToOSLog: true)
            }
        }
        watchdogTimer = timer
        watchdogLock.unlock()
        timer.resume()
    }

    public static func stopMainThreadWatchdog() {
        watchdogLock.lock()
        let timer = watchdogTimer
        watchdogTimer = nil
        watchdogPingInFlight = false
        watchdogLastLoggedBucket = 0
        watchdogLock.unlock()
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
        snapshot: MemorySnapshot? = nil,
        mirrorToOSLog: Bool = true
    ) {
        bootstrapIfNeeded()
        let ts = utcTimestampMillis()
        let thr = currentThreadLabel()
        let snap = snapshot ?? currentMemorySnapshot()
        let therm = thermalStateName()
        var line = String(
            format: "[%@] [thr=%@] [mem=%.1fMB(int=%.1f,comp=%.1f,ext=%.1f) avail=%dMB therm=%@] %@ %@: %@\n",
            ts, thr, snap.physMB, snap.internalMB, snap.compressedMB, snap.externalMB,
            snap.availMB, therm, category.rawValue, level, message
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
        let snap = currentMemorySnapshot()
        var report = """
        =========================================
        ALIGNAI STUDIO CRASH REPORT (NSException)
        Time: \(utcTimestampMillis())
        Thread: \(currentThreadLabel())
        LastStep: \(currentLastCheckpointString())
        Memory: phys=\(String(format: "%.1f", snap.physMB))MB (int=\(String(format: "%.1f", snap.internalMB)) comp=\(String(format: "%.1f", snap.compressedMB)) ext=\(String(format: "%.1f", snap.externalMB))) peak=\(String(format: "%.1f", snap.peakMB))MB avail=\(snap.availMB)MB thermal=\(thermalStateName())
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
    /// Writes signal code, last active checkpoint step, and native `backtrace_symbols_fd` frames to disk.
    public static func handleCrashSignal(_ sig: Int32) {
        if cleanExitMarkerCPath[0] != 0 {
            _ = Darwin.unlink(&cleanExitMarkerCPath)
        }
        var header: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0x0A, 0x3D, 0x3D, 0x3D, 0x20, 0x46, 0x41, 0x54, // \n=== FAT
            0x41, 0x4C, 0x20, 0x53, 0x49, 0x47, 0x4E, 0x41, // AL SIGNA
            0x4C, 0x20, 0x30, 0x30, 0x20, 0x3D, 0x3D, 0x3D, // L 00 ===
            0x0A, 0x4C, 0x41, 0x53, 0x54, 0x3A, 0x20, 0,    // \nLAST: 
            0, 0, 0, 0, 0, 0, 0, 0
        )
        let s = max(0, min(99, Int(sig)))
        header.18 = UInt8(0x30 + (s / 10))
        header.19 = UInt8(0x30 + (s % 10))

        // Stack-only 32-frame buffer (zero heap allocation inside POSIX signal handler).
        var frames: (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
        ) = (
            nil, nil, nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, nil, nil, nil, nil
        )
        let frameCount: Int32 = withUnsafeMutablePointer(to: &frames) { ptr in
            ptr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 32) { rawPtr in
                Darwin.backtrace(rawPtr, 32)
            }
        }

        let stepLen = max(0, min(255, lastCheckpointLen))

        func dumpToFD(_ fd: Int32) {
            guard fd >= 0 else { return }
            withUnsafePointer(to: &header) { ptr in
                _ = Darwin.write(fd, UnsafeRawPointer(ptr), 31)
            }
            if stepLen > 0 {
                _ = Darwin.write(fd, UnsafeRawPointer(lastCheckpointRawBuf), stepLen)
            }
            if frameCount > 0 {
                withUnsafeMutablePointer(to: &frames) { ptr in
                    ptr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 32) { rawPtr in
                        Darwin.backtrace_symbols_fd(rawPtr, frameCount, fd)
                    }
                }
            }
            _ = Darwin.fsync(fd)
        }

        dumpToFD(sessionFD)
        dumpToFD(crashFD)

        signal(sig, SIG_DFL)
        raise(sig)
    }

    fileprivate static func appendMetricKitDiagnostic(_ reportInput: String) {
        var report = reportInput
        fileLock.lock()
        didPreviousSessionExitUncleanly = true
        if previousSessionAbnormalSummary == nil {
            previousSessionAbnormalSummary = "MetricKit ghi nhận báo cáo Crash / Jetsam / CPU từ iOS cho phiên trước."
        }
        if let mkURL = metricKitLogFileURL, let data = report.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: mkURL.path),
               let fh = try? FileHandle(forWritingTo: mkURL) {
                _ = try? fh.seekToEnd()
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
            sections.append(String(content.suffix(16_000)))
        }
        if let mkURL = metricKitLogFileURL, FileManager.default.fileExists(atPath: mkURL.path),
           let mkContent = try? String(contentsOf: mkURL, encoding: .utf8),
           !mkContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("--- METRICKIT DIAGNOSTICS ---\n" + String(mkContent.suffix(16_000)))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Đọc những dòng cuối của `alignai_session_previous.log` (hoặc bản lưu crash gần nhất) kèm báo cáo crash/MetricKit.
    public static func readPreviousSessionLogTail(maxLines: Int = 260) -> String {
        var output: [String] = []
        if didPreviousSessionExitUncleanly, let summary = previousSessionAbnormalSummary {
            output.append("=== TÓM TẮT NHANH ===\n" + summary)
        }
        if let crash = readRecentCrashReport() {
            output.append("=== BÁO CÁO CRASH / SIGNAL / METRICKIT ===\n" + crash)
        }
        let sourceURL: URL? = {
            if let prev = previousSessionLogURL, FileManager.default.fileExists(atPath: prev.path) {
                return prev
            }
            return archivedCrashLogURLs().first
        }()
        if let prevURL = sourceURL,
           let text = try? String(contentsOf: prevURL, encoding: .utf8),
           !text.isEmpty {
            let lines = text.components(separatedBy: .newlines)
            let tail = lines.suffix(max(20, maxLines)).joined(separator: "\n")
            output.append("=== DÒNG CUỐI LOG PHIÊN TRƯỚC (\(min(lines.count, maxLines))/\(lines.count) dòng) ===\n" + tail)
        } else {
            output.append("(Chưa có log phiên trước — đây là lần mở đầu tiên hoặc log đã được xóa)")
        }
        let archives = archivedCrashLogURLs()
        if !archives.isEmpty {
            let names = archives.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            output.append("=== BẢN LƯU CRASH TRONG TỆP (Files/AlignAI Studio/CrashLogs) ===\n\(names)")
        }
        return output.joined(separator: "\n\n")
    }

    /// Bản rút gọn 90 dòng cuối cực gọn để copy 1 chạm gửi trực tiếp vào chat chẩn đoán.
    public static func readPreviousSessionQuickCopy(maxLines: Int = 90) -> String {
        let snap = currentMemorySnapshot()
        let header = """
        ALIGNAI QUICK CRASH TAIL | OS=\(ProcessInfo.processInfo.operatingSystemVersionString) | RAM=\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))MB | Unclean=\(didPreviousSessionExitUncleanly ? "YES" : "NO") | NowMem=\(String(format: "%.1f", snap.physMB))MB(avail=\(snap.availMB)MB)
        """
        return header + "\n" + readPreviousSessionLogTail(maxLines: maxLines)
    }

    public static func readRecentLogText(maxChars: Int = 12_000) -> String {
        guard let url = currentSessionLogURL, let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else {
            return "(Chưa có log nào được ghi trong phiên hiện tại)"
        }
        return content.count > maxChars ? String(content.suffix(maxChars)) : content
    }

    /// Đóng gói một file `.txt` đầy đủ (Thông tin máy + Crash/MetricKit + Log phiên trước + Log phiên hiện tại) để bấm nút Chia sẻ ngay trong App.
    public static func exportCombinedDiagnosticsFileURL() -> URL? {
        guard let dir = documentsDirectory else { return nil }
        let outURL = dir.appendingPathComponent("AlignAI_Previous_And_Current_Logs.txt")
        let snap = currentMemorySnapshot()
        let header = """
        ====================================================
        ALIGNAI FORENSIC DIAGNOSTIC BUNDLE
        Exported: \(utcTimestampMillis())
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Physical RAM: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) MB
        Current Footprint: \(String(format: "%.1f", snap.physMB)) MB (int=\(String(format: "%.1f", snap.internalMB)) comp=\(String(format: "%.1f", snap.compressedMB)) ext=\(String(format: "%.1f", snap.externalMB)) Peak=\(String(format: "%.1f", snap.peakMB)) MB)
        Available Headroom: \(snap.availMB) MB
        Thermal State: \(thermalStateName())
        Previous Session Unclean Exit: \(didPreviousSessionExitUncleanly ? "YES" : "NO")
        Summary: \(lastCrashHeadlineSummary())
        ====================================================

        """
        let prevSection = readPreviousSessionLogTail(maxLines: 800)
        let currSection = "\n\n=== LOG PHIÊN HIỆN TẠI (CUỐI) ===\n" + readRecentLogText(maxChars: 96_000)
        let fullText = header + prevSection + currSection
        try? fullText.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }

    public static var hasPreviousSessionLog: Bool {
        if let prev = previousSessionLogURL, FileManager.default.fileExists(atPath: prev.path) {
            return true
        }
        if !archivedCrashLogURLs().isEmpty {
            return true
        }
        return readRecentCrashReport() != nil
    }

    public static func readCurrentSessionLogTail(maxLines: Int = 220) -> String {
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
        if let dir = crashLogsDirectoryURL,
           let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        didPreviousSessionExitUncleanly = false
        previousSessionAbnormalSummary = nil
        latestArchivedCrashLogURL = nil
        if let curURL = currentSessionLogURL {
            sessionFD = Darwin.open(curURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if let crashURL = crashLogFileURL {
            crashFD = Darwin.open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        fileLock.unlock()
        info("Đã xóa toàn bộ nhật ký phiên trước, CrashLogs & hiện tại", category: .general)
    }

    // MARK: - Public Logging Entry Points

    private static let captureLog = OSLog(subsystem: subsystem, category: "Capture")
    private static let trackingLog = OSLog(subsystem: subsystem, category: "SpatialTracking")
    private static let photosLog = OSLog(subsystem: subsystem, category: "PhotoKit")
    private static let aiLog = OSLog(subsystem: subsystem, category: "AI_Engine")

    public enum Category: String, Sendable {
        case capture = "[CAPTURE]"
        case tracking = "[TRACKING_6DOF]"
        case photoKit = "[PHOTOS]"
        case ai = "[AI]"
        case motion = "[MOTION]"
        case general = "[SYSTEM]"
    }

    public static func lifecycle(_ event: String, detail: String = "", category: Category = .general) {
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        let payload = "\(event)\(suffix)"
        updateLastCheckpointBuffer("LIFECYCLE: \(payload)")
        writeFormattedLine(level: "LIFECYCLE", category: category, message: payload)
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
