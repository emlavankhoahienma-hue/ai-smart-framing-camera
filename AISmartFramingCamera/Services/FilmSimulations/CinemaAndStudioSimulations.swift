import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc phong thu chuyen nghiep (Studio Natural / Leica / Hasselblad) va mau dien anh Cinema.
/// Mo phong Studio Natural, Cinema Teal & Orange, Sunset Glow, Leica Monochrom, Noir High Contrast, Nordic Minimal va Cyberpunk Night.
public enum CinemaAndStudioSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .studioNatural:
            return applyStudioNatural(input)
        case .cinemaTealOrange:
            return applyCinemaTealOrange(input)
        case .sunsetGlow:
            return applySunsetGlow(input)
        case .leicaMonochrom:
            return applyLeicaMonochrom(input)
        case .monochromeNoir:
            return applyMonochromeNoir(input)
        case .nordicCold:
            return applyNordicCold(input)
        case .neonCyberpunk:
            return applyNeonCyberpunk(input)
        default:
            return input
        }
    }

    // MARK: - 1. Studio Natural (Chuan mau phong thu Leica / Hasselblad True-to-Life Color Science)
    private static func applyStudioNatural(_ input: CIImage) -> CIImage {
        // Can bang mau trung tinh hoan hao, dac biet bao toan tong mau da nguoi (skin tones) tu nhien nhat
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.01, y: 0.00, z: 0.00, w: 0),
            green: CIVector(x: 0.00, y: 1.01, z: 0.00, w: 0),
            blue: CIVector(x: 0.00, y: 0.00, z: 1.00, w: 0),
            bias: CIVector(x: 0.00, y: 0.00, z: 0.00, w: 0)
        )
        // Contrast diu nhe, saturation can bang 100%, giu chi tiet highlight va shadow
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.03, saturation: 1.00)
        return FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
    }

    // MARK: - 2. Cinema Teal & Orange (Tone mau dien anh kinh dien, vung toi cyan/teal va mau da cam vang)
    private static func applyCinemaTealOrange(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: 0.02, z: -0.05, w: 0),
            green: CIVector(x: -0.02, y: 1.04, z: 0.03, w: 0),
            blue: CIVector(x: -0.08, y: 0.04, z: 1.12, w: 0),
            bias: CIVector(x: -0.02, y: 0.01, z: 0.04, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.2)
    }

    // MARK: - 3. Sunset Glow (Anh nang hoang hon ruc ro, do am ap vang cam toa sang)
    private static func applySunsetGlow(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.10, y: 0.02, z: -0.04, w: 0),
            green: CIVector(x: 0.03, y: 1.05, z: -0.02, w: 0),
            blue: CIVector(x: -0.05, y: 0.01, z: 0.90, w: 0),
            bias: CIVector(x: 0.05, y: 0.03, z: -0.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 1.08)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.20, radius: 14.0)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.1)
    }

    // MARK: - 4. Leica Monochrom (Cam bien trang den chuyen dung khong dung bo loc Bayer, chi tiet toi da)
    private static func applyLeicaMonochrom(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            green: CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            blue: CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            bias: CIVector(x: 0, y: 0, z: 0, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.15, saturation: 0.0)
        return FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
    }

    // MARK: - 5. Noir High Contrast (Trang den dien anh co dien thap nien 40, tuong phan kich tinh)
    private static func applyMonochromeNoir(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            green: CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            blue: CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            bias: CIVector(x: 0, y: 0, z: 0, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.35, saturation: 0.0)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.01),
            p1: CGPoint(x: 0.25, y: 0.17),
            p2: CGPoint(x: 0.50, y: 0.48),
            p3: CGPoint(x: 0.75, y: 0.82),
            p4: CGPoint(x: 1.00, y: 1.00)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.25, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.38, radius: 1.7)
    }

    // MARK: - 6. Nordic Minimal (Dien anh Bac Au, tone mau lanh tram tinh, giam do bao hoa)
    private static func applyNordicCold(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.96, y: 0.01, z: 0.02, w: 0),
            green: CIVector(x: 0.00, y: 1.00, z: 0.03, w: 0),
            blue: CIVector(x: -0.02, y: 0.02, z: 1.08, w: 0),
            bias: CIVector(x: -0.01, y: 0.00, z: 0.03, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 0.80)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.10, grainSize: 1.1)
    }

    // MARK: - 7. Cyberpunk Night (Tone thanh pho dem neon, xanh lam dien tu va tim magenta)
    private static func applyNeonCyberpunk(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: -0.04, z: 0.06, w: 0),
            green: CIVector(x: -0.04, y: 1.02, z: 0.04, w: 0),
            blue: CIVector(x: 0.02, y: -0.02, z: 1.18, w: 0),
            bias: CIVector(x: 0.02, y: -0.01, z: 0.05, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.18, saturation: 1.15)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.20),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.25, radius: 9.0)
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.20, radius: 14.0)
        return FilmSimulationCore.applyVignette(out, intensity: 0.32, radius: 1.8)
    }
}
