import Foundation
import CoreGraphics
import simd

/// High-level photographic semantic domain used by the 3D Camera Framing Director.
/// Combines detections from COCO YOLO12s, OpenWorldPhotoYOLOE (143 classes), Vision,
/// and iOS 17+ VNGenerateForegroundInstanceMaskRequest into one unified ontology.
enum DirectorSubjectDomain: String, Sendable {
    case human
    case face
    case animal
    case pureFlower
    case pottedPlant
    case wideNature
    case architecture
    case food
    case vehicle
    case furniture
    case object
    case backgroundSurface
    case foregroundMask
}

/// Explicit 3-state optical zoom decision driven by subject fill, category comfort band,
/// and center-crop hardware optics.
enum DirectorZoomState: String, Sendable {
    case zoomIn = "ZOOM_IN"
    case noZoomNeeded = "NO_ZOOM"
    case zoomOut = "ZOOM_OUT"
}

/// Unified detection entry passed into `CameraFramingDirector`.
struct DirectorDetection: Sendable {
    let label: String
    let localizedLabel: String
    let boundingBox: CGRect
    let anchor: CGPoint?
    let confidence: Double
    let domain: DirectorSubjectDomain
    var gazeX: Double = 0.0
    var isGroup: Bool = false
    var isAttentionOnly: Bool = false
    var companionBounds: [CGRect] = []
    var faceBounds: [CGRect] = []

    var area: Double { Double(max(0, boundingBox.width) * max(0, boundingBox.height)) }
    var center: CGPoint { CGPoint(x: boundingBox.midX, y: boundingBox.midY) }
}

/// Photographic role resolved by the director.
enum DirectorPhotographicRole: String, Sendable {
    case portrait
    case environmentalPortrait
    case group
    case animal
    case indoorRoom
    case aperture
    case flower
    case foliage
    case food
    case vehicle
    case object
    case skyLandscape
    case architecture
    case street
    case scene

    var intent: LocalCompositionIntent {
        switch self {
        case .portrait: return .portrait
        case .environmentalPortrait: return .environmentalPortrait
        case .group: return .group
        case .animal: return .animal
        case .indoorRoom, .architecture, .aperture: return .architecture
        case .flower, .foliage: return .closeUp
        case .food: return .food
        case .vehicle, .object: return .object
        case .skyLandscape, .scene: return .landscape
        case .street: return .street
        }
    }
}

/// Photographic composition style selected for target placement.
enum DirectorCompositionStyle: String, Sendable {
    case keepNatural = "Giữ khung tự nhiên"
    case neuralFreeform = "AI Bố cục tự do"
    case centerFocus = "Tập trung Tâm điểm"
    case elevatedCenter = "Tâm cao thanh thoát"
    case groundedCenter = "Tâm vững trọng tâm"
    case symmetry = "Đối xứng Trục giữa"
    case subtleBalance = "Cân bằng Lệch nhẹ"
    case negativeSpace = "Không gian âm tối giản"
    case openHeadroom = "Khoảng thở thoáng đỉnh"
    case diagonalDynamic = "Đường chéo năng động"
    case lookingRoom = "Khoảng thở hướng nhìn"
    case leadingLines = "Đường dẫn phối cảnh"
    case frameInFrame = "Khung trong khung"
    case ruleOfThirds = "Bố cục Một phần ba"
    case goldenRatio = "Tỉ lệ vàng"
    case lowHorizonSky = "Chân trời thấp tôn mây trời"
    case highHorizonGround = "Chân trời cao tôn tiền cảnh"
    case mirrorHorizon = "Phản chiếu Đối xứng"
    case ultraWide = "Mở rộng Góc siêu rộng"
}

/// Output of the 3D Physical Camera Framing Director.
struct DirectorDecision: Sendable {
    let role: DirectorPhotographicRole
    let heroLabel: String
    let heroLocalizedLabel: String
    let heroBounds: CGRect
    let heroAnchor: CGPoint
    let destinationPoint: CGPoint
    let aimPointInSource: CGPoint
    let aimWorldRay: SIMD3<Double>
    let rotation: simd_quatd
    let recommendedZoom: CGFloat
    let confidence: Double
    let usesCenter: Bool
    let preservesOriginalFrame: Bool
    let ruleName: String
    let compositionStyle: DirectorCompositionStyle
    let explanation: String
    let detectedHorizonY: Double?
    var zoomState: DirectorZoomState = .noZoomNeeded
    var idealZoomAfterPan: CGFloat = 1.0
    var centerCropMaxZoom: CGFloat = 1.0
    var requiresPanBeforeZoom: Bool = false
    var centerCropVisibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var subjectFillMetric: Double = 0.0
    var targetFillMetric: Double = 0.0
    var allDetections: [DirectorDetection] = []
}

/// Thread-safe multi-frame hysteresis & adaptive smoothing memory for live camera re-evaluations.
/// Disabled by default for stateless single-photo benchmarks and unit tests so independent photos never cross-contaminate.
private final class DirectorTemporalState: @unchecked Sendable {
    static let shared = DirectorTemporalState()
    private let lock = NSLock()
    private var lastHeroBounds: CGRect?
    private var lastDomain: DirectorSubjectDomain?
    private var lastAnchor: CGPoint?
    private var lastDest: CGPoint?
    private var lastRole: DirectorPhotographicRole?
    private var lastZoom: CGFloat?
    private var lastZoomState: DirectorZoomState?
    private var lastTimestamp: TimeInterval = 0

    func reset() {
        lock.lock()
        lastHeroBounds = nil
        lastDomain = nil
        lastAnchor = nil
        lastDest = nil
        lastRole = nil
        lastZoom = nil
        lastZoomState = nil
        lastTimestamp = 0
        lock.unlock()
    }

    func heroBonus(for candidate: DirectorDetection, now: TimeInterval) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastTimestamp <= 4.5,
              let prevBox = lastHeroBounds,
              let prevDom = lastDomain else { return 1.0 }
        let inter = prevBox.intersection(candidate.boundingBox)
        let iou: Double
        if !inter.isNull && !inter.isEmpty {
            let ia = Double(inter.width * inter.height)
            let ua = Double(prevBox.width * prevBox.height + candidate.boundingBox.width * candidate.boundingBox.height) - ia
            iou = ua > 1e-6 ? ia / ua : 0.0
        } else {
            iou = 0.0
        }
        let dCenter = hypot(Double(prevBox.midX - candidate.boundingBox.midX),
                            Double(prevBox.midY - candidate.boundingBox.midY))
        if (iou >= 0.25 || dCenter <= 0.14) && (prevDom == candidate.domain || (prevDom == .human && candidate.domain == .face)) {
            return 1.24
        }
        return 1.0
    }

    func stabilizeZoom(
        proposedZoom: CGFloat,
        proposedState: DirectorZoomState,
        centerCropMax: CGFloat,
        now: TimeInterval
    ) -> CGFloat {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastTimestamp <= 4.5,
              let prevZoom = lastZoom,
              let prevState = lastZoomState else {
            return proposedZoom
        }
        if prevState == proposedState && abs(proposedZoom - prevZoom) < 0.18 {
            if proposedState == .zoomIn {
                return min(prevZoom, centerCropMax)
            }
            return prevZoom
        }
        return proposedZoom
    }

    func smoothDestination(
        proposedDest: CGPoint,
        anchor: CGPoint,
        role: DirectorPhotographicRole,
        now: TimeInterval
    ) -> CGPoint {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastTimestamp <= 4.5,
              lastRole == role,
              let prevAnchor = lastAnchor,
              let prevDest = lastDest,
              hypot(Double(proposedDest.x - prevDest.x), Double(proposedDest.y - prevDest.y)) < 0.16 else {
            return proposedDest
        }
        let motionSpeed = hypot(Double(anchor.x - prevAnchor.x), Double(anchor.y - prevAnchor.y))
        // Adaptive low-pass: strong damping when stationary (0.35), instant response during fast sweep (1.0)
        let alpha = min(1.0, 0.35 + 0.65 * (motionSpeed / 0.07))
        return CGPoint(
            x: prevDest.x + CGFloat(alpha) * (proposedDest.x - prevDest.x),
            y: prevDest.y + CGFloat(alpha) * (proposedDest.y - prevDest.y)
        )
    }

    func commit(
        heroBounds: CGRect,
        domain: DirectorSubjectDomain,
        anchor: CGPoint,
        dest: CGPoint,
        role: DirectorPhotographicRole,
        zoom: CGFloat,
        zoomState: DirectorZoomState,
        now: TimeInterval
    ) {
        lock.lock()
        lastHeroBounds = heroBounds
        lastDomain = domain
        lastAnchor = anchor
        lastDest = dest
        lastRole = role
        lastZoom = zoom
        lastZoomState = zoomState
        lastTimestamp = now
        lock.unlock()
    }
}

/// 3D Handheld Camera Framing & Optical Zoom Director.
enum CameraFramingDirector {
    private static let forward = SIMD3<Double>(0, 0, -1)
    /// Post-zoom normalized screen margin inside `[0, 1]^2` enforced around optical center `(0.5, 0.5)`.
    static let centerCropSafetyMargin: Double = 0.025

    static func resetTemporalState() {
        DirectorTemporalState.shared.reset()
    }

    private static let peripheralEquipmentTokens: Set<String> = [
        "monitor", "keyboard", "laptop", "bàn phím", "màn hình"
    ]
    private static let plantConfusableFoodTokens: Set<String> = [
        "banana", "broccoli", "carrot", "apple", "orange", "chuối", "táo", "cam"
    ]
    private static let groundCoverTokens: Set<String> = [
        "grass", "forest", "tree", "palm tree", "thảm cỏ", "khu rừng", "tán cây", "cây cọ"
    ]
    private static let scenicFeatureTokens: Set<String> = [
        "waterfall", "mountain", "hill", "rainbow", "thác nước", "dãy núi", "đồi núi", "cầu vồng"
    ]

    private static let skyTokens: Set<String> = ["sky", "cloud", "sunset", "bầu trời", "mây", "hoàng hôn"]
    private static let groundTokens: Set<String> = [
        "ocean", "sea", "beach", "river", "lake", "grass", "road", "street", "mountain", "hill",
        "biển", "bãi biển", "sông", "hồ", "núi", "đường"
    ]
    private static let wideNatureTokens: Set<String> = [
        "mountain", "hill", "ocean", "sea", "beach", "river", "lake", "sky", "cloud", "sunset",
        "waterfall", "forest", "rainbow", "núi", "biển", "bầu trời", "mây", "hoàng hôn", "rừng"
    ]

    /// Classifies an English or Vietnamese label string into `DirectorSubjectDomain`.
    static func classifyDomain(label: String, isHumanCategory: Bool = false, isFaceCategory: Bool = false,
                               isAnimalCategory: Bool = false, isGeneralCategory: Bool = false) -> DirectorSubjectDomain {
        if isFaceCategory { return .face }
        if isHumanCategory { return .human }
        if isAnimalCategory { return .animal }
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if l == "human face" || l == "khuôn mặt" || l == "face" { return .face }
        if l == "person" || l == "người" || l.hasPrefix("nhóm") { return .human }
        let animals: Set<String> = [
            "dog", "cat", "bird", "duck", "parrot", "horse", "sheep", "cow", "elephant", "bear",
            "zebra", "giraffe", "deer", "rabbit", "snake", "lizard", "frog", "turtle",
            "butterfly", "insect", "beetle", "fish", "animal",
            "chó", "mèo", "chim", "vịt", "vẹt", "ngựa", "bò", "hươu", "thỏ", "rắn", "ếch", "rùa",
            "bướm", "côn trùng", "bọ cánh cứng", "cá", "thú cưng", "động vật"
        ]
        if animals.contains(l) { return .animal }
        let pureFlowers: Set<String> = [
            "flower", "blossom", "rose", "sunflower", "tulip", "orchid", "bouquet",
            "succulent", "cactus", "mushroom", "leaf", "branch",
            "hoa", "bông hoa", "cụm hoa", "cành hoa", "lá cây", "hoa hồng", "hoa hướng dương",
            "sen đá", "xương rồng", "nấm"
        ]
        if pureFlowers.contains(l) { return .pureFlower }
        let potted: Set<String> = ["potted plant", "green plant", "chậu cây", "cây xanh"]
        if potted.contains(l) { return .pottedPlant }
        let wideNature: Set<String> = [
            "sky", "cloud", "sunset", "sun", "moon", "mountain", "hill", "sea", "ocean", "beach",
            "river", "lake", "waterfall", "rainbow", "forest", "grass", "tree", "palm tree",
            "rock", "cliff", "fireworks",
            "bầu trời", "mây", "hoàng hôn", "mặt trời", "núi", "biển", "bãi biển", "sông", "hồ",
            "thác nước", "rừng", "cây", "vách đá", "tảng đá", "pháo hoa"
        ]
        if wideNature.contains(l) { return .wideNature }
        let arch: Set<String> = [
            "building", "house", "skyscraper", "tower", "castle", "pagoda", "temple", "church", "cathedral",
            "bridge", "arch", "fountain", "monument", "sculpture", "statue",
            "window", "doorway", "balcony", "stairs", "street", "alley", "road", "street sign",
            "tòa nhà", "ngôi nhà", "nhà cao tầng", "tháp", "lâu đài", "chùa", "cây cầu", "đền chùa",
            "nhà thờ", "vòm cổng", "đài phun nước", "tượng đài", "điêu khắc", "bức tượng", "đường phố", "con hẻm"
        ]
        if arch.contains(l) { return .architecture }
        let food: Set<String> = [
            "food", "dish", "cake", "ice cream", "dessert", "fruit", "pizza", "burger", "noodle", "bread",
            "coffee", "cup", "mug", "tea", "cocktail", "drink", "glass", "wine glass", "bottle", "bowl", "plate", "teapot",
            "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "donut",
            "món ăn", "đồ ăn", "bánh ngọt", "kem", "trái cây", "cà phê", "cốc nước", "trà", "ly rượu", "chai nước", "bát đĩa", "ấm trà"
        ]
        if food.contains(l) { return .food }
        let vehicle: Set<String> = [
            "car", "motorcycle", "scooter", "bicycle", "bus", "truck", "train", "boat", "airplane",
            "ô tô", "xe máy", "xe tay ga", "xe đạp", "xe buýt", "xe tải", "tàu hỏa", "thuyền", "máy bay"
        ]
        if vehicle.contains(l) { return .vehicle }
        let bgSurface: Set<String> = ["table", "dining table", "bàn ăn"]
        if bgSurface.contains(l) { return .backgroundSurface }
        let furniture: Set<String> = [
            "chair", "sofa", "couch", "lamp", "chandelier", "bed", "bench",
            "ghế", "ghế sofa", "ghế dài", "đèn", "đèn chùm", "giường", "bàn"
        ]
        if furniture.contains(l) { return .furniture }
        if isGeneralCategory { return .wideNature }
        return .object
    }

    static func localizedName(for label: String) -> String {
        let map: [String: String] = [
            "person": "Người", "human face": "Khuôn mặt",
            "dog": "Chú chó", "cat": "Chú mèo", "bird": "Chim", "duck": "Chú vịt", "parrot": "Chú vẹt",
            "horse": "Ngựa", "cow": "Con bò", "sheep": "Con cừu", "elephant": "Voi", "bear": "Gấu",
            "zebra": "Ngựa vằn", "giraffe": "Hươu cao cổ",
            "deer": "Chú hươu", "rabbit": "Chú thỏ", "snake": "Con rắn", "lizard": "Thằn lằn",
            "frog": "Chú ếch", "turtle": "Con rùa", "butterfly": "Bướm", "insect": "Côn trùng",
            "beetle": "Bọ cánh cứng", "fish": "Cá", "animal": "Động vật",
            "flower": "Bông hoa", "blossom": "Cụm hoa", "rose": "Hoa hồng",
            "sunflower": "Hoa hướng dương", "tulip": "Hoa tulip", "bouquet": "Bó hoa",
            "succulent": "Sen đá", "mushroom": "Cây nấm",
            "leaf": "Chiếc lá", "green plant": "Cây xanh", "potted plant": "Chậu cây",
            "tree": "Tán cây", "palm tree": "Cây cọ", "branch": "Cành cây", "forest": "Khu rừng",
            "grass": "Thảm cỏ", "cactus": "Xương rồng", "rock": "Tảng đá", "cliff": "Vách đá",
            "sky": "Bầu trời", "cloud": "Mây trời", "sunset": "Hoàng hôn", "sun": "Mặt trời",
            "moon": "Mặt trăng", "mountain": "Dãy núi", "hill": "Đồi núi", "sea": "Mặt biển",
            "ocean": "Đại dương", "beach": "Bãi biển", "river": "Dòng sông", "lake": "Mặt hồ",
            "waterfall": "Thác nước", "rainbow": "Cầu vồng", "fireworks": "Pháo hoa",
            "building": "Tòa nhà", "house": "Ngôi nhà", "skyscraper": "Nhà cao tầng",
            "tower": "Tòa tháp", "castle": "Lâu đài", "pagoda": "Ngôi chùa", "temple": "Đền chùa",
            "church": "Nhà thờ", "cathedral": "Thánh đường", "bridge": "Cây cầu", "arch": "Vòm kiến trúc",
            "fountain": "Đài phun nước", "monument": "Tượng đài", "sculpture": "Tác phẩm điêu khắc",
            "window": "Cửa sổ", "doorway": "Khung cửa", "balcony": "Ban công", "stairs": "Cầu thang",
            "street": "Đường phố", "alley": "Con hẻm", "road": "Con đường", "street sign": "Biển báo",
            "food": "Món ăn", "dish": "Đĩa thức ăn", "cake": "Bánh ngọt", "ice cream": "Kem",
            "dessert": "Tráng miệng", "fruit": "Trái cây", "pizza": "Bánh pizza", "burger": "Burger",
            "noodle": "Mì/Phở", "bread": "Bánh mì", "coffee": "Ly cà phê", "cup": "Chiếc cốc",
            "mug": "Cốc sứ", "tea": "Ly trà", "cocktail": "Ly cocktail", "drink": "Đồ uống",
            "glass": "Ly thủy tinh", "wine glass": "Ly rượu", "bottle": "Chai nước", "bowl": "Bát", "plate": "Đĩa",
            "teapot": "Ấm trà", "sandwich": "Bánh mì kẹp", "donut": "Bánh donut", "banana": "Chuối", "apple": "Quả táo", "orange": "Quả cam",
            "car": "Ô tô", "motorcycle": "Xe máy", "scooter": "Xe tay ga", "bicycle": "Xe đạp",
            "bus": "Xe buýt", "truck": "Xe tải", "train": "Tàu hỏa", "boat": "Con thuyền", "airplane": "Máy bay",
            "helmet": "Mũ bảo hiểm",
            "laptop": "Laptop", "monitor": "Màn hình", "tv": "Màn hình TV", "keyboard": "Bàn phím",
            "mouse": "Chuột máy tính", "smartphone": "Điện thoại", "cell phone": "Điện thoại", "camera": "Máy ảnh",
            "headphones": "Tai nghe", "speaker": "Loa", "watch": "Đồng hồ đeo tay",
            "eyeglasses": "Kính mắt", "sunglasses": "Kính râm", "perfume": "Nước hoa", "ring": "Chiếc nhẫn",
            "book": "Cuốn sách", "lamp": "Đèn bàn", "chandelier": "Đèn chùm", "candle": "Ngọn nến",
            "lantern": "Đèn lồng", "vase": "Bình hoa", "clock": "Đồng hồ", "mirror": "Chiếc gương",
            "chair": "Chiếc ghế", "sofa": "Ghế sofa", "couch": "Ghế sofa", "bench": "Ghế dài",
            "table": "Mặt bàn", "bag": "Túi xách",
            "handbag": "Túi cầm tay", "backpack": "Ba lô", "shoe": "Giày", "sneaker": "Giày thể thao",
            "hat": "Mũ", "umbrella": "Chiếc ô", "statue": "Bức tượng", "toy": "Đồ chơi",
            "figurine": "Mô hình", "guitar": "Đàn guitar", "barrel": "Thùng gỗ",
            "box": "Chiếc hộp", "package": "Gói đồ",
        ]
        let key = label.lowercased()
        return map[key] ?? label
    }

