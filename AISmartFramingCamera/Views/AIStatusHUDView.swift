import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    public var body: some View {
        // Chỉ hiện thanh trạng thái duy nhất khi phiên căn bố cục đang hoạt động hoặc vừa chụp xong
        if viewModel.aiSessionState != .idle {
            HStack(spacing: 7) {
                // Biểu tượng trạng thái
                Image(systemName: statusIconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(statusAccentColor)

                // Câu hướng dẫn tinh gọn duy nhất
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)

                // Chỉ báo Zoom đề xuất tích hợp nhỏ gọn tinh tế ngay trong cùng 1 thanh
                if viewModel.aiSessionState.isTargetPlacedOrAligned && viewModel.pendingSuggestedZoom > 1.05 {
                    Text(String(format: "%.1fx", viewModel.pendingSuggestedZoom))
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.cyan.opacity(0.20)))
                }

                // Huy hiệu Cloud / Local tinh gọn
                if viewModel.activeAIIndicatorType == .cloud {
                    Text("CLOUD")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.yellow))
                } else if viewModel.activeAIIndicatorType == .local {
                    Text("LOCAL")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeInOut(duration: 0.22), value: viewModel.aiSessionState)
        }
    }

    private var statusIconName: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "viewfinder"
        case .analyzing:
            return "sparkle"
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
        case .idle: return .white.opacity(0.8)
        case .analyzing: return .yellow
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return .orange
            }
            return .yellow
        case .alignmentPerfect: return .green
        case .capturing: return .white
        case .done: return .green
        }
    }

    private var statusText: String {
        switch viewModel.aiSessionState {
        case .idle:
            return "Bố cục thông minh"
        case .analyzing:
            if viewModel.localCompositionChoices.isEmpty, viewModel.localSelectionMessage != nil {
                return "Chưa có khung để chọn"
            }
            if viewModel.activeAIIndicatorType == .cloud {
                let model = viewModel.activeModelUsedName.isEmpty ? "Cloud" : viewModel.activeModelUsedName
                return "Đang gửi Cloud AI (\(model))..."
            }
            return viewModel.localCompositionChoices.isEmpty ? viewModel.localAnalysisProgress : "Chọn phương án bố cục"
        case .targetPlaced, .alignmentPerfect:
            return viewModel.alignmentStatusText
        case .capturing:
            return viewModel.captureStatusText
        case .done:
            return "Đã chụp ảnh"
        }
    }
}
