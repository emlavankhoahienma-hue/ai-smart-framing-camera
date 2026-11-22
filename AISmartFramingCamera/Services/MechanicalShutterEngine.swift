import Foundation
import AVFoundation
import CoreHaptics
import UIKit

/// Hồ sơ Âm thanh Màn trập Cơ học & Phản hồi Rung CoreHaptics cho từng dòng máy ảnh kinh điển.
public enum MechanicalShutterProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoMatch = "auto_match"
    case leicaM = "leica_m"
    case nikonFM2 = "nikon_fm2"
    case contaxT2 = "contax_t2"
    case hasselblad500 = "hasselblad_500"
    case polaroidSX70 = "polaroid_sx70"
    case silentHaptic = "silent_haptic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoMatch: return "Tự khớp máy"
        case .leicaM: return "Leica M Rangefinder"
        case .nikonFM2: return "Nikon FM2 SLR"
        case .contaxT2: return "Contax T2 35mm"
        case .hasselblad500: return "Hasselblad 500C"
        case .polaroidSX70: return "Polaroid SX-70"
        case .silentHaptic: return "Chỉ rung im lặng"
        }
    }

    public var shortLabel: String {
        switch self {
        case .autoMatch: return "Tự động"
        case .leicaM: return "Leica M"
        case .nikonFM2: return "Nikon FM2"
        case .contaxT2: return "Contax T2"
        case .hasselblad500: return "Hasselblad"
        case .polaroidSX70: return "Polaroid"
        case .silentHaptic: return "Im lặng"
        }
    }

    public var hardwareSubtitle: String {
        switch self {
        case .autoMatch: return "Tự chọn màn trập khớp đúng dòng máy phim đang bật"
        case .leicaM: return "Màn trập vải êm gọn 2 nhịp (~75ms) · không lật gương"
        case .nikonFM2: return "Gương lật cơ khí đầm chắc (~130ms) · hồi gương rõ"
        case .contaxT2: return "Tiếng bấm giòn + mô-tơ cuộn phim 35mm (~320ms)"
        case .hasselblad500: return "Màn trập lá Trung khổ trầm sâu đầy uy lực (~150ms)"
        case .polaroidSX70: return "Tiếng bấm + rò rỉ trục lăn đẩy ảnh tức thì (~430ms)"
        case .silentHaptic: return "Không phát tiếng loa · giữ phản hồi rung cơ Taptic"
        }
    }

    public var iconName: String {
        switch self {
        case .autoMatch: return "sparkles.rectangle.stack"
        case .leicaM: return "camera.aperture"
        case .nikonFM2: return "camera.shutter.button"
        case .contaxT2: return "film"
        case .hasselblad500: return "square.split.2x2"
        case .polaroidSX70: return "photo.on.rectangle"
        case .silentHaptic: return "speaker.slash"
        }
    }

    /// Tự động suy ra hồ sơ màn trập chuẩn theo `FilmPreset` khi người dùng chọn `autoMatch`.
    public func resolved(for filmPreset: FilmPreset) -> MechanicalShutterProfile {
        guard self == .autoMatch else { return self }
        switch filmPreset {
        case .instaxMini, .instaxWide, .instaxSquare, .polaroid600, .sx70TimeZero, .polaroidSpectra:
            return .polaroidSX70
        case .medium120LG, .acrosBW, .cyanotype:
            return .hasselblad500
        case .grPositive, .grNegative, .grHighBW, .grFFilm, .grStreetSnap,
             .fujiX, .fxn35, .classicChrome, .classicNeg, .astia100F:
            return .leicaM
        case .triX400, .cinestill800T, .canonF1, .eos5DClassic, .bleachBypass, .lomoLCA:
            return .nikonFM2
        case .cpm35, .kodakPortra400, .gold200, .ektar100, .colorPlus200, .vision3500D,
             .fujiPro400H, .velvia50, .sureShot35, .cam1998, .cam1998Street, .toyK:
            return .contaxT2
        default:
            return .leicaM
        }
    }
}

/// Bộ tổng hợp âm thanh màn trập cơ học đa quá độ (Multi-Transient 44.1kHz PCM Synthesis)
/// kết hợp đồng bộ CoreHaptics Taptic Engine theo từng mili-giây.
public final class MechanicalShutterEngine: @unchecked Sendable {
    public static let shared = MechanicalShutterEngine()

