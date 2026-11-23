import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Photobooth Print Layouts (Chuẩn in tiệm Hàn Quốc 300 DPI — Đủ 4×1, 2×4, 2×4 Đôi, 2×2, 3×1, 2×1, 6 Cut, 1×1)
public enum PhotoboothLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case strip4x1 = "strip_4x1"
    case grid2x4 = "grid_2x4"
    case twin2x4 = "twin_2x4"
    case grid2x2 = "grid_2x2"
    case strip3x1 = "strip_3x1"
    case couple2x1 = "couple_2x1"
    case mini6Cut = "mini_6cut"
    case polaroidSingle = "polaroid_1x1"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strip4x1: return "Dải 4 ảnh (4×1)"
        case .grid2x4: return "Lưới 8 ảnh (2×4)"
        case .twin2x4: return "Đôi 2 dải (2×4 Cắt đôi)"
        case .grid2x2: return "Lưới 4 ảnh (2×2)"
        case .strip3x1: return "Dải 3 ảnh (3×1)"
        case .couple2x1: return "Đôi 2 ảnh (2×1)"
        case .mini6Cut: return "Lưới 6 ảnh (3×2)"
        case .polaroidSingle: return "Đơn 1 ảnh (1×1)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .strip4x1: return "4×1"
        case .grid2x4: return "2×4"
        case .twin2x4: return "2×4 Đôi"
        case .grid2x2: return "2×2"
        case .strip3x1: return "3×1"
        case .couple2x1: return "2×1"
        case .mini6Cut: return "3×2"
        case .polaroidSingle: return "1×1"
        }
    }

    /// Số lượng tấm ảnh cần chụp trong 1 lượt (`twin2x4` chụp 4 tấm rồi in song song thành 2 dải 4×1 để cắt đôi).
    public var slotCount: Int {
        switch self {
        case .strip4x1: return 4
        case .grid2x4: return 8
        case .twin2x4: return 4
        case .grid2x2: return 4
        case .strip3x1: return 3
        case .couple2x1: return 2
        case .mini6Cut: return 6
        case .polaroidSingle: return 1
        }
    }

    /// Kích thước xuất in chuẩn 300 DPI sắc nét tuyệt đối.
    public var canvasSize: CGSize {
        switch self {
        case .strip4x1: return CGSize(width: 900, height: 2700)      // 1:3 classic strip
        case .grid2x4: return CGSize(width: 1600, height: 2400)      // 2:3 8-cut sheet (Photo Story 2×4)
        case .twin2x4: return CGSize(width: 1800, height: 2700)      // 2:3 twin 4×1 cut strips side-by-side
        case .grid2x2: return CGSize(width: 1600, height: 2400)      // 2:3 4R booth postcard
        case .strip3x1: return CGSize(width: 900, height: 2150)
        case .couple2x1: return CGSize(width: 1400, height: 1950)
        case .mini6Cut: return CGSize(width: 1600, height: 2400)
        case .polaroidSingle: return CGSize(width: 1400, height: 1700)
        }
    }

    public var aspectRatio: CGFloat {
        canvasSize.width / max(1.0, canvasSize.height)
    }

    public var slotAspectRatio: CGFloat {
        let rects = slotRects(in: canvasSize)
        guard let first = rects.first, first.height > 1 else { return 4.0 / 3.0 }
        return first.width / first.height
    }

    /// Ánh xạ chỉ số hình chữ nhật vẽ trên giấy in về chỉ số ảnh chụp (`twin2x4` lặp lại 0..3 trên cả 2 cột).
    public func photoIndex(forRenderedRectIndex rectIndex: Int) -> Int {
        guard slotCount > 0 else { return 0 }
        return rectIndex % slotCount
    }

    /// Hình học khay ảnh dùng chung 100% giữa Preview trực quan, Vision Smart Placement, bản in 300 DPI và Video Tua Nhanh.
    public func slotRects(in size: CGSize, marginScale: CGFloat = 1.0) -> [CGRect] {
        let w = size.width
        let h = size.height
        let mScale = max(0.75, min(1.35, marginScale))

        switch self {
        case .strip4x1:
            let padX = w * 0.068 * mScale
            let topPad = h * 0.032
            let footerH = h * 0.105
            let gapY = h * 0.014
            let slotW = w - padX * 2.0
            let availH = h - topPad - footerH - gapY * 3.0
            let slotH = availH / 4.0
            return (0..<4).map { i in
                CGRect(x: padX, y: topPad + CGFloat(i) * (slotH + gapY), width: slotW, height: slotH)
            }

        case .grid2x4:
            // Lưới 2 cột × 4 hàng (8 ảnh riêng biệt — kiểu Denim Photo Story chuẩn tiệm Hàn/VN)
            let padX = w * 0.045 * mScale
            let topPad = h * 0.034
            let footerH = h * 0.095
            let gapX = w * 0.022
            let gapY = h * 0.013
            let slotW = (w - padX * 2.0 - gapX) * 0.5
            let slotH = (h - topPad - footerH - gapY * 3.0) / 4.0
            var result: [CGRect] = []
            for r in 0..<4 {
                for c in 0..<2 {
                    result.append(CGRect(
                        x: padX + CGFloat(c) * (slotW + gapX),
                        y: topPad + CGFloat(r) * (slotH + gapY),
                        width: slotW,
                        height: slotH
                    ))
                }
            }
            return result

        case .twin2x4:
            // Hai dải 4×1 song song trên cùng 1 tờ in (để cắt đôi làm 2 dải giống hệt nhau)
            let halfW = w * 0.5
            let padX = halfW * 0.068 * mScale
            let topPad = h * 0.032
            let footerH = h * 0.105
            let gapY = h * 0.014
            let slotW = halfW - padX * 2.0
            let slotH = (h - topPad - footerH - gapY * 3.0) / 4.0
            var result: [CGRect] = []
            // Cột trái (indices 0..3)
            for i in 0..<4 {
                result.append(CGRect(x: padX, y: topPad + CGFloat(i) * (slotH + gapY), width: slotW, height: slotH))
            }
            // Cột phải (indices 4..7 ánh xạ về photoIndex 0..3)
            for i in 0..<4 {
                result.append(CGRect(x: halfW + padX, y: topPad + CGFloat(i) * (slotH + gapY), width: slotW, height: slotH))
            }
            return result

        case .strip3x1:
            let padX = w * 0.072 * mScale
            let topPad = h * 0.042
            let footerH = h * 0.115
            let gapY = h * 0.018
            let slotW = w - padX * 2.0
            let availH = h - topPad - footerH - gapY * 2.0
            let slotH = availH / 3.0
            return (0..<3).map { i in
                CGRect(x: padX, y: topPad + CGFloat(i) * (slotH + gapY), width: slotW, height: slotH)
            }

        case .grid2x2:
            let padX = w * 0.056 * mScale
            let topPad = h * 0.048
            let footerH = h * 0.130
            let gapX = w * 0.028
            let gapY = h * 0.020
            let slotW = (w - padX * 2.0 - gapX) * 0.5
            let slotH = (h - topPad - footerH - gapY) * 0.5
            var result: [CGRect] = []
            for r in 0..<2 {
                for c in 0..<2 {
                    result.append(CGRect(
                        x: padX + CGFloat(c) * (slotW + gapX),
                        y: topPad + CGFloat(r) * (slotH + gapY),
                        width: slotW,
                        height: slotH
                    ))
                }
            }
            return result

        case .couple2x1:
            let padX = w * 0.064 * mScale
            let topPad = h * 0.048
            let footerH = h * 0.140
            let gapY = h * 0.022
            let slotW = w - padX * 2.0
            let slotH = (h - topPad - footerH - gapY) * 0.5
            return (0..<2).map { i in
                CGRect(x: padX, y: topPad + CGFloat(i) * (slotH + gapY), width: slotW, height: slotH)
            }

        case .mini6Cut:
            let padX = w * 0.054 * mScale
            let topPad = h * 0.044
            let footerH = h * 0.115
            let gapX = w * 0.028
            let gapY = h * 0.018
            let slotW = (w - padX * 2.0 - gapX) * 0.5
            let slotH = (h - topPad - footerH - gapY * 2.0) / 3.0
            var result: [CGRect] = []
            for r in 0..<3 {
                for c in 0..<2 {
                    result.append(CGRect(
                        x: padX + CGFloat(c) * (slotW + gapX),
                        y: topPad + CGFloat(r) * (slotH + gapY),
                        width: slotW,
                        height: slotH
                    ))
                }
            }
            return result

        case .polaroidSingle:
            let padX = w * 0.068 * mScale
            let topPad = w * 0.068 * mScale
            let footerH = h * 0.215
            return [CGRect(x: padX, y: topPad, width: w - padX * 2.0, height: h - topPad - footerH)]
        }
    }
}

