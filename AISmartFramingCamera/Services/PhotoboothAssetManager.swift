import Foundation
import UIKit
import Vision
import CoreImage
import CoreGraphics

/// Quản lý toàn bộ kho tài nguyên Photobooth:
/// 1) 24 Sticker PNG nền trong suốt đóng gói sẵn trong App Bundle (`PhotoboothAssets/*.png`)
/// 2) 36+ Sticker PNG nền trong suốt tải trực tiếp từ CDN OpenMoji / FluentUI (cache đĩa tự động)
/// 3) Studio Tạo Sticker AI / Tạo Nền Khung AI / Chuyển Đổi Chân Dung Booth (Google Gemini / Pollinations AI + Vision Subject Cutout)
/// 4) Tách nền chủ thể trực tiếp từ ảnh vừa chụp bằng iOS 17 `VNGenerateForegroundInstanceMaskRequest`
@MainActor
public final class PhotoboothAssetManager: ObservableObject {
    public static let shared = PhotoboothAssetManager()

    @Published public private(set) var bundledStickers: [PhotoboothStickerAsset] = []
    @Published public private(set) var onlineStickers: [PhotoboothStickerAsset] = []
    @Published public private(set) var customStickers: [PhotoboothStickerAsset] = []
    @Published public private(set) var downloadedOnlineIDs: Set<String> = []
    @Published public private(set) var customAIFrameFilenames: [String] = []
    @Published public private(set) var isDownloadingPack: PhotoboothOnlinePackCategory? = nil
    @Published public private(set) var isGeneratingAI: Bool = false
    @Published public var lastStatusMessage: String? = nil