    private struct RankedCandidate {
        let det: DirectorDetection
        let depth: Double
        let dAim: Double
        let hasFace: Bool
        let isCornerHeadless: Bool
        let isEdgeSliver: Bool
        let isSuppressedFood: Bool
        let heroScore: Double
    }

    private struct SharpCluster {
        let bounds: CGRect
        let center: CGPoint
        let meanDepth: Double
        let meanSharpness: Double
        let meanContrast: Double
        let area: Double
        let score: Double
    }

    private struct FramingCandidate {
        let destG: CGPoint
        let zoom: CGFloat
        let style: DirectorCompositionStyle
        let aim: CGPoint
        let rotation: simd_quatd
        let futureCalib: TrackingCalibration
        let cropBox: CGRect
        let isBaseline: Bool
    }

    /// Explicit comfort fill band (`[minFill, maxFill]`) and `idealFill` for each subject type.
    struct SubjectFillSpec {
        let minFill: Double
        let idealFill: Double
        let maxFill: Double
        let isWideContextual: Bool
    }

    static func fillSpec(
        for role: DirectorPhotographicRole,
        isFaceOnlyHero: Bool,
        isMinimalist: Bool
    ) -> SubjectFillSpec {
        if role == .portrait && isFaceOnlyHero {
            // Face-only close-up box (head without torso): face height should fill 20%-40% of frame height (ideal 28%)
            return SubjectFillSpec(minFill: 0.20, idealFill: 0.28, maxFill: 0.40, isWideContextual: false)
        }
        switch role {
        case .portrait:
            // Single person portrait: height fill 48%-84%, ideal 62%
            return SubjectFillSpec(minFill: 0.48, idealFill: 0.62, maxFill: 0.84, isWideContextual: false)
        case .environmentalPortrait:
            // Person in grand landscape/landmark: height fill 24%-58%, ideal 36%
            return SubjectFillSpec(minFill: 0.24, idealFill: 0.36, maxFill: 0.58, isWideContextual: false)
        case .group:
            // Multi-person group: union span 46%-84%, ideal 62%
            return SubjectFillSpec(minFill: 0.46, idealFill: 0.62, maxFill: 0.84, isWideContextual: false)
        case .animal:
            // Pet / wildlife: max(w, h) span 32%-78%, ideal 48%
            return SubjectFillSpec(minFill: 0.32, idealFill: 0.48, maxFill: 0.78, isWideContextual: false)
        case .flower:
            // Blossom / botanical close-up: effective span 34%-76%, ideal 46%
            return SubjectFillSpec(minFill: 0.34, idealFill: 0.46, maxFill: 0.76, isWideContextual: false)
        case .food:
            // Dish / drink / tabletop: effective span 38%-78%, ideal 48%
            return SubjectFillSpec(minFill: 0.38, idealFill: 0.48, maxFill: 0.78, isWideContextual: false)
        case .object, .vehicle:
            if isMinimalist {
                return SubjectFillSpec(minFill: 0.25, idealFill: 0.36, maxFill: 0.72, isWideContextual: false)
            }
            // Small/foreground object or vehicle: effective span 34%-78%, ideal 46%
            return SubjectFillSpec(minFill: 0.34, idealFill: 0.46, maxFill: 0.78, isWideContextual: false)
        case .architecture:
            return SubjectFillSpec(minFill: 0.44, idealFill: 0.66, maxFill: 0.88, isWideContextual: false)
        case .street:
            return SubjectFillSpec(minFill: 0.40, idealFill: 0.58, maxFill: 0.86, isWideContextual: true)
        case .foliage, .aperture, .indoorRoom, .skyLandscape, .scene:
            return SubjectFillSpec(minFill: 0.50, idealFill: 0.75, maxFill: 0.96, isWideContextual: true)
        }
    }

    static func measureSubjectFill(
        box: CGRect,
        role: DirectorPhotographicRole,
        isFaceOnlyHero: Bool
    ) -> Double {
        let bw = max(0.012, Double(box.width))
        let bh = max(0.012, Double(box.height))
        let bArea = bw * bh
        if role == .portrait && isFaceOnlyHero {
            return bh
        }
        switch role {
        case .portrait, .environmentalPortrait:
            return max(bh, 0.75 * sqrt(bArea) + 0.35 * bw)
        case .group:
            return max(bw, bh * 0.86)
        case .animal:
            return max(bw, bh)
        case .flower, .food, .object, .vehicle, .architecture, .street:
            return 0.55 * max(bw, bh) + 0.45 * sqrt(bArea)
        case .foliage, .aperture, .indoorRoom, .skyLandscape, .scene:
            return max(bw, bh)
        }
    }

    private struct OpticalZoomSolution {
        let state: DirectorZoomState
        let recommendedZoom: CGFloat
        let idealZoomAfterPan: CGFloat
        let centerCropMaxZoom: CGFloat
        let requiresPanBeforeZoom: Bool
        let measuredFill: Double
        let spec: SubjectFillSpec
    }

