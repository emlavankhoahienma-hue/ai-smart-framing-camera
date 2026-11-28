import Foundation
import CoreGraphics

// MARK: - Darkroom Navigation Tabs
public enum PhotoDarkroomMainTab: String, CaseIterable, Identifiable, Sendable {
    case looks = "Màu phim"
    case effects = "Hiệu ứng"
    case tools = "Công cụ"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .looks: return "camera.aperture"
        case .effects: return "circle.grid.2x1"
        case .tools: return "slider.horizontal.3"
        }
    }
}

public enum PhotoLooksSubTab: String, CaseIterable, Identifiable, Sendable {
    case films = "PHIM"
    case recipes = "CÔNG THỨC"
    case mine = "CỦA TÔI"
    case favorites = "YÊU THÍCH"

    public var id: String { rawValue }
}

// MARK: - 14 Real Optical & Analog Effects (Matching Reference Video 1:1)
public enum PhotoEffectKind: String, CaseIterable, Identifiable, Sendable {
    case grain
    case vignette
    case halation
    case bloom
    case flare
    case leak
    case burn
    case expired
    case fade
    case dust
    case prism
    case star
    case date
    case frame

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grain: return "GRAIN"
        case .vignette: return "VIGNETTE"
        case .halation: return "HALATION"
        case .bloom: return "BLOOM"
        case .flare: return "FLARE"
        case .leak: return "LEAK"
        case .burn: return "BURN"
        case .expired: return "EXPIRED"
        case .fade: return "FADE"
        case .dust: return "DUST"
        case .prism: return "PRISM"
        case .star: return "STAR"
        case .date: return "DATE"
        case .frame: return "FRAME"
        }
    }

    public var localizedSubtitle: String {
        switch self {
        case .grain: return "Hạt phim"
        case .vignette: return "Tối góc"
        case .halation: return "Quầng đỏ"
        case .bloom: return "Tỏa sáng"
        case .flare: return "Lóa nắng"
        case .leak: return "Lọt sáng"
        case .burn: return "Cháy mép"
        case .expired: return "Hết hạn"
        case .fade: return "Phai mờ"
        case .dust: return "Bụi phim"
        case .prism: return "Lăng kính"
        case .star: return "Sao sáng"
        case .date: return "Ngày giờ"
        case .frame: return "Khung ảnh"
        }
    }

    public var iconName: String {
        switch self {
        case .grain: return "circle.dotted"
        case .vignette: return "viewfinder"
        case .halation: return "flame"
        case .bloom: return "sparkle"
        case .flare: return "camera.aperture"
        case .leak: return "sunrise"
        case .burn: return "sun.max"
        case .expired: return "hourglass"
        case .fade: return "cloud"
        case .dust: return "smallcircle.filled.circle"
        case .prism: return "triangle"
        case .star: return "star"
        case .date: return "calendar"
        case .frame: return "photo.artframe"
        }
    }
}

// MARK: - 12 Real Pro Adjustment Tools (Matching Reference Video 1:1)
public enum PhotoToolKind: String, CaseIterable, Identifiable, Sendable {
    case crop
    case exposure
    case warmth
    case tint
    case contrast
    case highlights
    case shadows
    case saturation
    case vibrance
    case hsl
    case curves
    case detail

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .crop: return "CROP"
        case .exposure: return "PUSH/PULL"
        case .warmth: return "WARMTH"
        case .tint: return "TINT"
        case .contrast: return "CONTRAST"
        case .highlights: return "HIGHLIGHTS"
        case .shadows: return "SHADOWS"
        case .saturation: return "SATURATION"
        case .vibrance: return "VIBRANCE"
        case .hsl: return "HSL"
        case .curves: return "CURVES"
        case .detail: return "DETAIL"
        }
    }

    public var localizedSubtitle: String {
        switch self {
        case .crop: return "Cắt & Xoay"
        case .exposure: return "Phơi sáng EV"
        case .warmth: return "Độ ấm"
        case .tint: return "Sắc độ"
        case .contrast: return "Tương phản"
        case .highlights: return "Vùng sáng"
        case .shadows: return "Vùng tối"
        case .saturation: return "Bão hòa"
        case .vibrance: return "Rực rỡ"
        case .hsl: return "Màu HSL"
        case .curves: return "Đường cong"
        case .detail: return "Độ nét"
        }
    }

    public var iconName: String {
        switch self {
        case .crop: return "crop"
        case .exposure: return "sun.max.fill"
        case .warmth: return "thermometer.medium"
        case .tint: return "eyedropper"
        case .contrast: return "circle.lefthalf.filled"
        case .highlights: return "sun.min"
        case .shadows: return "moon"
        case .saturation: return "drop"
        case .vibrance: return "sparkles"
        case .hsl: return "paintpalette"
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .detail: return "viewfinder.circle"
        }
    }
}

// MARK: - Effect Sub-Styles
public enum PhotoFlareStyle: Int, CaseIterable, Identifiable, Codable, Sendable {
    case topLeftSun = 0
    case topRightSun = 1
    case anamorphicStreak = 2
    case opticalHalo = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .topLeftSun: return "Nắng trái"
        case .topRightSun: return "Nắng phải"
        case .anamorphicStreak: return "Tia ngang"
        case .opticalHalo: return "Quầng tròn"
        }
    }
}

public enum PhotoBurnEdge: Int, CaseIterable, Identifiable, Codable, Sendable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .left: return "Mép trái"
        case .right: return "Mép phải"
        case .top: return "Mép trên"
        case .bottom: return "Mép dưới"
        }
    }
}

public enum PhotoPrismAxis: Int, CaseIterable, Identifiable, Codable, Sendable {
    case horizontal = 0
    case vertical = 1
    case diagonal = 2

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .horizontal: return "Ngang"
        case .vertical: return "Dọc"
        case .diagonal: return "Chéo"
        }
    }
}

public enum PhotoStarPoints: Int, CaseIterable, Identifiable, Codable, Sendable {
    case four = 4
    case six = 6

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .four: return "4 cánh"
        case .six: return "6 cánh"
        }
    }
}