    private enum Keys {
        static let profile = "alignai.shutter.profile.v1"
        static let soundVolume = "alignai.shutter.soundVolume.v1"
        static let hapticIntensity = "alignai.shutter.hapticIntensity.v1"
        static let respectSilentSwitch = "alignai.shutter.respectSilentSwitch.v1"
        static let halfPressHaptic = "alignai.shutter.halfPressHaptic.v1"
        static let dialTicks = "alignai.shutter.dialTicks.v1"
    }

    private let lock = NSLock()
    private let synthQueue = DispatchQueue(label: "com.alignai.shutter.synth", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.alignai.shutter.audio", qos: .userInteractive)

    // User preferences
    private var _selectedProfile: MechanicalShutterProfile
    private var _soundVolume: Float
    private var _hapticIntensity: Float
    private var _respectSilentSwitch: Bool
    private var _enableHalfPressHaptic: Bool
    private var _enableMechanicalDialTicks: Bool

    // Runtime context
    private var _isVideoCaptureMode: Bool = false
    private var _activeFilmPreset: FilmPreset = .standard

    // Audio Engine + Dual Alternated Player Pool (prevents rapid bursts from clipping tail acoustics)
    private var audioEngine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayerIndex: Int = 0
    private var pcmBuffers: [String: AVAudioPCMBuffer] = [:]
    private let sampleRate: Double = 44100.0

    // CoreHaptics Engine
    private var hapticEngine: CHHapticEngine?
    private var supportsHaptics: Bool = false
    private var lastDialTickTime: TimeInterval = 0
    private var lastHalfPressTime: TimeInterval = 0

    // Fallback UIKit haptics for older devices
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    private init() {
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: Keys.profile), let p = MechanicalShutterProfile(rawValue: raw) {
            _selectedProfile = p
        } else {
            _selectedProfile = .autoMatch
        }
        _soundVolume = ud.object(forKey: Keys.soundVolume) != nil ? ud.float(forKey: Keys.soundVolume) : 0.80
        _hapticIntensity = ud.object(forKey: Keys.hapticIntensity) != nil ? ud.float(forKey: Keys.hapticIntensity) : 0.92
        _respectSilentSwitch = ud.object(forKey: Keys.respectSilentSwitch) != nil ? ud.bool(forKey: Keys.respectSilentSwitch) : false
        _enableHalfPressHaptic = ud.object(forKey: Keys.halfPressHaptic) != nil ? ud.bool(forKey: Keys.halfPressHaptic) : true
        _enableMechanicalDialTicks = ud.object(forKey: Keys.dialTicks) != nil ? ud.bool(forKey: Keys.dialTicks) : true

        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteOrConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        synthQueue.async { [weak self] in
            self?.buildAllPCMBuffers()
        }
    }

    // MARK: - Public Thread-Safe Settings

    public var selectedProfile: MechanicalShutterProfile {
        get { lock.withLock { _selectedProfile } }
        set {
            lock.withLock { _selectedProfile = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.profile)
        }
    }

    public var soundVolume: Float {
        get { lock.withLock { _soundVolume } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            lock.withLock { _soundVolume = clamped }
            UserDefaults.standard.set(clamped, forKey: Keys.soundVolume)
        }
    }

    public var hapticIntensity: Float {
        get { lock.withLock { _hapticIntensity } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            lock.withLock { _hapticIntensity = clamped }
            UserDefaults.standard.set(clamped, forKey: Keys.hapticIntensity)
        }
    }

    public var respectSilentSwitch: Bool {
        get { lock.withLock { _respectSilentSwitch } }
        set {
            lock.withLock { _respectSilentSwitch = newValue }
            UserDefaults.standard.set(newValue, forKey: Keys.respectSilentSwitch)
        }
    }

    public var enableHalfPressHaptic: Bool {
        get { lock.withLock { _enableHalfPressHaptic } }
        set {
            lock.withLock { _enableHalfPressHaptic = newValue }
            UserDefaults.standard.set(newValue, forKey: Keys.halfPressHaptic)
        }
    }

