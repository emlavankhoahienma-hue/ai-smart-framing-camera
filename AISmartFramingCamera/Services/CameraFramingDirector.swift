import Foundation
import CoreGraphics
import simd

/// High-level photographic semantic domain used by the 3D Camera Framing Director.
/// Combines detections from COCO YOLO12s, OpenWorldPhotoYOLOE (101 classes), Vision,
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

/// Free-form photographic composition style selected on merit (never shackled to Golden Ratio).
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
    case lowHorizonSky = "Chân trời thấp tôn mây trời"
    case highHorizonGround = "Chân trời cao tôn tiền cảnh"
    case mirrorHorizon = "Phản chiếu Đối xứng"
    case ultraWide = "Mở rộng Góc siêu rộng"
}

/// Output of the Free-Form Neural-Guided 3D Physical Camera Framing Director.
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
}

/// Free-Form Neural-Guided 3D Handheld Camera Framing Director.
///
/// Unlike rigid Golden-Ratio templates (which shove every subject onto 0.382/0.618),
/// this solver evaluates a rich multi-style portfolio (Center Focus, Symmetry, Minimalist
/// Negative Space, Subtle Editorial Off-Center, Dynamic Diagonal, Looking Room, Leading
/// Lines/VP, Frame-in-Frame, Horizon 1/3-2/3, Mirror Reflection, Pure Neural GAIC Peak,
/// and Keep Natural) JOINTLY across 3D physical pan/tilt and optical zoom lenses
/// (0.5x / 1.0x / 1.2x / 1.5x / 2.0x / 3.0x).
///
/// Every candidate `(destination G, optical zoom Z)` is scored by fusing:
/// 1. Continuous 256-box GAIC + SAMP-Net + Charm-PARA learned aesthetic field
/// 2. SigLIP + geometric edge clutter & incidental obstacle avoidance
/// 3. DepthAnythingV2 foreground/background openness & separation
/// 4. Visual mass torque balance & horizontal symmetry
/// 5. Optical lens quality, subject breathing room & companion protection
enum CameraFramingDirector {
    private static let forward = SIMD3<Double>(0, 0, -1)

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
            "ô tô", "xe máy", "xe tay ga", "xe đạp", "xe buýt", "tàu hỏa", "thuyền", "máy bay"
        ]
        if vehicle.contains(l) { return .vehicle }
        let bgSurface: Set<String> = ["table", "dining table", "bàn ăn"]
        if bgSurface.contains(l) { return .backgroundSurface }
        let furniture: Set<String> = [
            "chair", "sofa", "couch", "lamp", "chandelier", "bed",
            "ghế", "ghế sofa", "đèn", "đèn chùm", "giường", "bàn"
        ]
        if furniture.contains(l) { return .furniture }
        if isGeneralCategory { return .wideNature }
        return .object
    }

    static func localizedName(for label: String) -> String {
        let map: [String: String] = [
            "person": "Người", "human face": "Khuôn mặt",
            "dog": "Chú chó", "cat": "Chú mèo", "bird": "Chim", "duck": "Chú vịt", "parrot": "Chú vẹt",
            "horse": "Ngựa", "cow": "Con bò", "elephant": "Voi", "zebra": "Ngựa vằn", "giraffe": "Hươu cao cổ",
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
            "glass": "Ly thủy tinh", "bottle": "Chai nước", "bowl": "Bát", "plate": "Đĩa",
            "teapot": "Ấm trà", "sandwich": "Bánh mì kẹp",
            "car": "Ô tô", "motorcycle": "Xe máy", "scooter": "Xe tay ga", "bicycle": "Xe đạp",
            "bus": "Xe buýt", "train": "Tàu hỏa", "boat": "Con thuyền", "airplane": "Máy bay",
            "helmet": "Mũ bảo hiểm",
            "laptop": "Laptop", "monitor": "Màn hình", "tv": "Màn hình TV", "keyboard": "Bàn phím",
            "mouse": "Chuột máy tính", "smartphone": "Điện thoại", "camera": "Máy ảnh",
            "headphones": "Tai nghe", "speaker": "Loa", "watch": "Đồng hồ đeo tay",
            "eyeglasses": "Kính mắt", "sunglasses": "Kính râm", "perfume": "Nước hoa", "ring": "Chiếc nhẫn",
            "book": "Cuốn sách", "lamp": "Đèn bàn", "chandelier": "Đèn chùm", "candle": "Ngọn nến",
            "lantern": "Đèn lồng", "vase": "Bình hoa", "clock": "Đồng hồ", "mirror": "Chiếc gương",
            "chair": "Chiếc ghế", "sofa": "Ghế sofa", "table": "Mặt bàn", "bag": "Túi xách",
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
        let cropBox: CGRect
        let isBaseline: Bool
    }

    /// Main entry point: fuses multi-model evidence and solves the optimal free-form 3D camera target & optical zoom.
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
        allowedZooms: [CGFloat]
    ) -> DirectorDecision {
        let safeZoom = max(0.5, currentZoom)
        let safePose = simd_length(pose.vector) > 1e-6 ? simd_normalize(pose) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

        // 1. Fuse masks with semantic detections & deduplicate across YOLO12s + OpenWorldPhotoYOLOE + Foreground Mask
        let fused = deduplicate(detections)
        let faceDets = fused.filter { $0.domain == .face && $0.confidence >= 0.22 }

        // 2. Fuse dense 256-box GAIC + evaluated SAMP/Charm neural proposals FIRST so human-attention consensus guides hero ranking
        let combinedProposals = gaicProposals.isEmpty ? neuralProposals : (gaicProposals + neuralProposals)
        let neuralField = summarizeNeuralProposals(combinedProposals, fallbackBaseZoom: Double(safeZoom))
        let siglipScene = topSiglipScene(semanticAffinities)
        let horizonInfo = estimateHorizonAndRichness(detections: fused, raster: raster, sceneHints: sceneHints, affinities: semanticAffinities)
        let hasWideNatureDet = fused.contains {
            ($0.domain == .wideNature || wideNatureTokens.contains($0.label.lowercased())) && $0.confidence >= 0.20
        }
        let strongWideNature = fused.filter {
            $0.domain == .wideNature && $0.confidence >= 0.38 && $0.area >= 0.14
        }
        let strongArchitecture = fused.filter {
            $0.domain == .architecture && $0.confidence >= 0.30 && $0.area >= 0.16
        }
        let pureFlowerDets = fused.filter { $0.domain == .pureFlower && $0.confidence >= 0.16 }
        let sigHumanAffinity = max(
            semanticAffinities["person"] ?? 0.0,
            max(semanticAffinities["portrait_closeup"] ?? 0.0,
                max(semanticAffinities["portrait_fullbody"] ?? 0.0,
                    max(semanticAffinities["group"] ?? 0.0, semanticAffinities["person_scenery"] ?? 0.0)))
        )

        // 3. Rank foreground object candidates with DepthAnythingV2 + Face + GAIC Attention + Edge-sliver & Hand-held cross-checks
        var fgCandidates: [RankedCandidate] = []
        fgCandidates.reserveCapacity(fused.count + 4)
        for d in fused {
            if d.isAttentionOnly { continue }
            if d.domain == .backgroundSurface || d.domain == .wideNature { continue }
            let lower = d.label.lowercased()
            if lower == "table" || lower == "dining table" || lower == "bàn ăn" { continue }
            let area = d.area
            if area < 0.0035 || (area > 0.94 && d.domain != .human) { continue }
            if d.domain == .foregroundMask && (isBottomStrip(d.boundingBox, center: d.center) || isSideWall(d.boundingBox)) {
                continue
            }

            let c = d.center
            let dAim = hypot(Double(c.x) - 0.50, Double(c.y) - 0.48)
            let aimW = 0.72 + 0.52 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
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

            // Hand-held object detection: headless person/hand overlapping a high-confidence held object yields to the object
            let isHandHoldingObject: Bool = {
                guard d.domain == .human && !hasFace && sigHumanAffinity < 0.030 else { return false }
                return fused.contains { other in
                    (other.domain == .food || other.domain == .object || other.domain == .pureFlower) &&
                    other.confidence >= 0.62 &&
                    rectContainment(other.boundingBox, inside: d.boundingBox) >= 0.52
                }
            }()

            // Suppress plant-confusable COCO fruit hallucinations (e.g. green succulent -> "banana") when flora cues agree
            let isPlantConfusableFood: Bool = {
                guard plantConfusableFoodTokens.contains(lower) else { return false }
                let overlapsFlora = pureFlowerDets.contains { fl in
                    rectIoU(d.boundingBox, fl.boundingBox) > 0.22 || rectContainment(fl.boundingBox, inside: d.boundingBox) > 0.45
                }
                return overlapsFlora || siglipScene == "flower" || siglipScene == "foliage"
            }()

            let catW: Double
            if isCornerHeadless || isHandHoldingObject || isPlantConfusableFood {
                catW = 0.20
            } else {
                switch d.domain {
                case .human: catW = hasFace ? 1.40 : 1.24
                case .face: catW = 1.36
                case .animal: catW = 1.28
                case .pureFlower: catW = 1.22
                case .architecture: catW = 1.12
                case .foregroundMask: catW = 1.00
                default: catW = 1.04
                }
            }

            let isPeripheralClipped = peripheralEquipmentTokens.contains(lower) &&
                (touchesLR || touchesTB) && dAim > 0.18
            var clipW = isPeripheralClipped ? 0.45 : 1.0
            if edgeSliver { clipW *= 0.18 }

            // GAIC human-attention consensus + weak-label semantic cross-checks
            var extraW = 1.0
            if neuralField.hasLearnedScores {
                let dGaic = hypot(Double(c.x) - Double(neuralField.attentionCenter.x),
                                  Double(c.y) - Double(neuralField.attentionCenter.y))
                extraW *= (0.88 + 0.26 * exp(-(dGaic * dGaic) / (2.0 * 0.26 * 0.26)))
            }
            if d.domain == .human && !hasFace && d.confidence < 0.45 &&
                (sigHumanAffinity < 0.020 || Double(d.boundingBox.height) < Double(d.boundingBox.width) * 0.85) {
                extraW *= 0.40
            }
            if d.confidence < 0.42 && (d.domain == .object || d.domain == .furniture) &&
                (siglipScene == "animal" || siglipScene == "flower" || siglipScene == "foliage") {
                extraW *= 0.45
            }

            let score = d.confidence * sqrt(max(0.004, area)) * aimW * depW * catW * clipW * extraW
            fgCandidates.append(RankedCandidate(
                det: d, depth: dep, dAim: dAim, hasFace: hasFace,
                isCornerHeadless: isCornerHeadless || isHandHoldingObject,
                isEdgeSliver: edgeSliver,
                isSuppressedFood: isPlantConfusableFood,
                heroScore: score
            ))
        }

        // Supplement with crisp depth + edge + chromatic/saliency foreground clusters as fallback for non-COCO objects
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
                let aimW = 0.70 + 0.50 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
                let depW = 0.65 + 0.65 * cl.meanDepth
                let attW: Double
                if neuralField.hasLearnedScores {
                    let dGaic = hypot(Double(cl.center.x) - Double(neuralField.attentionCenter.x),
                                      Double(cl.center.y) - Double(neuralField.attentionCenter.y))
                    attW = 0.86 + 0.28 * exp(-(dGaic * dGaic) / (2.0 * 0.25 * 0.25))
                } else {
                    attW = 1.0
                }
                let sc = conf * sqrt(max(0.008, cl.area)) * aimW * depW * 0.92 * attW
                fgCandidates.append(RankedCandidate(
                    det: det, depth: cl.meanDepth, dAim: dAim, hasFace: false,
                    isCornerHeadless: false, isEdgeSliver: false, isSuppressedFood: false, heroScore: sc
                ))
            }
        }
        fgCandidates.sort { $0.heroScore > $1.heroScore }

        // 4. Identify people, dominant foreground objects, companions, interiors, architecture, and wide-nature scenes
        let validPeople = fgCandidates.filter {
            ($0.det.domain == .human || $0.det.domain == .face) &&
            $0.det.confidence >= ($0.hasFace ? 0.26 : 0.36) &&
            $0.det.area >= 0.012 && !$0.isCornerHeadless && !$0.isEdgeSliver
        }
        let validAnimals = fgCandidates.filter {
            $0.det.domain == .animal && !$0.isEdgeSliver && $0.det.confidence >= 0.20
        }
        let namedNonPerson = fgCandidates.filter {
            $0.det.domain != .human && $0.det.domain != .face &&
            $0.det.domain != .architecture && $0.det.domain != .foregroundMask &&
            !$0.isEdgeSliver && !$0.isSuppressedFood &&
            $0.det.confidence >= 0.22
        }
        let maskInstances = fgCandidates.filter {
            $0.det.domain == .foregroundMask && !$0.isEdgeSliver && $0.det.area >= 0.006 && $0.det.area <= 0.72
        }
        let topNamed = namedNonPerson.first
        let topForegroundNonPerson = topNamed ?? maskInstances.first

        // Foreground-object vs distant-bystander arbitration (never overrides clear foreground groups!)
        let bystanderOverridden: Bool = {
            guard let p0 = validPeople.first, let obj = topForegroundNonPerson else { return false }
            let isClearGroup = validPeople.count >= 2 &&
                validPeople[0].det.confidence >= 0.70 &&
                validPeople[1].det.confidence >= 0.65 &&
                validPeople[1].heroScore >= 0.35 * validPeople[0].heroScore
            guard !isClearGroup else { return false }
            if !p0.hasFace && p0.det.confidence < 0.65 && obj.heroScore > p0.heroScore * 1.45 { return true }
            return p0.det.area < 0.16 && obj.depth >= p0.depth + 0.14 && obj.dAim <= 0.26 &&
                (obj.det.area >= p0.det.area * 1.15 || obj.heroScore >= p0.heroScore * 1.10 || p0.dAim > 0.28)
        }()

        // Cohesive tabletop / multi-object companion detection (e.g. coffee + cake, stacked shelf/desk items)
        var companionBoxes: [CGRect] = []
        if namedNonPerson.count >= 2 {
            let lead = namedNonPerson[0]
            for nxt in namedNonPerson.dropFirst().prefix(4) {
                if nxt.heroScore >= 0.40 * lead.heroScore && abs(nxt.depth - lead.depth) < 0.18 {
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
        let dominantWideNature = !strongWideNature.isEmpty && !fgCandidates.contains {
            $0.det.domain == .pureFlower && $0.det.confidence >= 0.35 && !$0.isEdgeSliver
        }
        let dominantArchitecture = (!strongArchitecture.isEmpty || siglipScene == "architecture" || siglipScene == "street" ||
            sceneHints.role == .architecture || sceneHints.role == .streetLeading) &&
            (topNamed.map { $0.det.area < 0.12 && $0.dAim > 0.22 } ?? true)

        // 5. Intelligent Hero & Photographic Role Resolution
        var role: DirectorPhotographicRole = .object
        var heroLabel = "subject"
        var heroLocalized = "Chủ thể nổi bật"
        var heroConf = 0.72
        var heroBox = CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.56)
        var heroAnchor = CGPoint(x: 0.50, y: 0.48)
        var heroGazeX = 0.0
        var protectedBoxes: [CGRect] = []

        if !validPeople.isEmpty && !bystanderOverridden {
            if let explicitGroup = validPeople.first(where: { $0.det.isGroup }) {
                role = .group
                heroBox = explicitGroup.det.boundingBox
                heroAnchor = explicitGroup.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.26 * heroBox.height)
                heroLabel = explicitGroup.det.label
                heroLocalized = explicitGroup.det.localizedLabel
                heroConf = explicitGroup.det.confidence
                protectedBoxes = explicitGroup.det.companionBounds.isEmpty ? [heroBox] : explicitGroup.det.companionBounds
            } else if validPeople.count >= 2 && validPeople[1].heroScore >= 0.35 * validPeople[0].heroScore {
                let members = Array(validPeople.filter { $0.heroScore >= 0.30 * validPeople[0].heroScore }.prefix(6))
                let box = unionRects(members.map(\.det.boundingBox))
                role = .group
                heroBox = box
                heroAnchor = CGPoint(x: box.midX, y: box.minY + 0.26 * box.height)
                heroLabel = "group(\(members.count))"
                heroLocalized = "Nhóm \(members.count) người"
                heroConf = validPeople[0].det.confidence
                protectedBoxes = members.map(\.det.boundingBox)
            } else {
                let p0 = validPeople[0]
                let scenicContext = (siglipScene == "landscape" || siglipScene == "sky_clouds" || siglipScene == "sunset" ||
                    siglipScene == "person_scenery" || siglipScene == "architecture" || siglipScene == "street") &&
                    p0.det.area < 0.16
                role = scenicContext ? .environmentalPortrait : .portrait
                heroBox = p0.det.boundingBox
                if let explicitAnchor = p0.det.anchor {
                    heroAnchor = explicitAnchor
                } else if let matchingFace = faceDets.first(where: { f in
                    let fc = f.center
                    return fc.x >= heroBox.minX - 0.03 && fc.x <= heroBox.maxX + 0.03 &&
                        fc.y >= heroBox.minY - 0.05 && fc.y <= heroBox.minY + 0.45 * heroBox.height
                }) {
                    heroAnchor = CGPoint(x: matchingFace.boundingBox.midX,
                                         y: matchingFace.boundingBox.minY + 0.42 * matchingFace.boundingBox.height)
                } else {
                    heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.minY + 0.18 * heroBox.height)
                }
                heroGazeX = p0.det.gazeX
                heroLabel = p0.det.label
                heroLocalized = p0.det.localizedLabel
                heroConf = p0.det.confidence
                protectedBoxes = p0.det.faceBounds.isEmpty ? [heroBox] : (p0.det.faceBounds + [heroBox])
            }
        } else if let a0 = validAnimals.first,
                  topNamed.map({ $0.det.domain == .animal || a0.heroScore >= $0.heroScore * 0.75 }) ?? true {
            role = .animal
            heroBox = a0.det.boundingBox
            heroAnchor = a0.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.30 * heroBox.height)
            heroGazeX = a0.det.gazeX
            heroLabel = a0.det.label
            heroLocalized = a0.det.localizedLabel
            heroConf = a0.det.confidence
            protectedBoxes = [heroBox]
        } else if isFrameAperture {
            role = .aperture
            heroBox = neuralField.bestBox
            heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
            heroLabel = "frame_aperture"
            heroLocalized = "Khung nhìn qua cửa"
            heroConf = 0.78
        } else if isWholeIndoorRoom {
            role = .indoorRoom
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
            let archDets = fgCandidates.filter { $0.det.domain == .architecture && !$0.isEdgeSliver && $0.det.confidence >= 0.20 }
            role = (siglipScene == "street" || sceneHints.role == .streetLeading) ? .street : .architecture
            if archDets.count >= 2 {
                let box = unionRects(archDets.prefix(5).map(\.det.boundingBox))
                heroBox = box
                heroAnchor = CGPoint(x: box.midX, y: box.midY)
                heroLabel = "architecture(\(archDets.count))"
                heroLocalized = "Cụm kiến trúc"
                heroConf = archDets[0].det.confidence
            } else if let a0 = archDets.first {
                heroBox = a0.det.boundingBox
                heroAnchor = a0.det.center
                heroLabel = a0.det.label
                heroLocalized = a0.det.localizedLabel
                heroConf = a0.det.confidence
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
        } else if let food0 = namedNonPerson.first, food0.det.domain == .food && food0.dAim <= 0.36 {
            role = .food
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
                  (obj0.dAim <= 0.34 || obj0.det.domain == .pureFlower ||
                   (siglipScene != "flower" && siglipScene != "foliage" && siglipScene != "sky_clouds" && siglipScene != "sunset" && siglipScene != "landscape")) {
            role = obj0.det.domain == .animal ? .animal : (obj0.det.domain == .vehicle ? .vehicle : (obj0.det.domain == .pureFlower ? .flower : .object))
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
            let explicitFlora = fgCandidates.first { $0.det.domain == .pureFlower && !$0.isEdgeSliver && $0.det.area < 0.72 }
            if let f = explicitFlora {
                role = .flower
                heroBox = f.det.boundingBox
                heroAnchor = f.det.anchor ?? f.det.center
                heroLabel = f.det.label
                heroLocalized = f.det.localizedLabel
                heroConf = f.det.confidence
            } else if let m0 = maskInstances.first(where: { !$0.isEdgeSliver }), m0.det.area >= 0.04 {
                role = siglipScene == "flower" ? .flower : .foliage
                heroBox = m0.det.boundingBox
                heroAnchor = m0.det.anchor ?? m0.det.center
                heroLabel = role == .flower ? "flower_mask" : "foliage_mask"
                heroLocalized = role == .flower ? "Cụm hoa tiền cảnh" : "Tán lá thiên nhiên"
                heroConf = max(0.72, m0.det.confidence)
            } else {
                role = siglipScene == "flower" ? .flower : .foliage
                heroBox = neuralField.attentionBox
                heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
                heroLabel = role.rawValue
                heroLocalized = role == .flower ? "Cụm hoa nổi bật" : "Mảng xanh thiên nhiên"
                heroConf = 0.70
            }
            protectedBoxes = [heroBox]
        } else if siglipScene == "sky_clouds" || siglipScene == "sunset" || siglipScene == "landscape" ||
                  siglipScene == "person_scenery" || (hasWideNatureDet && horizonInfo.horizonY != nil) ||
                  sceneHints.role == .landscapeSky {
            let hy = horizonInfo.horizonY ?? 0.48
            role = .skyLandscape
            heroBox = CGRect(x: 0.10, y: max(0.05, hy - 0.16), width: 0.80, height: min(0.90, 0.32))
            heroAnchor = CGPoint(x: 0.50, y: hy)
            heroLabel = "sky_landscape"
            heroLocalized = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? "Bầu trời & mây" : "Cảnh quan rộng"
            heroConf = 0.78
        } else if let obj0 = topForegroundNonPerson {
            role = obj0.det.domain == .vehicle ? .vehicle : .object
            heroBox = obj0.det.boundingBox
            heroAnchor = obj0.det.anchor ?? obj0.det.center
            heroLabel = obj0.det.label
            heroLocalized = obj0.det.localizedLabel
            heroConf = obj0.det.confidence
            protectedBoxes = [heroBox]
        } else {
            role = .scene
            heroBox = neuralField.attentionBox
            heroAnchor = CGPoint(x: heroBox.midX, y: heroBox.midY)
            heroLabel = "scene_gaic"
            heroLocalized = "Khung cảnh tổng thể"
            heroConf = 0.66
        }

        // 6. Cramped Ultra-Wide 0.5x Gate (Immediate escape when subject is clipped on borders)
        let bw = max(0.02, Double(heroBox.width))
        let bh = max(0.02, Double(heroBox.height))
        let bArea = bw * bh
        let edgeTouches =
            (heroBox.minX <= 0.015 ? 1 : 0) +
            (heroBox.maxX >= 0.985 ? 1 : 0) +
            (heroBox.minY <= 0.015 ? 1 : 0) +
            (heroBox.maxY >= 0.985 ? 1 : 0)
        let topFaceClipped = (role == .portrait || role == .group) && heroBox.minY <= 0.012 && bArea >= 0.64
        let archCramped = role == .architecture && heroBox.minY <= 0.015 && heroBox.maxY >= 0.985 && bw >= 0.76
        let groupCramped = role == .group && edgeTouches >= 3 && bArea >= 0.66
        let isSeverelyCramped = topFaceClipped || archCramped || groupCramped

        let minHardwareZoom = allowedZooms.min() ?? 1.0
        let maxHardwareZoom = max(safeZoom, allowedZooms.max() ?? 3.0)
        let hasUltraWide = minHardwareZoom <= 0.60

        if isSeverelyCramped && ((hasUltraWide && safeZoom >= 0.90) || safeZoom > 1.15) {
            let wideZoom: CGFloat = (hasUltraWide && safeZoom >= 0.90) ? 0.5 : max(1.0, minHardwareZoom)
            let destG = CGPoint(x: 0.50, y: (role == .portrait || role == .group) ? 0.42 : 0.50)
            let solved = solveAimAndCrop(anchor: heroAnchor, destG: destG, relZoom: max(0.35, Double(wideZoom / safeZoom)), calibration: calibration)
            let aimWorldRay = safePose.act(solved.aimDeviceRay)
            let explanation = buildExplanation(
                role: role, localizedLabel: heroLocalized, destG: destG, zoom: wideZoom,
                currentZoom: safeZoom, style: .ultraWide, horizonY: horizonInfo.horizonY
            )
            return DirectorDecision(
                role: role, heroLabel: heroLabel, heroLocalizedLabel: heroLocalized,
                heroBounds: heroBox, heroAnchor: heroAnchor, destinationPoint: destG,
                aimPointInSource: solved.aim, aimWorldRay: aimWorldRay, rotation: solved.rotation,
                recommendedZoom: wideZoom, confidence: max(0.45, min(0.98, heroConf)),
                usesCenter: true, preservesOriginalFrame: false,
                ruleName: DirectorCompositionStyle.ultraWide.rawValue,
                compositionStyle: .ultraWide, explanation: explanation, detectedHorizonY: horizonInfo.horizonY
            )
        }

        // 7. JOINT FREE-FORM MULTI-STYLE (Destination G, Optical Zoom Z) PORTFOLIO — SENSOR-ASPECT AWARE
        let sensorAspect = calibration.aspect.isFinite && calibration.aspect > 0.1 ? calibration.aspect : 0.75
        let isPortraitSensor = sensorAspect < 0.88
        let isSquareSensor = sensorAspect >= 0.88 && sensorAspect <= 1.12
        let targetLinear = idealLinearFill(for: role)
        let areaRoot = sqrt(max(0.002, bArea))
        let visualSize: Double
        let targetScale: Double
        if role == .portrait || role == .environmentalPortrait {
            visualSize = 0.55 * areaRoot + 0.45 * bh
            targetScale = targetLinear * (sensorAspect > 1.12 ? 0.86 : 0.92)
        } else {
            visualSize = 0.68 * areaRoot + 0.32 * max(bw, bh)
            targetScale = targetLinear * 0.90
        }
        let isMinimalist = (semanticAffinities["minimalist_space"] ?? 0.0) > 0.032 ||
            (semanticAffinities["single_product"] ?? 0.0) > 0.040
        let isWaterReflection = (semanticAffinities["water_reflection"] ?? 0.0) > 0.045

        var zoomRungs: [CGFloat] = [safeZoom]
        if role != .skyLandscape && role != .indoorRoom {
            for rung in [CGFloat(1.0), 1.2, 1.5, 2.0, 3.0] {
                if rung >= safeZoom * 0.98 && rung <= min(maxHardwareZoom, safeZoom * 3.0) {
                    if !zoomRungs.contains(where: { abs($0 - rung) < 0.04 }) {
                        zoomRungs.append(rung)
                    }
                }
            }
            for hw in allowedZooms where hw >= safeZoom * 0.98 && hw <= min(3.5, safeZoom * 3.0) {
                if !zoomRungs.contains(where: { abs($0 - hw) < 0.04 }) {
                    zoomRungs.append(hw)
                }
            }
        }

        // Adjust sky landscape anchor if a dramatic sun/bright accent exists
        var effectiveAnchor = heroAnchor
        if role == .skyLandscape, let hy = horizonInfo.horizonY, let sunX = brightSkyAccentX(horizonY: hy, raster: raster) {
            effectiveAnchor = CGPoint(x: sunX, y: hy)
        }

        var candidates: [FramingCandidate] = [
            FramingCandidate(
                destG: effectiveAnchor, zoom: safeZoom, style: .keepNatural,
                aim: CGPoint(x: 0.5, y: 0.5), rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                cropBox: CGRect(x: 0, y: 0, width: 1, height: 1), isBaseline: true
            )
        ]

        for z in zoomRungs {
            let relZ = max(0.35, Double(z / safeZoom))
            let projW = bw * relZ
            let projH = bh * relZ
            if role != .portrait && role != .architecture && role != .street && role != .scene && role != .aperture &&
               (projW > 0.92 || projH > 0.92) && z > safeZoom * 1.04 {
                continue
            }
            if role == .portrait && (projW > 0.94 || projH > 1.38) && z > safeZoom * 1.04 {
                continue
            }

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
                // 1) Pure Learned Neural Optimum from 256-box GAIC + SAMP/Charm at this zoom
                if let neuralPeak = neuralField.peakBox(nearRelativeZoom: relZ) {
                    let gx = max(0.24, min(0.76, (Double(effectiveAnchor.x) - Double(neuralPeak.minX)) / max(0.05, Double(neuralPeak.width))))
                    let gy = max(0.24, min(0.76, (Double(effectiveAnchor.y) - Double(neuralPeak.minY)) / max(0.05, Double(neuralPeak.height))))
                    styleDests.append((CGPoint(x: gx, y: gy), .neuralFreeform))
                }

                // 2) Center Hero / Symmetry + Single-Axis Centering for tall/wide heroes
                let headToEye = max(0.04, Double(effectiveAnchor.y - heroBox.minY) * relZ)
                let minPortraitY: Double = (role == .portrait && isPortraitSensor) ? 0.32 : (role == .portrait ? 0.33 : 0.37)
                let portraitSafeY = min(0.45, max(minPortraitY, 0.07 + headToEye))
                let centerY: Double = (role == .portrait || role == .environmentalPortrait || role == .group)
                    ? portraitSafeY
                    : ((role == .flower || role == .animal) ? 0.46 : 0.50)
                styleDests.append((CGPoint(x: 0.50, y: centerY), (role == .architecture ? .symmetry : .centerFocus)))
                if projH >= 0.80 {
                    styleDests.append((CGPoint(x: 0.50, y: Double(effectiveAnchor.y)), .centerFocus))
                }
                if projW >= 0.80 {
                    styleDests.append((CGPoint(x: Double(effectiveAnchor.x), y: centerY), .centerFocus))
                }

                let thirdStyle: DirectorCompositionStyle = abs(heroGazeX) >= 0.14 ? .lookingRoom : .ruleOfThirds
                let isDynamicRole = (role == .object || role == .food || role == .flower ||
                    role == .animal || role == .vehicle || role == .foliage)

                // 3) Sensor-Aspect-Adapted Portfolio: Portrait (3:4 / 9:16) vs Square (1:1) vs Landscape (4:3 / 3:2)
                if isPortraitSensor {
                    if role != .portrait && role != .environmentalPortrait && role != .group {
                        styleDests.append((CGPoint(x: 0.50, y: 0.41), .elevatedCenter))
                        styleDests.append((CGPoint(x: 0.50, y: 0.58), .groundedCenter))
                        if projH < 0.48 {
                            styleDests.append((CGPoint(x: 0.50, y: 0.64), .openHeadroom))
                        }
                    }
                    let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                    styleDests.append((CGPoint(x: 0.44, y: subtleY), .subtleBalance))
                    styleDests.append((CGPoint(x: 0.56, y: subtleY), .subtleBalance))
                    if projW < 0.54 || abs(heroGazeX) >= 0.14 {
                        styleDests.append((CGPoint(x: 0.375, y: subtleY), thirdStyle))
                        styleDests.append((CGPoint(x: 0.625, y: subtleY), thirdStyle))
                    }
                    if isDynamicRole && projW < 0.56 && projH < 0.58 {
                        styleDests.append((CGPoint(x: 0.39, y: 0.40), .diagonalDynamic))
                        styleDests.append((CGPoint(x: 0.61, y: 0.58), .diagonalDynamic))
                    }
                } else if isSquareSensor {
                    if role != .portrait && role != .environmentalPortrait && role != .group {
                        styleDests.append((CGPoint(x: 0.50, y: 0.43), .elevatedCenter))
                        styleDests.append((CGPoint(x: 0.50, y: 0.56), .groundedCenter))
                    }
                    let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                    styleDests.append((CGPoint(x: 0.43, y: subtleY), .subtleBalance))
                    styleDests.append((CGPoint(x: 0.57, y: subtleY), .subtleBalance))
                    if projW < 0.54 || abs(heroGazeX) >= 0.14 {
                        styleDests.append((CGPoint(x: 0.375, y: subtleY), thirdStyle))
                        styleDests.append((CGPoint(x: 0.625, y: subtleY), thirdStyle))
                    }
                    if isDynamicRole && projW < 0.56 && projH < 0.56 {
                        styleDests.append((CGPoint(x: 0.38, y: 0.40), .diagonalDynamic))
                        styleDests.append((CGPoint(x: 0.62, y: 0.58), .diagonalDynamic))
                    }
                } else {
                    if role != .portrait && role != .environmentalPortrait && role != .group {
                        styleDests.append((CGPoint(x: 0.50, y: 0.44), .elevatedCenter))
                        styleDests.append((CGPoint(x: 0.50, y: 0.55), .groundedCenter))
                    }
                    let subtleY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.47
                    styleDests.append((CGPoint(x: 0.435, y: subtleY), .subtleBalance))
                    styleDests.append((CGPoint(x: 0.565, y: subtleY), .subtleBalance))
                    let thirdY: Double = (role == .portrait || role == .environmentalPortrait) ? portraitSafeY : 0.45
                    styleDests.append((CGPoint(x: 0.37, y: thirdY), thirdStyle))
                    styleDests.append((CGPoint(x: 0.63, y: thirdY), thirdStyle))
                    if projW < 0.50 && projH < 0.64 {
                        styleDests.append((CGPoint(x: 0.33, y: 0.46), .negativeSpace))
                        styleDests.append((CGPoint(x: 0.67, y: 0.46), .negativeSpace))
                    }
                    if isDynamicRole && projW < 0.54 && projH < 0.56 {
                        styleDests.append((CGPoint(x: 0.37, y: 0.40), .diagonalDynamic))
                        styleDests.append((CGPoint(x: 0.63, y: 0.58), .diagonalDynamic))
                    }
                }

                // 4) Leading Lines / Vanishing Point (for streets, alleys, bridges, architecture)
                if (role == .street || role == .architecture),
                   let vp = sceneHints.refinedVanishingPoint ?? raster.measuredVanishingPoint.map({ VanishingPointHint(point: $0.point, confidence: $0.confidence) }),
                   vp.confidence >= 0.30 {
                    let vpY = max(0.32, min(0.58, Double(vp.point.y)))
                    styleDests.append((CGPoint(x: 0.50, y: vpY), .leadingLines))
                }
            }

            for (rawDest, style) in styleDests {
                var gx = Double(rawDest.x)
                var gy = Double(rawDest.y)
                if role != .skyLandscape && role != .architecture && role != .street && role != .scene && role != .aperture && role != .indoorRoom {
                    let halfW = 0.5 * projW
                    let halfH = 0.5 * projH
                    if halfW < 0.44 { gx = max(0.05 + halfW, min(0.95 - halfW, gx)) } else { gx = 0.50 }
                    if role != .portrait && role != .environmentalPortrait {
                        if halfH < 0.44 { gy = max(0.05 + halfH, min(0.95 - halfH, gy)) } else { gy = 0.50 }
                    }
                }
                let dest = CGPoint(x: gx, y: gy)
                let solved = solveAimAndCrop(anchor: effectiveAnchor, destG: dest, relZoom: relZ, calibration: calibration)
                candidates.append(FramingCandidate(
                    destG: dest, zoom: z, style: style,
                    aim: solved.aim, rotation: solved.rotation, cropBox: solved.cropBox, isBaseline: false
                ))
            }
        }

        // 8. UNIFIED MULTI-CUE PHOTOGRAPHIC SCORING (Zero Golden-Ratio Straitjacket!)
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
        let rawAlreadyStrong = (gaicHeadroom < 0.025) && rawEdgeDist >= 0.27 && !heroCrampedSide && rawHorizonOK &&
            visualSize >= targetScale * 0.72 && abs(heroGazeX) < 0.14 && clutterSum < 0.28

        var bestCandidate = candidates[0]
        var bestScore = -Double.infinity

        for cand in candidates {
            let relZ = max(0.35, Double(cand.zoom / safeZoom))
            let crop = cand.cropBox
            let projHero = projectBox(heroBox, aim: cand.aim, relZoom: relZ)

            // Hard safety gate: never clip hero or companions when panning/zooming
            if !cand.isBaseline && role != .skyLandscape && role != .scene && role != .architecture &&
               role != .street && role != .indoorRoom && role != .aperture {
                let targetVis: Double = (role == .portrait) ? 0.72 : 0.85
                let minVis = min(targetVis, max(0.68, baseVisHero - 0.02))
                if visibleFraction(projHero, margin: 0.025) < minVis { continue }
                if !protectedBoxes.isEmpty {
                    let allProtectedOK = protectedBoxes.allSatisfy { pBox in
                        let pp = projectBox(pBox, aim: cand.aim, relZoom: relZ)
                        let basePVis = visibleFraction(pBox, margin: 0.02)
                        let req = min((role == .portrait && pBox == heroBox) ? 0.72 : 0.82, max(0.66, basePVis - 0.02))
                        return visibleFraction(pp, margin: 0.02) >= req
                    }
                    if !allProtectedOK { continue }
                }
            }

            // 1) Continuous 256-box Learned Neural Aesthetic Score
            //    - Zoomed views: exact interpolated GAIC score with hard floor (never wreck composition!)
            //    - 1.0x pan views: same-aspect directional GAIC gradient capped cleanly so 1x never steals zoom's gain
            let rawGAIC: Double
            let effectiveGAIC: Double
            if relZ > 1.05 {
                rawGAIC = neuralField.interpolatedScore(for: crop)
                let heroIsTiny = visualSize < targetScale * 0.64
                let maxAllowedDrop = heroIsTiny ? 0.050 : 0.015
                if neuralField.hasLearnedScores && rawGAIC < neuralField.baseScore - maxAllowedDrop {
                    continue
                }
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
                ? min(0.30, (rawGAIC - neuralField.baseScore) * 1.75)
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
                    visibleFraction(projectBox(inc, aim: cand.aim, relZoom: relZ), margin: 0.0) < 0.25
                }.count
                incidentalCleared = min(0.22, Double(clearedCount) * 0.08)
            }
            let clutterScore = min(1.0, max(-0.4, 0.45 + 0.55 * clutterCleared + 0.35 * panAwayClutter + incidentalCleared - panIntoClutter))

            // 3) Sensor-Aspect-Invariant Shot Scale & Optical Lens Quality
            let scaleErr = abs(log(max(0.05, visualSize * relZ) / targetScale))
            let scaleScore = exp(-1.15 * scaleErr * scaleErr)
            let isHardwareLens = allowedZooms.contains { abs($0 - cand.zoom) <= 0.06 }
            let optBonus = isHardwareLens ? 0.032 : 0.022
            let zoomPen = (visualSize >= targetScale * 0.85 && (!neuralField.hasLearnedScores || rawGAIC < neuralField.baseScore + 0.035))
                ? 0.04 * max(0.0, relZ - 1.5)
                : 0.0

            // 4) Natural Composition Harmony, Pan-Aware Visual Torque Balance, Edge-Relief & Depth Openness
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
                    let idealGazeX = wantLeft ? 0.375 : 0.625
                    let dxGaze = Double(cand.destG.x) - idealGazeX
                    let gazeGood = wantLeft ? (Double(cand.destG.x) < 0.42) : (Double(cand.destG.x) > 0.58)
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
                    if isMinimalist { centerMerit += 0.16 }
                    if bw * relZ >= 0.46 { centerMerit += 0.14 }
                    if role == .group || role == .architecture { centerMerit += 0.14 }
                    if isSquareSensor { centerMerit += 0.06 }
                    styleFit += centerMerit
                } else {
                    let placedLeft = Double(cand.destG.x) < 0.48
                    let openMatch = placedLeft ? (rightOpen - leftOpen) : (leftOpen - rightOpen)
                    styleFit += 0.24 * max(-0.22, min(0.45, openMatch * 2.2))
                    if bw * relZ < 0.46 && bh * relZ < 0.56 {
                        styleFit += 0.08
                    }
                }
                if cand.style == .leadingLines {
                    styleFit += 0.18
                }
            }

            // 5) Earned Keep-Natural stability + Breathing Negative-Space guard for tight zooms
            let shift = hypot(Double(cand.aim.x) - 0.5, Double(cand.aim.y) - 0.5)
            let keepBonus = cand.isBaseline
                ? (rawAlreadyStrong ? 0.042 : -0.055)
                : (-0.022 * max(0.0, shift - 0.26))

            let projFill = Double(projHero.width * projHero.height)
            let breathingPen: Double = (!cand.isBaseline && cand.zoom > safeZoom * 1.05 &&
                                        projFill > 0.62 &&
                                        role != .portrait && role != .environmentalPortrait &&
                                        role != .group && role != .architecture)
                ? 0.08 * min(1.0, (projFill - 0.62) / 0.28)
                : 0.0

            let neuralWeight = neuralField.hasLearnedScores ? 0.44 : 0.0
            let totalScore = neuralWeight * normGAIC +
                gaicGainBonus +
                0.18 * clutterScore +
                0.20 * scaleScore +
                0.22 * styleFit +
                optBonus + keepBonus - zoomPen - breathingPen

            if totalScore > bestScore {
                bestScore = totalScore
                bestCandidate = cand
            }
        }

        // 9. Finalize chosen 3D ray, style label & honest Vietnamese guidance explanation
        let finalAim = bestCandidate.aim
        let finalZoom = bestCandidate.zoom
        let finalDest = bestCandidate.destG
        let finalAimDeviceRay = calibration.deviceRay(at: finalAim)
        let finalRotation = simd_quatd(from: forward, to: finalAimDeviceRay)
        let aimWorldRay = safePose.act(finalAimDeviceRay)

        let aimShift = hypot(Double(finalAim.x - 0.5), Double(finalAim.y - 0.5))
        let zoomChanged = abs(finalZoom - safeZoom) >= 0.10
        let preservesOriginal = bestCandidate.isBaseline || (aimShift < 0.028 && !zoomChanged)

        let resolvedStyle: DirectorCompositionStyle = {
            if preservesOriginal { return .keepNatural }
            if bestCandidate.style == .neuralFreeform {
                let dCenter = hypot(Double(finalDest.x) - 0.5, Double(finalDest.y) - 0.5)
                if dCenter < 0.075 { return .centerFocus }
                if abs(Double(finalDest.x) - 0.5) > 0.08 && abs(Double(finalDest.y) - 0.5) > 0.08 { return .diagonalDynamic }
            }
            return bestCandidate.style
        }()

        let usesCenter = abs(Double(finalDest.x) - 0.50) < 0.065 && abs(Double(finalDest.y) - 0.50) < 0.085
        let explanation = buildExplanation(
            role: role,
            localizedLabel: heroLocalized,
            destG: finalDest,
            zoom: finalZoom,
            currentZoom: safeZoom,
            style: resolvedStyle,
            horizonY: horizonInfo.horizonY
        )

        return DirectorDecision(
            role: role,
            heroLabel: heroLabel,
            heroLocalizedLabel: heroLocalized,
            heroBounds: heroBox,
            heroAnchor: effectiveAnchor,
            destinationPoint: finalDest,
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
            detectedHorizonY: horizonInfo.horizonY
        )
    }

    // MARK: - 3D Geometry & Projection Helpers

    private static func solveAimAndCrop(
        anchor: CGPoint,
        destG: CGPoint,
        relZoom: Double,
        calibration: TrackingCalibration
    ) -> (aim: CGPoint, aimDeviceRay: SIMD3<Double>, rotation: simd_quatd, cropBox: CGRect) {
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
                panMinX = 0.26; panMaxX = 0.74
                panMinY = 0.20; panMaxY = 0.80
            } else if aspect > 1.12 {
                panMinX = 0.20; panMaxX = 0.80
                panMinY = 0.26; panMaxY = 0.74
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

        let cropBox: CGRect
        if relZoom <= 1.05 {
            // Visible overlap of the panned 1.0x frame inside the current sensor view
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
        return (finalAim, aimRay, finalRot, cropBox)
    }

    private static func projectBox(_ box: CGRect, aim: CGPoint, relZoom: Double) -> CGRect {
        let z = CGFloat(relZoom)
        let nx0 = 0.5 + (box.minX - aim.x) * z
        let ny0 = 0.5 + (box.minY - aim.y) * z
        return CGRect(x: nx0, y: ny0, width: box.width * z, height: box.height * z)
    }

    private static func visibleFraction(_ rect: CGRect, margin: CGFloat) -> Double {
        let area = Double(max(1e-6, rect.width * rect.height))
        let safeBounds = CGRect(x: margin, y: margin, width: max(0.01, 1.0 - 2 * margin), height: max(0.01, 1.0 - 2 * margin))
        let inter = rect.intersection(safeBounds)
        guard !inter.isNull, !inter.isEmpty else { return 0.0 }
        return Double(inter.width * inter.height) / area
    }

    // MARK: - Helpers

    private static func idealLinearFill(for role: DirectorPhotographicRole) -> Double {
        switch role {
        case .portrait: return 0.56
        case .environmentalPortrait: return 0.38
        case .group: return 0.66
        case .animal: return 0.48
        case .flower: return 0.48
        case .foliage: return 0.58
        case .food: return 0.52
        case .object: return 0.50
        case .vehicle: return 0.50
        case .indoorRoom: return 0.74
        case .aperture: return 0.66
        case .architecture: return 0.72
        case .street: return 0.62
        case .skyLandscape: return 0.80
        case .scene: return 0.72
        }
    }

    private static func deduplicate(_ detections: [DirectorDetection]) -> [DirectorDetection] {
        // 1. Fuse compact foreground masks with overlapping semantic detections (boosts confidence & tightens bounds)
        let compactMasks = detections.filter {
            $0.domain == .foregroundMask && $0.area <= 0.62 &&
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
                        mergedBox = CGRect(x: x0, y: y0, width: max(0.02, x1 - x0), height: max(0.02, y1 - y0))
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
        // 1b. Suppress giant COCO "tie" false positives on standalone vertical monuments/statues/towers
        // when OpenWorldPhotoYOLOE explicitly recognizes architecture/monument on the same box.
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
        // 2. Prioritize semantic detections over raw unlabeled masks when IoU > 0.55
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

    /// Rejects foreground horizontal ground/ledge/windowsill slabs touching the bottom border.
    private static func isBottomStrip(_ rect: CGRect, center: CGPoint) -> Bool {
        (rect.maxY >= 0.96 && center.y > 0.78 && rect.width > 0.45) ||
        (rect.maxY >= 0.90 && rect.width >= 0.88 && center.y > 0.60)
    }

    /// Rejects tall or thin vertical side-edge wall/pillar/strip occluders touching left or right border.
    private static func isSideWall(_ rect: CGRect) -> Bool {
        let touchesLR = rect.minX <= 0.025 || rect.maxX >= 0.975
        return touchesLR && ((rect.height >= 0.65 && rect.width <= 0.42) || (rect.height >= 0.32 && rect.width <= 0.14))
    }

    /// Universal border-rim fragment filter (stops tiny clipped cars, single corner leaves, or border artifacts
    /// from hijacking giant buildings, plants, or landscapes).
    private static func isEdgeSliver(_ rect: CGRect, domain: DirectorSubjectDomain, hasFace: Bool) -> Bool {
        if domain == .face || hasFace { return false }
        let area = Double(max(0, rect.width) * max(0, rect.height))
        let dAim = hypot(Double(rect.midX) - 0.50, Double(rect.midY) - 0.48)
        let touchesLR = rect.minX <= 0.04 || rect.maxX >= 0.96
        let touchesTB = rect.minY <= 0.04 || rect.maxY >= 0.96
        guard touchesLR || touchesTB else { return false }
        if area < 0.065 && dAim > 0.29 { return true }
        if (rect.minX <= 0.025 || rect.maxX >= 0.975) && rect.width < 0.11 && area < 0.09 { return true }
        if (rect.minY <= 0.025 || rect.maxY >= 0.975) && rect.height < 0.11 && area < 0.09 { return true }
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

    /// Combines DepthAnythingV2 disparity (detail-gated to suppress flat close tables/ledges),
    /// edge sharpness, and chromatic/saliency contrast to lift non-COCO objects (flowers, insects, products).
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
        // 3x3 box-smooth edge energy so textured object interiors stay cohesive while flat ledges stay near 0
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
        guard p95 - p20 >= 0.12 else { return [] }
        // Dual-threshold hysteresis heat-island growing: only high-energy cores (>= seedThresh)
        // can spawn a cluster, then connected silhouette pixels grow smoothly down to growThresh
        // without pulling in disconnected background clutter.
        let seedThresh = max(0.45, p82 + 0.28 * (p95 - p82))
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
                if area < 0.012 && (meanS < 0.20 || meanC < 0.38) { continue }
                if meanS < 0.08 && meanC < 0.24 { continue }
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

    private static func brightSkyAccentX(horizonY: Double, raster: CompositionRaster) -> Double? {
        let s = raster.side
        guard s >= 8, raster.luminance.count == s * s else { return nil }
        let cut = max(2, min(s - 2, Int(horizonY * Double(s))))
        var peakVal = 0.0
        var peakX = s / 2
        for y in 0..<cut {
            let row = y * s
            for x in 0..<s {
                let v = raster.luminance[row + x]
                if v > peakVal { peakVal = v; peakX = x }
            }
        }
        guard peakVal > 0.92 else { return nil }
        return (Double(peakX) + 0.5) / Double(s)
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

        /// Top-8 nearest-window sharp kernel interpolation (preserves true GAIC peaks without smearing).
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
                // Blend GAIC (256-box learned crop scorer) with fused SAMP/Charm score when evaluated
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

        // Compute top-10 tight GAIC consensus attention center & top-5 attention box
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
        horizonY: Double?
    ) -> String {
        let side = destG.x < 0.45 ? "trái" : (destG.x > 0.55 ? "phải" : "giữa")
        let zoomTag: String
        if zoom < currentZoom - 0.12 {
            zoomTag = String(format: " · Lùi góc rộng %.1fx", zoom)
        } else if zoom > currentZoom + 0.12 {
            zoomTag = String(format: " · Zoom quang học %.1fx", zoom)
        } else {
            zoomTag = ""
        }
        let subjectName = localizedLabel.lowercased()
        switch style {
        case .keepNatural:
            return "Khung hình \(subjectName) đã cân đối tự nhiên, giữ nguyên bố cục đẹp\(zoomTag)"
        case .ultraWide:
            return "Chủ thể sát viền — mở rộng góc %.1fx để giữ trọn \(subjectName)".replacingOccurrences(of: "%.1fx", with: String(format: "%.1fx", zoom))
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
        case .neuralFreeform:
            return "AI tối ưu tự do vị trí \(subjectName) theo thẩm mỹ & độ thoáng nền\(zoomTag)"
        }
    }
}
