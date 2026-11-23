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

// MARK: - Photobooth Frame Categories & 50 Authentic Editorial / Studio Frames
public enum PhotoboothFrameCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "Tất cả"
    case koreanStudio = "Hàn & Studio"
    case coquetteCute = "Dễ thương"
    case y2kCyber = "Y2K & Nhạc"
    case retroFilm = "Phim & Cổ điển"
    case editorialTicket = "Vé & Tạp chí"

    public var id: String { rawValue }
}

public enum PhotoboothFrameStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    // 25 khung gốc
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
    // 25 khung mở rộng mới (Tổng cộng 50 khung đa dạng phong cách)
    case seoulSubwaySign = "seoul_subway"
    case y2kFlipPhone = "y2k_flip_phone"
    case musicPlayerCard = "music_player"
    case strawberryMilkCarton = "strawberry_milk"
    case checkerboardRetro = "checkerboard_retro"
    case polaroidGalleryNote = "gallery_note"
    case passportStamp = "passport_stamp"
    case cherryBlossomSpring = "cherry_blossom"
    case cyberMatrixNeon = "cyber_matrix"
    case frenchPatisserie = "french_patisserie"
    case matchaLatteMenu = "matcha_menu"
    case vintagePostcard = "vintage_postcard"
    case cassetteMixtape = "cassette_mixtape"
    case magazineCoverEditorial = "magazine_cover"
    case heartLaceRed = "heart_lace_red"
    case cloudsDaydream = "clouds_daydream"
    case monochromeGallery = "monochrome_gallery"
    case honeyButterBear = "honey_butter"
    case midnightDisco = "midnight_disco"
    case pistachioGelato = "pistachio_gelato"
    case oldBookPage = "old_book_page"
    case filmContactSheet = "film_contact_sheet"
    case peachSodaPop = "peach_soda_pop"
    case royalVelvetGold = "royal_velvet_gold"
    case minimalGridNotebook = "grid_notebook"
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
        case .seoulSubwaySign: return "Ga Tàu Seoul"
        case .y2kFlipPhone: return "Máy Gập Y2K"
        case .musicPlayerCard: return "Nhạc Vinyl"
        case .strawberryMilkCarton: return "Hộp Sữa Dâu"
        case .checkerboardRetro: return "Caro Đen Trắng"
        case .polaroidGalleryNote: return "Triển Lãm"
        case .passportStamp: return "Hộ Chiếu"
        case .cherryBlossomSpring: return "Hoa Anh Đào"
        case .cyberMatrixNeon: return "Cyber Neon"
        case .frenchPatisserie: return "Tiệm Bánh Paris"
        case .matchaLatteMenu: return "Menu Matcha"
        case .vintagePostcard: return "Bưu Thiếp Cổ"
        case .cassetteMixtape: return "Băng Cassette"
        case .magazineCoverEditorial: return "Bìa Tạp Chí"
        case .heartLaceRed: return "Ren Đỏ"
        case .cloudsDaydream: return "Trời Mây Trắng"
        case .monochromeGallery: return "Xám Kiến Trúc"
        case .honeyButterBear: return "Bơ Mật Ong"
        case .midnightDisco: return "Đêm Disco"
        case .pistachioGelato: return "Kem Pistachio"
        case .oldBookPage: return "Trang Sách Cổ"
        case .filmContactSheet: return "Bản In Phim"
        case .peachSodaPop: return "Soda Đào"
        case .royalVelvetGold: return "Nhung Hoàng Gia"
        case .minimalGridNotebook: return "Sổ Ô Ly Muji"
        case .customAITexture: return "AI Thiết Kế"
        }
    }

    public var category: PhotoboothFrameCategory {
        switch self {
        case .oldmoonWhite, .photoismObsidian, .life4CutsCream, .haruSkyBlue, .softPearl, .matchaGarden, .sunsetSilk, .seoulSubwaySign, .monochromeGallery, .minimalGridNotebook, .customAITexture:
            return .koreanStudio
        case .coquettePinstripe, .pinkPlushRibbon, .lavenderWatercolor, .cafeGingham, .butterCream, .coquetteSilkRibbon, .strawberryMilkCarton, .cherryBlossomSpring, .heartLaceRed, .cloudsDaydream, .honeyButterBear, .pistachioGelato, .peachSodaPop:
            return .coquetteCute
        case .denimScrapbook, .starryVelvet, .y2kBrushedChrome, .y2kFlipPhone, .musicPlayerCard, .checkerboardRetro, .cyberMatrixNeon, .cassetteMixtape, .midnightDisco:
            return .y2kCyber
        case .kodak35mmSprocket, .vintageKraftPaper, .berryNightFlash, .cocoaVintage, .oldBookPage, .filmContactSheet, .royalVelvetGold, .frenchPatisserie:
            return .retroFilm
        case .boardingPass, .dailyNewspaper, .vintageCinemaTicket, .thermalReceipt, .polaroidGalleryNote, .passportStamp, .matchaLatteMenu, .vintagePostcard, .magazineCoverEditorial:
            return .editorialTicket
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
        case .photoismObsidian, .boardingPass, .starryVelvet, .kodak35mmSprocket, .berryNightFlash, .cocoaVintage, .denimScrapbook,
             .musicPlayerCard, .passportStamp, .cyberMatrixNeon, .heartLaceRed, .monochromeGallery, .midnightDisco, .filmContactSheet, .royalVelvetGold:
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
        case .seoulSubwaySign: return [Color(red: 0.95, green: 0.97, blue: 0.95), Color(red: 0.18, green: 0.64, blue: 0.36)]
        case .y2kFlipPhone: return [Color(red: 0.86, green: 0.89, blue: 0.94), Color(red: 0.62, green: 0.71, blue: 0.85)]
        case .musicPlayerCard: return [Color(red: 0.10, green: 0.11, blue: 0.15), Color(red: 0.20, green: 0.24, blue: 0.32)]
        case .strawberryMilkCarton: return [Color(red: 0.99, green: 0.91, blue: 0.93), Color(red: 0.95, green: 0.55, blue: 0.67)]
        case .checkerboardRetro: return [Color(red: 0.96, green: 0.95, blue: 0.92), Color(red: 0.15, green: 0.15, blue: 0.16)]
        case .polaroidGalleryNote: return [Color(red: 0.97, green: 0.96, blue: 0.93), Color(red: 0.84, green: 0.82, blue: 0.77)]
        case .passportStamp: return [Color(red: 0.10, green: 0.16, blue: 0.28), Color(red: 0.78, green: 0.65, blue: 0.38)]
        case .cherryBlossomSpring: return [Color(red: 0.99, green: 0.92, blue: 0.95), Color(red: 0.95, green: 0.78, blue: 0.85)]
        case .cyberMatrixNeon: return [Color(red: 0.05, green: 0.08, blue: 0.12), Color(red: 0.16, green: 0.78, blue: 0.86)]
        case .frenchPatisserie: return [Color(red: 0.98, green: 0.95, blue: 0.88), Color(red: 0.82, green: 0.68, blue: 0.42)]
        case .matchaLatteMenu: return [Color(red: 0.94, green: 0.96, blue: 0.90), Color(red: 0.48, green: 0.64, blue: 0.42)]
        case .vintagePostcard: return [Color(red: 0.96, green: 0.93, blue: 0.86), Color(red: 0.75, green: 0.26, blue: 0.26)]
        case .cassetteMixtape: return [Color(red: 0.95, green: 0.92, blue: 0.85), Color(red: 0.88, green: 0.46, blue: 0.24)]
        case .magazineCoverEditorial: return [Color(red: 0.98, green: 0.97, blue: 0.96), Color(red: 0.14, green: 0.14, blue: 0.15)]
        case .heartLaceRed: return [Color(red: 0.56, green: 0.09, blue: 0.15), Color(red: 0.38, green: 0.05, blue: 0.09)]
        case .cloudsDaydream: return [Color(red: 0.80, green: 0.91, blue: 0.99), Color(red: 0.95, green: 0.98, blue: 1.00)]
        case .monochromeGallery: return [Color(red: 0.16, green: 0.16, blue: 0.17), Color(red: 0.09, green: 0.09, blue: 0.10)]
        case .honeyButterBear: return [Color(red: 0.99, green: 0.93, blue: 0.75), Color(red: 0.88, green: 0.65, blue: 0.32)]
        case .midnightDisco: return [Color(red: 0.09, green: 0.08, blue: 0.18), Color(red: 0.46, green: 0.44, blue: 0.64)]
        case .pistachioGelato: return [Color(red: 0.86, green: 0.94, blue: 0.82), Color(red: 0.68, green: 0.84, blue: 0.64)]
        case .oldBookPage: return [Color(red: 0.93, green: 0.88, blue: 0.78), Color(red: 0.76, green: 0.68, blue: 0.55)]
        case .filmContactSheet: return [Color(red: 0.08, green: 0.08, blue: 0.08), Color(red: 0.78, green: 0.22, blue: 0.20)]
        case .peachSodaPop: return [Color(red: 0.99, green: 0.88, blue: 0.82), Color(red: 0.97, green: 0.68, blue: 0.62)]
        case .royalVelvetGold: return [Color(red: 0.32, green: 0.06, blue: 0.11), Color(red: 0.82, green: 0.67, blue: 0.34)]
        case .minimalGridNotebook: return [Color(red: 0.98, green: 0.98, blue: 0.96), Color(red: 0.82, green: 0.85, blue: 0.88)]
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

// MARK: - Gemini Photo AI Booth Presets & Built-In System Prompt Guardrail Engine

/// 10 mẫu Sticker AI 1 chạm (dùng sẵn System Prompt chuẩn Gemini Photo để người dùng không cần tự gõ câu lệnh phức tạp).
public enum PhotoboothAIStickerPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case catRibbon = "cat_ribbon"
    case cyberGlasses = "cyber_glasses"
    case teddyHeart = "teddy_heart"
    case princessCrown = "princess_crown"
    case matchaBoba = "matcha_boba"
    case bunnyPlushEars = "bunny_ears"
    case vintageCamera = "vintage_camera"
    case pinkTulips = "pink_tulips"
    case retroHeadphones = "retro_headphones"
    case chromeStarbow = "chrome_starbow"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .catRibbon: return "Mèo trắng nơ hồng"
        case .cyberGlasses: return "Kính râm bạc Y2K"
        case .teddyHeart: return "Gấu bông ôm tim"
        case .princessCrown: return "Vương miện pha lê"
        case .matchaBoba: return "Trà sữa Matcha"
        case .bunnyPlushEars: return "Tai thỏ bông"
        case .vintageCamera: return "Máy ảnh phim cổ"
        case .pinkTulips: return "Bó hoa Tulip hồng"
        case .retroHeadphones: return "Tai nghe bạc Y2K"
        case .chromeStarbow: return "Nơ bạc ánh kim"
        }
    }

    public var anchorZone: PhotoboothStickerAnchorZone {
        switch self {
        case .catRibbon, .teddyHeart, .pinkTulips: return .shoulderBack
        case .cyberGlasses: return .eyeBridge
        case .princessCrown, .bunnyPlushEars, .retroHeadphones: return .headCrown
        case .chromeStarbow: return .hairTemple
        case .matchaBoba, .vintageCamera: return .safeCorner
        }
    }

    public var studioSubjectSpecification: String {
        switch self {
        case .catRibbon:
            return "a single adorable fluffy white kitten wearing a pastel pink satin bow tie, Korean photobooth prop style"
        case .cyberGlasses:
            return "a single sleek Y2K metallic chrome oval sunglasses prop with subtle silver reflection"
        case .teddyHeart:
            return "a single soft cream plush teddy bear holding a pastel pink fabric heart"
        case .princessCrown:
            return "a single delicate silver tiara crown with tiny clear crystal pearls"
        case .matchaBoba:
            return "a single aesthetic iced matcha latte cup with tapioca pearls and a cute striped straw"
        case .bunnyPlushEars:
            return "a single pair of fluffy white and blush pink plush bunny ears headband prop"
        case .vintageCamera:
            return "a single classic silver and black 35mm rangefinder film camera icon prop"
        case .pinkTulips:
            return "a single small bouquet of fresh pastel pink tulips wrapped in cream kraft paper with a satin ribbon"
        case .retroHeadphones:
            return "a single pair of retro Y2K silver metallic over-ear headphones"
        case .chromeStarbow:
            return "a single glossy silver metallic Y2K ribbon bow with a tiny four-point sparkle charm"
        }
    }
}

