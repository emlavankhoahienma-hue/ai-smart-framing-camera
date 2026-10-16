import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc lich su va sang tao dac thu.
/// Mo phong:
/// 1. Cyanotype Print: Ban in lich su don sac xanh Pho (Prussian Blue) tu the ky 19.
/// 2. Ricoh GR Negative Film: Tong mau phim am ban duong pho tuong phan cao bieu tuong cua GR III.
/// 3. Silver Bleach Bypass: Ky thuat giu bac trong trang phim dien anh, tuong phan gat va khu bao hoa mau.
public enum HistoricAndCreativeSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .cyanotype:
            return applyCyanotype(input)
        case .grNegative:
            return applyGRNegative(input)
        case .bleachBypass:
            return applyBleachBypass(input)
        default:
            return input
        }
    }

    // MARK: - 1. Cyanotype Print (Ban in don sac xanh Pho Prussian Blue 1842)
    private static func applyCyanotype(_ input: CIImage) -> CIImage {
        // Chuyen sang don sac do sang cao
        let mono = FilmSimulationCore.applyColorControls(input, contrast: 1.18, saturation: 0.0)

        // Anh xa pho mau xanh Pho: Shadow xanh lam sau tham, Midtone cyan dam, Highlight trang nga xanh nhe
        var out = FilmSimulationCore.applyColorMatrix(
            mono,
            red: CIVector(x: 0.14, y: 0, z: 0, w: 0),
            green: CIVector(x: 0.38, y: 0, z: 0, w: 0),
            blue: CIVector(x: 0.68, y: 0, z: 0, w: 0),
            bias: CIVector(x: 0.04, y: 0.09, z: 0.22, w: 0)
        )

        // Duong cong phoi quang chat giay thu cong: Shadow dam da nhung khong bet, Highlight cuon mem
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.95)
        )

        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.25, radius: 2.2)
    }

    // MARK: - 2. Ricoh GR Negative Film (Chat film am ban duong pho GR III huyen thoai)
    private static func applyGRNegative(_ input: CIImage) -> CIImage {
        // Pho mau am ban: Xanh luc dam nga sẫm, do cam am ap, shadow nga lam toi
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.06, y: -0.02, z: -0.02, w: 0),
            green: CIVector(x: -0.03, y: 0.97, z: 0.02, w: 0),
            blue: CIVector(x: -0.05, y: 0.02, z: 1.08, w: 0),
            bias: CIVector(x: 0.01, y: 0.00, z: 0.02, w: 0)
        )

        // Can bang nhiet do hoi lanh xanh lam nhe, giu da mat am tu nhien
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6380, targetTint: -1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.18, saturation: 0.92)

        // Duong cong tuong phan cao duong pho: Den sau tham, midtone cuon manh
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.01),
            p1: CGPoint(x: 0.25, y: 0.19),
            p2: CGPoint(x: 0.50, y: 0.49),
            p3: CGPoint(x: 0.75, y: 0.81),
            p4: CGPoint(x: 1.00, y: 0.98)
        )

        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.3)
        return FilmSimulationCore.applyVignette(out, intensity: 0.26, radius: 2.0)
    }

    // MARK: - 3. Silver Bleach Bypass (Giu tinh the bac dien anh, tuong phan gat, khu bao hoa)
    private static func applyBleachBypass(_ input: CIImage) -> CIImage {
        // Lay kenh do sang cao
        let monoLuminance = FilmSimulationCore.applyColorControls(input, contrast: 1.32, saturation: 0.0)

        // Giam bao hoa mau xuong 40% (khu 60% sac do)
        let desaturated = FilmSimulationCore.applyColorControls(input, contrast: 1.10, saturation: 0.38)

        // Hoa tron lop do sang cao len lop giam bao hoa bang che do Soft Light de giu anh bac
        guard let blend = CIFilter(name: "CISoftLightBlendMode") else {
            return desaturated
        }
        blend.setValue(monoLuminance, forKey: kCIInputImageKey)
        blend.setValue(desaturated, forKey: kCIInputBackgroundImageKey)
        let blended = blend.outputImage?.cropped(to: input.extent) ?? desaturated

        // Duong cong gat dien anh: Toe chim, Shoulder sang chói
        var out = FilmSimulationCore.applyToneCurve(
            blended,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.18),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.84),
            p4: CGPoint(x: 1.00, y: 0.99)
        )

        // Can bang tong the hoi lanh thep
        out = FilmSimulationCore.applyTempTint(out, neutralTemp: 6500, targetTemp: 6300, targetTint: -0.6)
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.28, grainSize: 1.7)
        return FilmSimulationCore.applyVignette(out, intensity: 0.28, radius: 1.9)
    }
}
