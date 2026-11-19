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
        case .indoorRoom, .architecture: return .architecture
        case .flower, .foliage: return .closeUp
        case .food: return .food
        case .vehicle, .object: return .object
        case .skyLandscape, .scene: return .landscape
        case .street: return .street
        }
    }
}

/// Output of the 3D Physical Camera Pan/Tilt + Smart Optical Zoom Director.
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
    let explanation: String
    let detectedHorizonY: Double?
}

/// True 3D Handheld Camera Framing Director.
///
/// Unlike a static 2D cropper (which rejects all 1.0x shifts because corners move outside [0, 1]),
/// this solver understands that the photographer can physically pan/tilt the iPhone in 3D space
/// AND switch optical lenses (0.5x / 1.0x / 1.2x / 1.5x / 2.0x / 3.0x).
/// It solves the exact 3D spherical rotation R* mapping the chosen subject anchor (eye, flower
/// cluster, foreground object centroid, or horizon line) onto the ideal Golden Ratio / Rule-of-Thirds
/// / Symmetry sweet spot, while honoring DepthAnythingV2 depth separation, SigLIP scene semantics,
/// and per-photo normalized GAIC + SAMP-Net + Charm-PARA aesthetic scores.
enum CameraFramingDirector {
    private static let forward = SIMD3<Double>(0, 0, -1)

