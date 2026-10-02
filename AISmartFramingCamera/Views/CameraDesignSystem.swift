import SwiftUI
import UIKit

// MARK: - Central Camera Design System (Obsidian Pro Edition)
public enum CameraDesignSystem {
    // MARK: - Colors
    public enum Colors {
        /// Nền chính máy ảnh, màn hình review, các trang sheet modal: #08090C
        public static let background = Color(red: 0x08 / 255.0, green: 0x09 / 255.0, blue: 0x0C / 255.0)

        /// Nền các khối card, thanh dock điều khiển, toolbar: #12141A
        public static let surface = Color(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x1A / 255.0)

        /// Nền nút nổi, menu popover, control nhấc cao: #1A1D25
        public static let surfaceElevated = Color(red: 0x1A / 255.0, green: 0x1D / 255.0, blue: 0x25 / 255.0)

        /// Đường viền phân cách siêu mảnh 1px vật lý: #262933
        public static let hairline = Color(red: 0x26 / 255.0, green: 0x29 / 255.0, blue: 0x33 / 255.0)

        /// Màu chữ chính: tiêu đề, giá trị kỹ thuật quan trọng: #F5F5F3
        public static let textPrimary = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF3 / 255.0)

        /// Màu chữ phụ: nhãn chú thích, mô tả, chỉ số thứ cấp: #A5A8B1
        public static let textSecondary = Color(red: 0xA5 / 255.0, green: 0xA8 / 255.0, blue: 0xB1 / 255.0)

        /// Màu vàng ánh hổ phách / warm gold biểu trưng cho chế độ đang chọn, điểm nét và chỉnh tay: #D6A246
        public static let accent = Color(red: 0xD6 / 255.0, green: 0xA2 / 255.0, blue: 0x46 / 255.0)

        /// Màu accent khi ở trạng thái nhấn giữ: #BC8932
        public static let accentPressed = Color(red: 0xBC / 255.0, green: 0x89 / 255.0, blue: 0x32 / 255.0)

        /// Màu đỏ tiêu chuẩn quay video: #E04442
        public static let record = Color(red: 0xE0 / 255.0, green: 0x44 / 255.0, blue: 0x42 / 255.0)

        /// Màu xanh lá mức âm thanh an toàn: #56BD69
        public static let meterGood = Color(red: 0x56 / 255.0, green: 0xBD / 255.0, blue: 0x69 / 255.0)

        /// Màu vàng cam cảnh báo mức âm thanh sát clipping: #E2B44C
        public static let meterPeak = Color(red: 0xE2 / 255.0, green: 0xB4 / 255.0, blue: 0x4C / 255.0)
    }

    // MARK: - Dimensions & Spacings
    public enum Dimensions {
        public static let previewCornerRadius: CGFloat = 18.0
        public static let cardCornerRadius: CGFloat = 20.0
        public static let controlCornerRadius: CGFloat = 14.0
        public static let pillCornerRadius: CGFloat = 999.0

        public static let minTouchTarget: CGFloat = 44.0
        public static let shutterButtonDiameter: CGFloat = 78.0

        public static let space4: CGFloat = 4.0
        public static let space8: CGFloat = 8.0
        public static let space12: CGFloat = 12.0
        public static let space16: CGFloat = 16.0
        public static let space20: CGFloat = 20.0
        public static let space24: CGFloat = 24.0

        public static var physicalPixelHairline: CGFloat {
            1.0 / max(1.0, UIScreen.main.scale)
        }
    }

    // MARK: - Typography
    public enum Typography {
        public static let sheetTitle = Font.system(size: 32, weight: .bold)
        public static let sectionTitle = Font.system(size: 18, weight: .semibold)
        public static let body = Font.system(size: 16, weight: .regular)
        public static let bodyMedium = Font.system(size: 16, weight: .medium)
        public static let metadata = Font.system(size: 13, weight: .medium)
        public static let caption = Font.system(size: 11, weight: .medium)
        public static let proDialValue = Font.system(size: 22, weight: .bold, design: .monospaced)
    }

    // MARK: - Animations
    public enum Animations {
        public static let modeSwitch = Animation.snappy(duration: 0.22, extraBounce: 0)
        public static let panel = Animation.smooth(duration: 0.28)
        public static let reticle = Animation.easeInOut(duration: 0.20)
    }
}

// MARK: - Reusable Design System View Modifiers
public struct CameraCardBackgroundModifier: ViewModifier {
    var cornerRadius: CGFloat = CameraDesignSystem.Dimensions.cardCornerRadius
    var elevated: Bool = false

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(elevated ? CameraDesignSystem.Colors.surfaceElevated : CameraDesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(CameraDesignSystem.Colors.hairline, lineWidth: CameraDesignSystem.Dimensions.physicalPixelHairline)
            )
    }
}

public struct CameraPillBackgroundModifier: ViewModifier {
    var isSelected: Bool

    public func body(content: Content) -> some View {
        content
            .background(
                Capsule()
                    .fill(isSelected ? CameraDesignSystem.Colors.surfaceElevated : CameraDesignSystem.Colors.surface.opacity(0.85))
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.hairline,
                        lineWidth: CameraDesignSystem.Dimensions.physicalPixelHairline
                    )
            )
    }
}

public extension View {
    func cameraCardStyle(cornerRadius: CGFloat = CameraDesignSystem.Dimensions.cardCornerRadius, elevated: Bool = false) -> some View {
        modifier(CameraCardBackgroundModifier(cornerRadius: cornerRadius, elevated: elevated))
    }

    func cameraPillStyle(isSelected: Bool = false) -> some View {
        modifier(CameraPillBackgroundModifier(isSelected: isSelected))
    }

    func cameraHairlineBorder(cornerRadius: CGFloat = CameraDesignSystem.Dimensions.controlCornerRadius) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(CameraDesignSystem.Colors.hairline, lineWidth: CameraDesignSystem.Dimensions.physicalPixelHairline)
        )
    }
}