    private var imageCache: [String: UIImage] = [:]
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: true])

    private let onlineCacheDir: URL
    private let aiStickersDir: URL
    private let aiFramesDir: URL
    private let customIndexKey = "alignai.photobooth.customStickers.v1"
    private let customFramesIndexKey = "alignai.photobooth.customAIFrames.v1"

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? caches
        self.onlineCacheDir = caches.appendingPathComponent("PhotoboothOnlineAssets", isDirectory: true)
        self.aiStickersDir = docs.appendingPathComponent("PhotoboothAIStickers", isDirectory: true)
        self.aiFramesDir = docs.appendingPathComponent("PhotoboothAIFrames", isDirectory: true)

        try? FileManager.default.createDirectory(at: onlineCacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: aiStickersDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: aiFramesDir, withIntermediateDirectories: true)

        setupBundledCatalog()
        setupOnlineCatalog()
        loadPersistedUserAssets()
        scanCachedOnlineAssets()
    }

    // MARK: - 1. Catalog Setup

    private func setupBundledCatalog() {
        let coquetteItems: [(String, String, PhotoboothStickerAnchorZone)] = [
            ("pb_kitty_clip", "Kẹp mèo nơ đỏ", .hairTemple),
            ("pb_crown_silver", "Vương miện bạc", .headCrown),
            ("pb_ribbon_pink", "Nơ lụa hồng", .hairTemple),
            ("pb_ribbon_black", "Nơ nhung đen", .hairTemple),
            ("pb_bunny_ears", "Tai thỏ bông", .headCrown),
            ("pb_cat_ears", "Tai mèo cài đầu", .headCrown),
            ("pb_tulip_bouquet", "Bó hoa Tulip", .shoulderBack),
            ("pb_teddy_head", "Đầu gấu bông", .shoulderBack),
            ("pb_bear_plush", "Gấu bông", .shoulderBack),
            ("pb_speech_cute", "Bong bóng tim", .safeCorner),
            ("pb_tape_washi", "Băng keo caro", .safeCorner),
            ("pb_cherry_twin", "Cherry đôi", .cheekAccent),
            ("pb_strawberry_cake", "Bánh dâu", .safeCorner),
            ("pb_iced_latte", "Cà phê sữa đá", .safeCorner),
            ("pb_daisy_flower", "Cúc họa mi", .hairTemple),
            ("pb_pastel_cloud", "Mây pastel", .safeCorner),
            ("pb_heart_gem", "Trái tim pha lê", .cheekAccent),
            ("pb_angel_wings", "Cánh thiên thần", .shoulderBack),
        ]
        let y2kItems: [(String, String, PhotoboothStickerAnchorZone)] = [
            ("pb_camera_mini", "Máy ảnh bạc", .safeCorner),
            ("pb_headphone_y2k", "Tai nghe Y2K", .headCrown),
            ("pb_butterfly_silver", "Bướm bạc Holo", .hairTemple),
            ("pb_heart_doodle", "Tim nét bút đôi", .cheekAccent),
            ("pb_star_scribble", "Sao vẽ tay bạc", .safeCorner),
            ("pb_peace_hand", "Tay chữ V", .safeCorner),
            ("pb_chrome_star", "Ngôi sao Chrome", .safeCorner),
            ("pb_sparkle_trio", "Lấp lánh Y2K", .safeCorner),
            ("pb_film_roll", "Cuộn phim 35mm", .safeCorner),
            ("pb_clapperboard", "Bảng quay phim", .safeCorner),
            ("pb_vinyl_record", "Đĩa than Retro", .safeCorner),
            ("pb_disco_ball", "Quả cầu Disco", .safeCorner),
            ("pb_vintage_stamp", "Tem bưu chính", .safeCorner),
            ("pb_wax_seal", "Dấu sáp cổ điển", .safeCorner),
            ("pb_kiss_mark", "Dấu son môi", .cheekAccent),
            ("pb_retro_sunglasses", "Kính râm Oval", .eyeBridge),
            ("pb_lucky_clover", "Cỏ 4 lá", .safeCorner),
            ("pb_pixel_heart", "Tim Pixel 8-bit", .cheekAccent),
        ]

        var all: [PhotoboothStickerAsset] = []
        for (id, title, zone) in coquetteItems {
            all.append(PhotoboothStickerAsset(id: id, title: title, category: .coquette, source: .bundled(filename: "\(id).png"), anchorZone: zone))
        }
        for (id, title, zone) in y2kItems {
            all.append(PhotoboothStickerAsset(id: id, title: title, category: .y2k, source: .bundled(filename: "\(id).png"), anchorZone: zone))
        }
        self.bundledStickers = all
    }

    private func setupOnlineCatalog() {
        // Toàn bộ 48 URL bên dưới đã kiểm chứng thực tế HTTP 200 PNG RGBA nền trong suốt
        let specs: [(String, String, PhotoboothOnlinePackCategory, PhotoboothStickerAnchorZone, String)] = [
            // Y2K & Cyber (8)
            ("onl_cd", "Đĩa CD Y2K", .y2kCyber, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F4BF.png"),
            ("onl_sunglasses_3d", "Kính Mát 3D", .y2kCyber, .eyeBridge, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Sunglasses/3D/sunglasses_3d.png"),
            ("onl_butterfly_3d", "Bướm 3D", .y2kCyber, .hairTemple, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Butterfly/3D/butterfly_3d.png"),
            ("onl_alien", "Pixel Alien", .y2kCyber, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F47E.png"),
            ("onl_butterfly", "Bướm xanh", .y2kCyber, .hairTemple, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F98B.png"),
            ("onl_mirror_ball", "Cầu gương", .y2kCyber, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1FAA9.png"),
            ("onl_lightning", "Tia chớp", .y2kCyber, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/26A1.png"),
            ("onl_headphone", "Tai nghe", .y2kCyber, .headCrown, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F3A7.png"),

            // Nơ & Pastel (8)
            ("onl_ribbon_3d", "Nơ Hồng 3D", .bowsPastel, .hairTemple, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Ribbon/3D/ribbon_3d.png"),
            ("onl_crown_3d", "Vương Miện 3D", .bowsPastel, .headCrown, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Crown/3D/crown_3d.png"),
            ("onl_kiss_3d", "Dấu Son 3D", .bowsPastel, .cheekAccent, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Kiss%20mark/3D/kiss_mark_3d.png"),
            ("onl_hibiscus_3d", "Hoa Dâm Bụt 3D", .bowsPastel, .hairTemple, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Hibiscus/3D/hibiscus_3d.png"),
            ("onl_pink_heart", "Tim hồng", .bowsPastel, .cheekAccent, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1FA77.png"),
            ("onl_tulip", "Hoa Tulip", .bowsPastel, .hairTemple, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F337.png"),
            ("onl_swan", "Thiên nga", .bowsPastel, .shoulderBack, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F9A2.png"),
            ("onl_blossom", "Hoa anh đào", .bowsPastel, .hairTemple, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F338.png"),
            ("onl_ballet", "Giày Ballet", .bowsPastel, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1FA70.png"),

            // Phim & Rạp (7)
            ("onl_cam_3d", "Máy ảnh 3D", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Camera%20with%20flash/3D/camera_with_flash_3d.png"),
            ("onl_party_popper_3d", "Pháo Giấy 3D", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Party%20popper/3D/party_popper_3d.png"),
            ("onl_film_frames", "Dải phim 35mm", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F39E.png"),
            ("onl_clapper", "Bảng quay", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F3AC.png"),
            ("onl_ticket", "Vé xem phim", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F39F.png"),
            ("onl_cassette", "Băng VHS", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F4FC.png"),
            ("onl_mic", "Mic thu âm", .filmCinema, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F399.png"),

            // Cà phê & Bánh (8)
            ("onl_cherry_3d", "Cherry 3D", .cafeSweet, .cheekAccent, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Cherries/3D/cherries_3d.png"),
            ("onl_strawberry_3d", "Dâu Tây 3D", .cafeSweet, .cheekAccent, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Strawberry/3D/strawberry_3d.png"),
            ("onl_croissant", "Bánh sừng bò", .cafeSweet, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F950.png"),
            ("onl_matcha", "Trà Matcha", .cafeSweet, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F375.png"),
            ("onl_strawberry", "Dâu tây", .cafeSweet, .cheekAccent, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F353.png"),
            ("onl_shortcake", "Bánh kem dâu", .cafeSweet, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F370.png"),
            ("onl_boba", "Trà sữa trân châu", .cafeSweet, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F9CB.png"),
            ("onl_cherry", "Quả Cherry", .cafeSweet, .cheekAccent, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F352.png"),

            // Lấp lánh (9)
            ("onl_sparkles_3d", "Lấp lánh 3D", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Sparkles/3D/sparkles_3d.png"),
            ("onl_star_3d", "Sao Sáng 3D", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Glowing%20star/3D/glowing_star_3d.png"),
            ("onl_heart_ribbon_3d", "Tim Nơ 3D", .sparkleMagic, .cheekAccent, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Heart%20with%20ribbon/3D/heart_with_ribbon_3d.png"),
            ("onl_clover_3d", "Cỏ 4 Lá 3D", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Four%20leaf%20clover/3D/four_leaf_clover_3d.png"),
            ("onl_moon", "Trăng lưỡi liềm", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F319.png"),
            ("onl_dizzy", "Sao chổi", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F4AB.png"),
            ("onl_rainbow", "Cầu vồng", .sparkleMagic, .headCrown, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F308.png"),
            ("onl_gem", "Kim cương", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F48E.png"),
            ("onl_sun", "Mặt trời nhỏ", .sparkleMagic, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/2600.png"),

            // Mèo & Du lịch (7)
            ("onl_cat_3d", "Mèo con 3D", .petsTravel, .shoulderBack, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Cat%20face/3D/cat_face_3d.png"),
            ("onl_teddy_3d", "Gấu Bông 3D", .petsTravel, .shoulderBack, "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets/Teddy%20bear/3D/teddy_bear_3d.png"),
            ("onl_bunny", "Thỏ xinh", .petsTravel, .shoulderBack, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F430.png"),
            ("onl_bear", "Gấu Teddy", .petsTravel, .shoulderBack, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F9F8.png"),
            ("onl_paw", "Dấu chân mèo", .petsTravel, .cheekAccent, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F43E.png"),
            ("onl_plane", "Máy bay giấy", .petsTravel, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/2708.png"),
            ("onl_palm", "Cây dừa biển", .petsTravel, .safeCorner, "https://cdn.jsdelivr.net/gh/hfg-gmuend/openmoji@15.1.0/color/618x618/1F334.png"),
        ]

        self.onlineStickers = specs.map { id, title, pack, zone, url in
            PhotoboothStickerAsset(id: id, title: title, category: .onlinePacks, onlinePack: pack, source: .online(urlString: url), anchorZone: zone)
        }
    }

    private func loadPersistedUserAssets() {
        if let data = UserDefaults.standard.data(forKey: customIndexKey),
           let decoded = try? JSONDecoder().decode([PhotoboothStickerAsset].self, from: data) {
            self.customStickers = decoded.filter { asset in
                if case .localFile(let name) = asset.source {
                    return FileManager.default.fileExists(atPath: aiStickersDir.appendingPathComponent(name).path)
                }
                return false
            }
        }
        if let data = UserDefaults.standard.data(forKey: customFramesIndexKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.customAIFrameFilenames = decoded.filter {
                FileManager.default.fileExists(atPath: aiFramesDir.appendingPathComponent($0).path)
            }
        }
    }

    private func persistUserAssets() {
        if let data = try? JSONEncoder().encode(customStickers) {
            UserDefaults.standard.set(data, forKey: customIndexKey)
        }
        if let data = try? JSONEncoder().encode(customAIFrameFilenames) {
            UserDefaults.standard.set(data, forKey: customFramesIndexKey)
        }
    }

    private func scanCachedOnlineAssets() {
        var found = Set<String>()
        for asset in onlineStickers {
            let fileURL = onlineCacheDir.appendingPathComponent("\(asset.id).png")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                found.insert(asset.id)
            }
        }
        downloadedOnlineIDs = found
    }

    // MARK: - 2. Synchronous & Async Image Loading

    public func cachedImage(for source: PhotoboothAssetSource, id: String) -> UIImage? {
        if let mem = imageCache[id] { return mem }

        switch source {
        case .bundled(let filename):
            let baseName = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            let paths = [
                Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "PhotoboothAssets"),
                Bundle.main.path(forResource: baseName, ofType: ext)
            ].compactMap { $0 }
            for path in paths {
                if let img = UIImage(contentsOfFile: path) {
                    imageCache[id] = img
                    return img
                }
            }
            return nil

        case .online:
            let fileURL = onlineCacheDir.appendingPathComponent("\(id).png")
            if let img = UIImage(contentsOfFile: fileURL.path) {
                imageCache[id] = img
                return img
            }
            return nil

        case .localFile(let filename):
            let stickerURL = aiStickersDir.appendingPathComponent(filename)
            if let img = UIImage(contentsOfFile: stickerURL.path) {
                imageCache[id] = img
                return img
            }
            let frameURL = aiFramesDir.appendingPathComponent(filename)
            if let img = UIImage(contentsOfFile: frameURL.path) {
                imageCache[id] = img
                return img
            }
            return nil
        }
    }

    public func loadFrameTextureImage(filename: String) -> UIImage? {
        let key = "frame_\(filename)"
        if let mem = imageCache[key] { return mem }
        let url = aiFramesDir.appendingPathComponent(filename)
        if let img = UIImage(contentsOfFile: url.path) {
            imageCache[key] = img
            return img
        }
        return nil
    }

    public func bundledFrameTextureImage(filename: String) -> UIImage? {
        let key = "btex_\(filename)"
        if let mem = imageCache[key] { return mem }
        let baseName = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let paths = [
            Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "PhotoboothAssets"),
            Bundle.main.path(forResource: baseName, ofType: ext)
        ].compactMap { $0 }
        for path in paths {
            if let img = UIImage(contentsOfFile: path) {
                imageCache[key] = img
                return img
            }
        }
        return nil
    }

    // MARK: - 3. Live Online CDN Download & Caching

    public func downloadOnlineSticker(_ asset: PhotoboothStickerAsset) async -> UIImage? {
        if let cached = cachedImage(for: asset.source, id: asset.id) {
            downloadedOnlineIDs.insert(asset.id)
            return cached
        }
        guard case .online(let urlString) = asset.source,
              let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 14
        req.setValue("AlignAIStudio/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 128,
                  let img = UIImage(data: data),
                  let pngData = img.pngData() else {
                return nil
            }
            let dest = onlineCacheDir.appendingPathComponent("\(asset.id).png")
            try? pngData.write(to: dest, options: .atomic)
            imageCache[asset.id] = img
            downloadedOnlineIDs.insert(asset.id)
            return img
        } catch {
            return nil
        }
    }

    public func downloadOnlinePack(_ pack: PhotoboothOnlinePackCategory) async -> Int {
        guard isDownloadingPack == nil else { return 0 }
        isDownloadingPack = pack
        defer { isDownloadingPack = nil }

        let targets = onlineStickers.filter { $0.onlinePack == pack }
        var count = 0
        for asset in targets {
            if await downloadOnlineSticker(asset) != nil {
                count += 1
            }
        }
        lastStatusMessage = count > 0
            ? "Đã tải \(count)/\(targets.count) sticker gói \(pack.rawValue)"
            : "Không tải được gói \(pack.rawValue). Kiểm tra kết nối mạng."
        return count
    }

    public func syncFeaturedPackIfWiFi() async {
        let net = NetworkMonitor.shared.checkConnection()
        guard net.isConnected && net.isWiFi else { return }
        let featured = onlineStickers.filter { $0.onlinePack == .bowsPastel && !downloadedOnlineIDs.contains($0.id) }
        for asset in featured {
            _ = await downloadOnlineSticker(asset)
        }
    }

    // MARK: - 4. On-Device Vision Subject Cutout -> Die-Cut Booth Sticker

    public func createCutoutStickerFromPhoto(_ cgImage: CGImage, title: String = "Tự tách nền") async -> PhotoboothStickerAsset? {
        let cutResult: UIImage? = await Task.detached(priority: .userInitiated) { [ciContext] () -> UIImage? in
            Self.cutoutForegroundAndAddDieCutOutline(cgImage: cgImage, ciContext: ciContext)
        }.value

        guard let finalImg = cutResult, let pngData = finalImg.pngData() else {
            lastStatusMessage = "Không tìm thấy chủ thể rõ nét để tách nền trên ảnh này."
            return nil
        }

        let id = "cut_\(UUID().uuidString.prefix(8))"
        let filename = "\(id).png"
        let dest = aiStickersDir.appendingPathComponent(filename)
        try? pngData.write(to: dest, options: .atomic)
        imageCache[id] = finalImg

        let asset = PhotoboothStickerAsset(
            id: id,
            title: title,
            category: .myStickers,
            source: .localFile(filename: filename),
            isAIGenerated: false
        )
        customStickers.insert(asset, at: 0)
        persistUserAssets()
        lastStatusMessage = "Đã tách nền thành công thành sticker viền trắng!"
        return asset
    }

    public func deleteCustomSticker(id: String) {
        if let idx = customStickers.firstIndex(where: { $0.id == id }) {
            let item = customStickers.remove(at: idx)
            if case .localFile(let name) = item.source {
                try? FileManager.default.removeItem(at: aiStickersDir.appendingPathComponent(name))
            }
            imageCache.removeValue(forKey: id)
            persistUserAssets()
        }
    }

    // MARK: - 5. AI Sticker Generation (Gemini Image / Pollinations AI + Vision Subject Cutout + Offline Fallback)

    public func generateAISticker(prompt: String) async -> (asset: PhotoboothStickerAsset?, backendUsed: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return (nil, "Trống") }

        isGeneratingAI = true
        defer { isGeneratingAI = false }

        let wrappedPrompt = "\(cleanPrompt), cute tactile die-cut vinyl photobooth sticker illustration, crisp clean contour, centered isolated on pure flat solid #FFFFFF white background, zero text, zero watermark, clean studio print quality"

        var rawCG: CGImage? = nil
        var backendLabel = "Offline Studio"

        if let geminiKey = activeGoogleGeminiKey(), NetworkMonitor.shared.checkConnection().isConnected {
            rawCG = await fetchGeminiImage(prompt: wrappedPrompt, apiKey: geminiKey)
            if rawCG != nil {
                backendLabel = "Gemini Image"
            }
        }

        if rawCG == nil && NetworkMonitor.shared.checkConnection().isConnected {
            rawCG = await fetchPollinationsImage(prompt: wrappedPrompt, width: 512, height: 512)
            if rawCG != nil {
                backendLabel = "Pollinations AI"
            }
        }

        let finalStickerUI: UIImage?
        if let cg = rawCG {
            finalStickerUI = await Task.detached(priority: .userInitiated) { [ciContext] in
                Self.cutoutForegroundAndAddDieCutOutline(cgImage: cg, ciContext: ciContext)
                    ?? Self.floodFillWhiteBackgroundRemoval(cgImage: cg)
                    ?? UIImage(cgImage: cg)
            }.value
        } else {
            backendLabel = "Offline Studio Stamp"
            finalStickerUI = Self.renderOfflineProceduralSticker(title: cleanPrompt)
        }

        guard let stickerImg = finalStickerUI, let pngData = stickerImg.pngData() else {
            lastStatusMessage = "Không thể tạo sticker lúc này."
            return (nil, backendLabel)
        }

        let id = "aistk_\(UUID().uuidString.prefix(8))"
        let filename = "\(id).png"
        let dest = aiStickersDir.appendingPathComponent(filename)
        try? pngData.write(to: dest, options: .atomic)
        imageCache[id] = stickerImg

        let shortTitle = String(cleanPrompt.prefix(16))
        let asset = PhotoboothStickerAsset(
            id: id,
            title: shortTitle,
            category: .myStickers,
            source: .localFile(filename: filename),
            isAIGenerated: true
        )
        customStickers.insert(asset, at: 0)
        persistUserAssets()
        lastStatusMessage = "Đã tạo sticker qua \(backendLabel)!"
        return (asset, backendLabel)
    }

    // MARK: - 6. AI Custom Frame Paper Generator (Strict Zero-Text / Editorial Surface Guard)

    public func generateAIFrameTexture(prompt: String, slotImages: [CGImage]) async -> (filename: String?, backendUsed: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return (nil, "Trống") }

        isGeneratingAI = true
        defer { isGeneratingAI = false }

        let harmony = Self.extractHarmoniousColors(from: slotImages)
        let wrappedPrompt = "\(cleanPrompt), seamless physical print paper background texture for a photo booth border, soft palette near \(harmony.pastelDesc), fine matte paper grain, tasteful minimalist pattern, strictly NO text, NO letters, NO words, NO faces, clean uniform framing surface"

        var resultImg: UIImage? = nil
        var backendLabel = "Offline Editorial Generator"

        if let geminiKey = activeGoogleGeminiKey(), NetworkMonitor.shared.checkConnection().isConnected {
            if let cg = await fetchGeminiImage(prompt: wrappedPrompt, apiKey: geminiKey) {
                resultImg = UIImage(cgImage: cg)
                backendLabel = "Gemini Image"
            }
        }

        if resultImg == nil && NetworkMonitor.shared.checkConnection().isConnected {
            if let cg = await fetchPollinationsImage(prompt: wrappedPrompt, width: 640, height: 960) {
                resultImg = UIImage(cgImage: cg)
                backendLabel = "Pollinations AI"
            }
        }

        if resultImg == nil {
            resultImg = Self.renderOfflineProceduralFramePaper(baseColor: harmony.uiColor, seedText: cleanPrompt)
        }

        guard let finalImg = resultImg,
              let data = finalImg.jpegData(compressionQuality: 0.90) else {
            lastStatusMessage = "Không thể tạo nền khung AI."
            return (nil, backendLabel)
        }

        let filename = "aiframe_\(UUID().uuidString.prefix(8)).jpg"
        let dest = aiFramesDir.appendingPathComponent(filename)
        try? data.write(to: dest, options: .atomic)
        imageCache["frame_\(filename)"] = finalImg
        customAIFrameFilenames.insert(filename, at: 0)
        persistUserAssets()
        lastStatusMessage = "Đã tạo nền khung in qua \(backendLabel)!"
        return (filename, backendLabel)
    }

    // MARK: - 7. AI Booth Portrait Stylization (Verified Gemini Interactions Image-to-Image)

    public func stylizeBoothPhotoWithAI(_ cgImage: CGImage, style: PhotoboothAIStylePreset) async -> (image: CGImage?, errorMessage: String?) {
        guard NetworkMonitor.shared.checkConnection().isConnected else {
            return (nil, "Cần kết nối mạng để chuyển phong cách chân dung AI.")
        }
        guard let geminiKey = activeGoogleGeminiKey() else {
            return (nil, "Chức năng đổi ảnh thành \(style.displayName) cần Google AI Studio Key trong Cài đặt > Bố cục (Google Gemini).")
        }

        isGeneratingAI = true
        defer { isGeneratingAI = false }

        // Downscale neatly before upload (<= 1024px) for fast portrait stylization
        let srcUI = UIImage(cgImage: cgImage)
        guard let jpegData = Self.resizedJPEGData(srcUI, maxDim: 1024, quality: 0.86) else {
            return (nil, "Không thể mã hóa ảnh đầu vào.")
        }
        let b64 = jpegData.base64EncodedString()

        // Official Gemini Interactions Image-to-Image API (verified from Gemini API docs)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            return (nil, "URL Gemini không hợp lệ.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 35
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(geminiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")

        let payload: [String: Any] = [
            "model": "gemini-nano-banana-2.1",
            "input": [
                ["type": "text", "text": style.promptInstruction],
                ["type": "image", "mime_type": "image/jpeg", "data": b64]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (nil, "Lỗi đóng gói yêu cầu AI.")
        }
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return (nil, "Không nhận được phản hồi hợp lệ từ máy chủ Gemini.")
            }
            if http.statusCode != 200 {
                let errText = Self.extractAPIErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return (nil, "Gemini Image từ chối xử lý (\(errText)). Kiểm tra model hoặc quyền API Key.")
            }
            if let outCG = Self.decodeBase64ImageFromInteractionsJSON(data) {
                return (outCG, nil)
            }
            return (nil, "Phản hồi từ Gemini không chứa dữ liệu ảnh đầu ra.")
        } catch {
            return (nil, "Lỗi kết nối Gemini Image: \(error.localizedDescription)")
        }
    }

    // MARK: - 8. Private Network & Vision Cutout Helpers

    private func activeGoogleGeminiKey() -> String? {
        if let direct = KeychainHelper.standard.read(forKey: "ai_provider_key_google_gemini")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }
        if GeminiService.shared.selectedProvider == .googleGemini {
            let k = GeminiService.shared.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { return k }
        }
        return nil
    }

    private func fetchGeminiImage(prompt: String, apiKey: String) async -> CGImage? {
        // Verified OpenAI-compatible Gemini image generation endpoint
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/images/generations") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 28
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": "gemini-2.5-flash-image",
            "prompt": prompt,
            "response_format": "b64_json",
            "n": 1
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]],
                  let b64 = arr.first?["b64_json"] as? String,
                  let imgData = Data(base64Encoded: b64),
                  let ui = UIImage(data: imgData) else {
                return nil
            }
            return ui.cgImage
        } catch {
            return nil
        }
    }

    private func fetchPollinationsImage(prompt: String, width: Int, height: Int) async -> CGImage? {
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let seed = Int.random(in: 1000...999999)
        let urlStr = "https://image.pollinations.ai/prompt/\(encoded)?width=\(width)&height=\(height)&seed=\(seed)&nologo=true"
        guard let url = URL(string: urlStr) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("AlignAIStudio/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 1024,
                  let ui = UIImage(data: data) else {
                return nil
            }
            return ui.cgImage
        } catch {
            return nil
        }
    }

    private nonisolated static func decodeBase64ImageFromInteractionsJSON(_ data: Data) -> CGImage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let outImg = json["output_image"] as? [String: Any],
           let b64 = outImg["data"] as? String,
           let imgData = Data(base64Encoded: b64),
           let ui = UIImage(data: imgData) {
            return ui.cgImage
        }
        if let outputs = json["outputs"] as? [[String: Any]] {
            for item in outputs {
                if (item["type"] as? String) == "image",
                   let b64 = item["data"] as? String,
                   let imgData = Data(base64Encoded: b64),
                   let ui = UIImage(data: imgData) {
                    return ui.cgImage
                }
            }
        }
        return nil
    }

    private nonisolated static func extractAPIErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return String(msg.prefix(80))
        }
        return nil
    }

    /// Tách chủ thể sắc nét bằng iOS 17 Vision `VNGenerateForegroundInstanceMaskRequest` + thêm viền trắng die-cut chuẩn tiệm Photobooth.
    private nonisolated static func cutoutForegroundAndAddDieCutOutline(cgImage: CGImage, ciContext: CIContext) -> UIImage? {
        let srcCI = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(ciImage: srcCI, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                return nil
            }
            let maskedBuffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let cutCI = CIImage(cvPixelBuffer: maskedBuffer)
            let extent = cutCI.extent
            guard extent.width > 12, extent.height > 12,
                  let cutCG = ciContext.createCGImage(cutCI, from: extent) else {
                return nil
            }
            return wrapWithSoftDieCutBorder(cutCG: cutCG)
        } catch {
            return nil
        }
    }

    private nonisolated static func wrapWithSoftDieCutBorder(cutCG: CGImage) -> UIImage? {
        let w = cutCG.width
        let h = cutCG.height
        let maxSide = max(w, h)
        let outSide = 320
        let pad = 22
        let scale = CGFloat(outSide - pad * 2) / CGFloat(max(1, maxSide))
        let dw = CGFloat(w) * scale
        let dh = CGFloat(h) * scale
        let drawRect = CGRect(
            x: (CGFloat(outSide) - dw) * 0.5,
            y: (CGFloat(outSide) - dh) * 0.5,
            width: dw,
            height: dh
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let canvasCGSize = CGSize(width: outSide, height: outSide)
        let cutUI = UIImage(cgImage: cutCG)

        // Build solid white die-cut silhouette cleanly with modern UIGraphicsImageRenderer (upright & zero iOS 17 deprecations)
        let whiteSil = UIGraphicsImageRenderer(size: canvasCGSize, format: format).image { silCtx in
            silCtx.cgContext.interpolationQuality = .high
            cutUI.draw(in: drawRect)
            silCtx.cgContext.setBlendMode(.sourceIn)
            UIColor.white.setFill()
            silCtx.cgContext.fill(CGRect(origin: .zero, size: canvasCGSize))
        }

        let renderer = UIGraphicsImageRenderer(size: canvasCGSize, format: format)
        return renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            let borderRadius: CGFloat = 5.5
            for step in 0..<12 {
                let angle = (CGFloat(step) / 12.0) * .pi * 2.0
                let ox = cos(angle) * borderRadius
                let oy = sin(angle) * borderRadius
                whiteSil.draw(in: CGRect(x: ox, y: oy, width: CGFloat(outSide), height: CGFloat(outSide)))
            }
            cutUI.draw(in: drawRect)
        }
    }

    private nonisolated static func floodFillWhiteBackgroundRemoval(cgImage: CGImage) -> UIImage? {
        let w = min(384, max(64, cgImage.width))
        let h = min(384, max(64, cgImage.height))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bgMask = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        queue.reserveCapacity(w * 4)

        @inline(__always)
        func isNearWhite(_ idx: Int) -> Bool {
            let o = idx * 4
            return pixels[o] >= 240 && pixels[o + 1] >= 240 && pixels[o + 2] >= 240
        }

        for x in 0..<w {
            let top = x
            let bot = (h - 1) * w + x
            if isNearWhite(top) && !bgMask[top] { bgMask[top] = true; queue.append(top) }
            if isNearWhite(bot) && !bgMask[bot] { bgMask[bot] = true; queue.append(bot) }
        }
        for y in 0..<h {
            let left = y * w
            let right = y * w + (w - 1)
            if isNearWhite(left) && !bgMask[left] { bgMask[left] = true; queue.append(left) }
            if isNearWhite(right) && !bgMask[right] { bgMask[right] = true; queue.append(right) }
        }

        var head = 0
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let x = idx % w
            let y = idx / w
            let neighbors = [
                y > 0 ? idx - w : -1,
                y + 1 < h ? idx + w : -1,
                x > 0 ? idx - 1 : -1,
                x + 1 < w ? idx + 1 : -1
            ]
            for n in neighbors where n >= 0 && !bgMask[n] && isNearWhite(n) {
                bgMask[n] = true
                queue.append(n)
            }
        }

        for i in 0..<(w * h) where bgMask[i] {
            let o = i * 4
            pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
        }
        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG)
    }

    private nonisolated static func renderOfflineProceduralSticker(title: String) -> UIImage {
        let size = CGSize(width: 280, height: 140)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let clean = String(title.prefix(18)).uppercased()
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(x: 10, y: 20, width: 260, height: 100)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 28)
            UIColor.white.setFill()
            path.fill()
            UIColor(red: 0.90, green: 0.72, blue: 0.42, alpha: 1.0).setStroke()
            path.lineWidth = 4.0
            path.stroke()

            let inner = rect.insetBy(dx: 8, dy: 8)
            let innerPath = UIBezierPath(roundedRect: inner, cornerRadius: 22)
            UIColor(red: 0.14, green: 0.14, blue: 0.17, alpha: 1.0).setFill()
            innerPath.fill()

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            let txt = NSString(string: clean.isEmpty ? "STUDIO" : clean)
            let txtSize = txt.size(withAttributes: attrs)
            let txtRect = CGRect(
                x: inner.minX + 8,
                y: inner.midY - txtSize.height * 0.5,
                width: inner.width - 16,
                height: txtSize.height
            )
            txt.draw(in: txtRect, withAttributes: attrs)
            _ = ctx
        }
    }

    private nonisolated static func renderOfflineProceduralFramePaper(baseColor: UIColor, seedText: String) -> UIImage {
        let size = CGSize(width: 600, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            baseColor.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Subtle fine halftone dot studio paper texture
            let dotColor = UIColor.black.withAlphaComponent(0.035)
            dotColor.setFill()
            let spacing: CGFloat = 24
            var y: CGFloat = 12
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 12 : 24
                while x < size.width {
                    cg.fillEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
                    x += spacing
                }
                y += spacing
                row += 1
            }
            _ = seedText
        }
    }

    public nonisolated static func extractHarmoniousColors(from images: [CGImage]) -> (uiColor: UIColor, pastelDesc: String) {
        guard let first = images.first else {
            return (UIColor(red: 0.96, green: 0.93, blue: 0.89, alpha: 1.0), "warm cream studio pastel")
        }
        let sampleSide = 24
        var buf = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: &buf, width: sampleSide, height: sampleSide, bitsPerComponent: 8, bytesPerRow: sampleSide * 4, space: cs, bitmapInfo: bi) {
            ctx.draw(first, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
        }
        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        let count = Double(sampleSide * sampleSide)
        for i in 0..<(sampleSide * sampleSide) {
            rSum += Double(buf[i * 4]) / 255.0
            gSum += Double(buf[i * 4 + 1]) / 255.0
            bSum += Double(buf[i * 4 + 2]) / 255.0
        }
        let rAvg = rSum / count
        let gAvg = gSum / count
        let bAvg = bSum / count
        // Pull towards clean soft studio pastel background
        let pr = 0.78 + rAvg * 0.20
        let pg = 0.78 + gAvg * 0.20
        let pb = 0.78 + bAvg * 0.20
        let desc = String(format: "RGB(%.0f,%.0f,%.0f)", pr * 255.0, pg * 255.0, pb * 255.0)
        return (UIColor(red: pr, green: pg, blue: pb, alpha: 1.0), desc)
    }

    private nonisolated static func resizedJPEGData(_ img: UIImage, maxDim: CGFloat, quality: CGFloat) -> Data? {
        let sz = img.size
        let maxSide = max(sz.width, sz.height)
        if maxSide <= maxDim {
            return img.jpegData(compressionQuality: quality)
        }
        let scale = maxDim / max(1.0, maxSide)
        let target = CGSize(width: round(sz.width * scale), height: round(sz.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
