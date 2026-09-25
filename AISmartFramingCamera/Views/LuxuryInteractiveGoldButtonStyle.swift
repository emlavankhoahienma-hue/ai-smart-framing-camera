import SwiftUI
import UIKit

/// ButtonStyle chuyên biệt mang phong cách Dark Luxury Pro Camera:
/// - Khi nhấn giữ: Icon lập tức chuyển sang màu Vàng Hổ Phách Điện Ảnh (Amber Gold),
///   co nhẹ (scale 0.92) tạo cảm giác phản hồi cơ học chân thực, kích hoạt rung haptic.
/// - Khi buông tay: Duy trì ánh vàng lấp lánh trong 0.22s, sau đó chuyển màu mượt mà
///   (fade transition 0.28s) trở lại màu trắng nguyên bản, đàn hồi êm ái về kích thước 1.0.
public struct LuxuryInteractiveGoldButtonStyle: ButtonStyle {
    public let baseColor: Color
    public let activeColor: Color
    public let pressedScale: CGFloat

    public init(
        baseColor: Color = .white,
        activeColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16),
        pressedScale: CGFloat = 0.92
    ) {
        self.baseColor = baseColor
        self.activeColor = activeColor
        self.pressedScale = pressedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        LuxuryInteractiveGoldButtonContainer(
            configuration: configuration,
            baseColor: baseColor,
            activeColor: activeColor,
            pressedScale: pressedScale
        )
    }
}

private struct LuxuryInteractiveGoldButtonContainer: View {
    let configuration: ButtonStyle.Configuration
    let baseColor: Color
    let activeColor: Color
    let pressedScale: CGFloat

    @State private var isAmberActive: Bool = false
    @State private var releaseWorkItem: DispatchWorkItem? = nil

    var body: some View {
        configuration.label
            .foregroundColor(isAmberActive ? activeColor : baseColor)
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.70), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.28), value: isAmberActive)
            .onChangeCompatible(of: configuration.isPressed) { isPressed in
                if isPressed {
                    // Khi chạm ngón tay: Lập tức hủy timer decay trước đó, chuyển sang màu vàng tức thời
                    releaseWorkItem?.cancel()
                    releaseWorkItem = nil

                    let haptic = UISelectionFeedbackGenerator()
                    haptic.prepare()
                    haptic.selectionChanged()

                    isAmberActive = true
                } else {
                    // Khi buông tay: Giữ ánh vàng lấp lánh trong 0.22s rồi chuyển màu mượt mà về trắng
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.28)) {
                            isAmberActive = false
                        }
                    }
                    releaseWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
                }
            }
    }
}

public extension View {
    /// Áp dụng hiệu ứng chạm chuyển màu Vàng Hổ Phách rồi fade mượt về màu Trắng
    func luxuryGoldInteractive(
        baseColor: Color = .white,
        activeColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16),
        pressedScale: CGFloat = 0.92
    ) -> some View {
        self.buttonStyle(LuxuryInteractiveGoldButtonStyle(
            baseColor: baseColor,
            activeColor: activeColor,
            pressedScale: pressedScale
        ))
    }
}