    public var enableMechanicalDialTicks: Bool {
        get { lock.withLock { _enableMechanicalDialTicks } }
        set {
            lock.withLock { _enableMechanicalDialTicks = newValue }
            UserDefaults.standard.set(newValue, forKey: Keys.dialTicks)
        }
    }

    public var isVideoCaptureMode: Bool {
        get { lock.withLock { _isVideoCaptureMode } }
        set { lock.withLock { _isVideoCaptureMode = newValue } }
    }

    public var activeFilmPreset: FilmPreset {
        get { lock.withLock { _activeFilmPreset } }
        set { lock.withLock { _activeFilmPreset = newValue } }
    }

    public var effectiveResolvedProfile: MechanicalShutterProfile {
        let (p, preset) = lock.withLock { (_selectedProfile, _activeFilmPreset) }
        return p.resolved(for: preset)
    }

    // MARK: - Trigger Actions

    public func prepare() {
        DispatchQueue.main.async { [weak self] in
            self?.impactHeavy.prepare()
            self?.impactRigid.prepare()
            self?.impactLight.prepare()
        }
        audioQueue.async { [weak self] in
            self?.ensureHapticEngineRunning()
        }
    }

    /// Kích hoạt âm thanh màn trập & rung cơ học khi chụp (tự động im lặng loa nếu đang ở Video Mode để không lọt vào mic).
    public func fireShutter() {
        let state = lock.withLock {
            (_selectedProfile, _activeFilmPreset, _soundVolume, _hapticIntensity, _respectSilentSwitch, _isVideoCaptureMode)
        }
        let resolved = state.0.resolved(for: state.1)
        let hapticScale = state.3
        let playAudio = !state.5 && state.2 > 0.01 && resolved != .silentHaptic

        if playAudio {
            playSoundKey(resolved.rawValue, volume: state.2, respectSilent: state.4)
        }
        if hapticScale > 0.01 {
            playShutterHaptic(profile: resolved, scale: hapticScale)
        }
    }

    /// Phát thử tức thì âm thanh & rung theo đúng hồ sơ đang chọn (kể cả trong Cài đặt).
    public func firePreviewTest(profile: MechanicalShutterProfile) {
        let state = lock.withLock { (_activeFilmPreset, _soundVolume, _hapticIntensity, _respectSilentSwitch) }
        let resolved = profile.resolved(for: state.0)
        let vol = max(0.35, state.1)
        let hap = max(0.35, state.2)

        if resolved != .silentHaptic && state.1 > 0.01 {
            playSoundKey(resolved.rawValue, volume: vol, respectSilent: state.3)
        }
        playShutterHaptic(profile: resolved, scale: hap)
    }

    /// Rung nửa cò cơ học nhẹ (Half-Press detent khi vừa chạm giữ nút chụp).
    public func fireShutterHalfPress() {
        let (enabled, hap) = lock.withLock { (_enableHalfPressHaptic, _hapticIntensity) }
        guard enabled, hap > 0.02 else { return }
        let now = CACurrentMediaTime()
        guard now - lastHalfPressTime > 0.10 else { return }
        lastHalfPressTime = now
        playTransientHaptic(intensity: 0.44 * hap, sharpness: 0.90)
    }

    /// Rung khía bánh răng cơ học + tiếng click mảnh khi xoay tiêu cự / dial (throttle >= 36ms).
    public func fireMechanicalDialTick() {
        let (enabled, hap, vol, respectSilent, isVideo) = lock.withLock {
            (_enableMechanicalDialTicks, _hapticIntensity, _soundVolume, _respectSilentSwitch, _isVideoCaptureMode)
        }
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastDialTickTime >= 0.036 else { return }
        lastDialTickTime = now

        if hap > 0.02 {
            playTransientHaptic(intensity: 0.38 * hap, sharpness: 0.94)
        }
        if !isVideo && vol > 0.08 && effectiveResolvedProfile != .silentHaptic {
            playSoundKey("dial_tick", volume: vol * 0.34, respectSilent: respectSilent)
        }
    }