public enum PhotoDateStampMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case classicQuartz
    case retroLED
    case compactSlanted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Tắt"
        case .classicQuartz: return "Quartz"
        case .retroLED: return "LED 90s"
        case .compactSlanted: return "Compact"
        }
    }

    public var isEnabled: Bool { self != .off }
}

public enum PhotoFrameStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case leicaWhite
    case studioBlack
    case filmBorderWhite
    case filmBorderBlack
    case polaroidClassic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Tắt"
        case .leicaWhite: return "Trắng Leica"
        case .studioBlack: return "Đen Studio"
        case .filmBorderWhite: return "Viền Trắng"
        case .filmBorderBlack: return "Viền Đen"
        case .polaroidClassic: return "Polaroid"
        }
    }

    public var isEnabled: Bool { self != .off }

    public var usesMasterWatermark: Bool {
        self == .leicaWhite || self == .studioBlack
    }
}

public enum PhotoFrameLogoOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case alignStudio
    case aperturePro
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alignStudio: return "Align Studio"
        case .aperturePro: return "Khẩu Độ Pro"
        case .none: return "Không Logo"
        }
    }
}

// MARK: - Crop & Geometry State
public enum PhotoCropAspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case original = "Gốc"
    case free = "Tự do"
    case square = "1:1"
    case portrait4x5 = "4:5"
    case portrait3x4 = "3:4"
    case landscape4x3 = "4:3"
    case widescreen16x9 = "16:9"
    case vertical9x16 = "9:16"

    public var id: String { rawValue }

    /// Width / Height ratio (`nil` for `.original` or `.free`).
    public var numericRatio: Double? {
        switch self {
        case .original, .free: return nil
        case .square: return 1.0
        case .portrait4x5: return 4.0 / 5.0
        case .portrait3x4: return 3.0 / 4.0
        case .landscape4x3: return 4.0 / 3.0
        case .widescreen16x9: return 16.0 / 9.0
        case .vertical9x16: return 9.0 / 16.0
        }
    }
}

public struct PhotoCropState: Equatable, Codable, Sendable {
    public var aspectRatio: PhotoCropAspectRatio = .original
    /// Normalized crop rectangle in top-left image space `[0, 1] x [0, 1]`.
    public var cropX: Double = 0.0
    public var cropY: Double = 0.0
    public var cropWidth: Double = 1.0
    public var cropHeight: Double = 1.0
    /// Fine rotation angle in degrees (`-45 ... +45`).
    public var straightenDegrees: Double = 0.0
    /// Clockwise 90-degree increments (`0, 1, 2, 3`).
    public var quarterTurns: Int = 0
    /// Horizontal mirror flip.
    public var flipHorizontal: Bool = false

    public static let identity = PhotoCropState()

    public init(
        aspectRatio: PhotoCropAspectRatio = .original,
        cropX: Double = 0.0,
        cropY: Double = 0.0,
        cropWidth: Double = 1.0,
        cropHeight: Double = 1.0,
        straightenDegrees: Double = 0.0,
        quarterTurns: Int = 0,
        flipHorizontal: Bool = false
    ) {
        self.aspectRatio = aspectRatio
        self.cropX = max(0.0, min(0.9, cropX))
        self.cropY = max(0.0, min(0.9, cropY))
        self.cropWidth = max(0.1, min(1.0 - self.cropX, cropWidth))
        self.cropHeight = max(0.1, min(1.0 - self.cropY, cropHeight))
        self.straightenDegrees = max(-45.0, min(45.0, straightenDegrees))
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
    }

    public var normalizedRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }
        set {
            let x = max(0.0, min(0.9, Double(newValue.origin.x)))
            let y = max(0.0, min(0.9, Double(newValue.origin.y)))
            let w = max(0.1, min(1.0 - x, Double(newValue.size.width)))
            let h = max(0.1, min(1.0 - y, Double(newValue.size.height)))
            cropX = x
            cropY = y
            cropWidth = w
            cropHeight = h
        }
    }

    public var isIdentity: Bool {
        aspectRatio == .original &&
        abs(cropX) < 0.001 &&
        abs(cropY) < 0.001 &&
        abs(cropWidth - 1.0) < 0.001 &&
        abs(cropHeight - 1.0) < 0.001 &&
        abs(straightenDegrees) < 0.05 &&
        (quarterTurns % 4) == 0 &&
        !flipHorizontal
    }

    /// Computes exact centered normalized crop rect for a target `width/height` aspect inside an oriented image of size `(imageWidth, imageHeight)`.
    public static func centeredNormalizedRect(for targetAspect: Double, imageWidth: Double, imageHeight: Double) -> CGRect {
        guard imageWidth > 1, imageHeight > 1, targetAspect > 0.05 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let imgAspect = imageWidth / imageHeight
        if abs(imgAspect - targetAspect) < 0.002 {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if imgAspect > targetAspect {
            let w = max(0.1, min(1.0, targetAspect / imgAspect))
            return CGRect(x: (1.0 - w) * 0.5, y: 0.0, width: w, height: 1.0)
        } else {
            let h = max(0.1, min(1.0, imgAspect / targetAspect))
            return CGRect(x: 0.0, y: (1.0 - h) * 0.5, width: 1.0, height: h)
        }
    }

    /// Minimum uniform zoom factor required so a rotated rectangle of dimensions `(width, height)` rotated by `degrees`
    /// completely covers the original unrotated rectangle with zero black corner triangles.
    public static func inscribedScaleFactor(degrees: Double, width: Double, height: Double) -> Double {
        let rad = abs(degrees) * .pi / 180.0
        guard rad > 1e-6, width > 1, height > 1 else { return 1.0 }
        let c = cos(rad)
        let s = sin(rad)
        let scaleW = (width * c + height * s) / width
        let scaleH = (height * c + width * s) / height
        return max(1.0, max(scaleW, scaleH))
    }
}

