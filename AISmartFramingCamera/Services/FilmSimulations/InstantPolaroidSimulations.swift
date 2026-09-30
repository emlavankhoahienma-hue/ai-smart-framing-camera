import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may anh chup lay lien Polaroid va Instax.
/// Mo phong Polaroid 600, SX-70 Time-Zero, Instax Mini 7, Instax Wide 300, Instax SQ10 va Polaroid Spectra.
public enum InstantPolaroidSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .polaroid600:
            return applyPolaroid600(input)
        case .sx70TimeZero:
            return applySX70TimeZero(input)
        case .instaxMini:
            return applyInstaxMini(input)
        case .instaxWide:
            return applyInstaxWide(input)
        case .instaxSquare:
            return applyInstaxSquare(input)
        case .polaroidSpectra:
            return applyPolaroidSpectra(input)
        default:
            return input
        }
    }

    // MARK: - 1. Polaroid 600 (Vung toi ngả lam luc hoa hoc, vung den sua duc D-min, sang mau kem)
    private static func applyPolaroid600(_ input: CIImage) -> CIImage {
        // Pha tron thuoc nhuom hoa hoc dac trung: vung toi am cyan-blue, sang am kem
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.98, y: 0.02, z: 0.00, w: 0),
            green: CIVector(x: -0.01, y: 0.98, z: 0.03, w: 0),
            blue: CIVector(x: -0.04, y: 0.04, z: 1.05, w: 0),
            bias: CIVector(x: 0.02, y: 0.03, z: 0.06, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 0.95)
        // Nang manh chan duong cong toe lift tao chat den duc sua (milky chemical blacks)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.09),
            p1: CGPoint(x: 0.25, y: 0.28),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.94)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.24, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.32, radius: 1.8)
    }

    // MARK: - 2. SX-70 Time-Zero (Dong phim lay lien huyen thoai, sac vang chanh am ap)
    private static func applySX70TimeZero(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: 0.02, z: -0.02, w: 0),
            green: CIVector(x: 0.02, y: 1.02, z: 0.00, w: 0),
            blue: CIVector(x: -0.03, y: 0.00, z: 0.94, w: 0),
            bias: CIVector(x: 0.04, y: 0.03, z: -0.02, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 7100, targetTint: 3.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 1.00)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.08),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.5)
        return FilmSimulationCore.applyVignette(out, intensity: 0.28, radius: 1.9)
    }

    // MARK: - 3. Instax Mini 7 (Mau sac tuoi sang, tuong phan cao, da trang hong, den sach se)
    private static func applyInstaxMini(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: -0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.00, y: 1.04, z: -0.01, w: 0),
            blue: CIVector(x: -0.02, y: -0.01, z: 1.06, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6600, targetTint: 1.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.15, saturation: 1.12, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.80),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.1)
    }

    // MARK: - 4. Instax Wide 300 (Kho phim rong, chuyen vung tu nhien, mau can bang)
    private static func applyInstaxWide(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.10, saturation: 1.08)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.18, radius: 2.3)
    }

    // MARK: - 5. Instax SQ10 (Kho vuong hien dai, ruc ro sac net, vung sang muot ma)
    private static func applyInstaxSquare(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.12, saturation: 1.10)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.3)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
    }

    // MARK: - 6. Polaroid Spectra (Khổ phim rong chuyen nghiep, sac do trung tinh, giau chi tiet)
    private static func applyPolaroidSpectra(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6650, targetTint: 1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.07, saturation: 0.98)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.24, radius: 2.1)
    }
}
