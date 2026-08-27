import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    public var body: some View {
        HStack(spacing: 10) {
            // Scene Icon
            HStack(spacing: 5) {
                Image(systemName: sessionIconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(viewModel.aiSessionState.accentColor)
                
                Text(sceneLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.12))
            .cornerRadius(12)
            
            // Status Text
            Text(viewModel.aiSessionState.displayMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // AI Color Mode badge + Preset
            HStack(spacing: 4) {
                if viewModel.isAIFullColorEnabled {
                    Image(systemName: "wand.and.stars.inverse")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.cyan)
                }
                Text(viewModel.selectedFilmPreset.shortTitle)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(viewModel.isAIFullColorEnabled ? .cyan : .yellow)
                
                Circle()
                    .fill(viewModel.aiSessionState.accentColor)
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.4))
            .cornerRadius(8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .stroke(viewModel.aiSessionState.accentColor.opacity(0.45), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: viewModel.aiSessionState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.detectedScene)
    }
    
    private var sessionIconName: String {
        switch viewModel.aiSessionState {
        case .idle: return "camera.viewfinder"
        case .analyzing: return "cpu"
        case .targetPlaced: return "scope"
        case .alignmentPerfect: return "checkmark.circle.fill"
        case .capturing: return "camera.fill"
        case .done: return "checkmark.seal.fill"
        }
    }
    
    private var sceneLabel: String {
        switch viewModel.aiSessionState {
        case .idle: return "Sẵn sàng"
        case .analyzing: return "Đang phân tích"
        case .targetPlaced: return viewModel.detectedScene.localizedName.components(separatedBy: " (").first ?? viewModel.detectedScene.rawValue
        case .alignmentPerfect: return "Khớp!"
        case .capturing: return "Chụp"
        case .done: return "Xong"
        }
    }
}