// MARK: - 8-Band Selective HSL Adjustment State
public enum PhotoHSLColorChannel: Int, CaseIterable, Identifiable, Codable, Sendable {
    case red = 0
    case orange = 1
    case yellow = 2
    case green = 3
    case aqua = 4
    case blue = 5
    case purple = 6
    case magenta = 7

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .red: return "Đỏ"
        case .orange: return "Cam"
        case .yellow: return "Vàng"
        case .green: return "Lục"
        case .aqua: return "Ngọc"
        case .blue: return "Lam"
        case .purple: return "Tím"
        case .magenta: return "Hồng"
        }
    }

    /// Center hue angle in degrees `[0, 360)`.
    public var centerHueDegrees: Double {
        switch self {
        case .red: return 0.0
        case .orange: return 30.0
        case .yellow: return 60.0
        case .green: return 120.0
        case .aqua: return 180.0
        case .blue: return 225.0
        case .purple: return 275.0
        case .magenta: return 325.0
        }
    }

    /// Half-width of smooth cosine falloff window in degrees.
    public var halfWidthDegrees: Double {
        switch self {
        case .red: return 32.0
        case .orange: return 28.0
        case .yellow: return 36.0
        case .green: return 52.0
        case .aqua: return 46.0
        case .blue: return 46.0
        case .purple: return 44.0
        case .magenta: return 38.0
        }
    }

    public var swatchRGB: (Double, Double, Double) {
        switch self {
        case .red: return (0.94, 0.27, 0.25)
        case .orange: return (0.96, 0.56, 0.20)
        case .yellow: return (0.95, 0.83, 0.24)
        case .green: return (0.28, 0.80, 0.42)
        case .aqua: return (0.20, 0.82, 0.84)
        case .blue: return (0.26, 0.55, 0.96)
        case .purple: return (0.62, 0.36, 0.94)
        case .magenta: return (0.92, 0.32, 0.68)
        }
    }
}

public struct PhotoHSLBandValue: Equatable, Hashable, Codable, Sendable {
    /// Hue shift (`-1.0 ... +1.0`, maps to `±30°`).
    public var hue: Double = 0.0
    /// Saturation delta (`-1.0 ... +1.0`).
    public var saturation: Double = 0.0
    /// Luminance delta (`-1.0 ... +1.0`).
    public var luminance: Double = 0.0

    public static let zero = PhotoHSLBandValue()

    public init(hue: Double = 0.0, saturation: Double = 0.0, luminance: Double = 0.0) {
        self.hue = max(-1.0, min(1.0, hue))
        self.saturation = max(-1.0, min(1.0, saturation))
        self.luminance = max(-1.0, min(1.0, luminance))
    }

    public var isIdentity: Bool {
        abs(hue) < 0.005 && abs(saturation) < 0.005 && abs(luminance) < 0.005
    }
}

public struct PhotoHSLState: Equatable, Hashable, Codable, Sendable {
    public var red: PhotoHSLBandValue = .zero
    public var orange: PhotoHSLBandValue = .zero
    public var yellow: PhotoHSLBandValue = .zero
    public var green: PhotoHSLBandValue = .zero
    public var aqua: PhotoHSLBandValue = .zero
    public var blue: PhotoHSLBandValue = .zero
    public var purple: PhotoHSLBandValue = .zero
    public var magenta: PhotoHSLBandValue = .zero

    public static let identity = PhotoHSLState()

    public init(
        red: PhotoHSLBandValue = .zero,
        orange: PhotoHSLBandValue = .zero,
        yellow: PhotoHSLBandValue = .zero,
        green: PhotoHSLBandValue = .zero,
        aqua: PhotoHSLBandValue = .zero,
        blue: PhotoHSLBandValue = .zero,
        purple: PhotoHSLBandValue = .zero,
        magenta: PhotoHSLBandValue = .zero
    ) {
        self.red = red
        self.orange = orange
        self.yellow = yellow
        self.green = green
        self.aqua = aqua
        self.blue = blue
        self.purple = purple
        self.magenta = magenta
    }

    public subscript(channel: PhotoHSLColorChannel) -> PhotoHSLBandValue {
        get {
            switch channel {
            case .red: return red
            case .orange: return orange
            case .yellow: return yellow
            case .green: return green
            case .aqua: return aqua
            case .blue: return blue
            case .purple: return purple
            case .magenta: return magenta
            }
        }
        set {
            switch channel {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    public var isIdentity: Bool {
        red.isIdentity && orange.isIdentity && yellow.isIdentity && green.isIdentity &&
        aqua.isIdentity && blue.isIdentity && purple.isIdentity && magenta.isIdentity
    }
}

// MARK: - 4-Channel Interactive Tone Curves State (RGB, R, G, B with Monotone Cubic Hermite Spline)
public enum PhotoCurveChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgb = "RGB"
    case red = "Đỏ"
    case green = "Lục"
    case blue = "Lam"

    public var id: String { rawValue }
}

public struct PhotoCurvePoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = max(0.0, min(1.0, x))
        self.y = max(0.0, min(1.0, y))
    }
}

public struct PhotoSingleCurve: Equatable, Hashable, Codable, Sendable {
    /// 5 control points ordered by `x`: black `(0,0)`, shadow `(0.25,0.25)`, midtone `(0.5,0.5)`, highlight `(0.75,0.75)`, white `(1,1)`.
    public var points: [PhotoCurvePoint]

    public static let linear = PhotoSingleCurve(points: [
        PhotoCurvePoint(x: 0.00, y: 0.00),
        PhotoCurvePoint(x: 0.25, y: 0.25),
        PhotoCurvePoint(x: 0.50, y: 0.50),
        PhotoCurvePoint(x: 0.75, y: 0.75),
        PhotoCurvePoint(x: 1.00, y: 1.00)
    ])

    public init(points: [PhotoCurvePoint]) {
        if points.count == 5 {
            self.points = points
        } else {
            self.points = Self.linear.points
        }
    }

    public var isIdentity: Bool {
        guard points.count == 5 else { return true }
        let refs: [Double] = [0.0, 0.25, 0.50, 0.75, 1.0]
        for i in 0..<5 {
            if abs(points[i].x - refs[i]) > 0.004 || abs(points[i].y - refs[i]) > 0.004 {
                return false
            }
        }
        return true
    }

