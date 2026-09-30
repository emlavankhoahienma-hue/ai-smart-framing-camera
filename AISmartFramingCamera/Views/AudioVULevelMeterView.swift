import SwiftUI

/// Horizontal Stereo Audio VU Level Meter matching pro-grade camera monitor specs.
/// Renders two sleek parallel level bars with dark tracks,
/// smoothed dynamic response, and standard audio safety zones (green / yellow / red).
public struct AudioVULevelMeterView: View {
    public let levels: (left: Float, right: Float)

    public init(levels: (left: Float, right: Float)) {
        self.levels = levels
    }

    private let barWidth: CGFloat = 48
    private let barHeight: CGFloat = 3.5
    private let spacing: CGFloat = 2.5

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            channelBar(level: CGFloat(levels.left))
            channelBar(level: CGFloat(levels.right))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mức âm thanh: Trái \(Int(levels.left * 100))%, Phải \(Int(levels.right * 100))%")
    }

    @ViewBuilder
    private func channelBar(level: CGFloat) -> some View {
        let clampedLevel = max(0.0, min(1.0, level))
        ZStack(alignment: .leading) {
            // Muted dark track background
            Capsule()
                .fill(Color(white: 0.18))
                .frame(width: barWidth, height: barHeight)

            // Dynamic level bar
            if clampedLevel > 0.01 {
                Capsule()
                    .fill(barGradient(for: clampedLevel))
                    .frame(width: max(barHeight, barWidth * clampedLevel), height: barHeight)
                    .animation(.linear(duration: 0.04), value: clampedLevel)
            }
        }
    }

    private func barGradient(for level: CGFloat) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.18, green: 0.85, blue: 0.35),
                level > 0.75 ? Color(red: 0.95, green: 0.75, blue: 0.15) : Color(red: 0.18, green: 0.85, blue: 0.35),
                level > 0.92 ? Color(red: 0.95, green: 0.25, blue: 0.25) : (level > 0.75 ? Color(red: 0.95, green: 0.75, blue: 0.15) : Color(red: 0.18, green: 0.85, blue: 0.35))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