// MARK: - 24 Editorial & Textured Photobooth Frames (Sắc cạnh chuẩn in thật — Có chất liệu vải/giấy tạo từ Studio)
public enum PhotoboothFrameStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case oldmoonWhite = "oldmoon_white"
    case photoismObsidian = "photoism_obsidian"
    case boardingPass = "boarding_pass"
    case denimScrapbook = "denim_scrapbook"
    case starryVelvet = "starry_velvet"
    case coquettePinstripe = "coquette_pinstripe"
    case pinkPlushRibbon = "pink_plush_ribbon"
    case kodak35mmSprocket = "kodak_35mm"
    case matchaGarden = "matcha_garden"
    case y2kBrushedChrome = "y2k_chrome"
    case lavenderWatercolor = "lavender_watercolor"
    case vintageKraftPaper = "vintage_kraft"
    case dailyNewspaper = "daily_newspaper"
    case vintageCinemaTicket = "cinema_ticket"
    case thermalReceipt = "thermal_receipt"
    case cafeGingham = "cafe_gingham"
    case life4CutsCream = "life4cuts_cream"
    case haruSkyBlue = "haru_sky_blue"
    case butterCream = "butter_cream"
    case coquetteSilkRibbon = "coquette_ribbon"
    case berryNightFlash = "berry_night"
    case cocoaVintage = "cocoa_vintage"
    case sunsetSilk = "sunset_silk"
    case softPearl = "soft_pearl"
    case customAITexture = "custom_ai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oldmoonWhite: return "Trắng Oldmoon"
        case .photoismObsidian: return "Đen Life4Cuts"
        case .boardingPass: return "Vé Máy Bay"
        case .denimScrapbook: return "Denim Story"
        case .starryVelvet: return "Đêm Sao Velvet"
        case .coquettePinstripe: return "Sọc Ren Xanh"
        case .pinkPlushRibbon: return "Hồng Trái Tim"
        case .kodak35mmSprocket: return "Phim 35mm"
        case .matchaGarden: return "Lanh Matcha"
        case .y2kBrushedChrome: return "Bạc Foil Y2K"
        case .lavenderWatercolor: return "Mây Lavender"
        case .vintageKraftPaper: return "Giấy Kraft"
        case .dailyNewspaper: return "Báo Giấy"
        case .vintageCinemaTicket: return "Vé Rạp Phim"
        case .thermalReceipt: return "Hóa Đơn Nhiệt"
        case .cafeGingham: return "Caro Bánh"
        case .life4CutsCream: return "Kem Studio"
        case .haruSkyBlue: return "Xanh Haru"
        case .butterCream: return "Vàng Bơ"
        case .coquetteSilkRibbon: return "Hồng Lụa"
        case .berryNightFlash: return "Đỏ Rượu Đêm"
        case .cocoaVintage: return "Nâu Cacao"
        case .sunsetSilk: return "Hoàng Hôn"
        case .softPearl: return "Trắng Ngọc"
        case .customAITexture: return "AI Thiết Kế"
        }
    }

    public var bundledTextureFilename: String? {
        switch self {
        case .denimScrapbook: return "pb_tex_denim.jpg"
        case .coquettePinstripe: return "pb_tex_pinstripe.jpg"
        case .starryVelvet: return "pb_tex_starry.jpg"
        case .pinkPlushRibbon: return "pb_tex_pink_hearts.jpg"
        case .matchaGarden: return "pb_tex_matcha_linen.jpg"
        case .y2kBrushedChrome: return "pb_tex_silver_foil.jpg"
        case .lavenderWatercolor: return "pb_tex_lavender_wash.jpg"
        case .vintageKraftPaper: return "pb_tex_kraft_cream.jpg"
        default: return nil
        }
    }

    public var usesLightInk: Bool {
        switch self {
        case .photoismObsidian, .boardingPass, .starryVelvet, .kodak35mmSprocket, .berryNightFlash, .cocoaVintage, .denimScrapbook:
            return true
        default:
            return false
        }
    }

    public var swatchColors: [Color] {
        switch self {
        case .oldmoonWhite: return [Color(red: 0.99, green: 0.99, blue: 0.99), Color(red: 0.94, green: 0.94, blue: 0.94)]
        case .photoismObsidian: return [Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.14, green: 0.14, blue: 0.16)]
        case .boardingPass: return [Color(red: 0.14, green: 0.15, blue: 0.18), Color(red: 0.24, green: 0.26, blue: 0.30)]
        case .denimScrapbook: return [Color(red: 0.45, green: 0.58, blue: 0.72), Color(red: 0.28, green: 0.40, blue: 0.54)]
        case .starryVelvet: return [Color(red: 0.06, green: 0.09, blue: 0.20), Color(red: 0.14, green: 0.19, blue: 0.35)]
        case .coquettePinstripe: return [Color(red: 0.84, green: 0.91, blue: 0.96), Color(red: 0.97, green: 0.96, blue: 0.92)]
        case .pinkPlushRibbon: return [Color(red: 0.99, green: 0.87, blue: 0.90), Color(red: 0.95, green: 0.77, blue: 0.83)]
        case .kodak35mmSprocket: return [Color(red: 0.06, green: 0.06, blue: 0.06), Color(red: 0.88, green: 0.62, blue: 0.22)]
        case .matchaGarden: return [Color(red: 0.78, green: 0.84, blue: 0.70), Color(red: 0.64, green: 0.72, blue: 0.56)]
        case .y2kBrushedChrome: return [Color(red: 0.82, green: 0.84, blue: 0.88), Color(red: 0.58, green: 0.61, blue: 0.66)]
        case .lavenderWatercolor: return [Color(red: 0.88, green: 0.85, blue: 0.97), Color(red: 0.80, green: 0.86, blue: 0.98)]
        case .vintageKraftPaper: return [Color(red: 0.95, green: 0.91, blue: 0.83), Color(red: 0.87, green: 0.81, blue: 0.70)]
        case .dailyNewspaper: return [Color(red: 0.92, green: 0.89, blue: 0.83), Color(red: 0.28, green: 0.26, blue: 0.24)]
        case .vintageCinemaTicket: return [Color(red: 0.94, green: 0.88, blue: 0.76), Color(red: 0.64, green: 0.22, blue: 0.20)]
        case .thermalReceipt: return [Color(red: 0.98, green: 0.98, blue: 0.97), Color(red: 0.20, green: 0.22, blue: 0.24)]
        case .cafeGingham: return [Color(red: 0.98, green: 0.95, blue: 0.94), Color(red: 0.86, green: 0.42, blue: 0.44)]
        case .life4CutsCream: return [Color(red: 0.97, green: 0.95, blue: 0.91), Color(red: 0.90, green: 0.87, blue: 0.82)]
        case .haruSkyBlue: return [Color(red: 0.82, green: 0.90, blue: 0.97), Color(red: 0.68, green: 0.82, blue: 0.94)]
        case .butterCream: return [Color(red: 0.98, green: 0.93, blue: 0.72), Color(red: 0.95, green: 0.87, blue: 0.60)]
        case .coquetteSilkRibbon: return [Color(red: 0.98, green: 0.88, blue: 0.90), Color(red: 0.92, green: 0.74, blue: 0.79)]
        case .berryNightFlash: return [Color(red: 0.24, green: 0.05, blue: 0.09), Color(red: 0.48, green: 0.10, blue: 0.16)]
        case .cocoaVintage: return [Color(red: 0.24, green: 0.17, blue: 0.14), Color(red: 0.36, green: 0.26, blue: 0.21)]
        case .sunsetSilk: return [Color(red: 0.98, green: 0.82, blue: 0.70), Color(red: 0.94, green: 0.62, blue: 0.56)]
        case .softPearl: return [Color(red: 0.99, green: 0.99, blue: 0.99), Color(red: 0.93, green: 0.93, blue: 0.95)]
        case .customAITexture: return [Color(red: 0.90, green: 0.75, blue: 0.44), Color(red: 0.54, green: 0.42, blue: 0.88)]
        }
    }
}