/// 10 mẫu Nền Khung In AI 1 chạm (System Prompt khóa chặt bề mặt giấy/vải phẳng, không chữ rác, không vẽ ô giả).
public enum PhotoboothAIFramePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case coquetteSilkLace = "coquette_silk_lace"
    case seoulMinimalLinen = "seoul_minimal_linen"
    case y2kDenimPatch = "y2k_denim_patch"
    case midnightStarVelvet = "midnight_star_velvet"
    case matchaBotanical = "matcha_botanical"
    case pastelGinghamNote = "pastel_gingham_note"
    case vintageNewsprint = "vintage_newsprint"
    case holoSilverFoil = "holo_silver_foil"
    case cherryBlossomWash = "cherry_blossom_wash"
    case burgundyStudioVelvet = "burgundy_studio_velvet"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .coquetteSilkLace: return "Lụa hồng viền ren"
        case .seoulMinimalLinen: return "Vải lanh kem Hàn"
        case .y2kDenimPatch: return "Denim bạc Y2K"
        case .midnightStarVelvet: return "Nhung đêm sao bạc"
        case .matchaBotanical: return "Giấy trà xanh hoa nhí"
        case .pastelGinghamNote: return "Caro pastel bơ"
        case .vintageNewsprint: return "Giấy cổ điển ấm"
        case .holoSilverFoil: return "Bạc ánh kim Holo"
        case .cherryBlossomWash: return "Màu nước anh đào"
        case .burgundyStudioVelvet: return "Nhung đỏ Studio"
        }
    }

    public var surfaceSpecification: String {
        switch self {
        case .coquetteSilkLace:
            return "soft blush pink coquette brushed cotton paper with subtle tonal micro-ribbons and delicate ivory lace texture"
        case .seoulMinimalLinen:
            return "warm Korean photo studio ivory museum linen paper with fine woven organic fiber grain"
        case .y2kDenimPatch:
            return "authentic light-wash blue denim fabric texture with subtle diagonal twill weave and faint silver thread sheen"
        case .midnightStarVelvet:
            return "deep midnight navy velvet paper with tiny understated silver foil micro-star flecks"
        case .matchaBotanical:
            return "soft sage matcha green handmade deckle paper with subtle pressed botanical leaf fibers"
        case .pastelGinghamNote:
            return "warm butter-cream and pastel apricot micro-gingham woven picnic stationery pattern"
        case .vintageNewsprint:
            return "warm archival cream cotton parchment paper with subtle vintage letterpress paper grain"
        case .holoSilverFoil:
            return "brushed Y2K metallic silver Pearl matte foil cardstock with soft pearlescent gradient"
        case .cherryBlossomWash:
            return "airy sakura blush watercolor wash on cold-press cotton art paper with soft pastel cloud transitions"
        case .burgundyStudioVelvet:
            return "deep burgundy wine velvet matte studio cardstock with fine warm undertone"
        }
    }
}

