import Foundation
import CoreImage
import CoreGraphics

/// Bo gia lap chat mau quang hoc cua dong may anh duong pho Ricoh GR danh tieng.
/// Mo phong GR3 Positive Film, GR High-B&W Daido Moriyama, Ricoh GR1, GR Street Snap, Caplio R va Theta Doc.
public enum RicohGRSimulations {

    public static func apply(_ input: CIImage, preset: FilmPreset) -> CIImage? {
        switch preset {
        case .grPositive:
            return applyGRPositive(input)
        case .grHighBW:
            return applyGRHighBW(input)
        case .grFFilm:
            return applyGR1Film(input)
        case .grStreetSnap:
            return applyGRStreetSnap(input)
        case .caplioR:
            return applyCaplioR(input)
        case .thetaDoc:
            return applyThetaDoc(input)
        case .streetClassic:
            return applyStreetClassic(input)
        default:
            return input
        }
    }

    // MARK: - 1. GR3 Positive Film (Duong ban GR3, xanh bien tham dam, tuong phan duong pho sac sao)
    private static func applyGRPositive(_ input: CIImage) -> CIImage {
        // Day manh sac do va xanh duong, tang do trong treo
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.08, y: -0.03, z: -0.03, w: 0),
            green: CIVector(x: -0.04, y: 1.05, z: -0.03, w: 0),
            blue: CIVector(x: -0.05, y: -0.02, z: 1.15, w: 0),
            bias: CIVector(x: -0.01, y: 0.00, z: 0.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.16, saturation: 1.20)
        out = FilmSimulationCore.applyVibrance(out, amount: 0.15)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.02),
            p1: CGPoint(x: 0.25, y: 0.20),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.81),
            p4: CGPoint(x: 1.00, y: 0.98)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.12, grainSize: 1.1)
        return FilmSimulationCore.applyVignette(out, intensity: 0.22, radius: 2.1)
    }

    // MARK: - 2. GR High-B&W (Den trang tuong phan cuc doan phong cach Daido Moriyama, den sau tham)
    private static func applyGRHighBW(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0),
            green: CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0),
            blue: CIVector(x: 0.35, y: 0.55, z: 0.10, w: 0)
        )
        // Tuong phan cuc cao, ep den vung toi
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.35, saturation: 0.0)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.00),
            p1: CGPoint(x: 0.25, y: 0.12),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.88),
            p4: CGPoint(x: 1.00, y: 1.00)
        )
        // Hat tho sac net dac trung anh duong pho Nhat Ban
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.32, grainSize: 1.8)
        return FilmSimulationCore.applyVignette(out, intensity: 0.28, radius: 1.8)
    }

    // MARK: - 3. Ricoh GR1 Film (May anh phim 28mm f/2.8 thap nien 90, sac net, tuong phan tu nhien)
    private static func applyGR1Film(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorMatrix(
            input,
            red: CIVector(x: 1.04, y: -0.01, z: -0.01, w: 0),
            green: CIVector(x: 0.00, y: 1.02, z: -0.01, w: 0),
            blue: CIVector(x: -0.02, y: 0.01, z: 1.02, w: 0)
        )
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.10, saturation: 1.05)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.18, grainSize: 1.4)
        return FilmSimulationCore.applyVignette(out, intensity: 0.24, radius: 2.0)
    }

    // MARK: - 4. GR Street Snap (Bat khoanh khac duong pho, vi tuong phan cao, mau sac can bang)
    private static func applyGRStreetSnap(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyColorControls(input, contrast: 1.12, saturation: 0.98)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.03),
            p1: CGPoint(x: 0.25, y: 0.22),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.14, grainSize: 1.2)
        return FilmSimulationCore.applyVignette(out, intensity: 0.18, radius: 2.2)
    }

    // MARK: - 5. Caplio R (May anh compact ky thuat so dau nhung nam 2000 cua Ricoh)
    private static func applyCaplioR(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6650, targetTint: 1.2)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.06, saturation: 0.96)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.05),
            p1: CGPoint(x: 0.25, y: 0.26),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.76),
            p4: CGPoint(x: 1.00, y: 0.96)
        )
        return FilmSimulationCore.applyOrganicGrain(out, intensity: 0.10, grainSize: 1.1)
    }

    // MARK: - 6. Ricoh Theta Doc (Tai lieu trung thuc, sac do phang, han che sai mau)
    private static func applyThetaDoc(_ input: CIImage) -> CIImage {
        let out = FilmSimulationCore.applyColorControls(input, contrast: 1.02, saturation: 1.00)
        return FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.25),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.75),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
    }

    // MARK: - 7. Street Classic (Duong pho kinh dien chau Au, sac do diem tinh, vuot thoi gian)
    private static func applyStreetClassic(_ input: CIImage) -> CIImage {
        var out = FilmSimulationCore.applyTempTint(input, neutralTemp: 6500, targetTemp: 6420, targetTint: -1.0)
        out = FilmSimulationCore.applyColorControls(out, contrast: 1.09, saturation: 0.92)
        out = FilmSimulationCore.applyToneCurve(
            out,
            p0: CGPoint(x: 0.00, y: 0.04),
            p1: CGPoint(x: 0.25, y: 0.23),
            p2: CGPoint(x: 0.50, y: 0.50),
            p3: CGPoint(x: 0.75, y: 0.78),
            p4: CGPoint(x: 1.00, y: 0.97)
        )
        out = FilmSimulationCore.applyOrganicGrain(out, intensity: 0.16, grainSize: 1.3)
        return FilmSimulationCore.applyVignette(out, intensity: 0.20, radius: 2.1)
    }
}