public enum PhotoboothPaperFinish: String, CaseIterable, Identifiable, Codable, Sendable {
    case mattePaper = "matte"
    case glossyBooth = "glossy"
    case filmGrain = "grain"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mattePaper: return "Giấy lì"
        case .glossyBooth: return "Bóng kính"
        case .filmGrain: return "Hạt phim"
        }
    }
}

public enum PhotoboothTimerOption: Int, CaseIterable, Identifiable, Codable, Sendable {
    case manual = 0
    case sec3 = 3
    case sec6 = 6
    case sec8 = 8
    case sec10 = 10

    public var id: Int { rawValue }

    public var badgeTitle: String {
        switch self {
        case .manual: return "Tay"
        case .sec3: return "3s"
        case .sec6: return "6s"
        case .sec8: return "8s"
        case .sec10: return "10s"
        }
    }
}

public enum PhotoboothAIStylePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case koreanStudio = "korean_studio"
    case anime90s = "anime_90s"
    case watercolorEditorial = "watercolor"
    case pastelPorcelain = "pastel_porcelain"
    case magazineVogue = "magazine_vogue"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .koreanStudio: return "Studio Hàn Quốc"
        case .anime90s: return "Anime Thập Niên 90"
        case .watercolorEditorial: return "Màu Nước Nghệ Thuật"
        case .pastelPorcelain: return "Sứ Pastel Nhẹ"
        case .magazineVogue: return "Bìa Tạp Chí"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .koreanStudio:
            return "Transform into a crisp high-end Korean Seoul photo studio portrait with flattering softbox beauty light, clean glowing skin tones, keeping exact facial identity and pose."
        case .anime90s:
            return "Redraw as clean 1990s retro hand-painted cel anime illustration with soft film grain and warm highlights, strictly preserving the person's exact pose, hairstyle, expression, and outfit."
        case .watercolorEditorial:
            return "Transform into delicate fine-art fashion editorial watercolor and ink illustration on textured cream paper, preserving facial likeness and expression."
        case .pastelPorcelain:
            return "Transform into a soft pastel Korean aesthetic illustration portrait with silky gentle lighting and clean pastel tones, preserving facial identity."
        case .magazineVogue:
            return "Elevate into a dramatic editorial fashion magazine monochrome & high-contrast studio portrait with crisp rim lighting, preserving exact likeness."
        }
    }
}

