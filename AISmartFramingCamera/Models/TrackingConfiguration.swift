import Foundation

/// Cấu hình toàn diện các thông số bám Target (Target Tracking Calibration)
/// Cho phép điều chỉnh qua Web Dashboard, tải qua Cloud Remote Config, hoặc kéo slider trực tiếp trong app
public struct TrackingConfiguration: Codable, Equatable {
    // MARK: - 1. Bộ Lọc Chống Rung 1-Euro Filter (Độ Mượt & Độ Nhạy)
    /// Tần số cắt tối thiểu khi camera đứng yên (Hz). Càng nhỏ càng triệt rung tay; càng lớn càng nhạy (mặc định: 1.2)
    public var oneEuroMinCutoff: Double = 1.2
    /// Hệ số nhạy theo vận tốc lia máy. Càng lớn thì khi lia máy nhanh mỏ neo bám càng tức thì không độ trễ (mặc định: 1.0)
    public var oneEuroBeta: Double = 1.0
    /// Tần số cắt khi bật chế độ đi đường Street Mode (Hz) (mặc định: 1.6)
    public var oneEuroMinCutoffStreet: Double = 1.6
    /// Hệ số nhạy theo vận tốc khi đi đường Street Mode (mặc định: 1.2)
    public var oneEuroBetaStreet: Double = 1.2
    /// Tần số cắt đạo hàm vận tốc (mặc định: 1.0)
    public var oneEuroDCutoff: Double = 1.0
    
    // MARK: - 2. Nhận Diện Quang Học & Chống Nhảy Đột Biến (Vision & Noise Gate)
    /// Độ dịch chuyển tối đa cho phép trong 1 frame (0.0 đến 1.0 màn hình) trước khi kẹp lại chống teleport/nhảy giật (mặc định: 0.12)
    public var maxObservationJump: Double = 0.12
    /// Độ tin cậy tối thiểu để nhận frame quang học từ Vision (mặc định: 0.20)
    public var opticalAcceptThreshold: Double = 0.20
    /// Ngưỡng nhận diện vật thể màu trắng / đơn sắc thiếu texture (mặc định: 0.60)
    public var lowTextureThreshold: Double = 0.60
    /// Ngưỡng tương đồng histogram màu sắc chống trôi sang nền (mặc định: 0.78)
    public var histogramAcceptThreshold: Double = 0.78
    /// Khoảng cách vector đặc trưng FeaturePrint ANE tối đa (mặc định: 0.50)
    public var featurePrintDistanceThreshold: Double = 0.50
    
    // MARK: - 3. Nắn Tâm Định Kỳ & Trọng Số Tâm KLT (Anti-Drift & KLT)
    /// Chu kỳ frame gọi Saliency độc lập để nắn tâm tracker (mặc định: 4 frames)
    public var periodicCorrectionInterval: Int = 4
    /// Lực kéo nắn tâm tracker về trọng tâm vật thể (0.0 đến 1.0) (mặc định: 0.28 = 28%)
    public var periodicCorrectionStrength: Double = 0.28
    /// Tỷ lệ nới biên khi ôm khít vật thể bằng Saliency/Pose (mặc định: 1.15 = +15%)
    public var saliencyPaddingRatio: Double = 1.15
    /// Trọng số tối thiểu của điểm KLT ở sát mép biên (mặc định: 0.15)
    public var kltCenterWeightMin: Double = 0.15
    /// Tỷ lệ vùng trung tâm ROI cho lưới điểm fallback KLT (mặc định: 0.60 = 60%)
    public var kltGridCentralRatio: Double = 0.60
    
    // MARK: - 4. Bù Trừ Chuyển Động Con Quay Hồi Chuyển (Gyroscope Odometry)
    /// Hệ số bù trừ góc lia máy ngang Panning (mặc định: 0.85)
    public var gyroScaleX: Double = 0.85
    /// Hệ số bù trừ góc nghiêng máy dọc Tilting (mặc định: 0.95)
    public var gyroScaleY: Double = 0.95
    /// Thời gian chờ quang học mất nét trước khi kích hoạt Gyro Dead-reckoning (giây) (mặc định: 0.12)
    public var opticalHandoverGate: Double = 0.12
    /// Thời gian duy trì quán tính vận tốc quang học khi vừa mất dấu (giây) (mặc định: 0.23)
    public var velocityDecayWindow: Double = 0.23

    public init() {}

    public static let `default` = TrackingConfiguration()

    // MARK: - Persistence & JSON Helpers
    private static let userDefaultsKey = "AISmartFraming_TrackingConfiguration"

    public static func loadPersisted() -> TrackingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(TrackingConfiguration.self, from: data) else {
            return .default
        }
        return config
    }

    public func persist() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: TrackingConfiguration.userDefaultsKey)
        }
    }

    public static func resetPersisted() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    public func toJSONString(pretty: Bool = true) -> String? {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = .prettyPrinted
        }
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    public static func fromJSONString(_ jsonString: String) -> TrackingConfiguration? {
        guard let data = jsonString.data(using: .utf8),
              let config = try? JSONDecoder().decode(TrackingConfiguration.self, from: data) else {
            return nil
        }
        return config
    }
}