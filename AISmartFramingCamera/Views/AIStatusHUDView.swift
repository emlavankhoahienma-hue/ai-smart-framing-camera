import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    public var body: some View {
        VStack(spacing: 6) {
            // Main HUD pill
            HStack(spacing: 10) {
                // Session icon
                HStack(spacing: 5) {
                    Image(systemName: sessionIconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(viewModel.aiSessionState.accentColor)
                    
                    Text(sceneLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(12)
                
                // Status message
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Badges
                HStack(spacing: 4) {
                    // Gemini badge
                    if viewModel.useGeminiForAnalysis {
                        Image(systemName: viewModel.geminiService.hasAPIKey ? "sparkle" : "sparkle.slash")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(viewModel.geminiService.hasAPIKey ? .cyan : .gray)
                    }
                    
                    // AI Color badge
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
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.65))
                    .overlay(Capsule().stroke(viewModel.aiSessionState.accentColor.opacity(0.45), lineWidth: 1))
            )
            
            // Gemini explanation sub-pill (shows briefly after analysis)
            if !viewModel.geminiExplanation.isEmpty, case .targetPlaced = viewModel.aiSessionState {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    if !viewModel.activeModelUsedName.isEmpty {
                        Text(viewModel.activeModelUsedName.components(separatedBy: "-").prefix(2).joined(separator: " ").capitalized)
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    Text(viewModel.geminiExplanation)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: viewModel.aiSessionState)
        .animation(.easeInOut(duration: 0.3), value: viewModel.geminiExplanation)
    }
    
    private var sessionIconName: String {
        switch viewModel.aiSessionState {
        case .idle: return "camera.viewfinder"
        case .analyzing: return viewModel.isGeminiAnalyzing ? "sparkle" : "cpu"
        case .targetPlaced: return "scope"
        case .alignmentPerfect: return "checkmark.circle.fill"
        case .capturing: return "camera.fill"
        case .done: return "checkmark.seal.fill"
        }
    }
    
    private var statusText: String {
        if viewModel.isGeminiAnalyzing { return "Gemini AI đang phân tích cảnh vật..." }
        if let err = viewModel.geminiError { return "Lỗi Gemini: \(err.prefix(50))" }
        return viewModel.aiSessionState.displayMessage
    }
    
    private var sceneLabel: String {
        switch viewModel.aiSessionState {
        case .idle: return "Sẵn sàng"
        case .analyzing: return viewModel.isGeminiAnalyzing ? "Gemini" : "Phân tích"
        case .targetPlaced: return viewModel.detectedScene.localizedName.components(separatedBy: " (").first ?? "Scene"
        case .alignmentPerfect: return "Khớp!"
        case .capturing: return "Chụp"
        case .done: return "Xong"
        }
    }
}
