import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong may anh chup phim co dien va Toy Cam.
/// Mo phong LOMO LC-A, 120LG Medium Format, FXN 35, Toy K, CineStill 800T, 1998 Cam, 1998 Street, Kambo, CPM35 va Vintage Warm 70s.
public enum VintageCamSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .lomoLCA:
            return applyLomoLCA(input)
        case .medium120LG:
            return applyMedium120LG(input)
        case .fxn35:
            return applyFXN35(input)
        case .toyK:
            return applyToyK(input)
        case .cinestill800T:
            return applyCineStill800T(input)
        case .cam1998:
            return apply1998Cam(input)
        case .cam1998Street:
            return applyCam1998Street(input)
        case .kambo:
            return applyKambo(input)
        case .cpm35:
            return applyCPM35(input)
        case .vintageWarm:
            return applyVintageWarm(input)
        default:
            return input
        }
    }

    // MARK: - 1. LOMO LC-A (Ong kinh Minitar 1, tuong phan gat, vignetting sau, bong toi am cyan)
    private static func applyLomoLCA(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.12, y: -0.04, z: -0.02, w: 0),
            green: CIVector(x: -0.02, y: 1.10, z: 0.02, w: 0),
            blue: CIVector(x: -0.04, y: 0.02, z: 1.08, w: 0),
            bias: CIVector(x: -0.01, y: 0.02, z: 0.04, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.18, saturation: 1.22)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.18),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.82),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.26, grainSize: 1.7)
        return FilmSimulationCore.applyVignette(out, intensity: 0.52, radius: 1.4)
    }

    // MARK: - 2. 120LG Medium Format (Film kho lon, chuyen vung sang muot ma, hat min sang trong)
    private static func applyMedium120LG(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.02, y: 0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.00, y: 1.02, z: 0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 1.00, w: 0),
            bias: CIVector(x: 0.03, y: 0.02, z: 0.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.04, saturation: 0.96)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.74),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.16, radius: 12.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.28, radius: 2.0)
    }

    // MARK: - 3. FXN 35 (May film PnS Nhat Ban thap nien 90, tone am ngot ngao)
    private static func applyFXN35(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: 0.02, z: -0.02, w: 0),
            green: CIVector(x: 0.01, y: 1.03, z: 0.00, w: 0),
            blue: CIVector(x: -0.03, y: 0.01, z: 0.96, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.05)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.5)
        return FilmSimulationCore.applyVignette(out, intensity: 0.25, radius: 1.9)
    }

    // MARK: - 4. Toy K (May anh nhua Holga / Diana, bien mo ao, mau ruc lo-fi)
    private static func applyToyK(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.10, y: -0.02, z: -0.04, w: 0),
            green: CIVector(x: -0.02, y: 1.08, z: 0.01, w: 0),
            blue: CIVector(x: -0.03, y: 0.02, z: 1.04, w: 0),
            bias: CIVector(x: 0.01, y: 0.02, z: 0.03, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.14, saturation: 1.15, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.94)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.30, grainSize: 1.8)
        return FilmSimulationCore.applyVignette(out, intensity: 0.48, radius: 1.5)
    }

    // MARK: - 5. CineStill 800T (Phim dien anh quay dem, bong toi am cyan, halation do ruc ro quanh anh sang)
    private static func applyCineStill800T(_ input: CIImage) -> CIImage {
        // Can bang nhiet do mau von Tungsten 3200K dua vao anh sang ban ngay
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.94, y: 0.02, z: 0.00, w: 0),
            green: CIVector(x: -0.02, y: 1.02, z: 0.04, w: 0),
            blue: CIVector(x: -0.06, y: 0.06, z: 1.14, w: 0),
            bias: CIVector(x: -0.01, y: 0.02, z: 0.05, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.21),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        // Quang do Halation do ruc dac trung CineStill vi khong co lop than chong quang phan xa remjet
        out = FilmSimulationCore.applyHalationGlow(out, intensity: 0.45, radius: 18.0)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.28, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.24, radius: 2.0)
    }

    // MARK: - 6. 1998 Cam (May chup dung 1 lan thap nien 90, flash gat, am vang reu)
    private static func apply1998Cam(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: 0.02, z: -0.04, w: 0),
            green: CIVector(x: 0.02, y: 1.05, z: 0.00, w: 0),
            blue: CIVector(x: -0.04, y: 0.02, z: 0.92, w: 0),
            bias: CIVector(x: 0.03, y: 0.03, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.06, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.95)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.32, grainSize: 1.8)
        return FilmSimulationCore.applyVignette(out, intensity: 0.36, radius: 1.7)
    }

    // MARK: - 7. 1998 Street (Chat lieu anh phong su duong pho 1998, do hat tho, tuong phan cao)
    private static func applyCam1998Street(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: 0.01, z: -0.02, w: 0),
            green: CIVector(x: 0.01, y: 1.04, z: 0.01, w: 0),
            blue: CIVector(x: -0.03, y: 0.01, z: 0.95, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.00, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.16, saturation: 1.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.35, grainSize: 1.9)
        return FilmSimulationCore.applyVignette(out, intensity: 0.30, radius: 1.8)
    }

    // MARK: - 8. Kambo (Phong cach bao chi thoi trang retro, xanh da troi sau, da hong)
    private static func applyKambo(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: 0.01, z: -0.02, w: 0),
            green: CIVector(x: 0.00, y: 1.03, z: 0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.02, z: 1.06, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: 0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.1)
    }

    // MARK: - 9. CPM35 (May anh 35mm compact nhe nhang, mau sac trung thuc, hat min)
    private static func applyCPM35(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.03, y: 0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.00, y: 1.02, z: 0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 0.99, w: 0),
            bias: CIVector(x: 0.01, y: 0.01, z: 0.00, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 1.00)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.1)
    }

    // MARK: - 10. Vintage Warm 70s (Tone mau am ap thap nien 70, vang dong hoai niem)
    private static func applyVintageWarm(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: 0.03, z: -0.04, w: 0),
            green: CIVector(x: 0.02, y: 1.04, z: -0.01, w: 0),
            blue: CIVector(x: -0.04, y: 0.01, z: 0.90, w: 0),
            bias: CIVector(x: 0.04, y: 0.03, z: -0.01, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 1.02)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.07),
            p1: CGPoint(x: 0.25, y: 0.28),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.74),
            p4: CGPoint(x: 1.00, y: 0.94)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.25, grainSize: 1.6)
        return FilmSimulationCore.applyVignette(out, intensity: 0.26, radius: 1.9)
    }
}