public enum PhotoboothAIStylePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case koreanStudio = "korean_studio"
    case fujifilmJapanese = "fujifilm_japanese"
    case y2kDirectFlash = "y2k_direct_flash"
    case anime90s = "anime_90s"
    case pastelPorcelain = "pastel_porcelain"
    case watercolorEditorial = "watercolor"
    case magazineVogue = "magazine_vogue"
    case cyberNeonBooth = "cyber_neon_booth"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .koreanStudio: return "Studio Hàn (Life4Cuts)"
        case .fujifilmJapanese: return "Phim Nhật (Fujifilm)"
        case .y2kDirectFlash: return "Flash Y2K Cổ Điển"
        case .anime90s: return "Anime Thập Niên 90"
        case .pastelPorcelain: return "Sứ Pastel Trong Trẻo"
        case .watercolorEditorial: return "Màu Nước Nghệ Thuật"
        case .magazineVogue: return "Tạp Chí Đen Trắng"
        case .cyberNeonBooth: return "Cyber Neon Seoul"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .koreanStudio:
            return "Enhance into an authentic Seoul Life4Cuts / Photoism high-end photo booth portrait with flattering diffused softbox beauty lighting, natural luminous porcelain skin texture, clean studio backdrop, and crisp catchlights in the eyes."
        case .fujifilmJapanese:
            return "Grade and refine into an authentic Japanese Fujifilm Pro 400H medium-format film portrait with airy pastel cyan-green highlights, delicate organic silver halide grain, and gentle warm skin tones."
        case .y2kDirectFlash:
            return "Restyle as a nostalgic early-2000s Y2K compact CCD camera direct-flash party booth photo with crisp specular highlights, rich contrast, and warm retro color science."
        case .anime90s:
            return "Redraw as a clean 1990s retro hand-painted Japanese cel anime portrait with soft film grain and warm highlights, while keeping every person's exact pose, glasses, hairstyle, expression, and outfit."
        case .pastelPorcelain:
            return "Transform into a dreamy soft pastel Korean editorial illustration portrait with silky lighting and harmonious pastel tones, strictly preserving facial likeness."
        case .watercolorEditorial:
            return "Transform into a delicate fine-art fashion editorial watercolor and ink portrait on cold-press cream paper, preserving exact facial likeness and pose."
        case .magazineVogue:
            return "Elevate into a timeless high-fashion monochrome silver-gelatin studio portrait with sculptural key lighting and rich tonal gradation, preserving exact facial identity."
        case .cyberNeonBooth:
            return "Relight as a stylish Hongdae futuristic neon photo booth portrait with soft cyan and magenta rim lighting on the hair and shoulders while keeping skin tones clean and natural."
        }
    }
}

