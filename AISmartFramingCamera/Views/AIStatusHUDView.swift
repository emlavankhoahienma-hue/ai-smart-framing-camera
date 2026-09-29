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
                    compositionChoices
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

    private var compositionChoices: some View {
        VStack(spacing: 5) {
            Text("Chọn khung để căn máy")
                .font(.system(size: 11, weight: .semibold))
            HStack(alignment: .top, spacing: 6) {
                ForEach(viewModel.localCompositionChoices) { choice in
                    Button {
                        viewModel.chooseLocalComposition(id: choice.id)
                    } label: {
                        VStack(spacing: 4) {
                            Image(decorative: choice.preview, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 82, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(choice.plan.intent.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(2)
                                .frame(height: 26)
                            Text(String(format: "%.1f×", Double(choice.plan.zoom)))
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .frame(width: 88)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.yellow.opacity(choice.id == viewModel.localCompositionChoices.first?.id ? 0.9 : 0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.plan.intent.title + ". " + choice.plan.explanation)
                    .accessibilityHint("Chọn phương án và bắt đầu căn máy")
                }
            }
        }
        .foregroundColor(.white)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
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