    /// Exact center-crop visible frame around `(0.5, 0.5)` at `targetZoom` relative to `currentZoom`.
    static func centerCropFrame(currentZoom: CGFloat, targetZoom: CGFloat) -> CGRect {
        let cur = max(0.5, Double(currentZoom))
        let tgt = max(0.5, Double(targetZoom))
        if tgt > cur + 0.01 {
            let rel = tgt / cur
            let span = min(1.0, 1.0 / rel)
            let origin = 0.5 - span * 0.5
            return CGRect(x: origin, y: origin, width: span, height: span)
        } else if tgt < cur - 0.01 {
            let rel = tgt / cur
            let span = 1.0 / max(0.25, rel)
            let origin = 0.5 - span * 0.5
            return CGRect(x: origin, y: origin, width: span, height: span)
        }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Computes exact maximum zoom around `(0.5, 0.5)` that keeps `subjectBox + margin` inside `[0, 1]^2`.
    static func computeCenterCropMaxZoom(
        subjectBox: CGRect,
        currentZoom: CGFloat,
        qualityCeiling: CGFloat,
        margin: Double = centerCropSafetyMargin
    ) -> CGFloat {
        let dLeft = 0.5 - Double(subjectBox.minX)
        let dRight = Double(subjectBox.maxX) - 0.5
        let dTop = 0.5 - Double(subjectBox.minY)
        let dBot = Double(subjectBox.maxY) - 0.5
        let dEdge = max(0.05, max(dLeft, max(dRight, max(dTop, dBot))))
        let maxRel = (0.5 - margin) / dEdge
        if maxRel <= 1.0 {
            return currentZoom
        }
        let rawMax = Double(currentZoom) * maxRel
        // Floor to 0.1x so rounded zoom NEVER exceeds the exact geometric boundary by even 0.01x
        let floored = floor(rawMax * 10.0 + 1e-6) / 10.0
        return max(currentZoom, min(qualityCeiling, CGFloat(floored)))
    }

    private static func snapZoomToLensRungs(
        rawZoom: CGFloat,
        minZoom: CGFloat,
        maxAllowed: CGFloat,
        opticalSwitchovers: [CGFloat],
        mustNotExceedCeiling: Bool
    ) -> CGFloat {
        let clamped = max(minZoom, min(maxAllowed, rawZoom))
        let sortedOptical = opticalSwitchovers.filter { $0 >= minZoom - 0.02 && $0 <= maxAllowed + 0.01 }.sorted()
        // 1) Snap to physical optical switchover points (0.5x, 1.0x, 2.0x, 3.0x, 5.0x) within 10%
        for opt in sortedOptical {
            if mustNotExceedCeiling && opt > maxAllowed + 1e-4 { continue }
            if abs(clamped - opt) <= opt * 0.10 {
                return opt
            }
        }
        // 2) Snap to lossless sensor-crop prime focal lengths (1.2x = 28mm, 1.5x = 35mm) within 6%
        for prime in [CGFloat(1.2), 1.5, 2.0, 2.5, 3.0] {
            guard prime >= minZoom - 0.01 && prime <= maxAllowed + 1e-4 else { continue }
            if abs(clamped - prime) <= prime * 0.065 {
                return prime
            }
        }
        if mustNotExceedCeiling {
            let stepped = CGFloat(floor(Double(clamped) * 10.0 + 1e-6) / 10.0)
            return max(minZoom, min(maxAllowed, stepped))
        }
        let rounded = CGFloat((Double(clamped) * 10.0).rounded() / 10.0)
        return max(minZoom, min(maxAllowed, rounded))
    }

    private static func solveOpticalZoom(
        heroBox: CGRect,
        role: DirectorPhotographicRole,
        isFaceOnlyHero: Bool,
        isMinimalist: Bool,
        noClearSubject: Bool,
        currentZoom: CGFloat,
        allowedZooms: [CGFloat]
    ) -> OpticalZoomSolution {
        let spec = fillSpec(for: role, isFaceOnlyHero: isFaceOnlyHero, isMinimalist: isMinimalist)
        let measured = measureSubjectFill(box: heroBox, role: role, isFaceOnlyHero: isFaceOnlyHero)
        let minHW = allowedZooms.min() ?? 1.0
        let maxHW = max(currentZoom, allowedZooms.max() ?? 4.0)
        let hasUltraWide = minHW <= 0.60
        let maxOptical = allowedZooms.filter { $0 <= 5.0 }.max() ?? 1.0
        // Digital zoom quality ceiling: never recommend mushy extreme digital zoom
        let qualityCeiling = min(maxHW, max(2.4, maxOptical * 1.35))

        let bw = Double(heroBox.width)
        let bh = Double(heroBox.height)
        let bArea = bw * bh
        let edgeTouches =
            (heroBox.minX <= 0.014 ? 1 : 0) +
            (heroBox.maxX >= 0.986 ? 1 : 0) +
            (heroBox.minY <= 0.014 ? 1 : 0) +
            (heroBox.maxY >= 0.986 ? 1 : 0)

        let topFaceClipped = (role == .portrait || role == .group) && (
            (heroBox.minY <= 0.015 && (bArea >= 0.45 || bh >= 0.64)) ||
            (isFaceOnlyHero && bh > 0.40) ||
            (isFaceOnlyHero && heroBox.minY <= 0.025 && bh >= 0.32)
        )
        let archCramped = (role == .architecture || role == .indoorRoom) &&
            ((heroBox.minY <= 0.015 && heroBox.maxY >= 0.985 && bw >= 0.72) || (bw >= 0.86 && bh >= 0.84))
        let groupCramped = role == .group && ((edgeTouches >= 2 && bArea >= 0.46) || bw >= 0.84)
        let oppositeClipped = ((heroBox.minX <= 0.012 && heroBox.maxX >= 0.988) ||
                               (heroBox.minY <= 0.012 && heroBox.maxY >= 0.988 && role != .portrait)) &&
            max(bw, bh) >= 0.54
        let borderClippedSubject = !spec.isWideContextual && !noClearSubject && (
            ((heroBox.minX <= 0.010 || heroBox.maxX >= 0.990 || heroBox.minY <= 0.010) && measured >= spec.idealFill * 0.92 && max(bw, bh) >= 0.44) ||
            oppositeClipped
        )
        let isSeverelyCramped = topFaceClipped || archCramped || groupCramped || borderClippedSubject
        let isOversized = !spec.isWideContextual && !noClearSubject && measured > spec.maxFill
        let isZoomedInWideScene = currentZoom > 1.14 && (spec.isWideContextual || noClearSubject)

        // STATE 1: ZOOM OUT (subject too large, border-clipped, or zoomed-in wide landscape)
        if isSeverelyCramped || isOversized || isZoomedInWideScene {
            let targetOut: CGFloat
            if isZoomedInWideScene {
                targetOut = (isSeverelyCramped && hasUltraWide) ? 0.5 : max(1.0, minHW)
            } else if currentZoom > 1.14 {
                let scaleBack = CGFloat(spec.idealFill / max(0.30, measured))
                let rawOut = min(currentZoom - 0.20, currentZoom * scaleBack)
                let floorZoom: CGFloat = (isSeverelyCramped && hasUltraWide) ? 0.5 : max(1.0, minHW)
                targetOut = snapZoomToLensRungs(
                    rawZoom: max(floorZoom, rawOut),
                    minZoom: minHW,
                    maxAllowed: max(minHW, currentZoom - 0.15),
                    opticalSwitchovers: allowedZooms,
                    mustNotExceedCeiling: false
                )
            } else if hasUltraWide {
                targetOut = 0.5
            } else {
                targetOut = minHW
            }
            return OpticalZoomSolution(
                state: .zoomOut,
                recommendedZoom: targetOut,
                idealZoomAfterPan: targetOut,
                centerCropMaxZoom: targetOut,
                requiresPanBeforeZoom: false,
                measuredFill: measured,
                spec: spec
            )
        }

        // STATE 2: NO ZOOM NEEDED (wide scene, no clear subject, or already inside comfort band)
        if noClearSubject || spec.isWideContextual || measured >= spec.minFill {
            let cMax = computeCenterCropMaxZoom(subjectBox: heroBox, currentZoom: currentZoom, qualityCeiling: qualityCeiling)
            return OpticalZoomSolution(
                state: .noZoomNeeded,
                recommendedZoom: currentZoom,
                idealZoomAfterPan: currentZoom,
                centerCropMaxZoom: cMax,
                requiresPanBeforeZoom: false,
                measuredFill: measured,
                spec: spec
            )
        }

        // STATE 3: ZOOM IN (subject smaller than comfort band)
        let rawGain = min(3.5, spec.idealFill / max(0.05, measured))
        let rawIdeal = currentZoom * CGFloat(rawGain)
        let snappedIdeal = snapZoomToLensRungs(
            rawZoom: rawIdeal,
            minZoom: currentZoom,
            maxAllowed: qualityCeiling,
            opticalSwitchovers: allowedZooms,
            mustNotExceedCeiling: false
        )
        // Dead-band: suppress tiny <0.13x micro-zooms
        if snappedIdeal < currentZoom + 0.13 {
            let cMax = computeCenterCropMaxZoom(subjectBox: heroBox, currentZoom: currentZoom, qualityCeiling: qualityCeiling)
            return OpticalZoomSolution(
                state: .noZoomNeeded,
                recommendedZoom: currentZoom,
                idealZoomAfterPan: currentZoom,
                centerCropMaxZoom: cMax,
                requiresPanBeforeZoom: false,
                measuredFill: measured,
                spec: spec
            )
        }

        // Enforce strict hardware center-crop geometry around (0.5, 0.5): heroBox + margin MUST stay inside [0, 1]^2
        let centerMax = computeCenterCropMaxZoom(
            subjectBox: heroBox,
            currentZoom: currentZoom,
            qualityCeiling: qualityCeiling
        )
        let cappedRaw = min(snappedIdeal, centerMax)
        let immediateZoom: CGFloat
        if cappedRaw < currentZoom + 0.12 {
            immediateZoom = currentZoom
        } else {
            immediateZoom = snapZoomToLensRungs(
                rawZoom: cappedRaw,
                minZoom: currentZoom,
                maxAllowed: centerMax,
                opticalSwitchovers: allowedZooms,
                mustNotExceedCeiling: true
            )
        }
        let panLimited = snappedIdeal > immediateZoom + 0.15
        return OpticalZoomSolution(
            state: .zoomIn,
            recommendedZoom: immediateZoom,
            idealZoomAfterPan: snappedIdeal,
            centerCropMaxZoom: centerMax,
            requiresPanBeforeZoom: panLimited,
            measuredFill: measured,
            spec: spec
        )
    }

    /// Main entry point: fuses multi-model evidence and solves the optimal 3D camera target & optical zoom.
    static func direct(
        detections: [DirectorDetection],
        raster: CompositionRaster,
        sceneHints: CompositionSceneHints,
        semanticAffinities: [String: Double],
        neuralProposals: [CompositionProposal],
        gaicProposals: [CompositionProposal] = [],
        incidentalBounds: [CGRect] = [],
        calibration: TrackingCalibration,
        pose: simd_quatd,
        currentZoom: CGFloat,
        allowedZooms: [CGFloat],
        portraitBounds: CGRect? = nil,
        poseProfile: AnatomicalPoseProfile? = nil,
        enableTemporalHysteresis: Bool = false
    ) -> DirectorDecision {
        let now = ProcessInfo.processInfo.systemUptime
        let safeZoom = max(0.5, currentZoom)
        let safePose = simd_length(pose.vector) > 1e-6 ? simd_normalize(pose) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

        // 1. Fuse masks with semantic detections & deduplicate across YOLO12s + OpenWorldPhotoYOLOE + Foreground Mask
        let fused = deduplicate(detections)
        let faceDets = fused.filter { $0.domain == .face && $0.confidence >= 0.20 }

        // 2. Fuse dense 256-box GAIC + evaluated SAMP/Charm neural proposals
        let combinedProposals = gaicProposals.isEmpty ? neuralProposals : (gaicProposals + neuralProposals)
        let neuralField = summarizeNeuralProposals(combinedProposals, fallbackBaseZoom: Double(safeZoom))
        let siglipScene = topSiglipScene(semanticAffinities)
        let horizonInfo = estimateHorizonAndRichness(detections: fused, raster: raster, sceneHints: sceneHints, affinities: semanticAffinities)
        let hasWideNatureDet = fused.contains {
            ($0.domain == .wideNature || wideNatureTokens.contains($0.label.lowercased())) && $0.confidence >= 0.18
        }
        let strongWideNature = fused.filter {
            $0.domain == .wideNature && $0.confidence >= 0.34 && $0.area >= 0.12
        }
        let strongArchitecture = fused.filter {
            $0.domain == .architecture && $0.confidence >= 0.28 && $0.area >= 0.14
        }
        let pureFlowerDets = fused.filter { $0.domain == .pureFlower && $0.confidence >= 0.16 }
        let sigHumanAffinity = max(
            semanticAffinities["person"] ?? 0.0,
            max(semanticAffinities["portrait_closeup"] ?? 0.0,
                max(semanticAffinities["portrait_fullbody"] ?? 0.0,
                    max(semanticAffinities["group"] ?? 0.0, semanticAffinities["person_scenery"] ?? 0.0)))
        )

        // 3. Composite Hero Scoring (confidence * area^0.42 * centerProximity * category * depth * neuralAttention * temporal)
        var fgCandidates: [RankedCandidate] = []
        fgCandidates.reserveCapacity(fused.count + 4)
        for d in fused {
            if d.isAttentionOnly { continue }
            if d.domain == .backgroundSurface || d.domain == .wideNature { continue }
            let lower = d.label.lowercased()
            if lower == "table" || lower == "dining table" || lower == "bàn ăn" { continue }
            let area = d.area
            // Keep both small distant subjects (>=0.08% area) AND large border-clipped subjects (<=99.5% area)
            if area < 0.0008 || area > 0.995 { continue }
            if d.domain == .foregroundMask && (isBottomStrip(d.boundingBox, center: d.center) || isSideWall(d.boundingBox)) {
                continue
            }

            let c = d.center
            let dAim = hypot(Double(c.x) - 0.50, Double(c.y) - 0.48)
            let aimW = 0.68 + 0.52 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
            let dep = meanDepth(in: d.boundingBox, raster: raster)
            let depW = 0.65 + 0.70 * dep

            let hasFace: Bool = {
                if d.domain == .face { return true }
                guard d.domain == .human else { return false }
                if !d.faceBounds.isEmpty { return true }
                return faceDets.contains { f in
                    let fc = f.center
                    return fc.x >= d.boundingBox.minX - 0.03 &&
                        fc.x <= d.boundingBox.maxX + 0.03 &&
                        fc.y >= d.boundingBox.minY - 0.05 &&
                        fc.y <= d.boundingBox.minY + 0.48 * d.boundingBox.height
                }
            }()

            let touchesLR = d.boundingBox.minX <= 0.02 || d.boundingBox.maxX >= 0.98
            let touchesTB = d.boundingBox.minY <= 0.02 || d.boundingBox.maxY >= 0.98
            let isCornerHeadless = (d.domain == .human && touchesLR && touchesTB && !hasFace && area < 0.16 && dAim > 0.32)
            let edgeSliver = isEdgeSliver(d.boundingBox, domain: d.domain, hasFace: hasFace)

            // Hand-held object detection: headless hand overlapping a high-confidence held object yields to the object
            let isHandHoldingObject: Bool = {
                guard d.domain == .human && !hasFace && sigHumanAffinity < 0.030 else { return false }
                return fused.contains { other in
                    (other.domain == .food || other.domain == .object || other.domain == .pureFlower) &&
                    other.confidence >= 0.62 &&
                    rectContainment(other.boundingBox, inside: d.boundingBox) >= 0.52
                }
            }()

            let isPlantConfusableFood: Bool = {
                guard plantConfusableFoodTokens.contains(lower) else { return false }
                let overlapsFlora = pureFlowerDets.contains { fl in
                    rectIoU(d.boundingBox, fl.boundingBox) > 0.22 || rectContainment(fl.boundingBox, inside: d.boundingBox) > 0.45
                }
                return overlapsFlora || siglipScene == "flower" || siglipScene == "foliage"
            }()

            let catW: Double
            if isCornerHeadless || isHandHoldingObject || isPlantConfusableFood {
                catW = 0.18
            } else {
                switch d.domain {
                case .human: catW = hasFace ? 1.55 : 1.28
                case .face: catW = 1.46
                case .animal: catW = 1.34
                case .pureFlower: catW = 1.24
                case .food: catW = 1.18
                case .vehicle, .object: catW = 1.10
                case .architecture: catW = 1.08
                case .foregroundMask: catW = 0.94
                case .pottedPlant, .furniture: catW = 0.82
                case .wideNature, .backgroundSurface: catW = 0.50
                }
            }

            let isPeripheralClipped = peripheralEquipmentTokens.contains(lower) &&
                (touchesLR || touchesTB) && dAim > 0.18
            var clipW = isPeripheralClipped ? 0.45 : 1.0
            if edgeSliver { clipW *= 0.16 }

            var extraW = enableTemporalHysteresis ? DirectorTemporalState.shared.heroBonus(for: d, now: now) : 1.0
            if neuralField.hasLearnedScores {
                let dGaic = hypot(Double(c.x) - Double(neuralField.attentionCenter.x),
                                  Double(c.y) - Double(neuralField.attentionCenter.y))
                extraW *= (0.88 + 0.26 * exp(-(dGaic * dGaic) / (2.0 * 0.26 * 0.26)))
            }
            if d.domain == .human && !hasFace && d.confidence < 0.44 &&
                (sigHumanAffinity < 0.018 && Double(d.boundingBox.height) < Double(d.boundingBox.width) * 0.82) {
                extraW *= 0.40
            }
            if d.confidence < 0.40 && (d.domain == .object || d.domain == .furniture) &&
                (siglipScene == "animal" || siglipScene == "flower" || siglipScene == "foliage") {
                extraW *= 0.45
            }

            let confTerm = pow(max(0.05, d.confidence), 0.85)
            let areaTerm = min(0.86, max(0.09, pow(area, 0.42)))
            let score = confTerm * areaTerm * aimW * depW * catW * clipW * extraW
            fgCandidates.append(RankedCandidate(
                det: d, depth: dep, dAim: dAim, hasFace: hasFace,
                isCornerHeadless: isCornerHeadless || isHandHoldingObject,
                isEdgeSliver: edgeSliver,
                isSuppressedFood: isPlantConfusableFood,
                heroScore: score
            ))
        }

        // Supplement with crisp depth + edge + chromatic/saliency foreground clusters for unlabeled subjects
        let sharpClusters = extractSharpForegroundClusters(raster: raster)
        for cl in sharpClusters.prefix(3) {
            if isSideWall(cl.bounds) || isEdgeSliver(cl.bounds, domain: .foregroundMask, hasFace: false) { continue }
            let overlapsExisting = fgCandidates.contains { existing in
                rectContainment(cl.bounds, inside: existing.det.boundingBox) > 0.42
            }
            if !overlapsExisting {
                let dAim = hypot(Double(cl.center.x) - 0.50, Double(cl.center.y) - 0.48)
                let conf = min(0.84, 0.46 + 0.20 * cl.meanDepth + 0.18 * cl.meanSharpness + 0.18 * cl.meanContrast)
                let det = DirectorDetection(
                    label: "foreground_sharp_object",
                    localizedLabel: "Chủ thể nổi bật",
                    boundingBox: cl.bounds,
                    anchor: cl.center,
                    confidence: conf,
                    domain: .foregroundMask
                )
                let aimW = 0.68 + 0.50 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
                let depW = 0.65 + 0.65 * cl.meanDepth
                let attW: Double
                if neuralField.hasLearnedScores {
                    let dGaic = hypot(Double(cl.center.x) - Double(neuralField.attentionCenter.x),
                                      Double(cl.center.y) - Double(neuralField.attentionCenter.y))
                    attW = 0.86 + 0.28 * exp(-(dGaic * dGaic) / (2.0 * 0.25 * 0.25))
                } else {
                    attW = 1.0
                }
                let areaTerm = min(0.82, max(0.10, pow(cl.area, 0.42)))
                let sc = pow(conf, 0.85) * areaTerm * aimW * depW * 0.90 * attW
                fgCandidates.append(RankedCandidate(
                    det: det, depth: cl.meanDepth, dAim: dAim, hasFace: false,
                    isCornerHeadless: false, isEdgeSliver: false, isSuppressedFood: false, heroScore: sc
                ))
            }
        }
        fgCandidates.sort { $0.heroScore > $1.heroScore }

        // 4. Identify people (including distant full-body >= 0.18% area!), animals, objects, ensembles, and scenes
        let validPeople = fgCandidates.filter {
            ($0.det.domain == .human || $0.det.domain == .face) &&
            $0.det.confidence >= ($0.hasFace ? 0.24 : 0.34) &&
            $0.det.area >= ($0.hasFace ? 0.0010 : 0.0018) &&
            !$0.isCornerHeadless && !$0.isEdgeSliver
        }
        let validAnimals = fgCandidates.filter {
            $0.det.domain == .animal && !$0.isEdgeSliver && $0.det.confidence >= 0.20
        }
        let namedNonPerson = fgCandidates.filter {
            $0.det.domain != .human && $0.det.domain != .face &&
            $0.det.domain != .architecture && $0.det.domain != .foregroundMask &&
            !$0.isEdgeSliver && !$0.isSuppressedFood &&
            $0.det.confidence >= 0.20
        }
        let maskInstances = fgCandidates.filter {
            $0.det.domain == .foregroundMask && !$0.isEdgeSliver && $0.det.area >= 0.005 && $0.det.area <= 0.78
        }
        let topNamed = namedNonPerson.first
        let topForegroundNonPerson = topNamed ?? maskInstances.first

        // Foreground-object vs tiny background bystander arbitration (never overrides genuine distant solo portrait or clear group!)
        let bystanderOverridden: Bool = {
            guard let p0 = validPeople.first, let obj = topForegroundNonPerson else { return false }
            let isClearGroup = validPeople.count >= 2 &&
                validPeople[0].det.confidence >= 0.65 &&
                validPeople[1].det.confidence >= 0.58 &&
                validPeople[1].heroScore >= 0.35 * validPeople[0].heroScore
            guard !isClearGroup else { return false }
            if !p0.hasFace && p0.det.confidence < 0.62 && obj.heroScore > p0.heroScore * 1.35 { return true }
            return p0.det.area < 0.08 && obj.depth >= p0.depth + 0.14 && obj.dAim <= 0.26 &&
                obj.det.area >= p0.det.area * 1.6 && obj.heroScore >= p0.heroScore * 1.15
        }()

        // Cohesive tabletop / cluttered multi-object companion clustering
        var companionBoxes: [CGRect] = []
        if namedNonPerson.count >= 2 {
            let lead = namedNonPerson[0]
            for nxt in namedNonPerson.dropFirst().prefix(5) {
                let gapX = max(0.0, max(lead.det.boundingBox.minX, nxt.det.boundingBox.minX) - min(lead.det.boundingBox.maxX, nxt.det.boundingBox.maxX))
                let gapY = max(0.0, max(lead.det.boundingBox.minY, nxt.det.boundingBox.minY) - min(lead.det.boundingBox.maxY, nxt.det.boundingBox.maxY))
                if nxt.heroScore >= 0.42 * lead.heroScore && abs(nxt.depth - lead.depth) < 0.20 && gapX < 0.28 && gapY < 0.28 {
                    let tentative = ([lead.det.boundingBox] + companionBoxes + [nxt.det.boundingBox]).reduce(lead.det.boundingBox) { $0.union($1) }
                    if tentative.width <= 0.84 && tentative.height <= 0.80 {
                        companionBoxes.append(nxt.det.boundingBox)
                    }
                }
            }
        }

        let furnitureHits = fgCandidates.filter { $0.det.domain == .furniture && !$0.isEdgeSliver && $0.det.confidence >= 0.30 }
        let isIndoorRoomCue = siglipScene == "indoor_room" || sceneHints.role == .indoorRoom
        let isWholeIndoorRoom = isIndoorRoomCue &&
            (furnitureHits.count >= 2 || (furnitureHits.count == 1 && namedNonPerson.count == furnitureHits.count))
        let isFrameAperture = (semanticAffinities["frame_aperture"] ?? 0.0) > 0.034 &&
            (sceneHints.role == .apertureView || siglipScene == "aperture" || (namedNonPerson.isEmpty && isIndoorRoomCue))
        let dominantWideNature = !strongWideNature.isEmpty && validPeople.isEmpty && validAnimals.isEmpty && !fgCandidates.contains {
            ($0.det.domain == .pureFlower || $0.det.domain == .food) && $0.det.confidence >= 0.35 && !$0.isEdgeSliver
        }
        let dominantArchitecture = validPeople.isEmpty && validAnimals.isEmpty &&
            (!strongArchitecture.isEmpty || siglipScene == "architecture" || siglipScene == "street" ||
             sceneHints.role == .architecture || sceneHints.role == .streetLeading) &&
            (topNamed.map { $0.det.area < 0.12 && ($0.dAim > 0.22 || $0.isEdgeSliver) } ?? true)

        // 5. Intelligent Hero & Photographic Role Resolution
        var role: DirectorPhotographicRole = .object
        var heroDomain: DirectorSubjectDomain = .object
        var heroLabel = "subject"
        var heroLocalized = "Chủ thể nổi bật"
        var heroConf = 0.72
        var heroBox = CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.56)
        var heroAnchor = CGPoint(x: 0.50, y: 0.48)
        var heroGazeX = 0.0
        var protectedBoxes: [CGRect] = []
        var isFaceOnlyHero = false
        var portraitBustBox: CGRect? = nil
        var noClearSubject = false

        if !validPeople.isEmpty && !bystanderOverridden {
            if let explicitGroup = validPeople.first(where: { $0.det.isGroup }) {
                role = .group
                heroDomain = .human
                heroBox = explicitGroup.det.boundingBox
                let memberFaces = faceDets.filter { explicitGroup.det.boundingBox.insetBy(dx: -0.04, dy: -0.04).contains($0.center) }
                if !memberFaces.isEmpty {
                    let meanFaceY = memberFaces.map { Double($0.boundingBox.minY + 0.40 * $0.boundingBox.height) }.reduce(0.0, +) / Double(memberFaces.count)
                    heroAnchor = CGPoint(x: heroBox.midX, y: CGFloat(meanFaceY))
                } else {
                    heroAnchor = explicitGroup.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.24 * heroBox.height)
                }
                heroLabel = explicitGroup.det.label
                heroLocalized = explicitGroup.det.localizedLabel
                heroConf = explicitGroup.det.confidence
                protectedBoxes = (explicitGroup.det.companionBounds.isEmpty ? [heroBox] : explicitGroup.det.companionBounds) + memberFaces.map(\.boundingBox)
            } else if validPeople.count >= 2 && validPeople[1].heroScore >= 0.36 * validPeople[0].heroScore &&
                      abs(validPeople[0].depth - validPeople[1].depth) < 0.32 {
                let members = Array(validPeople.filter {
                    $0.heroScore >= 0.30 * validPeople[0].heroScore && abs($0.depth - validPeople[0].depth) < 0.35
                }.prefix(6))
                let box = unionRects(members.map(\.det.boundingBox))
                role = .group
                heroDomain = .human
                heroBox = box
                let memberFaces = faceDets.filter { box.insetBy(dx: -0.04, dy: -0.04).contains($0.center) }
                if !memberFaces.isEmpty {
                    let meanFaceY = memberFaces.map { Double($0.boundingBox.minY + 0.40 * $0.boundingBox.height) }.reduce(0.0, +) / Double(memberFaces.count)
                    heroAnchor = CGPoint(x: box.midX, y: CGFloat(meanFaceY))
                } else {
                    heroAnchor = CGPoint(x: box.midX, y: box.minY + 0.24 * box.height)
                }
                heroLabel = "group(\(members.count))"
                heroLocalized = "Nhóm \(members.count) người"
                heroConf = validPeople[0].det.confidence
                protectedBoxes = members.map(\.det.boundingBox) + memberFaces.map(\.boundingBox)
            } else {
                let p0 = validPeople[0]
                heroBox = p0.det.boundingBox
                heroDomain = p0.det.domain
                let matchingFace = faceDets.first(where: { f in
                    let fc = f.center
                    return fc.x >= heroBox.minX - 0.04 && fc.x <= heroBox.maxX + 0.04 &&
                        fc.y >= heroBox.minY - 0.05 && fc.y <= heroBox.minY + 0.52 * heroBox.height
                })
                let maxFaceH = max(
                    Double(p0.det.faceBounds.map(\.height).max() ?? 0),
                    Double(matchingFace?.boundingBox.height ?? 0)
                )
                isFaceOnlyHero = (p0.det.domain == .face) || (maxFaceH >= 0.44 * Double(heroBox.height))

                let hasGrandLandmark = !strongWideNature.isEmpty ||
                    strongArchitecture.contains { $0.confidence >= 0.42 && $0.area >= 0.24 }
                let scenicContext = !isFaceOnlyHero &&
                    (siglipScene == "landscape" || siglipScene == "sky_clouds" || siglipScene == "sunset" ||
                     siglipScene == "person_scenery" || (hasGrandLandmark && siglipScene == "landscape")) &&
                    sceneHints.avoid.maxAvoid < 0.48 &&
                    p0.det.area >= 0.035 && p0.det.area < 0.16
                role = scenicContext ? .environmentalPortrait : .portrait

                if let lEye = poseProfile?.leftEye, let rEye = poseProfile?.rightEye,
                   heroBox.insetBy(dx: -0.05, dy: -0.05).contains(lEye) {
                    heroAnchor = CGPoint(x: (lEye.x + rEye.x) * 0.5, y: (lEye.y + rEye.y) * 0.5)
                } else if let explicitAnchor = p0.det.anchor,
                          (isFaceOnlyHero || heroBox.height < 0.34 || explicitAnchor.y <= heroBox.minY + 0.36 * heroBox.height) {
                    heroAnchor = explicitAnchor
                } else if let mf = matchingFace {
                    heroAnchor = CGPoint(x: mf.boundingBox.midX,
                                         y: mf.boundingBox.minY + 0.40 * mf.boundingBox.height)
                } else if let nose = poseProfile?.nose, heroBox.insetBy(dx: -0.05, dy: -0.05).contains(nose) {
                    heroAnchor = nose
                } else if isFaceOnlyHero {
                    heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.minY + 0.40 * heroBox.height)
                } else {
                    heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.minY + 0.17 * heroBox.height)
                }
                heroGazeX = abs(p0.det.gazeX) >= 0.05 ? p0.det.gazeX : (matchingFace?.gazeX ?? 0.0)
                heroLabel = p0.det.label
                heroLocalized = p0.det.localizedLabel
                heroConf = p0.det.confidence