    private static let peripheralEquipmentTokens: Set<String> = [
        "monitor", "keyboard", "laptop", "bàn phím", "màn hình"
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
            "dog", "cat", "bird", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
            "butterfly", "fish", "animal", "chó", "mèo", "chim", "ngựa", "thú cưng", "động vật"
        ]
        if animals.contains(l) { return .animal }
        let pureFlowers: Set<String> = [
            "flower", "blossom", "rose", "sunflower", "tulip", "bouquet", "leaf", "branch", "cactus",
            "hoa", "bông hoa", "cành hoa", "lá cây", "hoa hồng", "hoa hướng dương"
        ]
        if pureFlowers.contains(l) { return .pureFlower }
        let potted: Set<String> = ["potted plant", "green plant", "chậu cây", "cây xanh"]
        if potted.contains(l) { return .pottedPlant }
        let wideNature: Set<String> = [
            "sky", "cloud", "sunset", "sun", "moon", "mountain", "hill", "sea", "ocean", "beach",
            "river", "lake", "waterfall", "rainbow", "forest", "grass", "tree", "palm tree",
            "bầu trời", "mây", "hoàng hôn", "mặt trời", "núi", "biển", "bãi biển", "sông", "hồ", "thác nước", "rừng", "cây"
        ]
        if wideNature.contains(l) { return .wideNature }
        let arch: Set<String> = [
            "building", "house", "skyscraper", "tower", "bridge", "temple", "church", "window",
            "doorway", "balcony", "stairs", "street", "alley", "road", "street sign",
            "tòa nhà", "ngôi nhà", "nhà cao tầng", "tháp", "cây cầu", "đền chùa", "nhà thờ", "đường phố", "con hẻm"
        ]
        if arch.contains(l) { return .architecture }
        let food: Set<String> = [
            "food", "dish", "cake", "dessert", "fruit", "pizza", "burger", "noodle", "bread",
            "coffee", "cup", "tea", "drink", "glass", "wine glass", "bottle", "bowl", "plate",
            "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "donut",
            "món ăn", "đồ ăn", "bánh ngọt", "trái cây", "cà phê", "cốc nước", "trà", "ly rượu", "chai nước", "bát đĩa"
        ]
        if food.contains(l) { return .food }
        let vehicle: Set<String> = [
            "car", "motorcycle", "bicycle", "bus", "truck", "train", "boat", "airplane",
            "ô tô", "xe máy", "xe đạp", "xe buýt", "tàu hỏa", "thuyền", "máy bay"
        ]
        if vehicle.contains(l) { return .vehicle }
        let bgSurface: Set<String> = ["table", "dining table", "bàn ăn"]
        if bgSurface.contains(l) { return .backgroundSurface }
        let furniture: Set<String> = [
            "chair", "sofa", "couch", "lamp", "bed",
            "ghế", "ghế sofa", "đèn", "giường", "bàn"
        ]
        if furniture.contains(l) { return .furniture }
        if isGeneralCategory { return .wideNature }
        return .object
    }

    static func localizedName(for label: String) -> String {
        let map: [String: String] = [
            "person": "Người", "human face": "Khuôn mặt",
            "dog": "Chú chó", "cat": "Chú mèo", "bird": "Chim", "horse": "Ngựa",
            "elephant": "Voi", "zebra": "Ngựa vằn", "giraffe": "Hươu cao cổ", "butterfly": "Bướm",
            "fish": "Cá", "animal": "Động vật",
            "flower": "Bông hoa", "blossom": "Cụm hoa", "rose": "Hoa hồng",
            "sunflower": "Hoa hướng dương", "tulip": "Hoa tulip", "bouquet": "Bó hoa",
            "leaf": "Chiếc lá", "green plant": "Cây xanh", "potted plant": "Chậu cây",
            "tree": "Tán cây", "palm tree": "Cây cọ", "branch": "Cành cây", "forest": "Khu rừng",
            "grass": "Thảm cỏ", "cactus": "Xương rồng",
            "sky": "Bầu trời", "cloud": "Mây trời", "sunset": "Hoàng hôn", "sun": "Mặt trời",
            "moon": "Mặt trăng", "mountain": "Dãy núi", "hill": "Đồi núi", "sea": "Mặt biển",
            "ocean": "Đại dương", "beach": "Bãi biển", "river": "Dòng sông", "lake": "Mặt hồ",
            "waterfall": "Thác nước", "rainbow": "Cầu vồng",
            "building": "Tòa nhà", "house": "Ngôi nhà", "skyscraper": "Nhà cao tầng",
            "tower": "Tòa tháp", "bridge": "Cây cầu", "temple": "Ngôi chùa", "church": "Nhà thờ",
            "window": "Cửa sổ", "doorway": "Khung cửa", "balcony": "Ban công", "stairs": "Cầu thang",
            "street": "Đường phố", "alley": "Con hẻm", "road": "Con đường", "street sign": "Biển báo",
            "food": "Món ăn", "dish": "Đĩa thức ăn", "cake": "Bánh ngọt", "dessert": "Tráng miệng",
            "fruit": "Trái cây", "pizza": "Bánh pizza", "burger": "Burger", "noodle": "Mì/Phở",
            "bread": "Bánh mì", "coffee": "Ly cà phê", "cup": "Chiếc cốc", "tea": "Ly trà",
            "drink": "Đồ uống", "glass": "Ly thủy tinh", "bottle": "Chai nước", "bowl": "Bát",
            "plate": "Đĩa", "sandwich": "Bánh mì kẹp",
            "car": "Ô tô", "motorcycle": "Xe máy", "bicycle": "Xe đạp", "bus": "Xe buýt",
            "train": "Tàu hỏa", "boat": "Con thuyền", "airplane": "Máy bay",
            "laptop": "Laptop", "monitor": "Màn hình", "tv": "Màn hình TV", "keyboard": "Bàn phím",
            "mouse": "Chuột máy tính", "smartphone": "Điện thoại", "camera": "Máy ảnh",
            "watch": "Đồng hồ đeo tay", "eyeglasses": "Kính mắt", "book": "Cuốn sách",
            "lamp": "Đèn bàn", "vase": "Bình hoa", "clock": "Đồng hồ", "chair": "Chiếc ghế",
            "sofa": "Ghế sofa", "table": "Mặt bàn", "bag": "Túi xách", "backpack": "Ba lô",
            "shoe": "Giày", "hat": "Mũ", "umbrella": "Chiếc ô", "statue": "Bức tượng", "guitar": "Đàn guitar",
        ]
        let key = label.lowercased()
        return map[key] ?? label
    }

    private struct RankedCandidate {
        let det: DirectorDetection
        let depth: Double
        let hasFace: Bool
        let isCornerHeadless: Bool
        let heroScore: Double
    }

    private struct SharpCluster {
        let bounds: CGRect
        let center: CGPoint
        let meanDepth: Double
        let meanSharpness: Double
        let area: Double
        let score: Double
    }

    /// Main entry point: fuses multi-model evidence and produces a physically valid 3D camera guidance decision.
    static func direct(
        detections: [DirectorDetection],
        raster: CompositionRaster,
        sceneHints: CompositionSceneHints,
        semanticAffinities: [String: Double],
        neuralProposals: [CompositionProposal],
        calibration: TrackingCalibration,
        pose: simd_quatd,
        currentZoom: CGFloat,
        allowedZooms: [CGFloat]
    ) -> DirectorDecision {
        let safeZoom = max(0.5, currentZoom)
        let safePose = simd_length(pose.vector) > 1e-6 ? simd_normalize(pose) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

        // 1. Deduplicate detections across YOLO12s + OpenWorldPhotoYOLOE + Foreground Mask
        let fused = deduplicate(detections)
        let faceDets = fused.filter { $0.domain == .face && $0.confidence >= 0.22 }

        // 2. Rank foreground object candidates with DepthAnythingV2 + Face validation + Edge-sliver filters
        var fgCandidates: [RankedCandidate] = []
        fgCandidates.reserveCapacity(fused.count)
        for d in fused {
            if d.isAttentionOnly { continue }
            if d.domain == .backgroundSurface || d.domain == .wideNature { continue }
            let lower = d.label.lowercased()
            if lower == "table" || lower == "dining table" || lower == "bàn ăn" { continue }
            let area = d.area
            if area < 0.0035 || (area > 0.94 && d.domain != .human) { continue }

            let c = d.center
            let dAim = hypot(Double(c.x) - 0.50, Double(c.y) - 0.48)
            let aimW = 0.72 + 0.50 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
            let dep = meanDepth(in: d.boundingBox, raster: raster)
            let depW = 0.68 + 0.65 * dep

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

            // Visual-Audit Fix #1: Corner-clipped headless person sliver (e.g. bare shoulder next to giant pizza!)
            let touchesLR = d.boundingBox.minX <= 0.02 || d.boundingBox.maxX >= 0.98
            let touchesTB = d.boundingBox.minY <= 0.02 || d.boundingBox.maxY >= 0.98
            let isCornerHeadless = (d.domain == .human && touchesLR && touchesTB && !hasFace && area < 0.16 && dAim > 0.32)

            let catW: Double
            if isCornerHeadless {
                catW = 0.28
            } else {
                switch d.domain {
                case .human: catW = hasFace ? 1.42 : 1.25
                case .face: catW = 1.38
                case .animal: catW = 1.28
                case .pureFlower: catW = 1.18
                case .foregroundMask: catW = 0.96
                default: catW = 1.00
                }
            }

            let isPeripheralClipped = peripheralEquipmentTokens.contains(lower) &&
                (touchesLR || touchesTB) && dAim > 0.18
            let clipW = isPeripheralClipped ? 0.45 : 1.0
            let score = d.confidence * sqrt(max(0.004, area)) * aimW * depW * catW * clipW
            fgCandidates.append(RankedCandidate(
                det: d, depth: dep, hasFace: hasFace, isCornerHeadless: isCornerHeadless, heroScore: score
            ))
        }
        fgCandidates.sort { $0.heroScore > $1.heroScore }

        // 3. Extract SigLIP top scene cue & GAIC best crop peak from evaluated neural proposals
        let siglipScene = topSiglipScene(semanticAffinities)
        let gaicSummary = summarizeNeuralProposals(neuralProposals)
        let horizonInfo = estimateHorizonAndRichness(detections: fused, raster: raster, sceneHints: sceneHints, affinities: semanticAffinities)
        let hasWideNatureDet = fused.contains {
            ($0.domain == .wideNature || wideNatureTokens.contains($0.label.lowercased())) && $0.confidence >= 0.20
        }

        // 4. Identify people, dominant non-person, and balanced indoor interiors
        let validPeople = fgCandidates.filter {
            ($0.det.domain == .human || $0.det.domain == .face) &&
            $0.det.confidence >= 0.28 && $0.det.area >= 0.012 && !$0.isCornerHeadless
        }
        let nonPersonTop = fgCandidates.first {
            $0.det.domain != .human && $0.det.domain != .face &&
            $0.det.domain != .architecture && $0.det.domain != .foregroundMask &&
            $0.det.confidence >= 0.34
        }
        let furnitureHits = fgCandidates.filter { $0.det.domain == .furniture && $0.det.confidence >= 0.32 }
        let isIndoorRoomCue = siglipScene == "indoor_room" || sceneHints.role == .indoorRoom
        let isBalancedInterior = isIndoorRoomCue && furnitureHits.count >= 2
        let maskInstances = fgCandidates.filter { $0.det.domain == .foregroundMask && $0.det.area >= 0.015 && $0.det.area <= 0.76 }

        // 5. 10-Tier Photographic Role & Hero Selection
        var role: DirectorPhotographicRole = .object
        var heroLabel = "subject"
        var heroLocalized = "Chủ thể nổi bật"
        var heroConf = 0.72
        var heroBox = CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.56)
        var heroAnchor = CGPoint(x: 0.50, y: 0.48)
        var heroGazeX = 0.0

        // Tier 1: Group of 2+ comparable people (or already-merged group candidate)
        if let explicitGroup = validPeople.first(where: { $0.det.isGroup }) {
            role = .group
            heroBox = explicitGroup.det.boundingBox
            heroAnchor = explicitGroup.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.26 * heroBox.height)
            heroLabel = explicitGroup.det.label
            heroLocalized = explicitGroup.det.localizedLabel
            heroConf = explicitGroup.det.confidence
        } else if validPeople.count >= 2 && validPeople[1].heroScore >= 0.35 * validPeople[0].heroScore {
            let groupMembers = validPeople.filter { $0.heroScore >= 0.30 * validPeople[0].heroScore }.prefix(6)
            let box = unionRects(groupMembers.map(\.det.boundingBox))
            role = .group
            heroBox = box
            heroAnchor = CGPoint(x: box.midX, y: box.minY + 0.26 * box.height)
            heroLabel = "group(\(groupMembers.count))"
            heroLocalized = "Nhóm \(groupMembers.count) người"
            heroConf = validPeople[0].det.confidence
        }
        // Tier 2: Single dominant person (unless headless sliver outranked 1.65x by dominant foreground food/object)
        else if let p0 = validPeople.first,
                !(nonPersonTop != nil && (nonPersonTop?.heroScore ?? 0) > p0.heroScore * 1.65 && !p0.hasFace) {
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
        }
        // Tier 3: Dominant Animal / Pet
        else if let a0 = fgCandidates.first, a0.det.domain == .animal && a0.det.confidence >= 0.25 {
            role = .animal
            heroBox = a0.det.boundingBox
            heroAnchor = a0.det.anchor ?? CGPoint(x: heroBox.midX, y: heroBox.minY + 0.30 * heroBox.height)
            heroGazeX = a0.det.gazeX
            heroLabel = a0.det.label
            heroLocalized = a0.det.localizedLabel
            heroConf = a0.det.confidence
        }
        // Tier 4: Balanced Indoor Interior (Visual-Audit Fix #5)
        else if isBalancedInterior {
            let items = fgCandidates.filter {
                ($0.det.domain == .furniture || $0.det.domain == .pottedPlant) && $0.det.confidence >= 0.32
            }.prefix(4)
            let box = unionRects(items.map(\.det.boundingBox))
            role = .indoorRoom
            heroBox = box
            heroAnchor = CGPoint(x: box.midX, y: box.midY)
            heroLabel = "indoor_room"
            heroLocalized = "Không gian nội thất"
            heroConf = 0.80
        }
        // Tier 5: Pure Flower / Foliage (Visual-Audit Fix #2: sharp foreground flower, NEVER blurry bottom strip!)
        else if (fgCandidates.first?.det.domain == .pureFlower && (fgCandidates.first?.det.confidence ?? 0) >= 0.18) ||
                siglipScene == "flower" || siglipScene == "foliage" {
            let explicitFlora = fgCandidates.first { $0.det.domain == .pureFlower && $0.det.area < 0.72 }
            if let f = explicitFlora {
                role = .flower
                heroBox = f.det.boundingBox
                heroAnchor = f.det.anchor ?? f.det.center
                heroLabel = f.det.label
                heroLocalized = f.det.localizedLabel
                heroConf = f.det.confidence
            } else if let m0 = maskInstances.first(where: { !isBottomStrip($0.det.boundingBox, center: $0.det.center) }) {
                role = siglipScene == "flower" ? .flower : .foliage
                heroBox = m0.det.boundingBox
                heroAnchor = m0.det.anchor ?? m0.det.center
                heroLabel = role == .flower ? "flower_mask" : "foliage_mask"
                heroLocalized = role == .flower ? "Cụm hoa tiền cảnh" : "Tán lá thiên nhiên"
                heroConf = max(0.70, m0.det.confidence)
            } else if let sharp = extractSharpForegroundClusters(raster: raster).first {
                role = siglipScene == "flower" ? .flower : .foliage
                heroBox = sharp.bounds
                heroAnchor = sharp.center
                heroLabel = role == .flower ? "flower_sharp_depth" : "foliage_sharp_depth"
                heroLocalized = role == .flower ? "Cụm hoa sắc nét" : "Cụm cây lá tiền cảnh"
                heroConf = min(0.84, 0.48 + 0.24 * sharp.meanDepth + 0.18 * sharp.meanSharpness)
            } else {
                role = siglipScene == "flower" ? .flower : .foliage
                heroBox = gaicSummary.bestBox
                heroAnchor = CGPoint(x: gaicSummary.bestBox.midX, y: gaicSummary.bestBox.midY)
                heroLabel = role.rawValue
                heroLocalized = role == .flower ? "Cụm hoa nổi bật" : "Mảng xanh thiên nhiên"
                heroConf = 0.70
            }
        }
        // Tier 6: Food / Coffee / Tabletop Dish
        else if let food0 = fgCandidates.first, food0.det.domain == .food && food0.det.confidence >= 0.24 {
            role = .food
            heroBox = food0.det.boundingBox
            heroAnchor = food0.det.anchor ?? food0.det.center
            heroLabel = food0.det.label
            heroLocalized = food0.det.localizedLabel
            heroConf = food0.det.confidence
        }
        // Tier 7: Clear Named Foreground Object or Vehicle (including COCO TV/bottle/clock/camera/potted plant)
        else if let obj0 = fgCandidates.first(where: {
            $0.det.domain != .architecture && $0.det.domain != .foregroundMask && $0.det.confidence >= 0.24
        }) {
            role = obj0.det.domain == .vehicle ? .vehicle : .object
            heroBox = obj0.det.boundingBox
            heroAnchor = obj0.det.anchor ?? obj0.det.center
            heroLabel = obj0.det.label
            heroLocalized = obj0.det.localizedLabel
            heroConf = obj0.det.confidence
        }
        // Tier 8: Sky / Clouds / Sunset / Wide Landscape (Visual-Audit Fix #2b: beats grass-bank depth fallback!)
        else if siglipScene == "sky_clouds" || siglipScene == "sunset" || siglipScene == "landscape" ||
                siglipScene == "person_scenery" || (hasWideNatureDet && horizonInfo.horizonY != nil) ||
                sceneHints.role == .landscapeSky {
            let hy = horizonInfo.horizonY ?? 0.48
            role = .skyLandscape
            heroBox = CGRect(x: 0.10, y: max(0.05, hy - 0.16), width: 0.80, height: min(0.90, 0.32))
            heroAnchor = CGPoint(x: 0.50, y: hy)
            heroLabel = "sky_landscape"
            heroLocalized = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? "Bầu trời & mây" : "Cảnh quan rộng"
            heroConf = 0.78
        }
        // Tier 9: Architecture / Building / Street (Visual-Audit Fix #3: union all buildings!)
        else if fgCandidates.first?.det.domain == .architecture || siglipScene == "architecture" ||
                siglipScene == "street" || sceneHints.role == .architecture || sceneHints.role == .streetLeading {
            let archDets = fgCandidates.filter { $0.det.domain == .architecture && $0.det.confidence >= 0.20 }
            role = (siglipScene == "street" || sceneHints.role == .streetLeading) ? .street : .architecture
            if archDets.count >= 2 {
                let box = unionRects(archDets.prefix(5).map(\.det.boundingBox))
                heroBox = box
                heroAnchor = CGPoint(x: box.midX, y: box.midY)
                heroLabel = "architecture(\(archDets.count))"
                heroLocalized = "Cụm kiến trúc"
                heroConf = archDets[0].det.confidence
            } else if let a0 = archDets.first, (0.22...0.78).contains(a0.det.center.x) {
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
                heroBox = gaicSummary.bestBox
                heroAnchor = CGPoint(x: gaicSummary.bestBox.midX, y: gaicSummary.bestBox.midY)
                heroLabel = role.rawValue
                heroLocalized = role == .street ? "Góc phố" : "Công trình kiến trúc"
                heroConf = 0.74
            }
        }
        // Tier 10: Universal iOS 17 Foreground Mask / Sharp-Depth / GAIC Peak fallback
        else if let m0 = maskInstances.first(where: { !isBottomStrip($0.det.boundingBox, center: $0.det.center) }) {
            role = .object
            heroBox = m0.det.boundingBox
            heroAnchor = m0.det.anchor ?? m0.det.center
            heroLabel = "foreground_instance"
            heroLocalized = "Chủ thể tiền cảnh"
            heroConf = max(0.68, m0.det.confidence)
        } else if let sharp = extractSharpForegroundClusters(raster: raster).first {
            role = .object
            heroBox = sharp.bounds
            heroAnchor = sharp.center
            heroLabel = "foreground_sharp_depth"
            heroLocalized = "Chủ thể sắc nét"
            heroConf = min(0.80, 0.45 + 0.24 * sharp.meanDepth + 0.16 * sharp.meanSharpness)
        } else {
            role = .scene
            heroBox = gaicSummary.bestBox
            heroAnchor = CGPoint(x: gaicSummary.bestBox.midX, y: gaicSummary.bestBox.midY)
            heroLabel = "scene_gaic"
            heroLocalized = "Khung cảnh tổng thể"
            heroConf = 0.66
        }

        // 6. SMART OPTICAL ZOOM DECISION (Visual-Audit Fix #4: strict 0.5x gate + clean optical rungs!)
        let bw = max(0.02, Double(heroBox.width))
        let bh = max(0.02, Double(heroBox.height))
        let bArea = bw * bh
        let linearSize = (role == .portrait || role == .environmentalPortrait || role == .animal) ? bh : max(bw, bh)
        let targetLinear = idealLinearFill(for: role)

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

        let chosenZoom: CGFloat
        if role == .skyLandscape || role == .indoorRoom {
            chosenZoom = safeZoom
        } else if isSeverelyCramped && hasUltraWide && safeZoom >= 0.90 {
            chosenZoom = 0.5
        } else if isSeverelyCramped && safeZoom > 1.15 {
            chosenZoom = max(1.0, minHardwareZoom)
        } else {
            // Candidate optical & prime rungs relative to current camera lens
            var candidateZooms: [CGFloat] = [safeZoom]
            for rung in [CGFloat(1.0), 1.2, 1.5, 2.0, 3.0] {
                if rung >= safeZoom * 0.98 && rung <= min(maxHardwareZoom, safeZoom * 3.0) {
                    if !candidateZooms.contains(where: { abs($0 - rung) < 0.04 }) {
                        candidateZooms.append(rung)
                    }
                }
            }
            for hw in allowedZooms where hw >= safeZoom * 0.98 && hw <= min(3.5, safeZoom * 3.0) {
                if !candidateZooms.contains(where: { abs($0 - hw) < 0.04 }) {
                    candidateZooms.append(hw)
                }
            }

            var bestZ = safeZoom
            var bestZScore = -Double.infinity
            for z in candidateZooms {
                let relZ = Double(z / safeZoom)
                let projW = bw * relZ
                let projH = bh * relZ
                if role != .portrait && (projW > 0.88 || projH > 0.88) && z > safeZoom * 1.04 {
                    continue
                }
                if role == .portrait && (projW > 0.90 || projH > 1.38) && z > safeZoom * 1.04 {
                    continue
                }
                let fit = -abs(log(max(0.05, linearSize * relZ) / targetLinear))
                let isHardwareLens = allowedZooms.contains { abs($0 - z) <= 0.06 }
                let optBonus = isHardwareLens ? 0.14 : 0.05
                let stayBonus = abs(z - safeZoom) < 0.05 ? 0.09 : 0.0
                let gaicBonus = 0.22 * gaicSummary.normalizedPeak(nearRelativeZoom: relZ)
                let sc = fit + optBonus + stayBonus + gaicBonus
                if sc > bestZScore {
                    bestZScore = sc
                    bestZ = z
                }
            }
            chosenZoom = bestZ
        }

        // 7. TRUE 3D PHOTOGRAPHIC DESTINATION G* (Rule of Thirds / Golden Ratio / Horizon / Symmetry)
        let relZoom = max(0.35, Double(chosenZoom / safeZoom))
        let leftOpen = 1.0 - halfDepthMean(leftHalf: true, raster: raster)
        let rightOpen = 1.0 - halfDepthMean(leftHalf: false, raster: raster)
        let gaicRelX = (Double(heroAnchor.x) - Double(gaicSummary.bestBox.minX)) / max(0.05, Double(gaicSummary.bestBox.width))

        let preferLeftThird: Bool
        if abs(heroGazeX) >= 0.14 {
            // Look-space rule: facing right (gazeX > 0) -> place subject on left Golden Ratio 0.382!
            preferLeftThird = heroGazeX > 0
        } else if abs(rightOpen - leftOpen) > 0.03 {
            preferLeftThird = rightOpen > leftOpen
        } else if gaicSummary.bestScore > gaicSummary.baseScore + 0.04 {
            preferLeftThird = gaicRelX < 0.50
        } else {
            preferLeftThird = heroAnchor.x <= 0.50
        }

        let destG: CGPoint
        var adjustedAnchor = heroAnchor
        let ruleName: String
        let usesCenter: Bool

        switch role {
        case .skyLandscape:
            let hy = horizonInfo.horizonY ?? 0.48
            let destY: Double = horizonInfo.skyRich >= horizonInfo.groundRich * 0.92 ? 0.667 : 0.333
            if let sunX = brightSkyAccentX(horizonY: hy, raster: raster) {
                let gx: Double = sunX < 0.50 ? 0.382 : 0.618
                adjustedAnchor = CGPoint(x: sunX, y: hy)
                destG = CGPoint(x: gx, y: destY)
            } else {
                destG = CGPoint(x: 0.50, y: destY)
            }
            ruleName = "Luật 1/3 Đường chân trời"
            usesCenter = false

        case .portrait, .environmentalPortrait:
            let gx: Double = preferLeftThird ? 0.382 : 0.618
            let baseGy: Double = role == .portrait ? 0.33 : 0.38
            let headToEye = max(0.04, Double(heroAnchor.y - heroBox.minY) * relZoom)
            let gy = min(0.46, max(baseGy, 0.07 + headToEye))
            destG = CGPoint(x: gx, y: gy)
            ruleName = "Tỷ lệ vàng Chân dung"
            usesCenter = false

        case .group:
            let headToEye = max(0.05, Double(heroAnchor.y - heroBox.minY) * relZoom)
            let gy = min(0.44, max(0.34, 0.08 + headToEye))
            destG = CGPoint(x: 0.50, y: gy)
            ruleName = "Cân bằng Nhóm"
            usesCenter = true

        case .indoorRoom:
            destG = CGPoint(x: 0.50, y: 0.50)
            ruleName = "Cân bằng Nội thất"
            usesCenter = true

        case .architecture:
            let sym = horizontalSymmetry(raster: raster)
            let gx: Double = sym > 0.68 ? 0.50 : (preferLeftThird ? 0.382 : 0.618)
            destG = CGPoint(x: gx, y: 0.48)
            ruleName = gx == 0.50 ? "Đối xứng Kiến trúc" : "Tỷ lệ vàng Kiến trúc"
            usesCenter = (gx == 0.50)

        case .flower, .animal, .food, .object, .vehicle:
            var gx: Double = preferLeftThird ? 0.382 : 0.618
            var gy: Double = (role == .flower || role == .animal) ? 0.40 : 0.48
            let halfW = 0.5 * bw * relZoom
            let halfH = 0.5 * bh * relZoom
            if halfW < 0.43 { gx = max(0.06 + halfW, min(0.94 - halfW, gx)) } else { gx = 0.50 }
            if halfH < 0.43 { gy = max(0.06 + halfH, min(0.94 - halfH, gy)) } else { gy = 0.50 }
            destG = CGPoint(x: gx, y: gy)
            ruleName = "Tỷ lệ vàng"
            usesCenter = abs(gx - 0.50) < 0.04 && abs(gy - 0.50) < 0.04

        case .foliage, .street, .scene:
            let gx: Double = preferLeftThird ? 0.382 : 0.618
            destG = CGPoint(x: gx, y: 0.45)
            ruleName = "Tỷ lệ vàng & Luật 1/3"
            usesCenter = false
        }

        // 8. SOLVE EXACT 3D SPHERICAL CAMERA ROTATION R* -> aimPointInSource & aimWorldRay
        let futureCalib = TrackingCalibration(
            fx: calibration.fx * relZoom,
            fy: calibration.fy * relZoom,
            cx: calibration.cx,
            cy: calibration.cy,
            aspect: calibration.aspect,
            isMeasured: calibration.isMeasured
        )
        let targetRay = futureCalib.deviceRay(at: destG)
        let sourceRay = calibration.deviceRay(at: adjustedAnchor)
        let solvedRotation = simd_quatd(from: targetRay, to: sourceRay)
        let rawAimProj = calibration.project(deviceRay: solvedRotation.act(forward))

        // Keep handheld pan/tilt comfortable AND prevent zoomed windows from drifting past sensor boundaries
        let panMin: CGFloat
        let panMax: CGFloat
        if relZoom <= 1.05 {
            panMin = 0.24
            panMax = 0.76
        } else {
            let halfSensorSpan = CGFloat(0.5 / relZoom)
            panMin = max(0.18, min(0.45, halfSensorSpan))
            panMax = min(0.82, max(0.55, 1.0 - halfSensorSpan))
        }
        let clampedAimX: CGFloat
        let clampedAimY: CGFloat
        if rawAimProj.isInFront && rawAimProj.point.x.isFinite && rawAimProj.point.y.isFinite {
            clampedAimX = min(panMax, max(panMin, rawAimProj.point.x))
            clampedAimY = min(panMax, max(panMin, rawAimProj.point.y))
        } else {
            clampedAimX = 0.5
            clampedAimY = 0.5
        }
        let finalAim = CGPoint(x: clampedAimX, y: clampedAimY)
        let finalAimDeviceRay = calibration.deviceRay(at: finalAim)
        let finalRotation = simd_quatd(from: forward, to: finalAimDeviceRay)
        let aimWorldRay = safePose.act(finalAimDeviceRay)

        let aimShift = hypot(Double(finalAim.x - 0.5), Double(finalAim.y - 0.5))
        let zoomChanged = abs(chosenZoom - safeZoom) >= 0.10
        let preservesOriginal = aimShift < 0.025 && !zoomChanged

        let explanation = buildExplanation(
            role: role,
            localizedLabel: heroLocalized,
            destG: destG,
            zoom: chosenZoom,
            currentZoom: safeZoom,
            ruleName: ruleName,
            usesCenter: usesCenter,
            horizonY: horizonInfo.horizonY
        )

        return DirectorDecision(
            role: role,
            heroLabel: heroLabel,
            heroLocalizedLabel: heroLocalized,
            heroBounds: heroBox,
            heroAnchor: adjustedAnchor,
            destinationPoint: destG,
            aimPointInSource: finalAim,
            aimWorldRay: aimWorldRay,
            rotation: finalRotation,
            recommendedZoom: chosenZoom,
            confidence: max(0.35, min(0.98, heroConf)),
            usesCenter: usesCenter,
            preservesOriginalFrame: preservesOriginal,
            ruleName: ruleName,
            explanation: explanation,
            detectedHorizonY: horizonInfo.horizonY
        )
    }

    // MARK: - Helpers

    private static func idealLinearFill(for role: DirectorPhotographicRole) -> Double {
        switch role {
        case .portrait: return 0.56
        case .environmentalPortrait: return 0.36
        case .group: return 0.68
        case .animal: return 0.46
        case .flower: return 0.44
        case .foliage: return 0.58
        case .food: return 0.48
        case .object: return 0.46
        case .vehicle: return 0.48
        case .indoorRoom: return 0.74
        case .architecture: return 0.72
        case .street: return 0.60
        case .skyLandscape: return 0.80
        case .scene: return 0.72
        }
    }

    private static func deduplicate(_ detections: [DirectorDetection]) -> [DirectorDetection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [DirectorDetection] = []
        kept.reserveCapacity(sorted.count)
        for d in sorted {
            if let idx = kept.firstIndex(where: { existing in
                let iou = rectIoU(d.boundingBox, existing.boundingBox)
                if iou <= 0.58 { return false }
                if d.label.lowercased() == existing.label.lowercased() { return true }
                if d.domain == existing.domain && d.domain != .object { return true }
                if d.domain == .foregroundMask && existing.domain != .foregroundMask && iou > 0.65 { return true }
                return false
            }) {
                // Merge fine Vision landmarks (eye anchor, gaze, faces, group flag) from overlapping detections
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

    private static func unionRects(_ rects: [CGRect]) -> CGRect {
        guard var acc = rects.first else { return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        for r in rects.dropFirst() { acc = acc.union(r) }
        return acc
    }

    private static func isBottomStrip(_ rect: CGRect, center: CGPoint) -> Bool {
        rect.maxY >= 0.96 && center.y > 0.78 && rect.width > 0.45
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

    private static func halfDepthMean(leftHalf: Bool, raster: CompositionRaster) -> Double {
        guard raster.side > 1, raster.foregroundDepth.count == raster.side * raster.side else { return 0.5 }
        let s = raster.side
        let x0 = leftHalf ? 0 : s / 2
        let x1 = leftHalf ? s / 2 : s
        var sum = 0.0
        var count = 0
        for y in 0..<s {
            let row = y * s
            for x in x0..<x1 {
                sum += raster.foregroundDepth[row + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    private static func horizontalSymmetry(raster: CompositionRaster) -> Double {
        guard raster.side > 4, raster.luminance.count == raster.side * raster.side else { return 0.0 }
        let s = raster.side
        let half = s / 2
        var diffSum = 0.0
        var count = 0
        for y in 0..<s {
            let row = y * s
            for x in 0..<half {
                let l = raster.luminance[row + x]
                let r = raster.luminance[row + (s - 1 - x)]
                diffSum += abs(l - r)
                count += 1
            }
        }
        let meanDiff = count > 0 ? diffSum / Double(count) : 1.0
        return max(0.0, min(1.0, 1.0 - meanDiff * 2.0))
    }

    /// Combines DepthAnythingV2 disparity with local edge sharpness and suppresses blurry bottom strips.
    private static func extractSharpForegroundClusters(raster: CompositionRaster) -> [SharpCluster] {
        let s = raster.side
        let n = s * s
        guard s >= 8, raster.foregroundDepth.count == n, raster.edges.count == n else { return [] }
        let sortedEdges = raster.edges.sorted()
        let e96 = max(1e-4, sortedEdges[Int(Double(n - 1) * 0.96)])
        var sharpDepth = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let en = min(1.0, max(0.0, raster.edges[i] / e96))
            sharpDepth[i] = 0.62 * raster.foregroundDepth[i] + 0.38 * en
        }
        let sortedSD = sharpDepth.sorted()
        let p20 = sortedSD[Int(Double(n - 1) * 0.20)]
        let p75 = sortedSD[Int(Double(n - 1) * 0.75)]
        let p94 = sortedSD[Int(Double(n - 1) * 0.94)]
        guard p94 - p20 >= 0.14 else { return [] }
        let thresh = max(0.48, p75 + 0.25 * (p94 - p75))

        var visited = [Bool](repeating: false, count: n)
        var clusters: [SharpCluster] = []
        let dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for sy in 0..<s {
            for sx in 0..<s {
                let start = sy * s + sx
                if visited[start] || sharpDepth[start] < thresh { continue }
                visited[start] = true
                var queue = [start]
                var head = 0
                var minX = sx, maxX = sx, minY = sy, maxY = sy
                var sumX = 0.0, sumY = 0.0, sumD = 0.0, sumS = 0.0, pix = 0
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
                    sumS += min(1.0, raster.edges[cur] / e96)
                    pix += 1
                    for (dx, dy) in dirs {
                        let nx = cx + dx, ny = cy + dy
                        if nx >= 0, nx < s, ny >= 0, ny < s {
                            let ni = ny * s + nx
                            if !visited[ni] && sharpDepth[ni] >= thresh {
                                visited[ni] = true
                                queue.append(ni)
                            }
                        }
                    }
                }
                let area = Double(pix) / Double(n)
                guard area >= 0.015 && area <= 0.72 else { continue }
                let x0 = Double(minX) / Double(s)
                let y0 = Double(minY) / Double(s)
                let x1 = Double(maxX + 1) / Double(s)
                let y1 = Double(maxY + 1) / Double(s)
                let cx = sumX / Double(pix)
                let cy = sumY / Double(pix)
                let box = CGRect(x: x0, y: y0, width: max(0.02, x1 - x0), height: max(0.02, y1 - y0))
                if isBottomStrip(box, center: CGPoint(x: cx, y: cy)) { continue }
                let meanD = sumD / Double(pix)
                let meanS = sumS / Double(pix)
                let dAim = hypot(cx - 0.50, cy - 0.46)
                let aimW = 0.70 + 0.50 * exp(-(dAim * dAim) / (2.0 * 0.28 * 0.28))
                let sc = (0.55 * meanD + 0.45 * meanS) * sqrt(area) * aimW
                clusters.append(SharpCluster(
                    bounds: box, center: CGPoint(x: cx, y: cy),
                    meanDepth: meanD, meanSharpness: meanS, area: area, score: sc
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

        // Boost sky richness when SigLIP confirms dramatic clouds / golden hour / sunset
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
        let bestBox: CGRect
        let baseScore: Double
        let bestScore: Double
        let entries: [(relZoom: Double, normScore: Double)]

        func normalizedPeak(nearRelativeZoom target: Double) -> Double {
            let matches = entries.filter { abs($0.relZoom - target) < 0.24 }.map(\.normScore)
            return matches.max() ?? 0.5
        }
    }

    private static func summarizeNeuralProposals(_ proposals: [CompositionProposal]) -> NeuralProposalSummary {
        guard !proposals.isEmpty else {
            return NeuralProposalSummary(
                bestBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70),
                baseScore: 0.5, bestScore: 0.5, entries: []
            )
        }
        let baseZoom = max(0.5, Double(proposals.first(where: \.isUnchangedView)?.zoom ?? proposals.first?.zoom ?? 1.0))
        let baseScore = proposals.first(where: \.isUnchangedView)?.gaicScore ?? 0.5
        let scores = proposals.map(\.gaicScore)
        let minS = scores.min() ?? 0.0
        let maxS = scores.max() ?? 1.0
        let span = max(1e-4, maxS - minS)

        var bestProp = proposals[0]
        var entries: [(relZoom: Double, normScore: Double)] = []
        entries.reserveCapacity(proposals.count)
        for p in proposals {
            if p.gaicScore > bestProp.gaicScore { bestProp = p }
            let relZ = max(0.35, Double(p.zoom) / baseZoom)
            let norm = (p.gaicScore - minS) / span
            entries.append((relZoom: relZ, normScore: norm))
        }
        let minX = max(0.0, min(1.0, bestProp.sourceCorners.map(\.x).min() ?? 0.15))
        let maxX = max(0.0, min(1.0, bestProp.sourceCorners.map(\.x).max() ?? 0.85))
        let minY = max(0.0, min(1.0, bestProp.sourceCorners.map(\.y).min() ?? 0.15))
        let maxY = max(0.0, min(1.0, bestProp.sourceCorners.map(\.y).max() ?? 0.85))
        let bestBox = CGRect(x: minX, y: minY, width: max(0.10, maxX - minX), height: max(0.10, maxY - minY))
        return NeuralProposalSummary(bestBox: bestBox, baseScore: baseScore, bestScore: bestProp.gaicScore, entries: entries)
    }

    private static func buildExplanation(
        role: DirectorPhotographicRole,
        localizedLabel: String,
        destG: CGPoint,
        zoom: CGFloat,
        currentZoom: CGFloat,
        ruleName: String,
        usesCenter: Bool,
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
        switch role {
        case .skyLandscape:
            let pos = destG.y > 0.55 ? "1/3 dưới tôn mây trời" : "1/3 trên tôn mặt đất"
            let hSuffix = horizonY != nil ? "" : " ước lượng"
            return "Đưa đường chân trời\(hSuffix) về \(pos) (\(ruleName))\(zoomTag)"
        case .portrait, .environmentalPortrait:
            return "Đưa ánh mắt \(localizedLabel.lowercased()) vào điểm \(ruleName) \(side), mở khoảng thở hướng nhìn\(zoomTag)"
        case .group:
            return "Giữ trọn \(localizedLabel.lowercased()) cân đối giữa khung, tránh cắt rìa\(zoomTag)"
        case .indoorRoom:
            return "Cân bằng toàn bộ không gian nội thất và ánh sáng phòng\(zoomTag)"
        case .architecture:
            return usesCenter
                ? "Căn đối xứng trục giữa cho \(localizedLabel.lowercased())\(zoomTag)"
                : "Đặt \(localizedLabel.lowercased()) tại điểm \(ruleName) \(side)\(zoomTag)"
        case .flower, .foliage:
            return "Tách nét \(localizedLabel.lowercased()) tiền cảnh về điểm \(ruleName) \(side)\(zoomTag)"
        default:
            return usesCenter
                ? "Cân giữa \(localizedLabel.lowercased()) theo bố cục chuẩn\(zoomTag)"
                : "Đặt \(localizedLabel.lowercased()) vào điểm \(ruleName) \(side)\(zoomTag)"
        }
    }
}
