import SwiftUI

/// Horizontal Stereo Audio VU Level Meter matching pro-grade camera monitor specs.
/// Renders two sleek parallel level bars with dark tracks,
/// smoothed dynamic response, and standard audio safety zones (green / yellow / red).
public struct AudioVULevelMeterView: View {
    public let levels: (left: Float, right: Float)

    public init(levels: (left: Float, right: Float)) {
        self.levels = levels
    }

    private let barWidth: CGFloat = 42
    private let barHeight: CGFloat = 3.0
    private let spacing: CGFloat = 2.5

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(AlignTheme.studioInkSecondary)

            VStack(alignment: .leading, spacing: spacing) {
                channelBar(level: CGFloat(levels.left))
                channelBar(level: CGFloat(levels.right))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(StudioGlassCapsule(tintOpacity: 0.52, borderOpacity: 0.14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mức âm thanh: Trái \(Int(levels.left * 100))%, Phải \(Int(levels.right * 100))%")
    }

    @ViewBuilder
    private func channelBar(level: CGFloat) -> some View {
        let clampedLevel = max(0.0, min(1.0, level))
        ZStack(alignment: .leading) {
            // Muted dark track background
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: barWidth, height: barHeight)

            // Dynamic level bar (Restrained studio palette: ivory -> warm titanium -> peak crimson)
            if clampedLevel > 0.01 {
                Capsule()
                    .fill(barFillColor(for: clampedLevel))
                    .frame(width: max(barHeight, barWidth * clampedLevel), height: barHeight)
                    .animation(.linear(duration: 0.04), value: clampedLevel)
            }
        }
    }

    private func barFillColor(for level: CGFloat) -> Color {
        if level > 0.90 {
            return AlignTheme.studioRecordRed
        }
        if level > 0.72 {
            return AlignTheme.studioAccent
        }
        return AlignTheme.studioInkPrimary.opacity(0.86)
    }
}
