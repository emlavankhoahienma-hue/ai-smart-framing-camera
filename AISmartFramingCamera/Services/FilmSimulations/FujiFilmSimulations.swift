import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may anh va phim Fujifilm truyen thong.
/// Mo phong chinh xac pho mau X-Trans, Classic Chrome, Velvia 50, Classic Neg, Pro 400H, Astia va Acros B&W.
public enum FujiFilmSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .classicChrome:
            return applyClassicChrome(input)
        case .fujiPro400H:
            return applyFujiPro400H(input)
        case .velvia50:
            return applyVelvia50(input)
        case .classicNeg:
            return applyClassicNeg(input)
        case .astia100F:
            return applyAstia100F(input)
        case .acrosBW:
            return applyAcrosBW(input)
        case .fujiX:
            return applyFujiX100(input)
        case .tokyoAiry:
            return applyTokyoClean(input)
        default:
            return input
        }
    }

    // MARK: - 1. Classic Chrome (Tuong phan bong toi cung, mau sac tram am, bau troi ngoc lam)
    private static func applyClassicChrome(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.92, y: 0.05, z: 0.03, w: 0),
            green: CIVector(x: -0.02, y: 0.98, z: 0.04, w: 0),
            blue: CIVector(x: -0.05, y: 0.08, z: 0.97, w: 0),
            bias: CIVector(x: -0.01, y: 0.01, z: 0.02, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6350, targetTint: -1.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 0.88)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.21),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.2)
    }

    // MARK: - 2. Fuji Pro 400H (Da sang min, mau pastel, vung sang nguyen am pastel)
    private static func applyFujiPro400H(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.96, y: 0.02, z: 0.02, w: 0),
            green: CIVector(x: 0.00, y: 1.02, z: -0.02, w: 0),
            blue: CIVector(x: 0.01, y: 0.04, z: 0.95, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: 0.03, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6420, targetTint: 1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.04, saturation: 0.95)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.12, radius: 6.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.2)
        return out
    }

    // MARK: - 3. Fuji Velvia 50 (Bao hoa toi da, xanh la cay va bien tham, tuong phan phong canh)
    private static func applyVelvia50(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.10, y: -0.05, z: -0.05, w: 0),
            green: CIVector(x: -0.05, y: 1.12, z: -0.07, w: 0),
            blue: CIVector(x: -0.04, y: -0.04, z: 1.08, w: 0),
            bias: CIVector(x: -0.02, y: -0.01, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.18, saturation: 1.24)
        out = FilmSimulationCore.applyVibrance(out, amount: 0.16)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.01),
            p1: CGPoint(x: 0.25, y: 0.19),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.82),
            p4: CGPoint(x: 1.00, y: 0.99)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.08, grainSize: 1.0)
        return out
    }

    // MARK: - 4. Classic Neg (Tuong phan cao, vung toi am reu, phong cach duong pho hoai co)
    private static func applyClassicNeg(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: -0.02, z: -0.02, w: 0),
            green: CIVector(x: 0.03, y: 0.96, z: 0.01, w: 0),
            blue: CIVector(x: -0.06, y: 0.05, z: 1.01, w: 0),
            bias: CIVector(x: 0.01, y: 0.02, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6680, targetTint: 2.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.14, saturation: 0.92)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.20),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.22, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.24, radius: 2.0)
    }

    // MARK: - 5. Astia 100F (Ton mau da chan dung diu em, nen sang tinh te)
    private static func applyAstia100F(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6550, targetTint: 0.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.03, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.10, grainSize: 1.1)
    }

    // MARK: - 6. Neopan Acros (Den trang do phan giai cao, hat min, do sau chi tiet)
    private static func applyAcrosBW(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.30, y: 0.59, z: 0.11, w: 0),
            green: CIVector(x: 0.30, y: 0.59, z: 0.11, w: 0),
            blue: CIVector(x: 0.30, y: 0.59, z: 0.11, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.16, saturation: 0.0)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.21),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.3)
        return out
    }

    // MARK: - 7. Fuji X100 (Cam bien X-Trans, vi tuong phan sac net, mau sac tu nhien)
    private static func applyFujiX100(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6420, targetTint: -0.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 0.96)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.16, radius: 2.2)
    }

    // MARK: - 8. Tokyo Clean (Trong treo, nang sang vung toi, mau pastel Nhat Ban)
    private static func applyTokyoClean(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6300, targetTint: -1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 0.98, saturation: 0.88, brightness: 0.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.08),
            p1: CGPoint(x: 0.25, y: 0.30),
            p2: CGPoint(x: 0.50, y: 0.53),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyLensDiffusion(out, intensity: 0.15, radius: 8.0)
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.08, grainSize: 1.0)
    }
}