// MARK: - Photobooth Sticker & Slot Data Models

public enum PhotoboothAssetCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case coquette = "Dễ thương"
    case y2k = "Y2K & Phim"
    case onlinePacks = "Online"
    case myStickers = "Tự tách & AI"

    public var id: String { rawValue }
}

public enum PhotoboothOnlinePackCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case y2kCyber = "Y2K & Cyber"
    case bowsPastel = "Nơ & Pastel"
    case filmCinema = "Phim & Rạp"
    case cafeSweet = "Cà phê & Bánh"
    case sparkleMagic = "Lấp lánh"
    case petsTravel = "Mèo & Du lịch"

    public var id: String { rawValue }
}

public enum PhotoboothAssetSource: Codable, Equatable, Sendable {
    case bundled(filename: String)
    case online(urlString: String)
    case localFile(filename: String)
}

/// Vùng neo thông minh cho từng loại sticker (Vision phát hiện khuôn mặt & góc trống, KHÔNG dán bừa che mặt).
public enum PhotoboothStickerAnchorZone: String, Codable, Equatable, Sendable {
    case headCrown
    case eyeBridge
    case hairTemple
    case cheekAccent
    case shoulderBack
    case safeCorner
}

/// Chủ đề tự động dán sticker thông minh 1 chạm theo nhận diện khuôn mặt & không gian trống.
public enum PhotoboothAutoDecorateStyle: String, CaseIterable, Identifiable, Sendable {
    case smartAdaptive = "Tự động theo mặt"
    case coquette = "Coquette"
    case y2kRetro = "Y2K Retro"
    case minimalCafe = "Tối giản Cafe"