    /// Nhịp đếm ngược studio cho Hẹn giờ & Photobooth (âm studio ấm + rung nhịp, giây cuối cao hơn).
    public func fireCountdownTick(secondsLeft: Int) {
        let (vol, hap, respectSilent, isVideo, profile) = lock.withLock {
            (_soundVolume, _hapticIntensity, _respectSilentSwitch, _isVideoCaptureMode, _selectedProfile)
        }
        let isFinal = (secondsLeft <= 1)
        if !isVideo && vol > 0.01 && profile != .silentHaptic {
            playSoundKey(isFinal ? "countdown_final" : "countdown_normal", volume: vol * 0.72, respectSilent: respectSilent)
        }
        if hap > 0.02 {
            playTransientHaptic(intensity: (isFinal ? 0.85 : 0.48) * hap, sharpness: isFinal ? 0.88 : 0.65)
        }
    }

    /// Tiếng lách bật đèn flash studio nhẹ dùng cho nháy màn chụp Photobooth.
    public func fireStudioFlashPop() {
        let (vol, hap, respectSilent, profile) = lock.withLock {
            (_soundVolume, _hapticIntensity, _respectSilentSwitch, _selectedProfile)
        }
        if vol > 0.01 && profile != .silentHaptic {
            playSoundKey("flash_pop", volume: vol * 0.55, respectSilent: respectSilent)
        }
        if hap > 0.02 {
            playTransientHaptic(intensity: 0.52 * hap, sharpness: 0.86)
        }
    }

    // MARK: - AVAudioEngine Management

