import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    public var body: some View {
        // Chỉ hiện thanh trạng thái khi phiên căn bố cục đang hoạt động hoặc vừa chụp xong
        if viewModel.aiSessionState != .idle {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: statusIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusAccentColor)

                    // Single clear status text
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)

                    // Huy hiệu nhận biết AI Cloud / Local
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
                            .background(Capsule().fill(Color.red))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )

                if case .analyzing = viewModel.aiSessionState,
                   !viewModel.localCompositionChoices.isEmpty {
                    Button(action: viewModel.showCompositionPreviews) {
                        Label("Xem \(viewModel.localCompositionChoices.count) khung gợi ý", systemImage: "rectangle.stack")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .tint(.yellow)
                }

                if showsExplanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 310)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeInOut(duration: 0.25), value: viewModel.aiSessionState)
        }
    }

    private var showsExplanation: Bool {
        switch viewModel.aiSessionState {
        case .targetPlaced, .alignmentPerfect: return true
        default: return false
        }
    }

    private var explanation: String {
        viewModel.activeAIIndicatorType == .cloud ?
            viewModel.geminiExplanation : viewModel.localCompositionExplanation
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
            return viewModel.localCompositionChoices.isEmpty ? "Đang so sánh bố cục…" : "Chọn phương án bố cục"
        case .targetPlaced:
            if viewModel.trackingQuality == .reacquiring || viewModel.trackingQuality == .lost {
                return "Đang tìm lại chủ thể…"
            }
            return "Đã khóa chủ thể · Di chuyển máy đến vòng tròn"
        case .alignmentPerfect:
            if viewModel.needsManualShutter { return "Đã căn khung · Bấm nút chụp" }
            if viewModel.localCompositionNeedsLevel { return "Giữ máy ngang để cân lại khung" }
            return "Đã khớp · Giữ máy ổn định"
        case .capturing:
            if let customProgress = viewModel.superResolutionProgressText {
                return customProgress
            }
            return "Đang chụp…"
        case .done:
            return "Đã lưu ảnh"
        }
    }
}
