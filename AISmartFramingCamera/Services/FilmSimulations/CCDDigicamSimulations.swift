import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may anh compact CCD Digicam Y2K.
/// Mo phong Sony CCD1 Cyber-shot, D-CCD Warm, BlueSK Cool, MangaCam, G-CCD Gold va InstaLite Flash.
public enum CCDDigicamSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .ccd1Cyber:
            return applyCCD1Cyber(input)
        case .dCcdWarm:
            return applyDCCDWarm(input)
        case .blueSKCool:
            return applyBlueSKCool(input)
        case .mangaCam:
            return applyMangaCam(input)
        case .gCcdGold:
            return applyGCCDGold(input)
        case .instaLiteFlash:
            return applyInstaLiteFlash(input)
        default:
            return input
        }
    }

    // MARK: - 1. Sony CCD1 Cyber-shot (Cam bien Super HAD CCD, mau tuoi ruc, xanh la va xanh bien bat mat)
    private static func applyCCD1Cyber(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: -0.02, z: -0.02, w: 0),
            green: CIVector(x: -0.02, y: 1.08, z: -0.04, w: 0),
            blue: CIVector(x: -0.03, y: -0.02, z: 1.10, w: 0),
            bias: CIVector(x: 0.00, y: 0.01, z: 0.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.14, saturation: 1.18)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.25, radius: 7.5)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.10, grainSize: 1.1)
        return out
    }

    // MARK: - 2. D-CCD Warm (Chat CCD am ap, ton mau da hong hao vang cam, khong khi chieu he)
    private static func applyDCCDWarm(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: 0.00, z: -0.02, w: 0),
            green: CIVector(x: 0.02, y: 1.02, z: -0.01, w: 0),
            blue: CIVector(x: -0.03, y: 0.00, z: 0.96, w: 0),
            bias: CIVector(x: 0.03, y: 0.02, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 7000, targetTint: 2.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.12)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.22, radius: 8.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.2)
        return out
    }

    // MARK: - 3. BlueSK Cool (Ton CCD ngả lanh xanh ngoc, bau troi trong vat Y2K)
    private static func applyBlueSKCool(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.95, y: 0.02, z: 0.01, w: 0),
            green: CIVector(x: -0.02, y: 1.00, z: 0.02, w: 0),
            blue: CIVector(x: 0.00, y: 0.05, z: 1.12, w: 0),
            bias: CIVector(x: -0.02, y: 0.00, z: 0.04, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6150, targetTint: -2.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.15)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.26, radius: 8.0)
        return out
    }

    // MARK: - 4. MangaCam (Phong cach truyen tranh Nhat Ban, mau sac tach bach, tuong phan cao)
    private static func applyMangaCam(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.10, y: -0.03, z: -0.03, w: 0),
            green: CIVector(x: -0.03, y: 1.08, z: -0.03, w: 0),
            blue: CIVector(x: -0.04, y: -0.02, z: 1.12, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.20, saturation: 1.26)
        out = FilmSimulationCore.applyVibrance(out, amount: 0.22)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.18),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.82),
            p4: CGPoint(x: 1.00, y: 0.99)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.20, radius: 6.5)
        return out
    }

    // MARK: - 5. G-CCD Gold (Mau vang ruc ro anh kim, hoang hon thap nien 2000)
    private static func applyGCCDGold(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 7300, targetTint: 3.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.16)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.80),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.28, radius: 9.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.3)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.1)
    }

    // MARK: - 6. InstaLite Flash (Gia lap den flash truc dien cua may anh compact Y2K)
    private static func applyInstaLiteFlash(_ input: CIImage) -> CIImage {
        // Tang manh tuong phan o chu the tien canh giong nhu bi den flash roi vao
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6700, targetTint: 1.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.22, saturation: 1.18, brightness: 0.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.01),
            p1: CGPoint(x: 0.25, y: 0.18),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.84),
            p4: CGPoint(x: 1.00, y: 0.99)
        )
        // Loa flash manh va toi dan ve bon goc (flashlight falloff)
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.32, radius: 10.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.40, radius: 1.6)
    }
}