    @objc private func handleAudioRouteOrConfigChange() {
        audioQueue.async { [weak self] in
            self?.teardownAudioEngine()
        }
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            audioQueue.async { [weak self] in
                self?.audioEngine?.pause()
            }
        }
    }

    private func teardownAudioEngine() {
        players.forEach { $0.stop() }
        players.removeAll()
        audioEngine?.stop()
        audioEngine = nil
    }

    private func playSoundKey(_ key: String, volume: Float, respectSilent: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard let buffer = self.lock.withLock({ self.pcmBuffers[key] }) else { return }

            do {
                let session = AVAudioSession.sharedInstance()
                let desiredCategory: AVAudioSession.Category = respectSilent ? .ambient : .playback
                if session.category != desiredCategory {
                    try session.setCategory(desiredCategory, mode: .default, options: [.mixWithOthers])
                }
                try session.setActive(true)
            } catch {
                // Keep quiet on restricted audio routes rather than crashing
            }

            if self.audioEngine == nil || self.players.isEmpty {
                let engine = AVAudioEngine()
                let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)!
                let p0 = AVAudioPlayerNode()
                let p1 = AVAudioPlayerNode()
                engine.attach(p0)
                engine.attach(p1)
                engine.connect(p0, to: engine.mainMixerNode, format: format)
                engine.connect(p1, to: engine.mainMixerNode, format: format)
                self.audioEngine = engine
                self.players = [p0, p1]
            }

            guard let engine = self.audioEngine, !self.players.isEmpty else { return }
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    self.teardownAudioEngine()
                    return
                }
            }

            let idx = self.nextPlayerIndex % self.players.count
            self.nextPlayerIndex &+= 1
            let player = self.players[idx]
            player.volume = max(0.0, min(1.0, volume))
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying {
                player.play()
            }
        }
    }

    // MARK: - CoreHaptics Management

    private func ensureHapticEngineRunning() {
        guard supportsHaptics else { return }
        if hapticEngine == nil {
            do {
                let engine = try CHHapticEngine()
                engine.isAutoShutdownEnabled = true
                engine.resetHandler = { [weak self] in
                    self?.audioQueue.async {
                        try? self?.hapticEngine?.start()
                    }
                }
                engine.stoppedHandler = { _ in }
                self.hapticEngine = engine
            } catch {
                self.supportsHaptics = false
                return
            }
        }
        try? hapticEngine?.start()
    }

    private func playTransientHaptic(intensity: Float, sharpness: Float) {
        let clampedInt = max(0.05, min(1.0, intensity))
        let clampedSharp = max(0.05, min(1.0, sharpness))
        if supportsHaptics {
            audioQueue.async { [weak self] in
                guard let self else { return }
                self.ensureHapticEngineRunning()
                guard let engine = self.hapticEngine else { return }
                let ev = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: clampedInt),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: clampedSharp)
                    ],
                    relativeTime: 0
                )
                if let pattern = try? CHHapticPattern(events: [ev], parameters: []),
                   let player = try? engine.makePlayer(with: pattern) {
                    try? player.start(atTime: CHHapticTimeImmediate)
                }
            }
        } else {
            DispatchQueue.main.async {
                if clampedSharp > 0.75 {
                    self.impactRigid.impactOccurred(intensity: CGFloat(clampedInt))
                } else {
                    self.impactLight.impactOccurred(intensity: CGFloat(clampedInt))
                }
            }
        }
    }

    private func playShutterHaptic(profile: MechanicalShutterProfile, scale: Float) {
        let s = max(0.05, min(1.0, scale))
        guard supportsHaptics else {
            DispatchQueue.main.async {
                self.impactHeavy.impactOccurred(intensity: CGFloat(min(1.0, s * 0.92)))
            }
            return
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureHapticEngineRunning()
            guard let engine = self.hapticEngine else { return }

            func tEv(_ t: TimeInterval, _ i: Float, _ sh: Float) -> CHHapticEvent {
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.02, min(1.0, i * s))),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0.02, min(1.0, sh)))
                    ],
                    relativeTime: t
                )
            }
            func cEv(_ t: TimeInterval, _ dur: TimeInterval, _ i: Float, _ sh: Float) -> CHHapticEvent {
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.02, min(1.0, i * s))),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0.02, min(1.0, sh)))
                    ],
                    relativeTime: t,
                    duration: dur
                )
            }

            let events: [CHHapticEvent]
            switch profile {
            case .autoMatch, .leicaM:
                events = [tEv(0.0, 0.90, 0.95), tEv(0.014, 0.45, 0.85)]
            case .nikonFM2:
                events = [tEv(0.0, 0.95, 0.48), cEv(0.004, 0.026, 0.54, 0.30), tEv(0.012, 0.86, 0.92), tEv(0.042, 0.72, 0.62)]
            case .contaxT2:
                events = [tEv(0.0, 0.88, 0.92), tEv(0.088, 0.28, 0.68), tEv(0.130, 0.28, 0.72), tEv(0.172, 0.26, 0.72), tEv(0.214, 0.22, 0.70)]
            case .hasselblad500:
                events = [tEv(0.0, 1.00, 0.36), cEv(0.005, 0.045, 0.66, 0.24), tEv(0.056, 0.52, 0.68)]
            case .polaroidSX70:
                events = [tEv(0.0, 0.86, 0.82), cEv(0.058, 0.300, 0.40, 0.28)]
            case .silentHaptic:
                events = [tEv(0.0, 0.64, 0.74)]
            }

            if let pattern = try? CHHapticPattern(events: events, parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }
    }

    // MARK: - Physical Acoustic Multi-Transient PCM Synthesis (Zero External Audio Assets Required)

    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 1 }
        mutating func nextSample() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            let norm = Double((z >> 40) & 0xFFFFFF) / Double(0xFFFFFF)
            return norm * 2.0 - 1.0
        }
    }

    private func rbjBandpass(_ input: [Double], centerHz: Double, q: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * min(centerHz, sampleRate * 0.44) / sampleRate
        let alpha = sin(w0) / (2.0 * max(0.25, q))
        let a0 = 1.0 + alpha
        let b0 = alpha / a0
        let b2 = -alpha / a0
        let a1 = (-2.0 * cos(w0)) / a0
        let a2 = (1.0 - alpha) / a0

        var out = [Double](repeating: 0.0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = b0 * x0 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            out[i] = y0
        }
        return out
    }

    private func addTransient(into buf: inout [Double], t0: Double, dur: Double, freq: Double, q: Double, gain: Double, bodyHz: Double, seed: UInt64) {
        let i0 = max(0, Int(t0 * sampleRate))
        let n = max(16, Int(dur * sampleRate))
        var rng = SplitMix64(seed: seed)
        var noise = [Double](repeating: 0.0, count: n)
        for k in 0..<n { noise[k] = rng.nextSample() }
        let bp = rbjBandpass(noise, centerHz: freq, q: q)

        let tau = max(0.0012, dur * 0.24)
        for k in 0..<n {
            let dst = i0 + k
            guard dst < buf.count else { break }
            let t = Double(k) / sampleRate
            let attack = k < 14 ? Double(k) / 14.0 : 1.0
            let env = exp(-t / tau) * attack
            let body = bodyHz > 0.0 ? sin(2.0 * Double.pi * bodyHz * t) * exp(-t / 0.008) * 0.42 : 0.0
            buf[dst] += (bp[k] * 0.85 + body) * env * gain
        }
    }

    private func addMotorWhirr(into buf: inout [Double], t0: Double, dur: Double, modHz: Double, bandpassHz: Double, gain: Double, seed: UInt64) {
        let i0 = max(0, Int(t0 * sampleRate))
        let n = max(32, Int(dur * sampleRate))
        var rng = SplitMix64(seed: seed)
        var noise = [Double](repeating: 0.0, count: n)
        for k in 0..<n { noise[k] = rng.nextSample() }
        let bp = rbjBandpass(noise, centerHz: bandpassHz, q: 2.2)

        for k in 0..<n {
            let dst = i0 + k
            guard dst < buf.count else { break }
            let t = Double(k) / sampleRate
            let fadeIn = min(1.0, t / 0.012)
            let fadeOut = min(1.0, max(0.0, (dur - t) / 0.025))
            let gear = 0.58 + 0.42 * sin(2.0 * Double.pi * modHz * t)
            let hum = 0.22 * sin(2.0 * Double.pi * (modHz * 2.0) * t)
            buf[dst] += (bp[k] * gear + hum) * fadeIn * fadeOut * gain
        }
    }

    private func makeStereoPCMBuffer(from mono: [Double], panSpread: Double = 0.04) -> AVAudioPCMBuffer? {
        guard !mono.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
              let chData = pcm.floatChannelData else { return nil }

        pcm.frameLength = AVAudioFrameCount(mono.count)
        let peak = mono.reduce(0.0) { max($0, abs($1)) }
        let norm = peak > 0.90 ? (0.88 / peak) : 1.0
        let fadeSamples = min(mono.count / 4, Int(0.002 * sampleRate))
        let left = chData[0]
        let right = chData[1]

        for i in 0..<mono.count {
            var env = 1.0
            if fadeSamples > 0 {
                if i < fadeSamples {
                    env = Double(i) / Double(fadeSamples)
                } else if i >= mono.count - fadeSamples {
                    env = Double(mono.count - 1 - i) / Double(fadeSamples)
                }
            }
            let v = Float(tanh(mono[i] * norm * 1.15) * 0.90 * env)
            let delayedR = i >= 6 ? mono[i - 6] : mono[i]
            let vR = Float(tanh(delayedR * norm * 1.15) * 0.90 * env)
            left[i] = v
            right[i] = v * Float(1.0 - panSpread) + vR * Float(panSpread)
        }
        return pcm
    }

    private func buildAllPCMBuffers() {
        var map: [String: AVAudioPCMBuffer] = [:]

        // 1. Leica M Rangefinder (75ms silky cloth-curtain snick-tick)
        var bLeica = [Double](repeating: 0.0, count: Int(0.075 * sampleRate))
        addTransient(into: &bLeica, t0: 0.000, dur: 0.018, freq: 2200, q: 2.8, gain: 1.55, bodyHz: 165, seed: 11)
        addTransient(into: &bLeica, t0: 0.012, dur: 0.022, freq: 3100, q: 3.2, gain: 1.25, bodyHz: 210, seed: 12)
        addTransient(into: &bLeica, t0: 0.026, dur: 0.014, freq: 1450, q: 1.8, gain: 0.62, bodyHz: 120, seed: 13)
        if let p = makeStereoPCMBuffer(from: bLeica) { map[MechanicalShutterProfile.leicaM.rawValue] = p }

        // 2. Nikon FM2 SLR (130ms metallic mirror-up + curtain + mirror return)
        var bNikon = [Double](repeating: 0.0, count: Int(0.130 * sampleRate))
        addTransient(into: &bNikon, t0: 0.000, dur: 0.026, freq: 980,  q: 1.8, gain: 1.70, bodyHz: 86,  seed: 21)
        addTransient(into: &bNikon, t0: 0.011, dur: 0.022, freq: 2650, q: 2.6, gain: 1.55, bodyHz: 180, seed: 22)
        addTransient(into: &bNikon, t0: 0.042, dur: 0.032, freq: 1180, q: 2.0, gain: 1.32, bodyHz: 98,  seed: 23)
        if let p = makeStereoPCMBuffer(from: bNikon) { map[MechanicalShutterProfile.nikonFM2.rawValue] = p }

        // 3. Contax T2 35mm Compact (320ms crisp click + subtle micro-gear film advance whirr)
        var bContax = [Double](repeating: 0.0, count: Int(0.320 * sampleRate))
        addTransient(into: &bContax, t0: 0.000, dur: 0.020, freq: 2400, q: 2.6, gain: 1.65, bodyHz: 195, seed: 31)
        addTransient(into: &bContax, t0: 0.015, dur: 0.014, freq: 1650, q: 2.0, gain: 0.85, bodyHz: 140, seed: 32)
        addMotorWhirr(into: &bContax, t0: 0.088, dur: 0.175, modHz: 42, bandpassHz: 920, gain: 0.76, seed: 33)
        if let p = makeStereoPCMBuffer(from: bContax) { map[MechanicalShutterProfile.contaxT2.rawValue] = p }

        // 4. Hasselblad 500C (150ms deep medium-format leaf-shutter thock)
        var bHassel = [Double](repeating: 0.0, count: Int(0.150 * sampleRate))
        addTransient(into: &bHassel, t0: 0.000, dur: 0.034, freq: 640,  q: 1.6, gain: 1.80, bodyHz: 68,  seed: 41)
        addTransient(into: &bHassel, t0: 0.016, dur: 0.028, freq: 1320, q: 2.2, gain: 1.05, bodyHz: 112, seed: 42)
        addTransient(into: &bHassel, t0: 0.056, dur: 0.024, freq: 820,  q: 2.4, gain: 0.82, bodyHz: 82,  seed: 43)
        if let p = makeStereoPCMBuffer(from: bHassel) { map[MechanicalShutterProfile.hasselblad500.rawValue] = p }

        // 5. Polaroid SX-70 (430ms click + iconic instant roller ejection motor)
        var bPolaroid = [Double](repeating: 0.0, count: Int(0.430 * sampleRate))
        addTransient(into: &bPolaroid, t0: 0.000, dur: 0.024, freq: 1850, q: 2.2, gain: 1.55, bodyHz: 148, seed: 51)
        addMotorWhirr(into: &bPolaroid, t0: 0.058, dur: 0.320, modHz: 56, bandpassHz: 740, gain: 0.88, seed: 52)
        if let p = makeStereoPCMBuffer(from: bPolaroid) { map[MechanicalShutterProfile.polaroidSX70.rawValue] = p }

        // 6. Countdown Normal (warm 784Hz studio chime) & Final (1046.5Hz harmonic studio chime)
        func makeChime(freqHz: Double, dur: Double) -> AVAudioPCMBuffer? {
            let n = Int(dur * sampleRate)
            var b = [Double](repeating: 0.0, count: n)
            for k in 0..<n {
                let t = Double(k) / sampleRate
                let attack = min(1.0, t / 0.004)
                let env = exp(-t / 0.036) * attack
                b[k] = (sin(2.0 * Double.pi * freqHz * t) * 0.72 + sin(4.0 * Double.pi * freqHz * t) * 0.18) * env * 0.55
            }
            return makeStereoPCMBuffer(from: b, panSpread: 0.02)
        }
        if let p = makeChime(freqHz: 784.0, dur: 0.105) { map["countdown_normal"] = p }
        if let p = makeChime(freqHz: 1046.5, dur: 0.145) { map["countdown_final"] = p }

        // 7. Aperture Dial Tick (4ms crisp tactile click) & Studio Flash Pop
        var bDial = [Double](repeating: 0.0, count: Int(0.012 * sampleRate))
        addTransient(into: &bDial, t0: 0.0, dur: 0.008, freq: 2900, q: 3.4, gain: 0.90, bodyHz: 240, seed: 71)
        if let p = makeStereoPCMBuffer(from: bDial) { map["dial_tick"] = p }

        var bFlash = [Double](repeating: 0.0, count: Int(0.045 * sampleRate))
        addTransient(into: &bFlash, t0: 0.0, dur: 0.022, freq: 3400, q: 1.5, gain: 1.15, bodyHz: 320, seed: 81)
        if let p = makeStereoPCMBuffer(from: bFlash) { map["flash_pop"] = p }

        lock.withLock {
            self.pcmBuffers = map
        }
    }
}
