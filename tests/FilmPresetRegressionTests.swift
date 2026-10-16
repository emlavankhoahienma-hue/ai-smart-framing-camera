import XCTest
import UIKit
import CoreImage
@testable import AISmartFramingCamera

/// Bo kiem thu tu dong he thong gia lap mau va danh muc preset (Color System Regression Tests).
/// Kiem thu do chinh xac va an toan cua thuat toan match(from:), su nhat quan cua danh muc,
/// va tinh dung dan cua cac thong so mo phong quang hoc.
final class FilmPresetRegressionTests: XCTestCase {

    // MARK: - 1. Kiem thu chong va cham chuoi con trong match(from:)
    func testCollisionFreeMatching() {
        // Nokia Symbian khong bao gio bi nhan nham thanh Nokia 3310
        XCTAssertEqual(FilmPreset.match(from: "Nokia Symbian"), .nokiaSymbian)
        XCTAssertEqual(FilmPreset.match(from: "nokia symbian"), .nokiaSymbian)
        XCTAssertEqual(FilmPreset.match(from: "Nokia Symbian Carl Zeiss"), .nokiaSymbian)
        XCTAssertEqual(FilmPreset.match(from: "nokia n73"), .nokiaSymbian)
        XCTAssertEqual(FilmPreset.match(from: "nokia n95"), .nokiaSymbian)

        // Nokia 3310 phai khop dung 3310 LCD
        XCTAssertEqual(FilmPreset.match(from: "NOKIA"), .nokia3310)
        XCTAssertEqual(FilmPreset.match(from: "Nokia 3310"), .nokia3310)
        XCTAssertEqual(FilmPreset.match(from: "Nokia 3310 LCD"), .nokia3310)
        XCTAssertEqual(FilmPreset.match(from: "3310"), .nokia3310)
        XCTAssertEqual(FilmPreset.match(from: "3310 LCD"), .nokia3310)

        // Nokia 8800 phai khop dung luxury8800
        XCTAssertEqual(FilmPreset.match(from: "8800"), .luxury8800)
        XCTAssertEqual(FilmPreset.match(from: "Nokia 8800"), .luxury8800)

        // 1998 Street khong bao gio bi nhan nham thanh 1998 Cam
        XCTAssertEqual(FilmPreset.match(from: "1998 Street"), .cam1998Street)
        XCTAssertEqual(FilmPreset.match(from: "90s Street"), .cam1998Street)
        XCTAssertEqual(FilmPreset.match(from: "1998"), .cam1998)
        XCTAssertEqual(FilmPreset.match(from: "1998 Cam"), .cam1998)
        XCTAssertEqual(FilmPreset.match(from: "Disposable 1998"), .cam1998)

        // G-CCD khong bao gio bi nhan nham thanh CCD1
        XCTAssertEqual(FilmPreset.match(from: "G-CCD"), .gCcdGold)
        XCTAssertEqual(FilmPreset.match(from: "G-CCD Gold"), .gCcdGold)
        XCTAssertEqual(FilmPreset.match(from: "gccd"), .gCcdGold)
        XCTAssertEqual(FilmPreset.match(from: "CCD1"), .ccd1Cyber)
        XCTAssertEqual(FilmPreset.match(from: "Sony CCD1"), .ccd1Cyber)
        XCTAssertEqual(FilmPreset.match(from: "D-CCD"), .dCcdWarm)
        XCTAssertEqual(FilmPreset.match(from: "BlueSK"), .blueSKCool)

        // Kodak Vision3 Daylight
        XCTAssertEqual(FilmPreset.match(from: "Kodak 500D"), .vision3500D)
        XCTAssertEqual(FilmPreset.match(from: "Vision3 250D"), .vision3500D)
        XCTAssertEqual(FilmPreset.match(from: "Vision3"), .vision3500D)
        XCTAssertEqual(FilmPreset.match(from: "250D"), .vision3500D)

        // Kodak Portra vs ColorPlus
        XCTAssertEqual(FilmPreset.match(from: "Portra 400"), .kodakPortra400)
        XCTAssertEqual(FilmPreset.match(from: "ColorPlus 200"), .colorPlus200)
        XCTAssertEqual(FilmPreset.match(from: "ColorPlus"), .colorPlus200)
        XCTAssertEqual(FilmPreset.match(from: "Kodak ColorPlus"), .colorPlus200)

        // Historic & Creative Additions
        XCTAssertEqual(FilmPreset.match(from: "Cyanotype"), .cyanotype)
        XCTAssertEqual(FilmPreset.match(from: "Cyanotype Print"), .cyanotype)
        XCTAssertEqual(FilmPreset.match(from: "CYANO"), .cyanotype)
        XCTAssertEqual(FilmPreset.match(from: "GR Negative"), .grNegative)
        XCTAssertEqual(FilmPreset.match(from: "GR Negative Film"), .grNegative)
        XCTAssertEqual(FilmPreset.match(from: "GR NEG"), .grNegative)
        XCTAssertEqual(FilmPreset.match(from: "Bleach Bypass"), .bleachBypass)
        XCTAssertEqual(FilmPreset.match(from: "BLEACH"), .bleachBypass)
    }

