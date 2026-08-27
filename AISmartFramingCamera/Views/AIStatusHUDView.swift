import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    public var body: some View {
        HStack(spacing: 10) {
            // Scene & AI Status Icon
            HStack(spacing: 5) {
                Image(systemName: viewModel.isAIAnalysisActive ? viewModel.detectedScene.iconName : "camera.metering.matrix")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor)
                
                Text(viewModel.isAIAnalysisActive ? viewModel.detectedScene.rawValue : "Manual")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.12))
            .cornerRadius(12)
            
            // Central Instruction Text
            Text(statusMessage)
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Active Composition Rule & Preset Pill
            HStack(spacing: 4) {
                Text(viewModel.selectedFilmPreset.shortTitle)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(.yellow)
                
                Circle()
                    .fill(Color.green)
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
                        .stroke(statusColor.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)
        )
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: viewModel.alignmentState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.detectedScene)
    }
    
    private var statusMessage: String {
        guard viewModel.isAIAnalysisActive else {
            return "Chế độ máy ảnh tiêu chuẩn"
        }
        return viewModel.alignmentState.statusDescription
    }
    
    private var statusColor: Color {
        guard viewModel.isAIAnalysisActive else { return .white }
        return viewModel.alignmentState.statusColor
    }
}
