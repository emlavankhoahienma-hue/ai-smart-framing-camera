import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may anh Canon danh tieng.
/// Mo phong PowerShot G (CCD), Canon IXUS Y2K, EOS 5D Classic, SureShot 35, Canon F-1 va PowerShot Pro1.
public enum CanonCCDSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .powershotG:
            return applyPowerShotG(input)
        case .ixusY2K:
            return applyCanonIXUS(input)
        case .eos5DClassic:
            return applyEOS5DClassic(input)
        case .sureShot35:
            return applySureShot35(input)
        case .canonF1:
            return applyCanonF1(input)
        case .powershotPro1:
            return applyPowerShotPro1(input)
        default:
            return input
        }
    }

    // MARK: - 1. PowerShot G (Cam bien CCD kinh dien, mau da am ap Canon Colors, bau troi xanh trong)
    private static func applyPowerShotG(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: -0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.01, y: 1.00, z: 0.00, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 1.04, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6720, targetTint: 1.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 1.10)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.20, radius: 7.0)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.12)
        return out
    }

    // MARK: - 2. Canon IXUS (May anh thoi trang Y2K, mau tuoi sang, loa sang nhe, chat anh dau nam 2000)
    private static func applyCanonIXUS(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: -0.02, z: 0.00, w: 0),
            green: CIVector(x: 0.00, y: 1.04, z: -0.01, w: 0),
            blue: CIVector(x: -0.01, y: 0.00, z: 1.05, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6850, targetTint: 2.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.16, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.80),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.28, radius: 8.5)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.15)
        return FilmSimulationCore.applyVignette(out, intensity: 0.16, radius: 2.2)
    }

    // MARK: - 3. Canon EOS 5D Classic ("5D Mark I", chat anh huu co giong phim, mau da em ai)
    private static func applyEOS5DClassic(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: 0.00, z: -0.01, w: 0),
            green: CIVector(x: 0.01, y: 1.01, z: 0.00, w: 0),
            blue: CIVector(x: -0.01, y: 0.00, z: 1.00, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.00, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6600, targetTint: 1.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 1.03)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        return out
    }

    // MARK: - 4. Canon SureShot 35 (May anh point-and-shoot am ap gia dinh, vien toi nhe)
    private static func applySureShot35(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6900, targetTint: 2.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.09, saturation: 1.06)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
    }

    // MARK: - 5. Canon F-1 (May anh co co khi chuyen nghiep thap nien 70, tuong phan moc mac)
    private static func applyCanonF1(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6650, targetTint: 1.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.07, saturation: 0.95)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.5)
        return FilmSimulationCore.applyVignette(out, intensity: 0.18, radius: 2.2)
    }

    // MARK: - 6. Canon PowerShot Pro1 (Ong kinh L-lens do vien do, vi tuong phan cao, mau trung thuc)
    private static func applyPowerShotPro1(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.10, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.15, radius: 6.0)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.10)
        return out
    }
}
