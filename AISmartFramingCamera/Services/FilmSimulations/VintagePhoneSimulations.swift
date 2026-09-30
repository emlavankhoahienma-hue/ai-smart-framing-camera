import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua cac dong dien thoai di dong co dien dau nhung nam 2000.
/// Mo phong Nokia 3310, Nokia Symbian N-Series, Motorola V3 RAZR, iPhone 3GS, Blackberry, Keitai 88, Sony K800i va Nokia 8800.
public enum VintagePhoneSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .nokia3310:
            return applyNokia3310(input)
        case .nokiaSymbian:
            return applyNokiaSymbian(input)
        case .motorolaV3:
            return applyMotorolaV3(input)
        case .iphone3GS:
            return applyIPhone3GS(input)
        case .blackberryQ10:
            return applyBlackberryQ10(input)
        case .keitai88:
            return applyKeitai88(input)
        case .sonyK800i:
            return applySonyK800i(input)
        case .luxury8800:
            return applyLuxury8800(input)
        default:
            return input
        }
    }

    // MARK: - 1. Nokia 3310 (Man hinh LCD xanh reu don sac, hoai niem tuoi tho)
    private static func applyNokia3310(_ input: CIImage) -> CIImage {
        // Chuyen sang trang den
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.25, saturation: 0.0)
        // Nhuom sac xanh reu dac trung cua man hinh monochrome Nokia
        out = FilmSimulationCore.applyColorMatrix(
            out,
            red: CIVector(x: 0.35, y: 0.0, z: 0.0, w: 0),
            green: CIVector(x: 0.0, y: 0.65, z: 0.0, w: 0),
            blue: CIVector(x: 0.0, y: 0.0, z: 0.25, w: 0),
            bias: CIVector(x: 0.08, y: 0.16, z: 0.06, w: 0)
        )
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.10),
            p1: CGPoint(x: 0.25, y: 0.30),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.72),
            p4: CGPoint(x: 1.00, y: 0.90)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.25, grainSize: 2.0)
    }

    // MARK: - 2. Nokia Symbian (Camera Carl Zeiss N73/N95, mau sac song dong thoi dau smartphone)
    private static func applyNokiaSymbian(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6750, targetTint: 1.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.12, saturation: 1.15)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.5)
        return out
    }

    // MARK: - 3. Motorola V3 RAZR (Dien thoai nap gap huyen thoai 2004, do phan giai mem mai)
    private static func applyMotorolaV3(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6850, targetTint: 2.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.05, saturation: 0.90, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.07),
            p1: CGPoint(x: 0.25, y: 0.28),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.94)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.20, grainSize: 1.7)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.0)
    }

    // MARK: - 4. iPhone 3GS (Camera 3MP nam 2009, chat anh am ap tu nhien, hoai niem)
    private static func applyIPhone3GS(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.05, y: -0.01, z: 0.00, w: 0),
            green: CIVector(x: 0.01, y: 1.00, z: 0.00, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 0.98, w: 0),
            bias: CIVector(x: 0.02, y: 0.01, z: 0.00, w: 0)
        )
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6780, targetTint: 1.5)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.08, saturation: 1.04)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.51),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.3)
        return out
    }

    // MARK: - 5. Blackberry Q10 (Phong cach doanh nhan, mau sac diem tinh, ro net)
    private static func applyBlackberryQ10(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.08, saturation: 0.92)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.77),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.10, grainSize: 1.1)
    }

    // MARK: - 6. Keitai 88 (Dien thoai nap gap Nhat Ban Garakei, mau tuoi sang, da min)
    private static func applyKeitai88(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6450, targetTint: -0.8)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 1.14, brightness: 0.01)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.06),
            p1: CGPoint(x: 0.25, y: 0.27),
            p2: CGPoint(x: 0.50, y: 0.52),
            p3: CGPoint(x: 0.75, y: 0.79),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyCCDBloom(out, intensity: 0.20, radius: 7.0)
        return out
    }

    // MARK: - 7. Sony K800i (Cyber-shot cam bien CMOS thoi ky dau, mau ruc ro bat mat)
    private static func applySonyK800i(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: -0.02, z: -0.02, w: 0),
            green: CIVector(x: -0.02, y: 1.06, z: -0.02, w: 0),
            blue: CIVector(x: -0.02, y: -0.02, z: 1.08, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.14, saturation: 1.18)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.21),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.80),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.18, radius: 2.2)
    }

    // MARK: - 8. Nokia 8800 (Dien thoai kim loai quy phai, ton mau kim khi sang trong)
    private static func applyLuxury8800(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6750, targetTint: 1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.09, saturation: 0.94)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.24),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.2)
    }
}
