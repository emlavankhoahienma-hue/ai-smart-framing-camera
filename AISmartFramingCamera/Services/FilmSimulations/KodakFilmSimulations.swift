import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong phim Kodak huyen thoai.
/// Mo phong Portra 400, Kodak Gold 200, ColorPlus 200, Ektar 100, Tri-X 400 va Vision3 250D Daylight Cinema.
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

    // MARK: - 1. Kodak Portra 400 (Pastel ton da chuyen nghiep, shadow em diu, highlight cuon muot ma)
    private static func applyPortra400(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.03, y: -0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.01, y: 0.99, z: 0.00, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 0.97, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: -0.01, w: 0)
        )
        // Can bang nhiet do am dao nhe nhang dac trung Portra (6780K)
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6780, targetTint: 1.2)
        // Tuong phan em, bao hoa vua phai de ton da sang trong
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.03, saturation: 0.98)
        // Duong cong S-Curve mem mai: Toe duoc nang sang nhe, Shoulder cuon muot khong chay
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.94)
        )
        out = FilmSimulationCore.applyLensDiffusion(out, intensity: 0.08, radius: 4.5)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.1)
        return FilmSimulationCore.applyVignette(out, intensity: 0.12, radius: 2.6)
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

    // MARK: - 3. Kodak ColorPlus 200 (Chat phim binh dan thap nien 90, vang cam dam, tuong phan dam da)
    private static func applyColorPlus200(_ input: CIImage) -> CIImage {
        // Pho mau vang cam dam dac trung film du lich duoc phong rua thap nien 90
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.09, y: 0.01, z: -0.03, w: 0),
            green: CIVector(x: 0.03, y: 0.96, z: -0.02, w: 0),
            blue: CIVector(x: -0.06, y: 0.01, z: 0.92, w: 0),
            bias: CIVector(x: 0.03, y: 0.02, z: -0.02, w: 0)
        )
        // Can bang nhiet do am vang dam dac (7150K)
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 7150, targetTint: 2.8)
        // Tuong phan dam va bao hoa mau nong ruc ro hon Portra 400
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.13, saturation: 1.07)
        // Duong cong tuong phan cao: Shadow chim nau canh gian, Highlight ruc nang
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.25, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
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
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.06, grainSize: 0.9)
        return out
    }

    // MARK: - 5. Kodak Tri-X 400 (Den trang phong su kinh dien, hat tho gai goc, tuong phan kich tinh)
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

    // MARK: - 6. Kodak Vision3 250D (Phim dien anh Hollywood Daylight 5207, dai sang rong, highlight em)
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
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.16, radius: 10.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.3)
        return out
    }
}