/// Bộ chuẩn hóa System Prompt tự động cho Gemini Photo:
/// - Tự động dịch & làm giàu mọi từ khóa tiếng Việt ngắn/lộn xộn của người dùng thành câu lệnh chuẩn Studio.
/// - Áp hàng rào âm bản (Negative Guardrails) nghiêm ngặt để Gemini Photo không bao giờ vẽ chữ sai, watermark, hay làm biến dạng khuôn mặt.
public enum PhotoboothAISystemPromptEngine {
    private static let vietnameseKeywordDictionary: [(String, String)] = [
        ("mèo", "cute fluffy kitten"),
        ("chó", "cute puppy"),
        ("thỏ", "fluffy bunny rabbit"),
        ("gấu", "soft plush teddy bear"),
        ("nơ", "satin ribbon bow"),
        ("kính", "stylish Y2K sunglasses"),
        ("vương miện", "delicate crystal tiara crown"),
        ("hoa", "fresh pastel flower bouquet"),
        ("tulip", "pastel tulip flowers"),
        ("anh đào", "sakura cherry blossom"),
        ("trà sữa", "aesthetic boba milk tea cup"),
        ("matcha", "iced matcha latte"),
        ("cà phê", "iced latte coffee cup"),
        ("bánh", "pastel strawberry shortcake"),
        (" dâu", "sweet red strawberry"),
        ("cherry", "glossy twin cherries"),
        ("tim", "glossy pastel heart charm"),
        ("sao", "metallic chrome four-point star"),
        ("mây", "fluffy daydream cloud"),
        ("máy ảnh", "vintage 35mm film camera"),
        ("tai nghe", "retro Y2K silver headphones"),
        ("bướm", "holographic silver butterfly"),
        ("hồng", "soft blush pastel pink"),
        ("xanh", "airy pastel sky blue"),
        ("tím", "dreamy pastel lavender"),
        ("vàng", "warm butter cream yellow"),
        ("đen", "sleek matte obsidian black"),
        ("trắng", "clean pearl white"),
        ("bạc", "brushed metallic chrome silver"),
        ("đỏ", "deep cherry velvet red"),
        ("cổ điển", "vintage retro archival style"),
        ("dễ thương", "adorable Korean coquette aesthetic"),
        ("hàn quốc", "clean Seoul Life4Cuts photo studio style"),
        ("lấp lánh", "subtle sparkling crystal accents"),
        ("ren", "delicate ivory lace trim"),
        ("caro", "pastel gingham check pattern"),
        ("nhung", "rich matte velvet texture"),
        ("vải", "fine woven studio linen texture"),
        ("giấy", "tactile matte cotton print paper")
    ]