    /// Fritsch–Carlson monotone cubic Hermite interpolation — guarantees smooth, overshoot-free tone curve LUT.
    public func buildLUT(samples: Int = 256) -> [Double] {
        let n = points.count
        guard n >= 2, samples >= 2 else {
            return (0..<max(2, samples)).map { Double($0) / Double(max(1, samples - 1)) }
        }
        var sorted = points.sorted { $0.x < $1.x }
        // Enforce strictly increasing x to prevent division by zero
        for i in 1..<n {
            if sorted[i].x <= sorted[i - 1].x + 0.005 {
                sorted[i].x = min(1.0, sorted[i - 1].x + 0.005)
            }
        }
        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = max(1e-5, sorted[i + 1].x - sorted[i].x)
            delta[i] = (sorted[i + 1].y - sorted[i].y) / h[i]
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            if delta[i - 1] * delta[i] <= 0.0 {
                m[i] = 0.0
            } else {
                let w1 = 2.0 * h[i] + h[i - 1]
                let w2 = h[i] + 2.0 * h[i - 1]
                m[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
            }
        }
        // Fritsch–Carlson slope clamping
        for i in 0..<(n - 1) {
            if abs(delta[i]) < 1e-8 {
                m[i] = 0.0
                m[i + 1] = 0.0
            } else {
                let alpha = m[i] / delta[i]
                let beta = m[i + 1] / delta[i]
                let r2 = alpha * alpha + beta * beta
                if r2 > 9.0 {
                    let tau = 3.0 / sqrt(r2)
                    m[i] = tau * alpha * delta[i]
                    m[i + 1] = tau * beta * delta[i]
                }
            }
        }

        var lut = [Double](repeating: 0, count: samples)
        var seg = 0
        for s in 0..<samples {
            let x = Double(s) / Double(samples - 1)
            if x <= sorted[0].x {
                lut[s] = max(0.0, min(1.0, sorted[0].y))
                continue
            }
            if x >= sorted[n - 1].x {
                lut[s] = max(0.0, min(1.0, sorted[n - 1].y))
                continue
            }
            while seg < n - 2 && x > sorted[seg + 1].x {
                seg += 1
            }
            let t = max(0.0, min(1.0, (x - sorted[seg].x) / h[seg]))
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2.0 * t3 - 3.0 * t2 + 1.0
            let h10 = t3 - 2.0 * t2 + t
            let h01 = -2.0 * t3 + 3.0 * t2
            let h11 = t3 - t2
            let val = h00 * sorted[seg].y + h10 * h[seg] * m[seg] + h01 * sorted[seg + 1].y + h11 * h[seg] * m[seg + 1]
            lut[s] = max(0.0, min(1.0, val))
        }
        return lut
    }
}

public struct PhotoCurvesState: Equatable, Hashable, Codable, Sendable {
    public var rgb: PhotoSingleCurve = .linear
    public var red: PhotoSingleCurve = .linear
    public var green: PhotoSingleCurve = .linear
    public var blue: PhotoSingleCurve = .linear

    public static let identity = PhotoCurvesState()