    // MARK: - 2. Kiem thu tinh nhat quan cua danh muc Catalog
    func testCatalogConsistency() {
        // Danh sach tuyen chon selectablePresets phai co dung 65 preset
        XCTAssertEqual(FilmPreset.selectablePresets.count, 65)
        XCTAssertEqual(FilmPreset.mainCuratedPresets.count, 65)

        // Danh sach legacy phai co dung 11 preset
        XCTAssertEqual(FilmPreset.legacyPresets.count, 11)

        // Tong allCases phai la 76 preset (65 curated + 11 legacy)
        XCTAssertEqual(FilmPreset.allCases.count, 76)

        // Tat ca cac preset trong selectablePresets deu khong phai la aiFullAuto
        for preset in FilmPreset.selectablePresets {
            XCTAssertFalse(preset.isAIFullAuto)
        }

        // Tong cac preset trong 11 nhom FilmPresetCategory.presets phai bang dung 65
        let totalCategoryPresets = FilmPresetCategory.allCases.reduce(0) { $0 + $1.presets.count }
        XCTAssertEqual(totalCategoryPresets, 65)

        // Khong nhom nao bi rong
        for cat in FilmPresetCategory.allCases {
            XCTAssertGreaterThan(cat.presets.count, 0, "Nhom \(cat.rawValue) khong duoc de rong")
        }
    }

    // MARK: - 3. Kiem thu tinh hop le cua cac thong so gia lap
    func testSimulationPropertiesIntegrity() {
        // Kiem thu cac preset don sac
        let monochromePresets: Set<FilmPreset> = [.acrosBW, .triX400, .leicaMonochrom, .monochromeNoir, .grHighBW, .cyanotype]
        for preset in FilmPreset.allCases {
            if monochromePresets.contains(preset) {
                XCTAssertTrue(preset.isMonochrome, "\(preset.rawValue) phai la don sac")
                XCTAssertEqual(preset.liveSaturation, 0.0, "\(preset.rawValue) phai co do bao hoa bang 0")
            } else {
                XCTAssertFalse(preset.isMonochrome, "\(preset.rawValue) khong phai la don sac")
            }
        }

        // Kiem thu do dai title va badge de khong bi vo layout giao dien
        for preset in FilmPreset.allCases {
            XCTAssertLessThanOrEqual(preset.shortTitle.count, 9, "Short title cua \(preset.rawValue) khong duoc vuot qua 9 ky tu")
            XCTAssertLessThanOrEqual(preset.deviceBadge.count, 7, "Device badge cua \(preset.rawValue) khong duoc vuot qua 7 ky tu")
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertFalse(preset.description.isEmpty)
            XCTAssertFalse(preset.idealScenario.isEmpty)
        }

        // Kiem thu phan loai simulationType day du
        for preset in FilmPreset.allCases {
            _ = preset.simulationType
        }
    }

    // MARK: - 4. Kiem thu tuong thich nguoc cho UserDefaults
    func testBackwardCompatibilityRawValues() {
        // Cac rawValue cu phai duoc bao toan 100% de khong lam hong cai dat UserDefaults cua nguoi dung
        XCTAssertEqual(FilmPreset(rawValue: "NOKIA"), .nokia3310)
        XCTAssertEqual(FilmPreset(rawValue: "Kodak 500D"), .vision3500D)
        XCTAssertEqual(FilmPreset(rawValue: "Teal & Orange"), .cinemaTealOrange)
        XCTAssertEqual(FilmPreset(rawValue: "Sunset Glow"), .sunsetGlow)
        XCTAssertEqual(FilmPreset(rawValue: "Tokyo Clean"), .tokyoAiry)
        XCTAssertEqual(FilmPreset(rawValue: "Noir High Contrast"), .monochromeNoir)
        XCTAssertEqual(FilmPreset(rawValue: "FUJI X"), .fujiX)
        XCTAssertEqual(FilmPreset(rawValue: "1998"), .cam1998)
        XCTAssertEqual(FilmPreset(rawValue: "Original Clean"), .standard)
    }
}
