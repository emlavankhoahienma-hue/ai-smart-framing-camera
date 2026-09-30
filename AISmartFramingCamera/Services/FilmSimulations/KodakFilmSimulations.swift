import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong phim Kodak huyen thoai.
/// Mo phong Portra 400, Kodak Gold 200, ColorPlus 200, Ektar 100, Tri-X 400 va Vision3 500D Cinema.
public enum KodakFilmSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .kodakPortra400:
            return applyPortra400(input)
        case .gold200:
            return applyGold200(input)
        case .colorPlus200:
            return applyColorPlus200(input)
        case .ektar100:
            return applyEktar100(input)
        case .triX400:
            return applyTriX400(input)
        case .vision3500D:
            return applyVision3500D(input)
        default:
            return input
        }
    }

    // MARK: - 1. Kodak Portra 400 (Vang am mat ong, mau da chan dung dinh cao, highlight mem mai)
    private static func applyPortra400(_ input: CIImage) -> CIImage {
        // Pha tron pho mau giu am sac da, giam do gat cua mau xanh
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: -0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.02, y: 0.98, z: 0.00, w: 0),
            blue: CIVector(x: -0.02, y: 0.02, z: 0.96, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: -0.01, w: 0)
        )
        // Can bang trang am tu nhien 6800K
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6850, targetTint: 1.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.05, saturation: 1.02)
        // Duong cong toe lift nhe nhang giu chi tiet vung toi
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.3)
        return FilmSimulationCore.applyVignette(out, intensity: 0.15, radius: 2.4)
    }

    // MARK: - 2. Kodak Gold 200 (Am ho phach ruc ro, nang he hoai niem, vung toi am vang)
    private static func applyGold200(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: 0.00, z: -0.02, w: 0),
            green: CIVector(x: 0.04, y: 0.98, z: -0.01, w: 0),
            blue: CIVector(x: -0.03, y: 0.00, z: 0.94, w: 0),
            bias: CIVector(x: 0.03, y: 0.02, z: -0.02, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 7100, targetTint: 3.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.08)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.5)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
    }

    // MARK: - 3. Kodak ColorPlus 200 (Chat anh thap nien 90, moc mac, hoi am vang cam)
    private static func applyColorPlus200(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: -0.02, z: 0.00, w: 0),
            green: CIVector(x: 0.02, y: 0.97, z: 0.01, w: 0),
            blue: CIVector(x: -0.04, y: 0.02, z: 0.95, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6920, targetTint: 2.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.07, saturation: 1.00)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.22, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.18, radius: 2.2)
    }

    // MARK: - 4. Kodak Ektar 100 (Bao hoa sieu cao, hat sieu min, do do va xanh noi bat)
    private static func applyEktar100(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.12, y: -0.04, z: -0.04, w: 0),
            green: CIVector(x: -0.03, y: 1.08, z: -0.02, w: 0),
            blue: CIVector(x: -0.02, y: -0.02, z: 1.09, w: 0),
            bias: CIVector(x: -0.01, y: 0.00, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.15, saturation: 1.22)
        out = FilmSimulationCore.applyVibrance(out, amount: 0.18)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.20),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.80),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        // Ektar co hat cuc ky min
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.06, grainSize: 0.9)
        return out
    }

    // MARK: - 5. Kodak Tri-X 400 (Den trang phong su kinh dien, hat thô gai goc, tuong phan kich tinh)
    private static func applyTriX400(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.32, y: 0.58, z: 0.10, w: 0),
            green: CIVector(x: 0.32, y: 0.58, z: 0.10, w: 0),
            blue: CIVector(x: 0.32, y: 0.58, z: 0.10, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.25, saturation: 0.0)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.01),
            p1: CGPoint(x: 0.25, y: 0.17),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.83),
            p4: CGPoint(x: 1.00, y: 0.99)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.28, grainSize: 1.8)
        return FilmSimulationCore.applyVignette(out, intensity: 0.26, radius: 1.9)
    }

    // MARK: - 6. Kodak Vision3 500D (Phim dien anh Hollywood, dai sang rong, highlight em)
    private static func applyVision3500D(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.02, y: 0.01, z: -0.01, w: 0),
            green: CIVector(x: -0.01, y: 1.01, z: 0.01, w: 0),
            blue: CIVector(x: 0.01, y: -0.02, z: 0.99, w: 0),
            bias: CIVector(x: 0.01, y: 0.00, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6600, targetTint: 0.6)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.2)
        return out
    }
}