    public init(
        rgb: PhotoSingleCurve = .linear,
        red: PhotoSingleCurve = .linear,
        green: PhotoSingleCurve = .linear,
        blue: PhotoSingleCurve = .linear
    ) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public subscript(channel: PhotoCurveChannel) -> PhotoSingleCurve {
        get {
            switch channel {
            case .rgb: return rgb
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    public var isIdentity: Bool {
        rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }
}

// MARK: - Complete 14 Effects State
public struct PhotoEffectsState: Equatable, Codable, Sendable {
    public var grain: Double = 0.0              // 0...1
    public var grainSize: Double = 1.25         // 0.6...2.2
    public var vignette: Double = 0.0           // 0...1
    public var vignetteRadius: Double = 1.45    // 0.8...2.2
    public var halation: Double = 0.0           // 0...1
    public var bloom: Double = 0.0              // 0...1
    public var bloomRadius: Double = 12.0       // 4...24
    public var flare: Double = 0.0              // 0...1
    public var flareStyle: PhotoFlareStyle = .topLeftSun
    public var leak: Double = 0.0               // 0...1
    public var leakPattern: Int = 0             // 0...7
    public var burn: Double = 0.0               // 0...1
    public var burnEdge: PhotoBurnEdge = .left
    public var expired: Double = 0.0            // 0...1
    public var fade: Double = 0.0               // 0...1
    public var dust: Double = 0.0               // 0...1
    public var dustSeed: Int = 0                // 0...4
    public var prism: Double = 0.0              // 0...1
    public var prismAxis: PhotoPrismAxis = .horizontal
    public var star: Double = 0.0               // 0...1
    public var starPoints: PhotoStarPoints = .four
    public var dateStamp: PhotoDateStampMode = .off
    public var frameStyle: PhotoFrameStyle = .off
    public var frameLogo: PhotoFrameLogoOption = .alignStudio

    public static let neutral = PhotoEffectsState()

    public init(
        grain: Double = 0.0,
        grainSize: Double = 1.25,
        vignette: Double = 0.0,
        vignetteRadius: Double = 1.45,
        halation: Double = 0.0,
        bloom: Double = 0.0,
        bloomRadius: Double = 12.0,
        flare: Double = 0.0,
        flareStyle: PhotoFlareStyle = .topLeftSun,
        leak: Double = 0.0,
        leakPattern: Int = 0,
        burn: Double = 0.0,
        burnEdge: PhotoBurnEdge = .left,
        expired: Double = 0.0,
        fade: Double = 0.0,
        dust: Double = 0.0,
        dustSeed: Int = 0,
        prism: Double = 0.0,
        prismAxis: PhotoPrismAxis = .horizontal,
        star: Double = 0.0,
        starPoints: PhotoStarPoints = .four,
        dateStamp: PhotoDateStampMode = .off,
        frameStyle: PhotoFrameStyle = .off,
        frameLogo: PhotoFrameLogoOption = .alignStudio
    ) {
        self.grain = grain
        self.grainSize = grainSize
        self.vignette = vignette
        self.vignetteRadius = vignetteRadius
        self.halation = halation
        self.bloom = bloom
        self.bloomRadius = bloomRadius
        self.flare = flare
        self.flareStyle = flareStyle
        self.leak = leak
        self.leakPattern = ((leakPattern % 8) + 8) % 8
        self.burn = burn
        self.burnEdge = burnEdge
        self.expired = expired
        self.fade = fade
        self.dust = dust
        self.dustSeed = ((dustSeed % 5) + 5) % 5
        self.prism = prism
        self.prismAxis = prismAxis
        self.star = star
        self.starPoints = starPoints
        self.dateStamp = dateStamp
        self.frameStyle = frameStyle
        self.frameLogo = frameLogo
    }

    public func isActive(_ kind: PhotoEffectKind) -> Bool {
        switch kind {
        case .grain: return grain >= 0.01
        case .vignette: return vignette >= 0.01
        case .halation: return halation >= 0.01
        case .bloom: return bloom >= 0.01
        case .flare: return flare >= 0.01
        case .leak: return leak >= 0.01
        case .burn: return burn >= 0.01
        case .expired: return expired >= 0.01
        case .fade: return fade >= 0.01
        case .dust: return dust >= 0.01
        case .prism: return prism >= 0.01
        case .star: return star >= 0.01
        case .date: return dateStamp.isEnabled
        case .frame: return frameStyle.isEnabled
        }
    }

    public mutating func reset(_ kind: PhotoEffectKind) {
        switch kind {
        case .grain: grain = 0.0; grainSize = 1.25
        case .vignette: vignette = 0.0; vignetteRadius = 1.45
        case .halation: halation = 0.0
        case .bloom: bloom = 0.0; bloomRadius = 12.0
        case .flare: flare = 0.0
        case .leak: leak = 0.0
        case .burn: burn = 0.0
        case .expired: expired = 0.0
        case .fade: fade = 0.0
        case .dust: dust = 0.0
        case .prism: prism = 0.0
        case .star: star = 0.0
        case .date: dateStamp = .off
        case .frame: frameStyle = .off
        }
    }

    public var isIdentity: Bool {
        !PhotoEffectKind.allCases.contains { isActive($0) }
    }
}

// MARK: - Complete 12 Tools State
public struct PhotoToolsState: Equatable, Codable, Sendable {
    public var crop: PhotoCropState = .identity
    /// Push / Pull Exposure EV (`-2.0 ... +2.0`).
    public var exposureEV: Double = 0.0
    /// Warmth (`-1.0 ... +1.0`).
    public var warmth: Double = 0.0
    /// Tint (`-1.0 ... +1.0`).
    public var tint: Double = 0.0
    /// Contrast (`-1.0 ... +1.0`).
    public var contrast: Double = 0.0
    /// Highlights (`-1.0 ... +1.0`).
    public var highlights: Double = 0.0
    /// Shadows (`-1.0 ... +1.0`).
    public var shadows: Double = 0.0
    /// Saturation (`-1.0 ... +1.0`).
    public var saturation: Double = 0.0
    /// Vibrance (`-1.0 ... +1.0`).
    public var vibrance: Double = 0.0
    /// 8-Band Selective HSL.
    public var hsl: PhotoHSLState = .identity
    /// 4-Channel Interactive Tone Curves.
    public var curves: PhotoCurvesState = .identity
    /// Sharpness (`0.0 ... 1.0`).
    public var sharpness: Double = 0.0
    /// Micro-contrast / Clarity (`0.0 ... 1.0`).
    public var clarity: Double = 0.0

    public static let neutral = PhotoToolsState()

    public init(
        crop: PhotoCropState = .identity,
        exposureEV: Double = 0.0,
        warmth: Double = 0.0,
        tint: Double = 0.0,
        contrast: Double = 0.0,
        highlights: Double = 0.0,
        shadows: Double = 0.0,
        saturation: Double = 0.0,
        vibrance: Double = 0.0,
        hsl: PhotoHSLState = .identity,
        curves: PhotoCurvesState = .identity,
        sharpness: Double = 0.0,
        clarity: Double = 0.0
    ) {
        self.crop = crop
        self.exposureEV = exposureEV
        self.warmth = warmth
        self.tint = tint
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.saturation = saturation
        self.vibrance = vibrance
        self.hsl = hsl
        self.curves = curves
        self.sharpness = sharpness
        self.clarity = clarity
    }

    public func isActive(_ kind: PhotoToolKind) -> Bool {
        switch kind {
        case .crop: return !crop.isIdentity
        case .exposure: return abs(exposureEV) >= 0.02
        case .warmth: return abs(warmth) >= 0.01
        case .tint: return abs(tint) >= 0.01
        case .contrast: return abs(contrast) >= 0.01
        case .highlights: return abs(highlights) >= 0.01
        case .shadows: return abs(shadows) >= 0.01
        case .saturation: return abs(saturation) >= 0.01
        case .vibrance: return abs(vibrance) >= 0.01
        case .hsl: return !hsl.isIdentity
        case .curves: return !curves.isIdentity
        case .detail: return sharpness >= 0.01 || clarity >= 0.01
        }
    }

    public mutating func reset(_ kind: PhotoToolKind) {
        switch kind {
        case .crop: crop = .identity
        case .exposure: exposureEV = 0.0
        case .warmth: warmth = 0.0
        case .tint: tint = 0.0
        case .contrast: contrast = 0.0
        case .highlights: highlights = 0.0
        case .shadows: shadows = 0.0
        case .saturation: saturation = 0.0
        case .vibrance: vibrance = 0.0
        case .hsl: hsl = .identity
        case .curves: curves = .identity
        case .detail: sharpness = 0.0; clarity = 0.0
        }
    }

    public var isIdentity: Bool {
        !PhotoToolKind.allCases.contains { isActive($0) }
    }

    /// Returns a copy with Crop stripped (for saving reusable Recipes across different photos).
    public var withoutCrop: PhotoToolsState {
        var copy = self
        copy.crop = .identity
        return copy
    }
}

// MARK: - Complete Unified Non-Destructive Edit State
public struct PhotoDarkroomEditState: Equatable, Codable, Sendable {
    /// Matches `FilmPreset.rawValue` (e.g. `"Original Clean"`, `"Kodak Gold 200"`).
    public var presetRawValue: String
    /// Film preset blend intensity (`0.0 ... 1.0`).
    public var filmIntensity: Double
    /// Optional active Recipe ID (built-in or user custom).
    public var activeRecipeID: String?
    /// Optional active Recipe display name.
    public var activeRecipeName: String?
    /// Toggle for scene-aware AI color balancing.
    public var isAIEnhanced: Bool
    /// All 14 optical & analog effects.
    public var effects: PhotoEffectsState
    /// All 12 tone, color, geometry, HSL, Curves & detail tools.
    public var tools: PhotoToolsState

    public init(
        presetRawValue: String = "Original Clean",
        filmIntensity: Double = 1.0,
        activeRecipeID: String? = nil,
        activeRecipeName: String? = nil,
        isAIEnhanced: Bool = false,
        effects: PhotoEffectsState = .neutral,
        tools: PhotoToolsState = .neutral
    ) {
        self.presetRawValue = presetRawValue
        self.filmIntensity = max(0.0, min(1.0, filmIntensity))
        self.activeRecipeID = activeRecipeID
        self.activeRecipeName = activeRecipeName
        self.isAIEnhanced = isAIEnhanced
        self.effects = effects
        self.tools = tools
    }

    public func isModifiedComparedTo(initialPresetRaw: String) -> Bool {
        presetRawValue != initialPresetRaw ||
        abs(filmIntensity - 1.0) > 0.015 ||
        isAIEnhanced ||
        !effects.isIdentity ||
        !tools.isIdentity
    }

    public var hasVisualColorOrEffectOrGeometryWork: Bool {
        let hasFilm = presetRawValue != "Original Clean" && presetRawValue != "AI Full Auto Color" && presetRawValue != "Pro Color" && filmIntensity > 0.005
        return hasFilm || isAIEnhanced || !effects.isIdentity || !tools.isIdentity
    }
}

// MARK: - Bounded Undo / Redo History Stack
public struct PhotoDarkroomHistoryStack: Sendable {
    private var undoStack: [PhotoDarkroomEditState] = []
    private var redoStack: [PhotoDarkroomEditState] = []
    public let maxDepth: Int

    public init(maxDepth: Int = 40) {
        self.maxDepth = max(4, maxDepth)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// Records the state *before* applying a committed change.
    public mutating func pushUndoSnapshot(_ previousState: PhotoDarkroomEditState, newState: PhotoDarkroomEditState) {
        guard previousState != newState else { return }
        if undoStack.last == previousState { return }
        undoStack.append(previousState)
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        redoStack.removeAll()
    }

    public mutating func undo(current: PhotoDarkroomEditState) -> PhotoDarkroomEditState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: PhotoDarkroomEditState) -> PhotoDarkroomEditState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Darkroom Recipe (Film + Effects + Tools Bundle)
public struct PhotoDarkroomRecipe: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String
    public let isBuiltIn: Bool
    public var presetRawValue: String
    public var filmIntensity: Double
    public var effects: PhotoEffectsState
    public var tools: PhotoToolsState

    public init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        presetRawValue: String,
        filmIntensity: Double = 1.0,
        effects: PhotoEffectsState = .neutral,
        tools: PhotoToolsState = .neutral
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.presetRawValue = presetRawValue
        self.filmIntensity = max(0.0, min(1.0, filmIntensity))
        self.effects = effects
        self.tools = tools.withoutCrop
    }

    public func apply(preservingCropFrom current: PhotoDarkroomEditState) -> PhotoDarkroomEditState {
        var appliedTools = tools.withoutCrop
        appliedTools.crop = current.tools.crop
        return PhotoDarkroomEditState(
            presetRawValue: presetRawValue,
            filmIntensity: filmIntensity,
            activeRecipeID: id,
            activeRecipeName: name,
            isAIEnhanced: false,
            effects: effects,
            tools: appliedTools
        )
    }

    // 23 Curated Built-in Analog Editorial Recipes (Distinct Film + Effects + Tools Signatures)
    public static let builtInRecipes: [PhotoDarkroomRecipe] = [
        PhotoDarkroomRecipe(
            id: "recipe.sun_deck",
            name: "SUN DECK",
            isBuiltIn: true,
            presetRawValue: "Kodak Gold 200",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.24, bloom: 0.24, fade: 0.10),
            tools: PhotoToolsState(exposureEV: 0.14, warmth: 0.22, highlights: -0.18, shadows: 0.14, vibrance: 0.15)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.coast_road",
            name: "COAST ROAD",
            isBuiltIn: true,
            presetRawValue: "Fuji Pro 400H",
            filmIntensity: 0.95,
            effects: PhotoEffectsState(grain: 0.22, vignette: 0.12, fade: 0.16),
            tools: PhotoToolsState(exposureEV: 0.10, warmth: -0.12, tint: -0.06, highlights: -0.14, shadows: 0.18,
                                   hsl: PhotoHSLState(aqua: PhotoHSLBandValue(hue: -0.10, saturation: 0.18, luminance: 0.08),
                                                      blue: PhotoHSLBandValue(hue: -0.08, saturation: 0.12, luminance: 0.06)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.moody",
            name: "MOODY",
            isBuiltIn: true,
            presetRawValue: "Classic Chrome",
            filmIntensity: 1.0,
            effects: PhotoEffectsState(grain: 0.34, vignette: 0.36, fade: 0.14),
            tools: PhotoToolsState(exposureEV: -0.22, warmth: -0.08, contrast: 0.22, highlights: -0.24, shadows: -0.18, saturation: -0.22, clarity: 0.24)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.moss",
            name: "MOSS",
            isBuiltIn: true,
            presetRawValue: "Classic Neg",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.28, halation: 0.18, fade: 0.18),
            tools: PhotoToolsState(exposureEV: -0.08, warmth: 0.06, tint: -0.16, contrast: 0.12, shadows: 0.10,
                                   hsl: PhotoHSLState(green: PhotoHSLBandValue(hue: -0.18, saturation: -0.16, luminance: -0.18)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.cozy",
            name: "COZY",
            isBuiltIn: true,
            presetRawValue: "CPM35",
            filmIntensity: 0.90,
            effects: PhotoEffectsState(grain: 0.22, vignette: 0.16, bloom: 0.26, fade: 0.12),
            tools: PhotoToolsState(warmth: 0.26, tint: 0.06, contrast: -0.06, shadows: 0.16, vibrance: 0.10)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.lagoon",
            name: "LAGOON",
            isBuiltIn: true,
            presetRawValue: "Astia 100F",
            filmIntensity: 0.90,
            effects: PhotoEffectsState(grain: 0.16, bloom: 0.16),
            tools: PhotoToolsState(warmth: -0.16, tint: -0.08, highlights: -0.12, vibrance: 0.22,
                                   hsl: PhotoHSLState(aqua: PhotoHSLBandValue(hue: -0.12, saturation: 0.26, luminance: 0.08),
                                                      blue: PhotoHSLBandValue(hue: -0.14, saturation: 0.20, luminance: -0.06)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.market_noon",
            name: "MARKET NOON",
            isBuiltIn: true,
            presetRawValue: "Kodak Ektar 100",
            filmIntensity: 0.90,
            effects: PhotoEffectsState(grain: 0.20, flare: 0.22, flareStyle: .topRightSun),
            tools: PhotoToolsState(exposureEV: 0.12, warmth: 0.18, contrast: 0.16, highlights: -0.22, vibrance: 0.20, clarity: 0.22)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.indigo",
            name: "INDIGO",
            isBuiltIn: true,
            presetRawValue: "CineStill 800T",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.30, vignette: 0.24, halation: 0.32),
            tools: PhotoToolsState(exposureEV: -0.12, warmth: -0.28, tint: 0.10, contrast: 0.16, shadows: -0.10,
                                   hsl: PhotoHSLState(blue: PhotoHSLBandValue(hue: 0.14, saturation: 0.22, luminance: -0.12)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.pop",
            name: "POP",
            isBuiltIn: true,
            presetRawValue: "Fuji Velvia 50",
            filmIntensity: 0.88,
            effects: PhotoEffectsState(grain: 0.14),
            tools: PhotoToolsState(contrast: 0.22, highlights: -0.10, saturation: 0.16, vibrance: 0.28, sharpness: 0.32, clarity: 0.26)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.autumn_lane",
            name: "AUTUMN LANE",
            isBuiltIn: true,
            presetRawValue: "Kodak Portra 400",
            filmIntensity: 0.95,
            effects: PhotoEffectsState(grain: 0.24, vignette: 0.18, leak: 0.22, leakPattern: 1, fade: 0.12),
            tools: PhotoToolsState(warmth: 0.28, contrast: 0.08,
                                   hsl: PhotoHSLState(orange: PhotoHSLBandValue(hue: -0.10, saturation: 0.24, luminance: 0.04),
                                                      yellow: PhotoHSLBandValue(hue: -0.28, saturation: 0.18, luminance: -0.06),
                                                      green: PhotoHSLBandValue(hue: -0.35, saturation: -0.22, luminance: -0.12)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.platform_wait",
            name: "PLATFORM WAIT",
            isBuiltIn: true,
            presetRawValue: "GR3 Positive",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.32, vignette: 0.28, fade: 0.10),
            tools: PhotoToolsState(warmth: -0.10, contrast: 0.20, highlights: -0.18, shadows: -0.12, saturation: -0.16, clarity: 0.28)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.rooftop_dusk",
            name: "ROOFTOP DUSK",
            isBuiltIn: true,
            presetRawValue: "Sunset Glow",
            filmIntensity: 0.86,
            effects: PhotoEffectsState(grain: 0.26, halation: 0.36, bloom: 0.28, fade: 0.12),
            tools: PhotoToolsState(warmth: 0.20, tint: 0.18, highlights: -0.20, shadows: 0.12, vibrance: 0.18)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.lake_holiday",
            name: "LAKE HOLIDAY",
            isBuiltIn: true,
            presetRawValue: "Kodak ColorPlus",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.20, bloom: 0.18, fade: 0.14, dateStamp: .classicQuartz),
            tools: PhotoToolsState(exposureEV: 0.16, warmth: 0.16, shadows: 0.20, vibrance: 0.14)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.nostalgic",
            name: "NOSTALGIC",
            isBuiltIn: true,
            presetRawValue: "1998",
            filmIntensity: 0.88,
            effects: PhotoEffectsState(grain: 0.36, vignette: 0.22, expired: 0.38, fade: 0.24, dust: 0.26, dustSeed: 1),
            tools: PhotoToolsState(warmth: 0.14, contrast: -0.08, saturation: -0.12)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.violet_ridge",
            name: "VIOLET RIDGE",
            isBuiltIn: true,
            presetRawValue: "Toy K",
            filmIntensity: 0.85,
            effects: PhotoEffectsState(grain: 0.24, bloom: 0.22, fade: 0.20, prism: 0.22, prismAxis: .diagonal),
            tools: PhotoToolsState(warmth: -0.14, tint: 0.26, shadows: 0.12,
                                   hsl: PhotoHSLState(purple: PhotoHSLBandValue(hue: 0.06, saturation: 0.24, luminance: 0.04)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.fern_trail",
            name: "FERN TRAIL",
            isBuiltIn: true,
            presetRawValue: "FUJI X",
            filmIntensity: 0.92,
            effects: PhotoEffectsState(grain: 0.24, vignette: 0.24, fade: 0.08),
            tools: PhotoToolsState(exposureEV: -0.06, tint: -0.12, contrast: 0.14, highlights: -0.18, clarity: 0.22,
                                   hsl: PhotoHSLState(green: PhotoHSLBandValue(hue: 0.10, saturation: 0.12, luminance: -0.16)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.concrete_steps",
            name: "CONCRETE STEPS",
            isBuiltIn: true,
            presetRawValue: "Neopan Acros",
            filmIntensity: 1.0,
            effects: PhotoEffectsState(grain: 0.42, grainSize: 1.45, vignette: 0.26, fade: 0.08),
            tools: PhotoToolsState(contrast: 0.26, highlights: -0.12, shadows: -0.14, sharpness: 0.35, clarity: 0.36)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.last_tram",
            name: "LAST TRAM",
            isBuiltIn: true,
            presetRawValue: "CineStill 800T",
            filmIntensity: 1.0,
            effects: PhotoEffectsState(grain: 0.36, vignette: 0.30, halation: 0.52, bloom: 0.22, star: 0.34, starPoints: .four),
            tools: PhotoToolsState(exposureEV: -0.10, warmth: -0.20, contrast: 0.22, highlights: -0.14)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.wet_pavement",
            name: "WET PAVEMENT",
            isBuiltIn: true,
            presetRawValue: "GR High-B&W",
            filmIntensity: 0.96,
            effects: PhotoEffectsState(grain: 0.38, vignette: 0.38),
            tools: PhotoToolsState(exposureEV: -0.16, contrast: 0.34, shadows: -0.22, sharpness: 0.40, clarity: 0.42)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.window_seat",
            name: "WINDOW SEAT",
            isBuiltIn: true,
            presetRawValue: "FXN 35",
            filmIntensity: 0.90,
            effects: PhotoEffectsState(grain: 0.22, bloom: 0.30, fade: 0.18),
            tools: PhotoToolsState(exposureEV: 0.08, warmth: 0.12, contrast: -0.06, highlights: -0.20, shadows: 0.22)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.arcade_lights",
            name: "ARCADE LIGHTS",
            isBuiltIn: true,
            presetRawValue: "CCD1",
            filmIntensity: 0.90,
            effects: PhotoEffectsState(grain: 0.24, halation: 0.44, bloom: 0.30, star: 0.42, starPoints: .six),
            tools: PhotoToolsState(contrast: 0.18, saturation: 0.20, vibrance: 0.24)
        ),
        PhotoDarkroomRecipe(
            id: "recipe.cinematic",
            name: "CINEMATIC",
            isBuiltIn: true,
            presetRawValue: "Kodak 500D",
            filmIntensity: 0.95,
            effects: PhotoEffectsState(grain: 0.28, vignette: 0.26, halation: 0.28, fade: 0.10),
            tools: PhotoToolsState(contrast: 0.18, highlights: -0.18, shadows: -0.08,
                                   hsl: PhotoHSLState(orange: PhotoHSLBandValue(hue: -0.06, saturation: 0.16, luminance: 0.04),
                                                      aqua: PhotoHSLBandValue(hue: 0.08, saturation: 0.18, luminance: -0.06),
                                                      blue: PhotoHSLBandValue(hue: -0.14, saturation: 0.14, luminance: -0.10)))
        ),
        PhotoDarkroomRecipe(
            id: "recipe.blush",
            name: "BLUSH",
            isBuiltIn: true,
            presetRawValue: "Kodak Portra 400",
            filmIntensity: 0.88,
            effects: PhotoEffectsState(grain: 0.18, bloom: 0.32, fade: 0.22),
            tools: PhotoToolsState(exposureEV: 0.14, warmth: 0.12, tint: 0.22, contrast: -0.10, shadows: 0.20, saturation: -0.08)
        )
    ]
}

// MARK: - Persistent Store for User Recipes ("MINE") & Favorites ("FAVORITES")
public final class PhotoDarkroomRecipeStore: @unchecked Sendable {
    public static let shared = PhotoDarkroomRecipeStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let customRecipesKey: String
    private let favoriteFilmsKey: String
    private let favoriteRecipesKey: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "alignai.darkroom.v1"
    ) {
        self.defaults = defaults
        self.customRecipesKey = "\(keyPrefix).customRecipes"
        self.favoriteFilmsKey = "\(keyPrefix).favoriteFilms"
        self.favoriteRecipesKey = "\(keyPrefix).favoriteRecipes"
    }

    public func loadCustomRecipes() -> [PhotoDarkroomRecipe] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: customRecipesKey),
              let decoded = try? JSONDecoder().decode([PhotoDarkroomRecipe].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveCustomRecipe(_ recipe: PhotoDarkroomRecipe) -> [PhotoDarkroomRecipe] {
        lock.lock()
        defer { lock.unlock() }
        var current = loadCustomRecipesUnlocked()
        if let idx = current.firstIndex(where: { $0.id == recipe.id }) {
            current[idx] = recipe
        } else {
            current.insert(recipe, at: 0)
        }
        persistCustomRecipesUnlocked(current)
        return current
    }

    public func deleteCustomRecipe(id: String) -> [PhotoDarkroomRecipe] {
        lock.lock()
        defer { lock.unlock() }
        var current = loadCustomRecipesUnlocked()
        current.removeAll { $0.id == id }
        persistCustomRecipesUnlocked(current)
        var favs = loadSetUnlocked(forKey: favoriteRecipesKey)
        favs.remove(id)
        saveSetUnlocked(favs, forKey: favoriteRecipesKey)
        return current
    }

    public func loadFavoriteFilmRawValues() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadSetUnlocked(forKey: favoriteFilmsKey)
    }

    public func toggleFavoriteFilm(_ presetRawValue: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var set = loadSetUnlocked(forKey: favoriteFilmsKey)
        if set.contains(presetRawValue) {
            set.remove(presetRawValue)
        } else {
            set.insert(presetRawValue)
        }
        saveSetUnlocked(set, forKey: favoriteFilmsKey)
        return set
    }

    public func loadFavoriteRecipeIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadSetUnlocked(forKey: favoriteRecipesKey)
    }

    public func toggleFavoriteRecipe(_ recipeID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var set = loadSetUnlocked(forKey: favoriteRecipesKey)
        if set.contains(recipeID) {
            set.remove(recipeID)
        } else {
            set.insert(recipeID)
        }
        saveSetUnlocked(set, forKey: favoriteRecipesKey)
        return set
    }

    private func loadCustomRecipesUnlocked() -> [PhotoDarkroomRecipe] {
        guard let data = defaults.data(forKey: customRecipesKey),
              let decoded = try? JSONDecoder().decode([PhotoDarkroomRecipe].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistCustomRecipesUnlocked(_ recipes: [PhotoDarkroomRecipe]) {
        if let encoded = try? JSONEncoder().encode(recipes) {
            defaults.set(encoded, forKey: customRecipesKey)
        }
    }

    private func loadSetUnlocked(forKey key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func saveSetUnlocked(_ set: Set<String>, forKey key: String) {
        defaults.set(Array(set).sorted(), forKey: key)
    }
}
