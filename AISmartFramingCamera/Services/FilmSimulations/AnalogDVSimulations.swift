import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may quay bang tu va ky thuat so thoi ky dau (DV / Camcorder).
/// Mo phong MiniDV 4:3, Hi8 Analog, DCR-DVD, DVX100 24p, VHS-C Home, HDV 1080i va HK Cinema 90s.
public enum AnalogDVSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .miniDV43:
            return applyMiniDV43(input)
        case .hi8Analog:
            return applyHi8Analog(input)
        case .dcrDVD:
            return applyDCRDVD(input)
        case .dvx10024p:
            return applyDVX10024p(input)
        case .vhscHome:
            return applyVHSCHome(input)
        case .hdv1080i:
            return applyHDV1080i(input)
        case .hkCinema90s:
            return applyHKCinema90s(input)
        default:
            return input
        }
    }

    // MARK: - 1. MiniDV 4:3 (Camcorder bang MiniDV cuoi 90s, do tuong phan video gamma, tran sang CCD nhe)
    private static func applyMiniDV43(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.02, y: -0.01, z: 0.00, w: 0),
            green: CIVector(x: 0.00, y: 1.04, z: -0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.02, z: 1.05, w: 0),
            bias: CIVector(x: 0.02, y: 0.02, z: 0.03, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 0.94, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.07),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.73),
            p4: CGPoint(x: 1.00, y: 0.93)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.16, radius: 6.0)
        out = FilmSimulationCore.applyChromaBleed(out, shiftX: 2.0)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.14)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
    }

    // MARK: - 2. Hi8 Analog (Bang tu 8mm analog, mau hoi be, am ngot ngao, nhieu bang tu)
    private static func applyHi8Analog(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: 0.02, z: -0.02, w: 0),
            green: CIVector(x: 0.01, y: 1.03, z: 0.00, w: 0),
            blue: CIVector(x: -0.03, y: 0.01, z: 0.94, w: 0),
            bias: CIVector(x: 0.03, y: 0.02, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 0.92, brightness: 0.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.08),
            p1: CGPoint(x: 0.25, y: 0.29),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.73),
            p4: CGPoint(x: 1.00, y: 0.93)
        )
        out = FilmSimulationCore.applyChromaBleed(out, shiftX: 3.0)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.20)
        return FilmSimulationCore.applyVignette(out, intensity: 0.26, radius: 1.9)
    }

    // MARK: - 3. DCR-DVD (Handycam ghi truc tiep dia mini-DVD dau nhung nam 2000, sac net ky thuat so)
    private static func applyDCRDVD(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: 0.00, z: -0.01, w: 0),
            green: CIVector(x: -0.01, y: 1.03, z: 0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 1.02, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.14, radius: 5.0)
        return FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.12)
    }

    // MARK: - 4. DVX100 24p (May quay phim doc lap huyen thoai cua Panasonic, CineGamma dam da)
    private static func applyDVX10024p(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: 0.01, z: -0.02, w: 0),
            green: CIVector(x: 0.00, y: 1.04, z: 0.01, w: 0),
            blue: CIVector(x: -0.03, y: 0.02, z: 0.98, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.00, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.14, saturation: 0.96)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.24, radius: 2.1)
    }

    // MARK: - 5. VHS-C Home (May quay gia dinh bang VHS-C, tong mau am am, den duc sua)
    private static func applyVHSCHome(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: 0.03, z: -0.03, w: 0),
            green: CIVector(x: 0.02, y: 1.04, z: -0.01, w: 0),
            blue: CIVector(x: -0.04, y: 0.01, z: 0.92, w: 0),
            bias: CIVector(x: 0.04, y: 0.03, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.05, saturation: 0.95, brightness: 0.025)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.09),
            p1: CGPoint(x: 0.25, y: 0.30),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.72),
            p4: CGPoint(x: 1.00, y: 0.91)
        )
        out = FilmSimulationCore.applyChromaBleed(out, shiftX: 4.0)
        out = FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.24)
        return FilmSimulationCore.applyVignette(out, intensity: 0.32, radius: 1.8)
    }

    // MARK: - 6. HDV 1080i (Ky nguyen Sony HDR-FX1 / Z1, do phan giai cao dau tien, sac mau ruc ro)
    private static func applyHDV1080i(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.03, y: 0.00, z: -0.01, w: 0),
            green: CIVector(x: -0.01, y: 1.04, z: 0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 1.04, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        return FilmSimulationCore.applyDigitalCCDNoise(out, intensity: 0.10)
    }

    // MARK: - 7. HK Cinema 90s (Dien anh Hong Kong thap nien 90, Vuong Gia Ve, xanh ngoc luc bao va vang am)
    private static func applyHKCinema90s(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: 0.02, z: -0.04, w: 0),
            green: CIVector(x: -0.02, y: 1.08, z: 0.02, w: 0),
            blue: CIVector(x: -0.06, y: 0.03, z: 0.98, w: 0),
            bias: CIVector(x: 0.01, y: 0.03, z: 0.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.16, saturation: 1.05)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.25, radius: 14.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.26, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.36, radius: 1.8)
    }
}
