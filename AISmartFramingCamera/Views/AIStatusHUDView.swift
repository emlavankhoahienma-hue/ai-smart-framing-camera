import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    public var body: some View {
        if let message = status {
            HStack(spacing: 6) {
                if viewModel.aiSessionState == .analyzing || viewModel.isAIVideoDirectorAnalyzing {
                    ProgressView().controlSize(.mini).tint(CameraUI.accent)
                } else { Image(systemName: viewModel.isPerfectAlignment ? "checkmark.circle" : "viewfinder").foregroundColor(CameraUI.accent) }
                Text(message).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(.black.opacity(0.62), in: Capsule()).foregroundColor(.white)
            .accessibilityElement(children: .combine).allowsHitTesting(false)
        }
    }
    private var status: String? {
        if viewModel.isAEAFLocked { return "Đã khóa sáng & nét · Chạm để mở" }
        if viewModel.isAIVideoDirectorAnalyzing { return "Đang chuẩn bị hướng dẫn quay…" }
        if viewModel.isAIVideoDirectorActive { return "Di chuyển máy theo các điểm đánh dấu" }
        switch viewModel.aiSessionState {
        case .idle: return nil
        case .analyzing: return "Đang tìm bố cục…"
        case .targetPlaced:
            return viewModel.trackingQuality == .lost || viewModel.trackingQuality == .reacquiring
                ? "Đang tìm lại chủ thể…" : "Đưa vòng tròn về tâm khung hình"
        case .alignmentPerfect: return "Đã căn khớp · Giữ máy ổn định"
        case .capturing: return "Đang chụp…"
        case .done: return "Đã chụp ảnh"
        }
    }
}