    public var id: String { rawValue }
}

/// Phong cách xuất video tua nhanh hậu trường Photobooth (chuẩn đăng TikTok / IG Reels 9:16).
public enum PhotoboothTimelapseStyle: String, CaseIterable, Identifiable, Sendable {
    case movingStrip = "Khung động (Life4Cuts)"
    case btsReelsReveal = "Hậu trường + Lật ảnh"

    public var id: String { rawValue }
}

/// Tốc độ tua cho video hậu trường Photobooth (chậm rãi mượt mắt hơn — mặc định 2x).
public enum PhotoboothTimelapseSpeed: Double, CaseIterable, Identifiable, Sendable {
    case x1_5 = 1.5
    case x2 = 2.0
    case x3 = 3.0

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .x1_5: return "1.5x"
        case .x2: return "2x"
        case .x3: return "3x"
        }
    }
}

/// Khung hình nén JPEG nhẹ ghi lại tự động trong quá trình tạo dáng chụp Photobooth.
public struct PhotoboothTimelapseClipFrame: Sendable {
    public let slotIndex: Int
    public let timestamp: TimeInterval
    public let jpegData: Data

    public init(slotIndex: Int, timestamp: TimeInterval, jpegData: Data) {
        self.slotIndex = slotIndex
        self.timestamp = timestamp
        self.jpegData = jpegData
    }
}

