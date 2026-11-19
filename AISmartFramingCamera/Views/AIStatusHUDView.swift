import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    public var body: some View {
        // Chỉ hiện thanh trạng thái duy nhất khi phiên căn bố cục đang hoạt động hoặc vừa chụp xong
        if viewModel.aiSessionState != .idle {
            HStack(spacing: 7) {
                Image(systemName: statusIconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusAccentColor)

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .lineLimit(1)

                if viewModel.aiSessionState.isTargetPlacedOrAligned && viewModel.pendingSuggestedZoom > 1.05 {
                    Text(String(format: "%.1fx", viewModel.pendingSuggestedZoom))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(AlignTheme.studioAccentSoft)
                        )
                }

                if viewModel.activeAIIndicatorType == .cloud {
                    Text("CLOUD")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.5))
                        )
                } else if viewModel.activeAIIndicatorType == .local {
                    Text("LOCAL")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.82))
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(StudioGlassCapsule(tintOpacity: 0.52, borderOpacity: 0.14))
            .shadow(color: Color.black.opacity(0.30), radius: 8, x: 0, y: 2)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeInOut(duration: 0.22), value: viewModel.aiSessionState)
        }
    }

    private var statusIconName: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "viewfinder"
        case .analyzing:
            return "viewfinder"
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return "arrow.triangle.2.circlepath"
            }
            return "scope"
        case .alignmentPerfect:
            return "checkmark.circle.fill"
        case .capturing:
            return "camera.fill"
        case .done:
            return "checkmark"
        }
    }

    private var statusAccentColor: Color {
        switch viewModel.aiSessionState {
        case .idle: return AlignTheme.studioInkPrimary.opacity(0.80)
        case .analyzing: return AlignTheme.studioAccent
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return AlignTheme.studioInkSecondary
            }
            return AlignTheme.studioAccent
        case .alignmentPerfect: return AlignTheme.studioPositive
        case .capturing: return AlignTheme.studioInkPrimary
        case .done: return AlignTheme.studioPositive
        }
    }

    private var statusText: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "Bố cục thông minh"
        case .analyzing:
            return "Đang phân tích bố cục…"
        case .targetPlaced:
            return "Lia máy vào khung"
        case .alignmentPerfect:
            return "Khóa nét & Bố cục hoàn hảo"
        case .capturing:
            return "Đang chụp…"
        case .done:
            return "Đã chụp ảnh"
        }
    }
}
