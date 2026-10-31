import Foundation
import CoreGraphics

/// Tap trung toan bo hang so, nguong gia tri va thong so tinh chinh cua he thong bo cuc AI.
/// Moi thong so deu co ghi chu ve nguon goc va muc dich su dung.
public enum CompositionTuning {

    // MARK: - 1. YOLO Detection & Box Filtering
    /// Nguong tin cay toi thieu de chap nhan mot candidate tu YOLO model
    public static let yoloConfidenceThreshold: Float = 0.28
    public static let yoloLowLightConfidenceThreshold: Float = 0.16

    /// Kich thuoc toi thieu cua bounding box (ty le tren chieu dai/rong 0...1)
    public static let minBoxDimension: CGFloat = 0.04

    /// Kich thuoc toi da cua bounding box (tranh lay toan bo khung hinh)
    public static let maxBoxDimension: CGFloat = 0.95

    /// Ty le khung hinh width/height toi thieu (tranh box qua det ngang)
    public static let minAspectRatio: CGFloat = 0.15

    /// Ty le khung hinh width/height toi da (tranh box qua det doc)
    public static let maxAspectRatio: CGFloat = 6.5

    /// Ty le dien tich hop le toi thieu nam ben trong khung hinh [0...1]
    public static let minVisibleAreaFraction: CGFloat = 0.75

    /// He so uu tien danh muc trong tinh diem YOLO Prominence
    public static let categoryBonusFace: Double = 2.4
    public static let categoryBonusAnimal: Double = 2.0
    public static let categoryBonusHuman: Double = 1.8
    public static let categoryBonusObject: Double = 0.8

    // MARK: - 2. Composition Rules & Anchors
    /// Truc ty le vang / Luat 1/3 ben trai tren truc ngang
    public static let goldenSectionLeft: CGFloat = 0.36

    /// Truc ty le vang / Luat 1/3 ben phai tren truc ngang
    public static let goldenSectionRight: CGFloat = 0.64

    /// Duong mat chan dung chuan tren truc doc
    public static let portraitEyeLineY: Double = 0.36

    /// He so dich chuyen muc tieu theo huong anh mat (Gaze Lead Room)
    public static let gazeLeadFactor: Double = 0.15

    /// Khoang cach dinh dau ly tuong cho anh chan dung (Headroom target)
    public static let headroomTargetY: Double = 0.075

    /// Do rong ham Gaussian danh gia headroom
    public static let headroomSigma: Double = 0.08

    /// Diem thuong toi da khi target neo gan truc 1/3
    public static let ruleOfThirdsBonusWeight: Double = 0.08

    /// He so suy hao khoang cach tam trong tinh diem noi bat
    public static let centerDistanceDecay: Double = 0.7

    // MARK: - 3. Target Desired Area Fraction (Dien tich mong muon theo y do)
    public static let desiredAreaPortrait: Double = 0.31
    public static let desiredAreaFace: Double = 0.095
    public static let desiredAreaFood: Double = 0.34
    public static let desiredAreaCloseUp: Double = 0.35
    public static let desiredAreaAnimal: Double = 0.28
    public static let desiredAreaGroup: Double = 0.38
    public static let desiredAreaEnvironment: Double = 0.22
    public static let desiredAreaStreet: Double = 0.22
    public static let desiredAreaLandscape: Double = 0.15
    public static let desiredAreaArchitecture: Double = 0.48

    /// Mau so chuan hoa dien tich de tinh diem kich thuoc chu the
    public static let heroFaceAreaDivisor: Double = 0.06
    public static let heroBodyAreaDivisor: Double = 0.24

    /// Mau so ham log-normal tinh sizeFit
    public static let sizeFitVarianceDivisor: Double = 0.85

    // MARK: - 4. Camera Intrinsics & 3D Spatial Tracking
    /// Goc nhin videoFieldOfView mac dinh cho camera chinh (wide 1x) tren iPhone (~69 do)
    public static let defaultCameraFOVWide: Double = 69.0

    /// Goc nhin videoFieldOfView cho camera goc sieu rong (ultra wide 0.5x, ~120 do)
    public static let defaultCameraFOVRearUltraWide: Double = 120.0

    /// Goc nhin videoFieldOfView cho camera telephoto (3x/5x, ~30 do)
    public static let defaultCameraFOVTelephoto: Double = 30.0

    /// Goc nhin videoFieldOfView cho camera truoc (front camera, ~70 do)
    public static let defaultCameraFOVFront: Double = 70.0

    /// Goc nhin ngang mac dinh (do) khi khong doc duoc camera intrinsics tu frame
    public static let fallbackFOVHorizontalDegrees: Double = 69.0

    /// Ty le khung hinh doc mac dinh (4:3 rear portrait)
    public static let fallbackBufferAspectRatio: Double = 0.75

    /// Nguong kiem dinh Mahalanobis (chi-squared) trong Kalman Filter
    public static let mahalanobisGateThreshold: Double = 16.0
    public static let mahalanobisContinuationGate: Double = 25.0

    /// He so suy hao van toc goc quay cua dien thoai (tranh troi da)
    public static let angularVelocityDampingRate: Double = 1.5

    /// Nguong khoang cach can le an toan khi zoom (margin tu target toi mep)
    public static let edgeSafetyMargin: Double = 0.05

    /// Khoang thoi gian toi thieu giua 2 mau IMU de tinh slerp tranh chia cho 0 (1 microgiay)
    public static let motionInterpolationMinDt: Double = 1e-6

    /// Khoang thoi gian toi da giua 2 mau IMU de cho phep noi suy (100ms)
    public static let motionInterpolationMaxDt: Double = 0.10

    /// Bien ngoai suy toi da cho phep o 2 dau cua chuoi mau IMU (20ms)
    public static let motionInterpolationMargin: Double = 0.02

    /// Do tre thoi gian toi da cho phep giua frame va pose gan nhat (200ms)
    public static let maxFrameToMotionLatency: Double = 0.20

    // MARK: - 5. Debug & Experiment Flags
    /// Co bat che do hien thi debug overlay tren Preview
    public static var isDebugOverlayEnabled: Bool = false

    /// Co bat ghi log cac thuc nghiem tren may that A, B, C, D
    public static var isExperimentLoggingEnabled: Bool = true
}