    /// Chuẩn hóa chuỗi người dùng nhập (loại bỏ ký tự nhiễu, tự động bổ sung ngữ nghĩa tiếng Anh nếu người dùng gõ tiếng Việt ngắn).
    public static func normalizeUserConcept(_ rawInput: String, fallbackConcept: String) -> String {
        let cleaned = rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else { return fallbackConcept }

        let lower = cleaned.lowercased()
        var mappedHints: [String] = []
        for (vi, en) in vietnameseKeywordDictionary where lower.contains(vi) {
            mappedHints.append(en)
        }
        let clippedUser = String(cleaned.prefix(90))
        if mappedHints.isEmpty {
            return clippedUser
        }
        return "\(clippedUser) (\(mappedHints.prefix(4).joined(separator: ", ")))"
    }

    /// System Prompt chuẩn Gemini Photo cho tạo Sticker tách nền Die-Cut.
    public static func composeStickerSystemPrompt(
        userInput: String,
        preset: PhotoboothAIStickerPreset? = nil
    ) -> String {
        let baseConcept: String
        if let preset, userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseConcept = preset.studioSubjectSpecification
        } else {
            let fallback = preset?.studioSubjectSpecification ?? PhotoboothAIStickerPreset.catRibbon.studioSubjectSpecification
            baseConcept = normalizeUserConcept(userInput, fallbackConcept: fallback)
        }
        return """
        [SYSTEM INSTRUCTION — GEMINI PHOTO DIE-CUT STICKER STUDIO]:
        Generate ONE single centered die-cut photobooth prop sticker of: \(baseConcept).
        Visual Rules:
        1. Style: High-craft tactile Korean Life4Cuts / Photoism vinyl sticker prop with clean silhouette, soft studio lighting, and charming physical detail.
        2. Background: Pure flat solid #FFFFFF white background with at least 18% empty white padding around all sides so foreground masking is 100% clean.
        3. Strict Negative Guardrails: STRICTLY NO text, NO letters, NO numbers, NO watermarks, NO logos, NO human faces, NO multiple scattered items, NO background room or table, NO cropped edges.
        """
    }

    /// System Prompt chuẩn Gemini Photo cho tạo Nền Khung In 300 DPI.
    public static func composeFrameSystemPrompt(
        userInput: String,
        preset: PhotoboothAIFramePreset? = nil,
        harmonyDescription: String
    ) -> String {
        let baseSurface: String
        if let preset, userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseSurface = preset.surfaceSpecification
        } else {
            let fallback = preset?.surfaceSpecification ?? PhotoboothAIFramePreset.seoulMinimalLinen.surfaceSpecification
            baseSurface = normalizeUserConcept(userInput, fallbackConcept: fallback)
        }
        return """
        [SYSTEM INSTRUCTION — GEMINI PHOTO PRINT BORDER SURFACE STUDIO]:
        Generate a seamless top-down flat-lay physical print paper or fabric background texture: \(baseSurface), harmonized with subtle tones near \(harmonyDescription).
        Visual Rules:
        1. Style: Authentic Korean photobooth print border surface, uniform edge-to-edge flat lighting, subtle tactile paper/fabric grain suitable for framing portraits.
        2. Strict Negative Guardrails: STRICTLY NO photo frames, NO empty cutout boxes, NO rectangles, NO text, NO typography, NO letters, NO numbers, NO people, NO faces, NO watermarks, NO 3D perspective angle.
        """
    }

    /// System Prompt chuẩn Gemini Photo cho chuyển đổi Chân Dung Booth (giữ nguyên danh tính khuôn mặt 100%).
    public static func composePortraitSystemPrompt(style: PhotoboothAIStylePreset) -> String {
        return """
        [SYSTEM INSTRUCTION — GEMINI PHOTO BOOTH PORTRAIT ENGINE]:
        Task: \(style.promptInstruction)
        Identity & Geometry Guardrails:
        1. Strictly preserve the exact number of people, their facial identity, facial proportions, eye direction, eyeglasses, hair silhouette, hand gestures, and framing.
        2. Keep skin tones flattering and clean; never distort fingers, eyes, or teeth.
        3. STRICTLY DO NOT add any text, captions, dates, frames, borders, or watermarks onto the photo.
        """
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