public struct PhotoboothStickerAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var category: PhotoboothAssetCategory
    public var onlinePack: PhotoboothOnlinePackCategory?
    public var source: PhotoboothAssetSource
    public var anchorZone: PhotoboothStickerAnchorZone
    public var isAIGenerated: Bool

    public init(
        id: String,
        title: String,
        category: PhotoboothAssetCategory,
        onlinePack: PhotoboothOnlinePackCategory? = nil,
        source: PhotoboothAssetSource,
        anchorZone: PhotoboothStickerAnchorZone = .safeCorner,
        isAIGenerated: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.onlinePack = onlinePack
        self.source = source
        self.anchorZone = anchorZone
        self.isAIGenerated = isAIGenerated
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, category, onlinePack, source, anchorZone, isAIGenerated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.category = try c.decode(PhotoboothAssetCategory.self, forKey: .category)
        self.onlinePack = try c.decodeIfPresent(PhotoboothOnlinePackCategory.self, forKey: .onlinePack)
        self.source = try c.decode(PhotoboothAssetSource.self, forKey: .source)
        self.anchorZone = try c.decodeIfPresent(PhotoboothStickerAnchorZone.self, forKey: .anchorZone) ?? .safeCorner
        self.isAIGenerated = try c.decodeIfPresent(Bool.self, forKey: .isAIGenerated) ?? false
    }
}

public struct PlacedPhotoboothSticker: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var assetID: String
    public var assetSource: PhotoboothAssetSource
    public var normalizedX: CGFloat
    public var normalizedY: CGFloat
    public var scale: CGFloat
    public var rotationDegrees: Double
    public var opacity: Double

    public init(
        id: UUID = UUID(),
        assetID: String,
        assetSource: PhotoboothAssetSource,
        normalizedX: CGFloat = 0.5,
        normalizedY: CGFloat = 0.5,
        scale: CGFloat = 0.19,
        rotationDegrees: Double = 0.0,
        opacity: Double = 1.0
    ) {
        self.id = id
        self.assetID = assetID
        self.assetSource = assetSource
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
    }
}

public struct PhotoboothSlotPhoto: Identifiable, Sendable {
    public let id: UUID
    public var image: CGImage
    public var originalImage: CGImage
    public var aiStyledImage: CGImage?
    public var isAIStyleActive: Bool
    public var isMirrored: Bool

    public init(
        id: UUID = UUID(),
        image: CGImage,
        isMirrored: Bool = false
    ) {
        self.id = id
        self.image = image
        self.originalImage = image
        self.aiStyledImage = nil
        self.isAIStyleActive = false
        self.isMirrored = isMirrored
    }

    public var displayImage: CGImage {
        (isAIStyleActive ? aiStyledImage : nil) ?? image
    }
}

public struct PhotoboothStripConfig: Equatable, Codable, Sendable {
    public var layout: PhotoboothLayout = .strip4x1
    public var frameStyle: PhotoboothFrameStyle = .oldmoonWhite
    public var customAITextureFilename: String? = nil
    public var customBackgroundHex: String? = nil
    /// Vuông sắc cạnh 90 độ chuẩn máy in Photobooth thật (mặc định 0.0 — không bo góc).
    public var slotCornerRadiusRatio: CGFloat = 0.0
    public var marginScale: CGFloat = 1.0
    public var showDateStamp: Bool = true
    public var customCaption: String = "ALIGN STUDIO"
    public var paperFinish: PhotoboothPaperFinish = .mattePaper

    public init(
        layout: PhotoboothLayout = .strip4x1,
        frameStyle: PhotoboothFrameStyle = .oldmoonWhite,
        customAITextureFilename: String? = nil,
        customBackgroundHex: String? = nil,
        slotCornerRadiusRatio: CGFloat = 0.0,
        marginScale: CGFloat = 1.0,
        showDateStamp: Bool = true,
        customCaption: String = "ALIGN STUDIO",
        paperFinish: PhotoboothPaperFinish = .mattePaper
    ) {
        self.layout = layout
        self.frameStyle = frameStyle
        self.customAITextureFilename = customAITextureFilename
        self.customBackgroundHex = customBackgroundHex
        self.slotCornerRadiusRatio = slotCornerRadiusRatio
        self.marginScale = marginScale
        self.showDateStamp = showDateStamp
        self.customCaption = customCaption
        self.paperFinish = paperFinish
    }
}