                let knownFaces = !p0.det.faceBounds.isEmpty ? p0.det.faceBounds : (matchingFace.map { [$0.boundingBox] } ?? [])
                if role == .portrait {
                    if let measuredBust = portraitBounds,
                       heroBox.insetBy(dx: -0.04, dy: -0.04).contains(measuredBust),
                       measuredBust.contains(heroAnchor) {
                        portraitBustBox = measuredBust
                    } else if let fBox = knownFaces.first, !isFaceOnlyHero {
                        let bustTop = max(0.0, min(heroBox.minY, fBox.minY - 0.18 * fBox.height))
                        let bustBottom = min(heroBox.maxY, max(fBox.maxY + 0.10, fBox.minY + 2.65 * fBox.height))
                        portraitBustBox = CGRect(x: heroBox.minX, y: bustTop, width: heroBox.width, height: max(0.14, bustBottom - bustTop))
                    } else if !isFaceOnlyHero && heroBox.height >= 0.48 {
                        portraitBustBox = CGRect(x: heroBox.minX, y: heroBox.minY, width: heroBox.width, height: heroBox.height * 0.58)
                    }
                    if let bust = portraitBustBox {
                        protectedBoxes = knownFaces + [bust]
                    } else {
                        protectedBoxes = knownFaces.isEmpty ? [heroBox] : (knownFaces + [heroBox])
                    }
                } else {
                    protectedBoxes = knownFaces.isEmpty ? [heroBox] : (knownFaces + [heroBox])
                }
            }
        } else if let a0 = validAnimals.first,
                  topNamed.map({ $0.det.domain == .animal || a0.heroScore >= $0.heroScore * 0.72 }) ?? true {
            // Multi-animal group support when two pets stand together
            if validAnimals.count >= 2 && validAnimals[1].heroScore >= 0.48 * a0.heroScore {
                let pets = Array(validAnimals.filter { $0.heroScore >= 0.42 * a0.heroScore }.prefix(4))
                let uBox = unionRects(pets.map(\.det.boundingBox))
                if uBox.width <= 0.86 && uBox.height <= 0.84 {
                    role = .animal
                    heroDomain = .animal
                    heroBox = uBox
                    heroAnchor = CGPoint(x: uBox.midX, y: uBox.minY + 0.36 * uBox.height)
                    heroLabel = "\(a0.det.label)+\(pets.count - 1)"
                    heroLocalized = "Nhóm \(a0.det.localizedLabel.lowercased())"
                    heroConf = a0.det.confidence
                    protectedBoxes = pets.map(\.det.boundingBox)
                } else {
                    role = .animal
                    heroDomain = .animal
                    heroBox = a0.det.boundingBox
                    heroAnchor = a0.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.30 * heroBox.height)
                    heroGazeX = a0.det.gazeX
                    heroLabel = a0.det.label
                    heroLocalized = a0.det.localizedLabel
                    heroConf = a0.det.confidence
                    protectedBoxes = [heroBox]
                }
            } else {
                role = .animal
                heroDomain = .animal
                heroBox = a0.det.boundingBox
                let gazeLeadShift = abs(a0.det.gazeX) >= 0.10 ? CGFloat(a0.det.gazeX) * heroBox.width * 0.14 : 0.0
                heroAnchor = a0.det.anchor ?? CGPoint(
                    x: min(heroBox.maxX - 0.02, max(heroBox.minX + 0.02, heroBox.midX + gazeLeadShift)),
                    y: heroBox.minY + 0.30 * heroBox.height
                )
                heroGazeX = a0.det.gazeX
                heroLabel = a0.det.label
                heroLocalized = a0.det.localizedLabel
                heroConf = a0.det.confidence
                protectedBoxes = [heroBox]
            }
        } else if isFrameAperture {
            role = .aperture
            heroDomain = .architecture
            heroBox = neuralField.bestBox
            heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
            heroLabel = "frame_aperture"
            heroLocalized = "Khung nhìn qua cửa"
            heroConf = 0.78
        } else if isWholeIndoorRoom {
            role = .indoorRoom
            heroDomain = .furniture
            let items = fgCandidates.filter {
                ($0.det.domain == .furniture || $0.det.domain == .pottedPlant) && !$0.isEdgeSliver && $0.det.confidence >= 0.30
            }.prefix(4)
            heroBox = items.count >= 2 ? unionRects(items.map(\.det.boundingBox)) : CGRect(x: 0.12, y: 0.15, width: 0.76, height: 0.70)
            heroAnchor = CGPoint(x: 0.50, y: 0.50)
            heroLabel = "indoor_room"
            heroLocalized = "Không gian nội thất"
            heroConf = 0.80
        } else if dominantWideNature,
                  let wn = strongWideNature.max(by: { $0.confidence * sqrt($0.area) < $1.confidence * sqrt($1.area) }) {
            let wnLower = wn.label.lowercased()
            heroDomain = .wideNature
            let hasSkyDet = fused.contains { skyTokens.contains($0.label.lowercased()) && $0.confidence >= 0.18 }
            if groundCoverTokens.contains(wnLower) && !hasSkyDet &&
                siglipScene != "sky_clouds" && siglipScene != "sunset" && siglipScene != "landscape" {
                role = .foliage
                heroBox = neuralField.attentionBox
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = wn.label
                heroLocalized = wn.localizedLabel
                heroConf = wn.confidence
            } else if scenicFeatureTokens.contains(wnLower) && horizonInfo.horizonY == nil {
                role = .scene
                heroBox = wn.boundingBox
                heroAnchor = wn.anchor ?? wn.center
                heroLabel = wn.label
                heroLocalized = wn.localizedLabel
                heroConf = wn.confidence
            } else {
                let hy = horizonInfo.horizonY ?? 0.48
                role = .skyLandscape
                heroBox = CGRect(x: 0.10, y: max(0.05, hy - 0.16), width: 0.80, height: min(0.90, 0.32))
                heroAnchor = CGPoint(x: 0.50, y: hy)
                heroLabel = wn.label
                heroLocalized = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? "Bầu trời & mây" : wn.localizedLabel
                heroConf = max(0.76, wn.confidence)
            }
        } else if dominantArchitecture {
            heroDomain = .architecture
            let archDets = fgCandidates.filter { $0.det.domain == .architecture && !$0.isEdgeSliver && $0.det.confidence >= 0.20 }
            role = (siglipScene == "street" || sceneHints.role == .streetLeading) ? .street : .architecture
            if archDets.count >= 2 {
                var box = unionRects(archDets.prefix(5).map(\.det.boundingBox))
                if let roofY = sceneHints.archRoofTopY ?? raster.structuralArchRoofTopY,
                   roofY > 0.04, roofY < Double(box.minY) {
                    let ny = CGFloat(max(0.03, roofY - 0.02))
                    box = CGRect(x: box.minX, y: ny, width: box.width, height: max(0.16, box.maxY - ny))
                }
                heroBox = box
                heroAnchor = CGPoint(x: box.midX, y: box.minY + 0.46 * box.height)
                heroLabel = "architecture(\(archDets.count))"
                heroLocalized = "Cụm kiến trúc"
                heroConf = archDets[0].det.confidence
                protectedBoxes = [box]
            } else if let a0 = archDets.first {
                var box = a0.det.boundingBox
                if let roofY = sceneHints.archRoofTopY ?? raster.structuralArchRoofTopY,
                   roofY > 0.04, roofY < Double(box.minY) {
                    let ny = CGFloat(max(0.03, roofY - 0.02))
                    box = CGRect(x: box.minX, y: ny, width: box.width, height: max(0.16, box.maxY - ny))
                }
                heroBox = box
                heroAnchor = CGPoint(x: box.midX, y: box.minY + 0.46 * box.height)
                heroLabel = a0.det.label
                heroLocalized = a0.det.localizedLabel
                heroConf = a0.det.confidence
                protectedBoxes = [box]
            } else if role == .street, let vp = sceneHints.refinedVanishingPoint ?? raster.measuredVanishingPoint.map({ VanishingPointHint(point: $0.point, confidence: $0.confidence) }) {
                heroBox = CGRect(x: max(0.08, vp.point.x - 0.30), y: max(0.10, vp.point.y - 0.24), width: 0.60, height: 0.52)
                heroAnchor = vp.point
                heroLabel = "street_vp"
                heroLocalized = "Đường dẫn phối cảnh"
                heroConf = max(0.68, vp.confidence)
            } else {
                heroBox = neuralField.attentionBox
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = role.rawValue
                heroLocalized = role == .street ? "Góc phố" : "Công trình kiến trúc"
                heroConf = 0.74
            }
        } else if let food0 = namedNonPerson.first, food0.det.domain == .food {
            role = .food
            heroDomain = .food
            if !companionBoxes.isEmpty {
                let allB = [food0.det.boundingBox] + companionBoxes
                heroBox = unionRects(allB)
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = "\(food0.det.label)+\(companionBoxes.count)"
                heroLocalized = "Cụm \(food0.det.localizedLabel.lowercased())"
                protectedBoxes = allB
            } else {
                heroBox = food0.det.boundingBox
                heroAnchor = food0.det.anchor ?? food0.det.center
                heroLabel = food0.det.label
                heroLocalized = food0.det.localizedLabel
                protectedBoxes = [heroBox]
            }
            heroConf = food0.det.confidence
        } else if let obj0 = topNamed,
                  obj0.det.domain != .furniture && obj0.det.domain != .pottedPlant &&
                  (obj0.dAim <= 0.42 || obj0.det.confidence >= 0.45 || obj0.det.domain == .pureFlower ||
                   (siglipScene != "flower" && siglipScene != "foliage" && siglipScene != "sky_clouds" && siglipScene != "sunset" && siglipScene != "landscape")) {
            role = obj0.det.domain == .animal ? .animal : (obj0.det.domain == .vehicle ? .vehicle : (obj0.det.domain == .pureFlower ? .flower : .object))
            heroDomain = obj0.det.domain
            if !companionBoxes.isEmpty && role == .object && (siglipScene == "object" || siglipScene == "indoor_room" || siglipScene == "food") {
                let allB = [obj0.det.boundingBox] + companionBoxes
                heroBox = unionRects(allB)
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = "\(obj0.det.label)+\(companionBoxes.count)"
                heroLocalized = "Cụm \(obj0.det.localizedLabel.lowercased())"
                protectedBoxes = allB
            } else {
                heroBox = obj0.det.boundingBox
                heroAnchor = obj0.det.anchor ?? obj0.det.center
                heroLabel = obj0.det.label
                heroLocalized = obj0.det.localizedLabel
                protectedBoxes = [heroBox]
            }
            heroConf = obj0.det.confidence
        } else if (fgCandidates.first?.det.domain == .pureFlower && !(fgCandidates.first?.isEdgeSliver ?? true) && (fgCandidates.first?.det.confidence ?? 0) >= 0.16) ||
                  siglipScene == "flower" || siglipScene == "foliage" {
            let explicitFlora = fgCandidates.first { $0.det.domain == .pureFlower && !$0.isEdgeSliver && $0.det.area < 0.78 }
            if let f = explicitFlora {
                role = .flower
                heroDomain = .pureFlower
                heroBox = f.det.boundingBox
                heroAnchor = f.det.anchor ?? f.det.center
                heroLabel = f.det.label
                heroLocalized = f.det.localizedLabel
                heroConf = f.det.confidence
            } else if let m0 = maskInstances.first(where: { !$0.isEdgeSliver }), m0.det.area >= 0.03 {
                role = siglipScene == "flower" ? .flower : .foliage
                heroDomain = .foregroundMask
                heroBox = m0.det.boundingBox
                heroAnchor = m0.det.anchor ?? m0.det.center
                heroLabel = role == .flower ? "flower_mask" : "foliage_mask"
                heroLocalized = role == .flower ? "Cụm hoa tiền cảnh" : "Tán lá thiên nhiên"
                heroConf = max(0.72, m0.det.confidence)
            } else {
                role = siglipScene == "flower" ? .flower : .foliage
                heroDomain = .wideNature
                heroBox = neuralField.attentionBox
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = role.rawValue
                heroLocalized = role == .flower ? "Cụm hoa nổi bật" : "Mảng xanh thiên nhiên"
                heroConf = 0.70
                if role == .foliage && explicitFlora == nil {
                    noClearSubject = false
                }
            }
            protectedBoxes = [heroBox]
        } else if siglipScene == "sky_clouds" || siglipScene == "sunset" || siglipScene == "landscape" ||
                  siglipScene == "person_scenery" || (hasWideNatureDet && horizonInfo.horizonY != nil) ||
                  sceneHints.role == .landscapeSky {
            let hy = horizonInfo.horizonY ?? 0.48
            role = .skyLandscape
            heroDomain = .wideNature
            heroBox = CGRect(x: 0.10, y: max(0.05, hy - 0.16), width: 0.80, height: min(0.90, 0.32))
            heroAnchor = CGPoint(x: 0.50, y: hy)
            heroLabel = "sky_landscape"
            heroLocalized = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? "Bầu trời & mây" : "Cảnh quan rộng"
            heroConf = 0.78
        } else if let obj0 = topForegroundNonPerson,
                  obj0.det.confidence >= 0.34 && obj0.heroScore >= 0.045 {
            role = obj0.det.domain == .vehicle ? .vehicle : .object
            heroDomain = obj0.det.domain
            heroBox = obj0.det.boundingBox
            heroAnchor = obj0.det.anchor ?? obj0.det.center
            heroLabel = obj0.det.label
            heroLocalized = obj0.det.localizedLabel
            heroConf = obj0.det.confidence
            protectedBoxes = [heroBox]
        } else {
            // Honest No-Clear-Subject fallback: do not hallucinate random corner crops or false zooms!
            role = .scene
            heroDomain = .wideNature
            noClearSubject = true
            heroBox = CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70)
            heroAnchor = CGPoint(x: 0.50, y: 0.50)
            heroLabel = "scene_ambient"
            heroLocalized = "Khung cảnh tổng thể"
            heroConf = 0.58
        }

        // 6. Solve 3-State Optical Zoom with Center-Crop Geometric Constraint
        let isMinimalist = (semanticAffinities["minimalist_space"] ?? 0.0) > 0.032 ||
            (semanticAffinities["single_product"] ?? 0.0) > 0.040
        let isWaterReflection = (semanticAffinities["water_reflection"] ?? 0.0) > 0.045

        let zoomSolution = solveOpticalZoom(
            heroBox: heroBox,
            role: role,
            isFaceOnlyHero: isFaceOnlyHero,
            isMinimalist: isMinimalist,
            noClearSubject: noClearSubject,
            currentZoom: safeZoom,
            allowedZooms: allowedZooms
        )
        let stabilizedZoom = enableTemporalHysteresis
            ? DirectorTemporalState.shared.stabilizeZoom(
                proposedZoom: zoomSolution.recommendedZoom,
                proposedState: zoomSolution.state,
                centerCropMax: zoomSolution.centerCropMaxZoom,
                now: now
            )
            : zoomSolution.recommendedZoom

        // Fast-return for No-Clear-Subject scenes: keep centered equilibrium (or zoom back out to 1.0x if zoomed in)
        if noClearSubject {
            let solved = solveAimAndCrop(
                anchor: heroAnchor,
                destG: CGPoint(x: 0.50, y: 0.50),
                relZoom: max(0.35, Double(stabilizedZoom / safeZoom)),
                calibration: calibration
            )
            let aimWorldRay = safePose.act(solved.aimDeviceRay)
            let zoomChanged = abs(stabilizedZoom - safeZoom) >= 0.10
            let expText = zoomChanged
                ? String(format: "Cảnh không có chủ thể tách biệt — lùi về %.1fx giữ toàn cảnh cân đối", stabilizedZoom)
                : "Cảnh không có chủ thể tách biệt rõ — giữ nguyên khung hình cân đối tự nhiên"
            return DirectorDecision(
                role: .scene,
                heroLabel: heroLabel,
                heroLocalizedLabel: heroLocalized,
                heroBounds: heroBox,
                heroAnchor: heroAnchor,
                destinationPoint: CGPoint(x: 0.50, y: 0.50),
                aimPointInSource: solved.aim,
                aimWorldRay: aimWorldRay,
                rotation: solved.rotation,
                recommendedZoom: stabilizedZoom,
                confidence: heroConf,
                usesCenter: true,
                preservesOriginalFrame: !zoomChanged,
                ruleName: DirectorCompositionStyle.keepNatural.rawValue,
                compositionStyle: .keepNatural,
                explanation: expText,
                detectedHorizonY: horizonInfo.horizonY,
                zoomState: zoomSolution.state,
                idealZoomAfterPan: zoomSolution.idealZoomAfterPan,
                centerCropMaxZoom: zoomSolution.centerCropMaxZoom,
                requiresPanBeforeZoom: false,
                centerCropVisibleFrame: centerCropFrame(currentZoom: safeZoom, targetZoom: stabilizedZoom),
                subjectFillMetric: zoomSolution.measuredFill,
                targetFillMetric: zoomSolution.spec.idealFill,
                allDetections: fused
            )
        }

        // Immediate Ultra-Wide / Zoom-Out execution when subject is cramped or oversized at 1x
        if zoomSolution.state == .zoomOut && stabilizedZoom < safeZoom - 0.10 && stabilizedZoom <= 0.65 {
            let destG = CGPoint(x: 0.50, y: (role == .portrait || role == .group) ? 0.42 : 0.50)
            let solved = solveAimAndCrop(
                anchor: heroAnchor,
                destG: destG,
                relZoom: max(0.35, Double(stabilizedZoom / safeZoom)),
                calibration: calibration
            )
            let aimWorldRay = safePose.act(solved.aimDeviceRay)
            let explanation = buildExplanation(
                role: role,
                localizedLabel: heroLocalized,
                destG: solved.actualDest,
                zoom: stabilizedZoom,
                currentZoom: safeZoom,
                style: .ultraWide,
                horizonY: horizonInfo.horizonY,
                zoomState: zoomSolution.state,
                requiresPanBeforeZoom: false,
                idealZoomAfterPan: zoomSolution.idealZoomAfterPan
            )
            if enableTemporalHysteresis {
                DirectorTemporalState.shared.commit(
                    heroBounds: heroBox, domain: heroDomain, anchor: heroAnchor,
                    dest: solved.actualDest, role: role, zoom: stabilizedZoom,
                    zoomState: zoomSolution.state, now: now
                )
            }
            return DirectorDecision(
                role: role,
                heroLabel: heroLabel,
                heroLocalizedLabel: heroLocalized,
                heroBounds: heroBox,
                heroAnchor: heroAnchor,
                destinationPoint: solved.actualDest,
                aimPointInSource: solved.aim,
                aimWorldRay: aimWorldRay,
                rotation: solved.rotation,
                recommendedZoom: stabilizedZoom,
                confidence: max(0.45, min(0.98, heroConf)),
                usesCenter: true,
                preservesOriginalFrame: false,
                ruleName: DirectorCompositionStyle.ultraWide.rawValue,
                compositionStyle: .ultraWide,
                explanation: explanation,
                detectedHorizonY: horizonInfo.horizonY,
                zoomState: zoomSolution.state,
                idealZoomAfterPan: zoomSolution.idealZoomAfterPan,
                centerCropMaxZoom: zoomSolution.centerCropMaxZoom,
                requiresPanBeforeZoom: false,
                centerCropVisibleFrame: centerCropFrame(currentZoom: safeZoom, targetZoom: stabilizedZoom),
                subjectFillMetric: zoomSolution.measuredFill,
                targetFillMetric: zoomSolution.spec.idealFill,
                allDetections: fused
            )
        }

        // 7. Build Zoom Rungs strictly faithful to the 3-State Zoom Solution & Center-Crop Constraint
        let bw = max(0.015, Double(heroBox.width))
        let bh = max(0.015, Double(heroBox.height))
        let minHardwareZoom = allowedZooms.min() ?? 1.0
        let maxHardwareZoom = max(safeZoom, allowedZooms.max() ?? 4.0)

        var zoomRungs: [CGFloat] = []
        func appendZoomRung(_ candidateZoom: CGFloat) {
            guard candidateZoom.isFinite,
                  candidateZoom >= min(0.5, minHardwareZoom) - 0.02,
                  candidateZoom <= max(safeZoom, maxHardwareZoom) + 0.02 else { return }
            if zoomSolution.state == .zoomIn && candidateZoom > zoomSolution.centerCropMaxZoom + 1e-4 {
                return
            }
            if !zoomRungs.contains(where: { abs($0 - candidateZoom) < 0.04 }) {
                zoomRungs.append(candidateZoom)
            }
        }

        appendZoomRung(stabilizedZoom)
        if zoomSolution.state == .zoomIn && stabilizedZoom > safeZoom + 0.12 {
            // Only evaluate valid zoomed rungs near stabilizedZoom (never let 1x steal a required optical zoom!)
            for opt in [CGFloat(1.2), 1.5, 2.0, 2.5, 3.0, 4.0] + allowedZooms {
                if opt >= max(safeZoom + 0.14, stabilizedZoom * 0.86) &&
                   opt <= min(zoomSolution.centerCropMaxZoom, stabilizedZoom * 1.12) {
                    appendZoomRung(opt)
                }
            }
        }
        if zoomRungs.isEmpty {
            zoomRungs.append(safeZoom)
        }

        // Adjust sky landscape anchor ONLY if a genuine localized sun/moon disk exists (never overcast cloud corners)
        var effectiveAnchor = heroAnchor
        if role == .skyLandscape, let hy = horizonInfo.horizonY,
           let sunX = brightSkyAccentX(horizonY: hy, raster: raster, detections: fused) {
            effectiveAnchor = CGPoint(x: sunX, y: hy)
        }

        let sensorAspect = calibration.aspect.isFinite && calibration.aspect > 0.1 ? calibration.aspect : 0.75
        let isPortraitSensor = sensorAspect < 0.88
        let isSquareSensor = sensorAspect >= 0.88 && sensorAspect <= 1.12

        var candidates: [FramingCandidate] = []
        if zoomSolution.state == .noZoomNeeded && !zoomSolution.requiresPanBeforeZoom {
            candidates.append(FramingCandidate(
                destG: effectiveAnchor, zoom: safeZoom, style: .keepNatural,
                aim: CGPoint(x: 0.5, y: 0.5), rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                futureCalib: calibration, cropBox: CGRect(x: 0, y: 0, width: 1, height: 1), isBaseline: true
            ))
        }

        for z in zoomRungs {
            let relZ = max(0.35, Double(z / safeZoom))
            // When off-center subject needs pan-before-zoom, size destination style targets for the post-pan ideal zoom
            // so the user pans the subject straight into a comfortable post-pan framing zone!
            let sizingRelZ = zoomSolution.requiresPanBeforeZoom
                ? max(relZ, Double(zoomSolution.idealZoomAfterPan / safeZoom))
                : relZ
            let projW = bw * sizingRelZ
            let projH = bh * sizingRelZ

            var styleDests: [(CGPoint, DirectorCompositionStyle)] = []
            switch role {
            case .skyLandscape:
                let accentX: Double = (effectiveAnchor.x != 0.50) ? (effectiveAnchor.x < 0.50 ? 0.382 : 0.618) : 0.50
                if isWaterReflection {
                    styleDests.append((CGPoint(x: 0.50, y: 0.50), .mirrorHorizon))
                }
                styleDests.append((CGPoint(x: accentX, y: 0.667), .lowHorizonSky))
                styleDests.append((CGPoint(x: accentX, y: 0.333), .highHorizonGround))
                styleDests.append((CGPoint(x: 0.50, y: 0.58), .ruleOfThirds))

            case .aperture:
                styleDests.append((CGPoint(x: 0.50, y: 0.50), .frameInFrame))
                styleDests.append((CGPoint(x: 0.50, y: 0.46), .frameInFrame))

            case .indoorRoom:
                styleDests.append((CGPoint(x: 0.50, y: 0.50), .symmetry))

            default:
                // 1) Learned Neural Optimum from 256-box GAIC + SAMP/Charm (only when pan-before-zoom is not required)
                if !zoomSolution.requiresPanBeforeZoom, let neuralPeak = neuralField.peakBox(nearRelativeZoom: relZ) {
                    let gx = max(0.28, min(0.72, (Double(effectiveAnchor.x) - Double(neuralPeak.minX)) / max(0.05, Double(neuralPeak.width))))
                    let gy = max(0.28, min(0.72, (Double(effectiveAnchor.y) - Double(neuralPeak.minY)) / max(0.05, Double(neuralPeak.height))))
                    styleDests.append((CGPoint(x: gx, y: gy), .neuralFreeform))
                }

                // 2) Center Hero / Symmetry + Safe Portrait Eye-Line
                let headToEye = max(0.04, Double(effectiveAnchor.y - heroBox.minY) * sizingRelZ)
                let minPortraitY: Double = isFaceOnlyHero ? 0.36 : ((role == .portrait && isPortraitSensor) ? 0.33 : (role == .portrait ? 0.34 : 0.37))
                let portraitSafeY = min(0.45, max(minPortraitY, 0.07 + headToEye))
                let centerY: Double = (role == .portrait || role == .environmentalPortrait || role == .group)
                    ? portraitSafeY
                    : ((role == .flower || role == .animal) ? 0.46 : 0.50)
                styleDests.append((CGPoint(x: 0.50, y: centerY), (role == .architecture ? .symmetry : .centerFocus)))

                if zoomSolution.requiresPanBeforeZoom {
                    // When panning before zoom, prioritize destinations close enough to center that idealZoomAfterPan fits cleanly!
                    let maxOffCenterAfterPan = max(0.0, 0.46 - 0.5 * projW)
                    if maxOffCenterAfterPan >= 0.09 {
                        let offX = min(0.118, maxOffCenterAfterPan)
                        let panStyle: DirectorCompositionStyle = abs(heroGazeX) >= 0.14 ? .lookingRoom : .goldenRatio
                        styleDests.append((CGPoint(x: 0.50 - offX, y: centerY), panStyle))
                        styleDests.append((CGPoint(x: 0.50 + offX, y: centerY), panStyle))
                    }
                } else {
                    if projH >= 0.80 {
                        styleDests.append((CGPoint(x: 0.50, y: Double(effectiveAnchor.y)), .centerFocus))
                    }
                    if projW >= 0.80 {
                        styleDests.append((CGPoint(x: Double(effectiveAnchor.x), y: centerY), .centerFocus))
                    }

                    let gazeActive = abs(heroGazeX) >= 0.14
                    let thirdStyle: DirectorCompositionStyle = gazeActive ? .lookingRoom : .ruleOfThirds
                    let goldenStyle: DirectorCompositionStyle = gazeActive ? .lookingRoom : .goldenRatio
                    let isDynamicRole = (role == .object || role == .food || role == .flower ||
                        role == .animal || role == .vehicle || role == .foliage)
                    let allowSubtleNudge = projW >= 0.40 || sceneHints.avoid.maxAvoid >= 0.28

                    if isPortraitSensor {
                        if role != .portrait && role != .environmentalPortrait && role != .group {
                            styleDests.append((CGPoint(x: 0.50, y: 0.41), .elevatedCenter))
                            styleDests.append((CGPoint(x: 0.50, y: 0.58), .groundedCenter))
                            if projH < 0.48 {
                                styleDests.append((CGPoint(x: 0.50, y: 0.62), .openHeadroom))
                            }
                        }
                        let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                        if allowSubtleNudge {
                            styleDests.append((CGPoint(x: 0.435, y: subtleY), .subtleBalance))
                            styleDests.append((CGPoint(x: 0.565, y: subtleY), .subtleBalance))
                        }
                        if projW < 0.58 || gazeActive {
                            styleDests.append((CGPoint(x: 0.382, y: subtleY), goldenStyle))
                            styleDests.append((CGPoint(x: 0.618, y: subtleY), goldenStyle))
                            styleDests.append((CGPoint(x: 0.333, y: subtleY), thirdStyle))
                            styleDests.append((CGPoint(x: 0.667, y: subtleY), thirdStyle))
                        }
                        if isDynamicRole && projW < 0.56 && projH < 0.58 {
                            styleDests.append((CGPoint(x: 0.382, y: 0.39), .diagonalDynamic))
                            styleDests.append((CGPoint(x: 0.618, y: 0.58), .diagonalDynamic))
                        }
                    } else if isSquareSensor {
                        if role != .portrait && role != .environmentalPortrait && role != .group {
                            styleDests.append((CGPoint(x: 0.50, y: 0.43), .elevatedCenter))
                            styleDests.append((CGPoint(x: 0.50, y: 0.56), .groundedCenter))
                        }
                        let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                        if allowSubtleNudge {
                            styleDests.append((CGPoint(x: 0.43, y: subtleY), .subtleBalance))
                            styleDests.append((CGPoint(x: 0.57, y: subtleY), .subtleBalance))
                        }
                        if projW < 0.58 || gazeActive {
                            styleDests.append((CGPoint(x: 0.382, y: subtleY), goldenStyle))
                            styleDests.append((CGPoint(x: 0.618, y: subtleY), goldenStyle))
                        }
                        if isDynamicRole && projW < 0.56 && projH < 0.56 {
                            styleDests.append((CGPoint(x: 0.382, y: 0.39), .diagonalDynamic))
                            styleDests.append((CGPoint(x: 0.618, y: 0.58), .diagonalDynamic))
                        }
                    } else {
                        if role != .portrait && role != .environmentalPortrait && role != .group {
                            styleDests.append((CGPoint(x: 0.50, y: 0.44), .elevatedCenter))
                            styleDests.append((CGPoint(x: 0.50, y: 0.55), .groundedCenter))
                        }
                        let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                        if allowSubtleNudge {
                            styleDests.append((CGPoint(x: 0.435, y: subtleY), .subtleBalance))
                            styleDests.append((CGPoint(x: 0.565, y: subtleY), .subtleBalance))
                        }
                        let thirdY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.45
                        styleDests.append((CGPoint(x: 0.382, y: thirdY), goldenStyle))
                        styleDests.append((CGPoint(x: 0.618, y: thirdY), goldenStyle))
                        styleDests.append((CGPoint(x: 0.333, y: thirdY), thirdStyle))
                        styleDests.append((CGPoint(x: 0.667, y: thirdY), thirdStyle))
                        if projW < 0.50 && projH < 0.64 {
                            styleDests.append((CGPoint(x: 0.333, y: 0.46), .negativeSpace))
                            styleDests.append((CGPoint(x: 0.667, y: 0.46), .negativeSpace))
                        }
                        if isDynamicRole && projW < 0.54 && projH < 0.56 {
                            styleDests.append((CGPoint(x: 0.382, y: 0.39), .diagonalDynamic))
                            styleDests.append((CGPoint(x: 0.618, y: 0.58), .diagonalDynamic))
                        }
                    }

                    if (role == .street || role == .architecture),
                       let vp = sceneHints.refinedVanishingPoint ?? raster.measuredVanishingPoint.map({ VanishingPointHint(point: $0.point, confidence: $0.confidence) }),
                       vp.confidence >= 0.30 {
                        let vpY = max(0.32, min(0.58, Double(vp.point.y)))
                        styleDests.append((CGPoint(x: 0.50, y: vpY), .leadingLines))
                    }
                }
            }

            for (rawDest, style) in styleDests {
                var gx = Double(rawDest.x)
                var gy = Double(rawDest.y)
                if role != .skyLandscape && role != .architecture && role != .street && role != .scene && role != .aperture && role != .indoorRoom {
                    let halfW = 0.5 * bw * relZ
                    let halfH = 0.5 * bh * relZ
                    if halfW < 0.44 { gx = max(0.05 + halfW, min(0.95 - halfW, gx)) } else { gx = 0.50 }
                    if role != .portrait && role != .environmentalPortrait {
                        if halfH < 0.44 { gy = max(0.05 + halfH, min(0.95 - halfH, gy)) } else { gy = 0.50 }
                    }
                }
                let dest = CGPoint(x: gx, y: gy)
                let solved = solveAimAndCrop(anchor: effectiveAnchor, destG: dest, relZoom: relZ, calibration: calibration)
                let clampDrift = hypot(Double(solved.actualDest.x - dest.x), Double(solved.actualDest.y - dest.y))
                if clampDrift > 0.14 && style != .centerFocus && style != .symmetry {
                    continue
                }
                candidates.append(FramingCandidate(
                    destG: solved.actualDest, zoom: z, style: style,
                    aim: solved.aim, rotation: solved.rotation, futureCalib: solved.futureCalib,
                    cropBox: solved.cropBox, isBaseline: false
                ))
            }
        }

        if candidates.isEmpty {
            let solved = solveAimAndCrop(
                anchor: effectiveAnchor,
                destG: CGPoint(x: 0.50, y: 0.46),
                relZoom: max(0.35, Double(stabilizedZoom / safeZoom)),
                calibration: calibration
            )
            candidates.append(FramingCandidate(
                destG: solved.actualDest, zoom: stabilizedZoom, style: .centerFocus,
                aim: solved.aim, rotation: solved.rotation, futureCalib: solved.futureCalib,
                cropBox: solved.cropBox, isBaseline: false
            ))
        }

        // 8. Unified Photographic Candidate Scoring
        let centerPanProbe = neuralField.hasLearnedScores ? neuralField.panProxyScore(around: CGPoint(x: 0.5, y: 0.5)) : neuralField.baseScore
        let avoid = sceneHints.avoid
        let clutterSum = avoid.left + avoid.right + avoid.top + avoid.bottom
        let rawEdgeDist = min(Double(effectiveAnchor.x), min(1.0 - Double(effectiveAnchor.x), min(Double(effectiveAnchor.y), 1.0 - Double(effectiveAnchor.y))))
        let boxMarginL = Double(heroBox.minX)
        let boxMarginR = Double(1.0 - heroBox.maxX)
        let boxMarginT = Double(heroBox.minY)
        let boxMarginB = Double(1.0 - heroBox.maxY)
        let minBoxMargin = min(boxMarginL, min(boxMarginR, min(boxMarginT, boxMarginB)))
        let heroCrampedSide = minBoxMargin < 0.055 && (abs(boxMarginL - boxMarginR) > 0.14 || abs(boxMarginT - boxMarginB) > 0.14)
        let baseVisHero = visibleFraction(heroBox, margin: 0.025)

        let skyPrefY: Double = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? 0.667 : 0.333
        let horizonTargetY: Double = isWaterReflection ? 0.50 : skyPrefY
        let rawHorizonOK = role != .skyLandscape || horizonInfo.horizonY.map { abs($0 - horizonTargetY) < 0.045 } ?? true
        let gaicHeadroom = neuralField.maxScore - neuralField.baseScore
        let rawGazeAlreadyAligned = abs(heroGazeX) < 0.14 ||
            (heroGazeX > 0 && Double(effectiveAnchor.x) >= 0.26 && Double(effectiveAnchor.x) <= 0.43) ||
            (heroGazeX < 0 && Double(effectiveAnchor.x) >= 0.57 && Double(effectiveAnchor.x) <= 0.74)
        let rawAlreadyStrong = (zoomSolution.state == .noZoomNeeded) && !zoomSolution.requiresPanBeforeZoom &&
            (gaicHeadroom < 0.025) && rawEdgeDist >= 0.27 && !heroCrampedSide && rawHorizonOK &&
            rawGazeAlreadyAligned && clutterSum < 0.28

        var bestCandidate = candidates[0]
        var bestScore = -Double.infinity

        for cand in candidates {
            let relZ = max(0.35, Double(cand.zoom / safeZoom))
            let crop = cand.cropBox
            let projHero = projectBox(
                heroBox, calibration: calibration, futureCalib: cand.futureCalib,
                rotation: cand.rotation, fallbackAim: cand.aim, relZoom: relZ
            )

            // Safety gate: never clip hero head/bust or companions when panning/zooming
            if !cand.isBaseline && role != .skyLandscape && role != .scene && role != .architecture &&
               role != .street && role != .indoorRoom && role != .aperture {
                if role == .portrait && portraitBustBox != nil {
                    if projHero.minY < -0.015 { continue }
                } else {
                    let targetVis: Double = (role == .portrait) ? 0.72 : 0.85
                    let minVis = min(targetVis, max(0.65, baseVisHero - 0.03))
                    if visibleFraction(projHero, margin: 0.02) < minVis { continue }
                }
                if !protectedBoxes.isEmpty {
                    let allProtectedOK = protectedBoxes.allSatisfy { pBox in
                        let pp = projectBox(
                            pBox, calibration: calibration, futureCalib: cand.futureCalib,
                            rotation: cand.rotation, fallbackAim: cand.aim, relZoom: relZ
                        )
                        let basePVis = visibleFraction(pBox, margin: 0.02)
                        let isBust = (portraitBustBox != nil && pBox == portraitBustBox)
                        let isSmallFace = (role == .portrait || role == .group) && pBox.height < heroBox.height * 0.65 && !isBust
                        let capReq: Double = isSmallFace ? 0.92 : (isBust ? 0.82 : ((role == .portrait && pBox == heroBox) ? 0.70 : 0.80))
                        let req = min(capReq, max(0.62, basePVis - 0.03))
                        return visibleFraction(pp, margin: 0.02) >= req
                    }
                    if !allProtectedOK { continue }
                }
            } else if !cand.isBaseline && role == .architecture, !protectedBoxes.isEmpty {
                let projArch = projectBox(
                    heroBox, calibration: calibration, futureCalib: cand.futureCalib,
                    rotation: cand.rotation, fallbackAim: cand.aim, relZoom: relZ
                )
                if heroBox.minY >= 0.025 && projArch.minY < 0.015 { continue }
            }

            // 1) Learned Neural Aesthetic Score (guides framing placement without vetoing needed zoom!)
            let rawGAIC: Double
            let effectiveGAIC: Double
            if relZ > 1.05 {
                rawGAIC = neuralField.interpolatedScore(for: crop)
                effectiveGAIC = rawGAIC
            } else {
                rawGAIC = neuralField.baseScore
                if neuralField.hasLearnedScores && !cand.isBaseline {
                    let probeDelta = max(-0.05, min(0.05, neuralField.panProxyScore(around: cand.aim) - centerPanProbe))
                    effectiveGAIC = neuralField.baseScore + 0.45 * probeDelta
                } else {
                    effectiveGAIC = neuralField.baseScore
                }
            }
            let normGAIC = neuralField.hasLearnedScores
                ? (effectiveGAIC - neuralField.minScore) / max(0.04, neuralField.maxScore - neuralField.minScore)
                : 0.5
            let gaicGainBonus: Double = (neuralField.hasLearnedScores && relZ > 1.05 && rawGAIC > neuralField.baseScore + 0.015)
                ? min(0.24, (rawGAIC - neuralField.baseScore) * 1.5)
                : 0.0

            // 2) Clutter, Edge-Obstacle & Incidental Distraction Avoidance
            let trimL = min(1.0, Double(crop.minX) / 0.16)
            let trimR = min(1.0, Double(1.0 - crop.maxX) / 0.16)
            let trimT = min(1.0, Double(crop.minY) / 0.16)
            let trimB = min(1.0, Double(1.0 - crop.maxY) / 0.16)
            let clutterCleared = (avoid.left * trimL + avoid.right * trimR + avoid.top * trimT + avoid.bottom * trimB) / max(1.0, clutterSum + 0.4)
            let panAwayClutter = (avoid.left * max(0.0, Double(cand.aim.x) - 0.5) +
                                  avoid.right * max(0.0, 0.5 - Double(cand.aim.x)) +
                                  avoid.top * max(0.0, Double(cand.aim.y) - 0.5) +
                                  avoid.bottom * max(0.0, 0.5 - Double(cand.aim.y))) * 1.4
            let panIntoClutter = (avoid.left * max(0.0, 0.5 - Double(cand.aim.x)) +
                                  avoid.right * max(0.0, Double(cand.aim.x) - 0.5) +
                                  avoid.top * max(0.0, 0.5 - Double(cand.aim.y)) +
                                  avoid.bottom * max(0.0, Double(cand.aim.y) - 0.5)) * 1.6
            var incidentalCleared = 0.0
            if !incidentalBounds.isEmpty && relZ > 1.05 {
                let clearedCount = incidentalBounds.filter { inc in
                    let pInc = projectBox(
                        inc, calibration: calibration, futureCalib: cand.futureCalib,
                        rotation: cand.rotation, fallbackAim: cand.aim, relZoom: relZ
                    )
                    return visibleFraction(pInc, margin: 0.0) < 0.25
                }.count
                incidentalCleared = min(0.22, Double(clearedCount) * 0.08)
            }
            let clutterScore = min(1.0, max(-0.4, 0.45 + 0.55 * clutterCleared + 0.35 * panAwayClutter + incidentalCleared - panIntoClutter))

            // 3) Scale Fidelity to 3-State Zoom Engine & Optical Switchover Quality
            let zoomMatchErr = abs(log(max(0.4, Double(cand.zoom)) / max(0.4, Double(stabilizedZoom))))
            let scaleScore = exp(-3.2 * zoomMatchErr * zoomMatchErr)
            let isHardwareLens = allowedZooms.contains { abs($0 - cand.zoom) <= 0.06 }
            let isPrimeSensorCrop = abs(cand.zoom - 1.2) <= 0.05 || abs(cand.zoom - 1.5) <= 0.05
            let optBonus = isHardwareLens ? 0.045 : (isPrimeSensorCrop ? 0.028 : 0.015)

            // 4) Composition Harmony, Symmetry, Looking Room, Horizon & Depth Openness
            let evalCrop = relZ > 1.05 ? crop : CGRect(x: 0, y: 0, width: 1, height: 1)
            let viewSym = horizontalSymmetry(raster: raster, in: evalCrop)
            let distCenter = hypot(Double(cand.destG.x) - 0.5, Double(cand.destG.y) - 0.5)
            let leftOpen = 1.0 - halfDepthMean(leftHalf: true, raster: raster, in: evalCrop, splitX: Double(effectiveAnchor.x))
            let rightOpen = 1.0 - halfDepthMean(leftHalf: false, raster: raster, in: evalCrop, splitX: Double(effectiveAnchor.x))
            let torqueBal = (role == .skyLandscape && relZ <= 1.05)
                ? visualBalanceScore(raster: raster, in: evalCrop, aim: CGPoint(x: 0.5, y: 0.5), relZoom: 1.0)
                : visualBalanceScore(raster: raster, in: evalCrop, aim: cand.aim, relZoom: relZ)
            let destEdge = min(Double(cand.destG.x), min(1.0 - Double(cand.destG.x), min(Double(cand.destG.y), 1.0 - Double(cand.destG.y))))
            let edgePen = max(0.0, (0.22 - destEdge) * 2.2)

            let projMinMargin = min(Double(projHero.minX), min(Double(1.0 - projHero.maxX), min(Double(projHero.minY), Double(1.0 - projHero.maxY))))
            let edgeRelief = (heroCrampedSide && !cand.isBaseline)
                ? max(0.0, min(0.28, (projMinMargin - minBoxMargin) * 1.4))
                : 0.0

            var styleFit = 0.42 * torqueBal + edgeRelief - edgePen
            switch role {
            case .skyLandscape:
                if isWaterReflection && abs(Double(cand.destG.y) - 0.50) < 0.04 {
                    styleFit += 0.54
                } else {
                    let dy = Double(cand.destG.y) - skyPrefY
                    let weight = isWaterReflection ? 0.36 : 0.48
                    styleFit += weight * exp(-16.0 * dy * dy)
                }
            case .aperture, .indoorRoom:
                styleFit += 0.38 * exp(-12.0 * distCenter * distCenter)
            default:
                if abs(heroGazeX) >= 0.14 {
                    let wantLeft = heroGazeX > 0
                    let idealGazeX = wantLeft ? 0.382 : 0.618
                    let dxGaze = Double(cand.destG.x) - idealGazeX
                    let gazeGood = wantLeft ? (Double(cand.destG.x) < 0.44) : (Double(cand.destG.x) > 0.56)
                    let gazeWrong = wantLeft ? (Double(cand.destG.x) > 0.52) : (Double(cand.destG.x) < 0.48)
                    if gazeGood {
                        styleFit += 0.34 + 0.10 * exp(-40.0 * dxGaze * dxGaze)
                    } else if gazeWrong {
                        styleFit -= 0.24
                    } else {
                        styleFit += 0.10
                    }
                }
                if distCenter < 0.085 {
                    var centerMerit = 0.36 * max(0.0, viewSym - 0.42)
                    if isMinimalist { centerMerit += 0.18 }
                    if bw * relZ >= 0.46 { centerMerit += 0.14 }
                    if role == .group || role == .architecture { centerMerit += 0.16 }
                    if zoomSolution.requiresPanBeforeZoom { centerMerit += 0.20 }
                    if isSquareSensor { centerMerit += 0.06 }
                    styleFit += centerMerit
                } else {
                    let placedLeft = Double(cand.destG.x) < 0.48
                    let openMatch = placedLeft ? (rightOpen - leftOpen) : (leftOpen - rightOpen)
                    let openWeight = (role == .vehicle && bw >= bh * 1.25) ? 0.34 : 0.24
                    styleFit += openWeight * max(-0.22, min(0.45, openMatch * 2.2))
                    if bw * relZ < 0.46 && bh * relZ < 0.56 {
                        styleFit += 0.08
                    }
                }
                if cand.style == .leadingLines {
                    styleFit += 0.18
                }
            }

            // 5) Ergonomic Pan Economy & Anti-Joint-Amputation guard
            let shift = hypot(Double(cand.aim.x) - 0.5, Double(cand.aim.y) - 0.5)
            let gentleSweepEconomy = (!cand.isBaseline && abs(heroGazeX) < 0.14 && clutterSum < 0.30 && !heroCrampedSide)
                ? (-0.032 * shift)
                : 0.0
            let keepBonus = cand.isBaseline
                ? (rawAlreadyStrong ? 0.055 : -0.055)
                : (-0.020 * max(0.0, shift - 0.28) + gentleSweepEconomy)

            let ankleCutPen: Double = (!cand.isBaseline && role == .portrait && !isFaceOnlyHero &&
                                       heroBox.maxY <= 0.96 && projHero.maxY > 0.965 && projHero.maxY < 1.075)
                ? 0.075
                : 0.0

            let projFill = Double(projHero.width * projHero.height)
            let breathingPen: Double = (!cand.isBaseline && cand.zoom > safeZoom * 1.05 &&
                                        projFill > 0.64 &&
                                        role != .portrait && role != .environmentalPortrait &&
                                        role != .group && role != .architecture)
                ? 0.08 * min(1.0, (projFill - 0.64) / 0.26)
                : 0.0

            let neuralWeight = neuralField.hasLearnedScores ? 0.30 : 0.0
            let totalScore = neuralWeight * normGAIC +
                gaicGainBonus +
                0.18 * clutterScore +
                0.28 * scaleScore +
                0.24 * styleFit +
                optBonus + keepBonus - breathingPen - ankleCutPen

            if totalScore > bestScore {
                bestScore = totalScore
                bestCandidate = cand
            }
        }

        // 9. Finalize chosen 3D ray (with optional temporal destination smoothing), style & guidance explanation
        let finalZoom = bestCandidate.zoom
        let rawDest = bestCandidate.destG
        let smoothedDest: CGPoint
        let finalAim: CGPoint
        let finalRotation: simd_quatd
        if enableTemporalHysteresis && !bestCandidate.isBaseline {
            let targetDest = DirectorTemporalState.shared.smoothDestination(
                proposedDest: rawDest, anchor: effectiveAnchor, role: role, now: now
            )
            let reSolved = solveAimAndCrop(
                anchor: effectiveAnchor,
                destG: targetDest,
                relZoom: max(0.35, Double(finalZoom / safeZoom)),
                calibration: calibration
            )
            smoothedDest = reSolved.actualDest
            finalAim = reSolved.aim
            finalRotation = reSolved.rotation
        } else {
            smoothedDest = rawDest
            finalAim = bestCandidate.aim
            let finalAimDeviceRay = calibration.deviceRay(at: finalAim)
            finalRotation = simd_quatd(from: forward, to: finalAimDeviceRay)
        }
        let aimWorldRay = safePose.act(calibration.deviceRay(at: finalAim))

        if enableTemporalHysteresis {
            DirectorTemporalState.shared.commit(
                heroBounds: heroBox, domain: heroDomain, anchor: effectiveAnchor,
                dest: smoothedDest, role: role, zoom: finalZoom,
                zoomState: zoomSolution.state, now: now
            )
        }

        let aimShift = hypot(Double(finalAim.x - 0.5), Double(finalAim.y - 0.5))
        let zoomChanged = abs(finalZoom - safeZoom) >= 0.10
        let preservesOriginal = !zoomSolution.requiresPanBeforeZoom &&
            (bestCandidate.isBaseline || (aimShift < 0.028 && !zoomChanged))

        let resolvedStyle: DirectorCompositionStyle = {
            if preservesOriginal { return .keepNatural }
            if bestCandidate.style == .neuralFreeform {
                let dCenter = hypot(Double(smoothedDest.x) - 0.5, Double(smoothedDest.y) - 0.5)
                if dCenter < 0.075 { return .centerFocus }
                if abs(Double(smoothedDest.x) - 0.5) > 0.08 && abs(Double(smoothedDest.y) - 0.5) > 0.08 { return .diagonalDynamic }
            }
            return bestCandidate.style
        }()

        let usesCenter = abs(Double(smoothedDest.x) - 0.50) < 0.065 && abs(Double(smoothedDest.y) - 0.50) < 0.085
        let explanation = buildExplanation(
            role: role,
            localizedLabel: heroLocalized,
            destG: smoothedDest,
            zoom: finalZoom,
            currentZoom: safeZoom,
            style: resolvedStyle,
            horizonY: horizonInfo.horizonY,
            zoomState: zoomSolution.state,
            requiresPanBeforeZoom: zoomSolution.requiresPanBeforeZoom,
            idealZoomAfterPan: zoomSolution.idealZoomAfterPan
        )

        return DirectorDecision(
            role: role,
            heroLabel: heroLabel,
            heroLocalizedLabel: heroLocalized,
            heroBounds: heroBox,
            heroAnchor: effectiveAnchor,
            destinationPoint: smoothedDest,
            aimPointInSource: finalAim,
            aimWorldRay: aimWorldRay,
            rotation: finalRotation,
            recommendedZoom: finalZoom,
            confidence: max(0.38, min(0.98, heroConf)),
            usesCenter: usesCenter,
            preservesOriginalFrame: preservesOriginal,
            ruleName: resolvedStyle.rawValue,
            compositionStyle: resolvedStyle,
            explanation: explanation,
            detectedHorizonY: horizonInfo.horizonY,
            zoomState: zoomSolution.state,
            idealZoomAfterPan: zoomSolution.idealZoomAfterPan,
            centerCropMaxZoom: zoomSolution.centerCropMaxZoom,
            requiresPanBeforeZoom: zoomSolution.requiresPanBeforeZoom,
            centerCropVisibleFrame: centerCropFrame(currentZoom: safeZoom, targetZoom: finalZoom),
            subjectFillMetric: zoomSolution.measuredFill,
            targetFillMetric: zoomSolution.spec.idealFill,
            allDetections: fused
        )
    }

    // MARK: - 3D Geometry & Projection Helpers

    private static func solveAimAndCrop(
        anchor: CGPoint,
        destG: CGPoint,
        relZoom: Double,
        calibration: TrackingCalibration
    ) -> (
        aim: CGPoint,
        actualDest: CGPoint,
        aimDeviceRay: SIMD3<Double>,
        rotation: simd_quatd,
        futureCalib: TrackingCalibration,
        cropBox: CGRect
    ) {
        let futureCalib = TrackingCalibration(
            fx: calibration.fx * relZoom,
            fy: calibration.fy * relZoom,
            cx: calibration.cx,
            cy: calibration.cy,
            aspect: calibration.aspect,
            isMeasured: calibration.isMeasured
        )
        let targetRay = futureCalib.deviceRay(at: destG)
        let sourceRay = calibration.deviceRay(at: anchor)
        let solvedRotation = simd_quatd(from: targetRay, to: sourceRay)
        let rawAimProj = calibration.project(deviceRay: solvedRotation.act(forward))

        let panMinX: CGFloat
        let panMaxX: CGFloat
        let panMinY: CGFloat
        let panMaxY: CGFloat
        if relZoom <= 1.05 {
            let aspect = calibration.aspect.isFinite && calibration.aspect > 0.1 ? calibration.aspect : 0.75
            if aspect < 0.88 {
                panMinX = 0.24; panMaxX = 0.76
                panMinY = 0.18; panMaxY = 0.82
            } else if aspect > 1.12 {
                panMinX = 0.18; panMaxX = 0.82
                panMinY = 0.24; panMaxY = 0.76
            } else {
                panMinX = 0.22; panMaxX = 0.78
                panMinY = 0.22; panMaxY = 0.78
            }
        } else {
            let halfSensorSpan = CGFloat(0.5 / relZoom)
            let lo = max(0.16, min(0.45, halfSensorSpan))
            let hi = min(0.84, max(0.55, 1.0 - halfSensorSpan))
            panMinX = lo; panMaxX = hi
            panMinY = lo; panMaxY = hi
        }

        let clampedX: CGFloat
        let clampedY: CGFloat
        if rawAimProj.isInFront && rawAimProj.point.x.isFinite && rawAimProj.point.y.isFinite {
            clampedX = min(panMaxX, max(panMinX, rawAimProj.point.x))
            clampedY = min(panMaxY, max(panMinY, rawAimProj.point.y))
        } else {
            clampedX = 0.5
            clampedY = 0.5
        }
        let finalAim = CGPoint(x: clampedX, y: clampedY)
        let aimRay = calibration.deviceRay(at: finalAim)
        let finalRot = simd_quatd(from: forward, to: aimRay)
        let actualProj = futureCalib.project(deviceRay: finalRot.inverse.act(sourceRay))
        let actualDest: CGPoint = (actualProj.isInFront && actualProj.point.x.isFinite && actualProj.point.y.isFinite)
            ? actualProj.point
            : destG

        let cropBox: CGRect
        if relZoom < 0.95 {
            cropBox = CGRect(x: 0, y: 0, width: 1, height: 1)
        } else if relZoom <= 1.05 {
            let vx0 = max(CGFloat(0.0), finalAim.x - 0.5)
            let vy0 = max(CGFloat(0.0), finalAim.y - 0.5)
            let vx1 = min(CGFloat(1.0), finalAim.x + 0.5)
            let vy1 = min(CGFloat(1.0), finalAim.y + 0.5)
            cropBox = CGRect(x: vx0, y: vy0, width: max(0.15, vx1 - vx0), height: max(0.15, vy1 - vy0))
        } else {
            let visW = CGFloat(min(1.0, 1.0 / max(0.35, relZoom)))
            let visH = visW
            let vx0 = max(0.0, min(1.0 - visW, finalAim.x - visW * 0.5))
            let vy0 = max(0.0, min(1.0 - visH, finalAim.y - visH * 0.5))
            cropBox = CGRect(x: vx0, y: vy0, width: visW, height: visH)
        }
        return (finalAim, actualDest, aimRay, finalRot, futureCalib, cropBox)
    }

    private static func projectBox(
        _ box: CGRect,
        calibration: TrackingCalibration,
        futureCalib: TrackingCalibration,
        rotation: simd_quatd,
        fallbackAim: CGPoint,
        relZoom: Double
    ) -> CGRect {
        if calibration.isValid && futureCalib.isValid {
            let corners = [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.maxY),
                CGPoint(x: box.maxX, y: box.maxY)
            ]
            let invRot = rotation.inverse
            let projected = corners.map { futureCalib.project(deviceRay: invRot.act(calibration.deviceRay(at: $0))) }
            if projected.allSatisfy({ $0.isInFront && $0.point.x.isFinite && $0.point.y.isFinite }),
               let minX = projected.map(\.point.x).min(),
               let maxX = projected.map(\.point.x).max(),
               let minY = projected.map(\.point.y).min(),
               let maxY = projected.map(\.point.y).max() {
                return CGRect(x: minX, y: minY, width: max(1e-4, maxX - minX), height: max(1e-4, maxY - minY))
            }
        }
        let z = CGFloat(relZoom)
        let nx0 = 0.5 + (box.minX - fallbackAim.x) * z
        let ny0 = 0.5 + (box.minY - fallbackAim.y) * z
        return CGRect(x: nx0, y: ny0, width: box.width * z, height: box.height * z)
    }

    private static func visibleFraction(_ rect: CGRect, margin: CGFloat) -> Double {
        let area = Double(max(1e-6, rect.width * rect.height))
        let safeBounds = CGRect(x: margin, y: margin, width: max(0.01, 1.0 - 2 * margin), height: max(0.01, 1.0 - 2 * margin))
        let inter = rect.intersection(safeBounds)
        guard !inter.isNull, !inter.isEmpty else { return 0.0 }
        return Double(inter.width * inter.height) / area
    }

    // MARK: - Deduplication & Spatial Evidence Helpers

    private static func deduplicate(_ detections: [DirectorDetection]) -> [DirectorDetection] {
        let compactMasks = detections.filter {
            $0.domain == .foregroundMask && $0.area <= 0.72 &&
            !isBottomStrip($0.boundingBox, center: $0.center) && !isSideWall($0.boundingBox)
        }
        var nonMasks = detections.filter { $0.domain != .foregroundMask }
        for i in nonMasks.indices {
            let nm = nonMasks[i]
            if nm.domain == .backgroundSurface || nm.domain == .wideNature { continue }
            for m in compactMasks {
                let iou = rectIoU(nm.boundingBox, m.boundingBox)
                if iou >= 0.45 {
                    let boostedConf = min(0.95, nm.confidence + 0.08 * iou)
                    let mergedAnchor = nm.anchor ?? m.anchor
                    var mergedBox = nm.boundingBox
                    if iou >= 0.58 && m.area < nm.area {
                        let x0 = 0.60 * nm.boundingBox.minX + 0.40 * m.boundingBox.minX
                        let y0 = 0.60 * nm.boundingBox.minY + 0.40 * m.boundingBox.minY
                        let x1 = 0.60 * nm.boundingBox.maxX + 0.40 * m.boundingBox.maxX
                        let y1 = 0.60 * nm.boundingBox.maxY + 0.40 * m.boundingBox.maxY
                        mergedBox = CGRect(x: x0, y: y0, width: max(0.015, x1 - x0), height: max(0.015, y1 - y0))
                    }
                    nonMasks[i] = DirectorDetection(
                        label: nm.label, localizedLabel: nm.localizedLabel,
                        boundingBox: mergedBox, anchor: mergedAnchor,
                        confidence: boostedConf, domain: nm.domain,
                        gazeX: nm.gazeX, isGroup: nm.isGroup,
                        isAttentionOnly: nm.isAttentionOnly,
                        companionBounds: nm.companionBounds, faceBounds: nm.faceBounds
                    )
                    break
                }
            }
        }
        let monumentDets = nonMasks.filter {
            $0.confidence >= 0.35 && (
                $0.domain == .architecture ||
                ["monument", "statue", "sculpture", "tower", "tượng đài", "bức tượng", "điêu khắc"].contains($0.label.lowercased())
            )
        }
        if !monumentDets.isEmpty {
            nonMasks.removeAll { det in
                let lbl = det.label.lowercased()
                guard (lbl == "tie" || lbl == "cà vạt") && det.area >= 0.10 else { return false }
                return monumentDets.contains { rectIoU(det.boundingBox, $0.boundingBox) >= 0.45 }
            }
        }
        let ordered = nonMasks.sorted { $0.confidence > $1.confidence } +
            compactMasks.sorted { $0.confidence > $1.confidence }
        var kept: [DirectorDetection] = []
        kept.reserveCapacity(ordered.count)
        for d in ordered {
            if let idx = kept.firstIndex(where: { existing in
                let iou = rectIoU(d.boundingBox, existing.boundingBox)
                if iou <= 0.55 { return false }
                if d.label.lowercased() == existing.label.lowercased() { return true }
                if d.domain == existing.domain && d.domain != .object { return true }
                if d.domain == .foregroundMask && existing.domain != .foregroundMask { return true }
                return false
            }) {
                let prev = kept[idx]
                let mergedAnchor = prev.anchor ?? d.anchor
                let mergedGaze = abs(prev.gazeX) >= 0.05 ? prev.gazeX : d.gazeX
                let mergedFaces = prev.faceBounds.isEmpty ? d.faceBounds : prev.faceBounds
                let mergedGroup = prev.isGroup || d.isGroup
                let mergedCompanions = prev.companionBounds.isEmpty ? d.companionBounds : prev.companionBounds
                kept[idx] = DirectorDetection(
                    label: prev.label,
                    localizedLabel: prev.localizedLabel,
                    boundingBox: prev.boundingBox,
                    anchor: mergedAnchor,
                    confidence: prev.confidence,
                    domain: prev.domain,
                    gazeX: mergedGaze,
                    isGroup: mergedGroup,
                    isAttentionOnly: prev.isAttentionOnly && d.isAttentionOnly,
                    companionBounds: mergedCompanions,
                    faceBounds: mergedFaces
                )
            } else {
                kept.append(d)
            }
        }
        return kept
    }

    private static func rectIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0.0 }
        let ia = Double(inter.width * inter.height)
        let ua = Double(a.width * a.height + b.width * b.height) - ia
        return ua > 1e-6 ? ia / ua : 0.0
    }

    private static func rectContainment(_ a: CGRect, inside b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0.0 }
        let ia = Double(inter.width * inter.height)
        let minA = max(1e-6, min(Double(a.width * a.height), Double(b.width * b.height)))
        return ia / minA
    }

    private static func unionRects(_ rects: [CGRect]) -> CGRect {
        guard var acc = rects.first else { return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        for r in rects.dropFirst() { acc = acc.union(r) }
        return acc
    }

    private static func isBottomStrip(_ rect: CGRect, center: CGPoint) -> Bool {
        (rect.maxY >= 0.96 && center.y > 0.78 && rect.width > 0.45) ||
        (rect.maxY >= 0.90 && rect.width >= 0.88 && center.y > 0.60)
    }

    private static func isSideWall(_ rect: CGRect) -> Bool {
        let touchesLR = rect.minX <= 0.025 || rect.maxX >= 0.975
        return touchesLR && ((rect.height >= 0.65 && rect.width <= 0.42) || (rect.height >= 0.32 && rect.width <= 0.14))
    }

    /// Rejects tiny corner/border debris slivers while preserving genuine edge subjects & clipped main subjects.
    private static func isEdgeSliver(_ rect: CGRect, domain: DirectorSubjectDomain, hasFace: Bool) -> Bool {
        if domain == .face || hasFace { return false }
        let area = Double(max(0, rect.width) * max(0, rect.height))
        let dAim = hypot(Double(rect.midX) - 0.50, Double(rect.midY) - 0.48)
        let touchesLR = rect.minX <= 0.025 || rect.maxX >= 0.975
        let touchesTB = rect.minY <= 0.025 || rect.maxY >= 0.975
        guard touchesLR || touchesTB else { return false }
        if touchesLR && touchesTB && area < 0.045 && dAim > 0.36 { return true }
        if (rect.minX <= 0.015 || rect.maxX >= 0.985) && rect.width < 0.075 && area < 0.035 && domain != .human && domain != .animal {
            return true
        }
        if (rect.minY <= 0.015 || rect.maxY >= 0.985) && rect.height < 0.085 && area < 0.035 {
            return true
        }
        return false
    }

    private static func meanDepth(in rect: CGRect, raster: CompositionRaster) -> Double {
        guard raster.side > 0, raster.foregroundDepth.count == raster.side * raster.side else { return 0.5 }
        let s = raster.side
        let x0 = max(0, min(s - 1, Int(Double(rect.minX) * Double(s))))
        let x1 = max(x0 + 1, min(s, Int(ceil(Double(rect.maxX) * Double(s)))))
        let y0 = max(0, min(s - 1, Int(Double(rect.minY) * Double(s))))
        let y1 = max(y0 + 1, min(s, Int(ceil(Double(rect.maxY) * Double(s)))))
        var sum = 0.0
        var count = 0
        for y in y0..<y1 {
            let row = y * s
            for x in x0..<x1 {
                sum += raster.foregroundDepth[row + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    private static func halfDepthMean(leftHalf: Bool, raster: CompositionRaster, in crop: CGRect, splitX: Double) -> Double {
        guard raster.side > 1, raster.foregroundDepth.count == raster.side * raster.side else { return 0.5 }
        let s = raster.side
        let cMinX = max(0, min(s - 2, Int(Double(crop.minX) * Double(s))))
        let cMaxX = max(cMinX + 2, min(s, Int(ceil(Double(crop.maxX) * Double(s)))))
        let cMinY = max(0, min(s - 1, Int(Double(crop.minY) * Double(s))))
        let cMaxY = max(cMinY + 1, min(s, Int(ceil(Double(crop.maxY) * Double(s)))))
        let midX = max(cMinX + 1, min(cMaxX - 1, Int(splitX * Double(s))))
        let x0 = leftHalf ? cMinX : midX
        let x1 = leftHalf ? midX : cMaxX
        guard x1 > x0 else { return 0.5 }
        var sum = 0.0
        var count = 0
        for y in cMinY..<cMaxY {
            let row = y * s
            for x in x0..<x1 {
                sum += raster.foregroundDepth[row + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    private static func horizontalSymmetry(raster: CompositionRaster, in crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Double {
        guard raster.side > 4, raster.luminance.count == raster.side * raster.side else { return 0.0 }
        let s = raster.side
        let x0 = max(0, min(s - 4, Int(Double(crop.minX) * Double(s))))
        let x1 = max(x0 + 4, min(s, Int(ceil(Double(crop.maxX) * Double(s)))))
        let y0 = max(0, min(s - 2, Int(Double(crop.minY) * Double(s))))
        let y1 = max(y0 + 2, min(s, Int(ceil(Double(crop.maxY) * Double(s)))))
        let w = x1 - x0
        let half = w / 2
        guard half >= 2 else { return 0.0 }
        var diffSum = 0.0
        var count = 0
        for y in y0..<y1 {
            let row = y * s
            for dx in 0..<half {
                let l = raster.luminance[row + x0 + dx]
                let r = raster.luminance[row + (x1 - 1 - dx)]
                diffSum += abs(l - r)
                count += 1
            }
        }
        let meanDiff = count > 0 ? diffSum / Double(count) : 1.0
        return max(0.0, min(1.0, 1.0 - meanDiff * 2.1))
    }

    private static func visualBalanceScore(
        raster: CompositionRaster,
        in crop: CGRect,
        aim: CGPoint = CGPoint(x: 0.5, y: 0.5),
        relZoom: Double = 1.0
    ) -> Double {
        guard raster.side > 4, raster.edges.count == raster.side * raster.side,
              raster.foregroundDepth.count == raster.side * raster.side else { return 0.5 }
        let s = raster.side
        let x0 = max(0, min(s - 2, Int(Double(crop.minX) * Double(s))))
        let x1 = max(x0 + 2, min(s, Int(ceil(Double(crop.maxX) * Double(s)))))
        let y0 = max(0, min(s - 2, Int(Double(crop.minY) * Double(s))))
        let y1 = max(y0 + 2, min(s, Int(ceil(Double(crop.maxY) * Double(s)))))
        let invS = 1.0 / Double(s)
        let ax = Double(aim.x)
        let ay = Double(aim.y)
        var sumW = 0.0, sumX = 0.0, sumY = 0.0
        for y in y0..<y1 {
            let row = y * s
            let gy = (Double(y) + 0.5) * invS
            let py = 0.5 + (gy - ay) * relZoom
            guard py >= 0.0 && py <= 1.0 else { continue }
            for x in x0..<x1 {
                let gx = (Double(x) + 0.5) * invS
                let px = 0.5 + (gx - ax) * relZoom
                guard px >= 0.0 && px <= 1.0 else { continue }
                let idx = row + x
                let wt = raster.edges[idx] + 0.35 * raster.foregroundDepth[idx]
                sumW += wt
                sumX += wt * px
                sumY += wt * py
            }
        }
        guard sumW > 1e-6 else { return 0.5 }
        let comX = sumX / sumW
        let comY = sumY / sumW
        return max(0.0, 1.0 - min(1.0, hypot(comX - 0.5, comY - 0.5) * 2.1))
    }

    private static func extractSharpForegroundClusters(raster: CompositionRaster) -> [SharpCluster] {
        let s = raster.side
        let n = s * s
        guard s >= 8, raster.foregroundDepth.count == n, raster.edges.count == n else { return [] }
        let sortedEdges = raster.edges.sorted()
        let e96 = max(1e-4, sortedEdges[Int(Double(n - 1) * 0.96)])
        var edgeNorm = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            edgeNorm[i] = min(1.0, max(0.0, raster.edges[i] / e96))
        }
        var edgeSmooth = [Double](repeating: 0.0, count: n)
        for y in 0..<s {
            for x in 0..<s {
                var acc = 0.0
                var cnt = 0.0
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < s else { continue }
                    let r = ny * s
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < s else { continue }
                        acc += edgeNorm[r + nx]
                        cnt += 1.0
                    }
                }
                edgeSmooth[y * s + x] = cnt > 0 ? acc / cnt : 0.0
            }
        }
        let hasChroma = raster.structuralChromaticAccentMap.count == n
        let hasSync = raster.synchronizedSaliency.count == n
        let meanLuma = raster.luminance.count == n
            ? raster.luminance.reduce(0.0, +) / Double(n)
            : 0.5

        var distinctMap = [Double](repeating: 0.0, count: n)
        var sharpDepth = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let chroma = hasChroma ? min(1.0, max(0.0, raster.structuralChromaticAccentMap[i])) : 0.0
            let sync = hasSync ? min(1.0, max(0.0, raster.synchronizedSaliency[i])) : 0.0
            let lumaPop = raster.luminance.count == n ? min(1.0, abs(raster.luminance[i] - meanLuma) * 2.2) : 0.0
            let distinct = max(chroma, max(sync * 0.92, lumaPop * 0.62))
            distinctMap[i] = distinct
            let detailGate = 0.22 + 0.78 * max(edgeSmooth[i], distinct * 0.90)
            sharpDepth[i] = 0.40 * raster.foregroundDepth[i] * detailGate + 0.30 * edgeSmooth[i] + 0.30 * distinct
        }

        let sortedSD = sharpDepth.sorted()
        let p20 = sortedSD[Int(Double(n - 1) * 0.20)]
        let p82 = sortedSD[Int(Double(n - 1) * 0.82)]
        let p95 = sortedSD[Int(Double(n - 1) * 0.95)]
        guard p95 - p20 >= 0.14 else { return [] }
        let seedThresh = max(0.46, p82 + 0.28 * (p95 - p82))
        let growThresh = min(seedThresh - 0.04, max(0.28, p82 - 0.12 * (p95 - p82)))
        let maxClusterPixels = Int(Double(n) * 0.66)

        var visited = [Bool](repeating: false, count: n)
        var clusters: [SharpCluster] = []
        let dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for sy in 0..<s {
            for sx in 0..<s {
                let start = sy * s + sx
                if visited[start] || sharpDepth[start] < seedThresh { continue }
                visited[start] = true
                var queue = [start]
                var head = 0
                var minX = sx, maxX = sx, minY = sy, maxY = sy
                var sumX = 0.0, sumY = 0.0, sumD = 0.0, sumS = 0.0, sumC = 0.0, pix = 0
                while head < queue.count {
                    let cur = queue[head]
                    head += 1
                    let cx = cur % s
                    let cy = cur / s
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    sumX += (Double(cx) + 0.5) / Double(s)
                    sumY += (Double(cy) + 0.5) / Double(s)
                    sumD += raster.foregroundDepth[cur]
                    sumS += edgeNorm[cur]
                    sumC += distinctMap[cur]
                    pix += 1
                    if pix >= maxClusterPixels { break }
                    for (dx, dy) in dirs {
                        let nx = cx + dx, ny = cy + dy
                        if nx >= 0, nx < s, ny >= 0, ny < s {
                            let ni = ny * s + nx
                            if !visited[ni] && sharpDepth[ni] >= growThresh {
                                visited[ni] = true
                                queue.append(ni)
                            }
                        }
                    }
                }
                let area = Double(pix) / Double(n)
                guard area >= 0.004 && area <= 0.68 else { continue }
                let x0 = Double(minX) / Double(s)
                let y0 = Double(minY) / Double(s)
                let x1 = Double(maxX + 1) / Double(s)
                let y1 = Double(maxY + 1) / Double(s)
                let cx = sumX / Double(pix)
                let cy = sumY / Double(pix)
                let box = CGRect(x: x0, y: y0, width: max(0.02, x1 - x0), height: max(0.02, y1 - y0))
                if isBottomStrip(box, center: CGPoint(x: cx, y: cy)) || isSideWall(box) { continue }
                let meanD = sumD / Double(pix)
                let meanS = sumS / Double(pix)
                let meanC = sumC / Double(pix)
                if area < 0.012 && (meanS < 0.22 || meanC < 0.40) { continue }
                if meanS < 0.10 && meanC < 0.26 { continue }
                let dAim = hypot(cx - 0.50, cy - 0.46)
                let aimW = 0.68 + 0.55 * exp(-(dAim * dAim) / (2.0 * 0.26 * 0.26))
                let sc = (0.34 * meanD + 0.33 * meanS + 0.33 * meanC) * sqrt(max(0.012, area)) * aimW
                clusters.append(SharpCluster(
                    bounds: box, center: CGPoint(x: cx, y: cy),
                    meanDepth: meanD, meanSharpness: meanS, meanContrast: meanC, area: area, score: sc
                ))
            }
        }
        return clusters.sorted { $0.score > $1.score }
    }

    private struct HorizonRichness {
        let horizonY: Double?
        let skyRich: Double
        let groundRich: Double
    }

    private static func estimateHorizonAndRichness(
        detections: [DirectorDetection],
        raster: CompositionRaster,
        sceneHints: CompositionSceneHints,
        affinities: [String: Double]
    ) -> HorizonRichness {
        var hy: Double? = nil
        let skyBoxes = detections.filter { skyTokens.contains($0.label.lowercased()) && $0.confidence >= 0.13 }
        if let bestSky = skyBoxes.max(by: { Double($0.boundingBox.width) * $0.confidence < Double($1.boundingBox.width) * $1.confidence }),
           bestSky.boundingBox.minY < 0.16,
           (0.16...0.85).contains(bestSky.boundingBox.maxY) {
            hy = Double(bestSky.boundingBox.maxY)
        }
        if hy == nil {
            let groundBoxes = detections.filter { groundTokens.contains($0.label.lowercased()) && $0.confidence >= 0.15 }
            if let bestG = groundBoxes.max(by: { Double($0.boundingBox.width) * $0.confidence < Double($1.boundingBox.width) * $1.confidence }),
               (0.16...0.82).contains(bestG.boundingBox.minY),
               bestG.boundingBox.maxY > 0.68 {
                hy = Double(bestG.boundingBox.minY)
            }
        }
        if hy == nil, let mh = raster.measuredHorizon, mh.confidence >= 0.35, (0.16...0.82).contains(mh.y) {
            hy = Double(mh.y)
        }
        if hy == nil, let sh = sceneHints.estimatedHorizonY ?? raster.structuralEstimatedHorizonY, (0.16...0.82).contains(sh) {
            hy = sh
        }
        if hy == nil, raster.side >= 12, raster.foregroundDepth.count == raster.side * raster.side {
            let s = raster.side
            var rowMean = [Double](repeating: 0.0, count: s)
            for y in 0..<s {
                var sum = 0.0
                for x in 0..<s { sum += raster.foregroundDepth[y * s + x] }
                rowMean[y] = sum / Double(s)
            }
            let topMean = rowMean.prefix(s / 3).reduce(0.0, +) / Double(max(1, s / 3))
            let botMean = rowMean.suffix(s / 3).reduce(0.0, +) / Double(max(1, s / 3))
            if topMean < botMean - 0.14 {
                let yLo = Int(Double(s) * 0.18)
                let yHi = Int(Double(s) * 0.78)
                var bestGrad = -Double.infinity
                var bestRow = s / 2
                for y in yLo..<max(yLo + 1, min(s - 1, yHi)) {
                    let g = rowMean[y + 1] - rowMean[y]
                    if g > bestGrad { bestGrad = g; bestRow = y }
                }
                hy = Double(bestRow) / Double(s)
            }
        }

        guard let resolvedHy = hy else {
            return HorizonRichness(horizonY: nil, skyRich: 0.5, groundRich: 0.5)
        }
        let s = raster.side
        guard s >= 8, raster.luminance.count == s * s, raster.edges.count == s * s else {
            return HorizonRichness(horizonY: resolvedHy, skyRich: 0.55, groundRich: 0.45)
        }
        let cut = max(2, min(s - 2, Int(resolvedHy * Double(s))))
        let skyStats = bandRichness(yRange: 0..<cut, raster: raster)
        let groundStats = bandRichness(yRange: cut..<s, raster: raster)

        let skyCueBoost = max(
            affinities["dramatic_clouds"] ?? 0.0,
            max(affinities["sunset"] ?? 0.0, max(affinities["golden_hour"] ?? 0.0, affinities["horizon_sky"] ?? 0.0))
        )
        let skyRich = min(1.0, skyStats + max(0.0, skyCueBoost * 1.4))
        let groundRich = min(1.0, groundStats)
        return HorizonRichness(horizonY: resolvedHy, skyRich: skyRich, groundRich: groundRich)
    }

    private static func bandRichness(yRange: Range<Int>, raster: CompositionRaster) -> Double {
        let s = raster.side
        let count = max(1, yRange.count * s)
        var sumL = 0.0, sqL = 0.0, sumE = 0.0, sumAccent = 0.0
        let hasAccent = raster.structuralChromaticAccentMap.count == s * s
        for y in yRange {
            let row = y * s
            for x in 0..<s {
                let idx = row + x
                let l = raster.luminance[idx]
                sumL += l
                sqL += l * l
                sumE += raster.edges[idx]
                if hasAccent { sumAccent += raster.structuralChromaticAccentMap[idx] }
            }
        }
        let meanL = sumL / Double(count)
        let stdL = sqrt(max(0.0, sqL / Double(count) - meanL * meanL))
        let meanE = sumE / Double(count)
        let meanAccent = hasAccent ? sumAccent / Double(count) : 0.0
        return min(1.0, 1.8 * stdL + 2.0 * meanE + 1.2 * meanAccent)
    }

    private static func brightSkyAccentX(
        horizonY: Double,
        raster: CompositionRaster,
        detections: [DirectorDetection] = []
    ) -> Double? {
        if let sunOrMoon = detections.first(where: {
            let l = $0.label.lowercased()
            return (l == "sun" || l == "moon" || l == "mặt trời" || l == "mặt trăng") &&
                $0.confidence >= 0.22 && Double($0.boundingBox.midY) <= horizonY + 0.08
        }) {
            let sx = Double(sunOrMoon.boundingBox.midX)
            if (0.08...0.92).contains(sx) { return sx }
        }
        let s = raster.side
        guard s >= 8, raster.luminance.count == s * s else { return nil }
        let cut = max(2, min(s - 2, Int(horizonY * Double(s))))
        var skyVals: [Double] = []
        skyVals.reserveCapacity(cut * s)
        var peakVal = 0.0
        var peakX = s / 2
        for y in 0..<cut {
            let row = y * s
            for x in 0..<s {
                let v = raster.luminance[row + x]
                skyVals.append(v)
                if v > peakVal { peakVal = v; peakX = x }
            }
        }
        guard peakVal >= 0.93, skyVals.count >= 8 else { return nil }
        let sortedSky = skyVals.sorted()
        let p85 = sortedSky[Int(Double(sortedSky.count - 1) * 0.85)]
        guard peakVal - p85 >= 0.12 else { return nil }
        let normX = (Double(peakX) + 0.5) / Double(s)
        guard (0.08...0.92).contains(normX) else { return nil }
        return normX
    }

    private static func topSiglipScene(_ affinities: [String: Double]) -> String {
        guard !affinities.isEmpty else { return "general" }
        let groups: [(String, [String])] = [
            ("flower", ["flower", "flower_closeup", "macro"]),
            ("foliage", ["foliage", "foliage_garden", "forest_woods"]),
            ("sunset", ["sunset", "golden_hour"]),
            ("sky_clouds", ["sky", "horizon_sky", "dramatic_clouds", "clear_blue_sky"]),
            ("landscape", ["landscape", "mountain_vista", "ocean_beach", "water", "water_reflection"]),
            ("person_scenery", ["person_scenery", "portrait_fullbody"]),
            ("person", ["person", "portrait_closeup"]),
            ("group", ["group"]),
            ("animal", ["animal", "pet_portrait"]),
            ("architecture", ["building", "architecture_facade", "architecture_symmetry"]),
            ("street", ["street", "street_perspective", "night_city"]),
            ("food", ["food", "food_spread", "coffee_drink"]),
            ("indoor_room", ["indoor_furnished", "indoor_living_room"]),
            ("aperture", ["frame_aperture"]),
            ("object", ["object", "single_product", "tabletop_ensemble", "desk_workspace"]),
        ]
        var bestName = "general"
        var bestVal = -Double.infinity
        for (name, keys) in groups {
            let v = keys.compactMap { affinities[$0] }.max() ?? -Double.infinity
            if v > bestVal {
                bestVal = v
                bestName = name
            }
        }
        return bestVal > 0.01 ? bestName : "general"
    }

    private struct NeuralProposalSummary {
        struct Entry {
            let box: CGRect
            let relZoom: Double
            let score: Double
        }

        let bestBox: CGRect
        let attentionCenter: CGPoint
        let attentionBox: CGRect
        let baseScore: Double
        let minScore: Double
        let maxScore: Double
        let hasLearnedScores: Bool
        let entries: [Entry]

        func peakBox(nearRelativeZoom target: Double) -> CGRect? {
            let targetSpan = min(1.0, 1.0 / max(0.35, target))
            let matches = entries.filter { abs(Double($0.box.width) - targetSpan) < 0.16 || abs($0.relZoom - target) < 0.24 }
            return matches.max(by: { $0.score < $1.score })?.box
        }

        func interpolatedScore(for crop: CGRect) -> Double {
            guard !entries.isEmpty else { return 0.5 }
            var nearest: [(dist: Double, score: Double)] = []
            nearest.reserveCapacity(9)
            for e in entries {
                let d = abs(Double(e.box.minX - crop.minX)) +
                    abs(Double(e.box.minY - crop.minY)) +
                    abs(Double(e.box.maxX - crop.maxX)) +
                    abs(Double(e.box.maxY - crop.maxY))
                if nearest.count < 8 {
                    nearest.append((d, e.score))
                    if nearest.count == 8 { nearest.sort { $0.dist < $1.dist } }
                } else if d < nearest[7].dist {
                    nearest[7] = (d, e.score)
                    nearest.sort { $0.dist < $1.dist }
                }
            }
            var wSum = 0.0
            var valSum = 0.0
            for item in nearest {
                let w = exp(-item.dist * 18.0)
                wSum += w
                valSum += w * item.score
            }
            return wSum > 1e-9 ? (valSum / wSum) : (nearest.first?.score ?? baseScore)
        }

        func panProxyScore(around aim: CGPoint) -> Double {
            let s: CGFloat = 0.86
            let vx0 = max(0.0, min(1.0 - s, aim.x - s * 0.5))
            let vy0 = max(0.0, min(1.0 - s, aim.y - s * 0.5))
            return interpolatedScore(for: CGRect(x: vx0, y: vy0, width: s, height: s))
        }
    }

    private static func summarizeNeuralProposals(_ proposals: [CompositionProposal], fallbackBaseZoom: Double) -> NeuralProposalSummary {
        guard !proposals.isEmpty else {
            let fallbackBox = CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70)
            return NeuralProposalSummary(
                bestBox: fallbackBox,
                attentionCenter: CGPoint(x: 0.50, y: 0.50),
                attentionBox: fallbackBox,
                baseScore: 0.5, minScore: 0.5, maxScore: 0.5, hasLearnedScores: false, entries: []
            )
        }
        let baseZoom = max(0.5, Double(proposals.first(where: \.isUnchangedView)?.zoom ?? proposals.first?.zoom ?? CGFloat(fallbackBaseZoom)))
        let gaicValues = proposals.map(\.gaicScore)
        let hasGAICVariance = (gaicValues.max() ?? 0.5) - (gaicValues.min() ?? 0.5) > 0.005

        func effectiveScore(_ p: CompositionProposal) -> Double {
            if hasGAICVariance {
                let clampedScore = min(1.0, max(0.0, p.score))
                return 0.72 * p.gaicScore + 0.28 * clampedScore
            }
            return min(1.0, max(0.0, p.score))
        }

        var entries: [NeuralProposalSummary.Entry] = []
        entries.reserveCapacity(proposals.count)
        var bestBox = CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70)
        var bestScore = -Double.infinity
        var minScore = Double.infinity
        var maxScore = -Double.infinity
        var baseScore = 0.5

        for p in proposals {
            let minX = max(0.0, min(1.0, Double(p.sourceCorners.map(\.x).min() ?? 0.0)))
            let maxX = max(0.0, min(1.0, Double(p.sourceCorners.map(\.x).max() ?? 1.0)))
            let minY = max(0.0, min(1.0, Double(p.sourceCorners.map(\.y).min() ?? 0.0)))
            let maxY = max(0.0, min(1.0, Double(p.sourceCorners.map(\.y).max() ?? 1.0)))
            let box = CGRect(x: minX, y: minY, width: max(0.05, maxX - minX), height: max(0.05, maxY - minY))
            let sc = effectiveScore(p)
            let relZ = max(0.35, Double(p.zoom) / baseZoom)
            entries.append(NeuralProposalSummary.Entry(box: box, relZoom: relZ, score: sc))
            if p.isUnchangedView { baseScore = sc }
            if sc < minScore { minScore = sc }
            if sc > maxScore { maxScore = sc }
            if sc > bestScore {
                bestScore = sc
                bestBox = box
            }
        }
        if !minScore.isFinite { minScore = 0.5 }
        if !maxScore.isFinite { maxScore = 0.5 }
        let hasLearned = hasGAICVariance || (maxScore - minScore > 0.015)

        let tightEntries = entries.filter { Double($0.box.width) <= 0.78 }.sorted { $0.score > $1.score }
        var attCenter = CGPoint(x: bestBox.midX, y: bestBox.midY)
        var attBox = bestBox
        if let lead = tightEntries.first {
            let topK = Array(tightEntries.prefix(10))
            var wSum = 0.0, cxSum = 0.0, cySum = 0.0
            for e in topK {
                let w = exp((e.score - lead.score) * 18.0)
                wSum += w
                cxSum += w * Double(e.box.midX)
                cySum += w * Double(e.box.midY)
            }
            if wSum > 1e-6 {
                attCenter = CGPoint(x: cxSum / wSum, y: cySum / wSum)
            }
            let top5 = Array(tightEntries.prefix(5))
            var w5Sum = 0.0, ax0 = 0.0, ay0 = 0.0, ax1 = 0.0, ay1 = 0.0
            for e in top5 {
                let w = exp((e.score - lead.score) * 18.0)
                w5Sum += w
                ax0 += w * Double(e.box.minX)
                ay0 += w * Double(e.box.minY)
                ax1 += w * Double(e.box.maxX)
                ay1 += w * Double(e.box.maxY)
            }
            if w5Sum > 1e-6 {
                let rx0 = ax0 / w5Sum
                let ry0 = ay0 / w5Sum
                let rw = max(0.08, (ax1 / w5Sum) - rx0)
                let rh = max(0.08, (ay1 / w5Sum) - ry0)
                attBox = CGRect(x: rx0, y: ry0, width: rw, height: rh)
            }
        }
        return NeuralProposalSummary(
            bestBox: bestBox, attentionCenter: attCenter, attentionBox: attBox,
            baseScore: baseScore, minScore: minScore, maxScore: maxScore,
            hasLearnedScores: hasLearned, entries: entries
        )
    }

    private static func buildExplanation(
        role: DirectorPhotographicRole,
        localizedLabel: String,
        destG: CGPoint,
        zoom: CGFloat,
        currentZoom: CGFloat,
        style: DirectorCompositionStyle,
        horizonY: Double?,
        zoomState: DirectorZoomState,
        requiresPanBeforeZoom: Bool,
        idealZoomAfterPan: CGFloat
    ) -> String {
        let side = destG.x < 0.45 ? "trái" : (destG.x > 0.55 ? "phải" : "giữa")
        let subjectName = localizedLabel.lowercased()

        if requiresPanBeforeZoom {
            if zoom > currentZoom + 0.12 {
                return String(
                    format: "Chủ thể lệch tâm — tạm zoom %.1fx giữ trọn %@, dịch máy rồi mới zoom %.1fx",
                    zoom, subjectName, idealZoomAfterPan
                )
            } else {
                return String(
                    format: "Chủ thể sát mép — giữ %.1fx không cắt viền, dịch máy rồi mới zoom %.1fx",
                    zoom, idealZoomAfterPan
                )
            }
        }

        if zoomState == .zoomOut && zoom >= currentZoom - 0.08 {
            return "Chủ thể quá sát/bị cắt viền — hãy lùi máy ra xa một bước để lấy trọn \(subjectName)"
        }

        let zoomTag: String
        if zoom < currentZoom - 0.10 {
            zoomTag = String(format: " · Zoom out %.1fx", zoom)
        } else if zoom > currentZoom + 0.10 {
            zoomTag = String(format: " · Zoom quang học %.1fx", zoom)
        } else {
            zoomTag = ""
        }

        switch style {
        case .keepNatural:
            return "Khung hình \(subjectName) đã cân đối tự nhiên, giữ nguyên bố cục đẹp\(zoomTag)"
        case .ultraWide:
            return String(format: "Chủ thể quá lớn/bị cắt — mở rộng góc %.1fx để giữ trọn %@", zoom, subjectName)
        case .lowHorizonSky:
            let hSuffix = horizonY != nil ? "" : " ước lượng"
            return "Hạ đường chân trời\(hSuffix) xuống 1/3 dưới để tôn mây trời\(zoomTag)"
        case .highHorizonGround:
            let hSuffix = horizonY != nil ? "" : " ước lượng"
            return "Đưa đường chân trời\(hSuffix) lên 1/3 trên để tôn tiền cảnh\(zoomTag)"
        case .mirrorHorizon:
            return "Căn đường chân trời giữa khung tôn hiệu ứng phản chiếu đối xứng\(zoomTag)"
        case .centerFocus, .symmetry:
            return "Đặt \(subjectName) tập trung giữa khung theo bố cục cân đối\(zoomTag)"
        case .elevatedCenter:
            return "Đặt \(subjectName) giữa trục với khoảng nền thoáng bên dưới\(zoomTag)"
        case .groundedCenter:
            return "Đặt \(subjectName) vững trọng tâm với khoảng thở thoáng phía trên\(zoomTag)"
        case .openHeadroom:
            return "Mở khoảng không thoáng phía trên để tôn nổi bật \(subjectName)\(zoomTag)"
        case .negativeSpace:
            return "Tạo không gian âm tối giản quanh \(subjectName) (lệch \(side))\(zoomTag)"
        case .diagonalDynamic:
            return "Đặt \(subjectName) theo đường chéo năng động (\(side)) tạo chiều sâu\(zoomTag)"
        case .lookingRoom:
            return "Đưa \(subjectName) về phía \(side), mở khoảng thở tự nhiên theo hướng nhìn\(zoomTag)"
        case .leadingLines:
            return "Căn đường dẫn phối cảnh hút mắt về \(subjectName)\(zoomTag)"
        case .frameInFrame:
            return "Căn trọn khung nhìn tự nhiên theo bố cục khung trong khung\(zoomTag)"
        case .subtleBalance:
            return "Cân bằng \(subjectName) lệch nhẹ về \(side) gọn gàng, tránh rối viền\(zoomTag)"
        case .ruleOfThirds:
            return "Đặt \(subjectName) tại điểm nhấn \(side) theo bố cục 1/3\(zoomTag)"
        case .goldenRatio:
            return "Đặt \(subjectName) theo trục tỉ lệ vàng (\(side))\(zoomTag)"
        case .neuralFreeform:
            return "AI tối ưu tự do vị trí \(subjectName) theo thẩm mỹ & độ thoáng nền\(zoomTag)"
        }
    }
}
