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
                
                // Badges Deck
                HStack(spacing: 5) {
                    // Tracking Quality & Confidence Badge
                    if case .targetPlaced = viewModel.aiSessionState {
                        switch viewModel.trackingQuality {
                        case .locked:
                            if viewModel.lastVisualConfidence > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "scope")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("\(Int(viewModel.lastVisualConfidence * 100))%")
                                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                }
                                .foregroundColor(.green)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Color.green.opacity(0.18))
                                .cornerRadius(6)
                            }
                        case .predicting:
                            HStack(spacing: 2) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8, weight: .bold))
                                Text("DỰ ĐOÁN")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25))
                            .cornerRadius(6)
                        case .reacquiring:
                            HStack(spacing: 2) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 8, weight: .bold))
                                Text("TÌM LẠI")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25))
                            .cornerRadius(6)
                        case .lost:
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text("MẤT DẤU")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.red.opacity(0.25))
                            .cornerRadius(6)
                        }
                    }
                    
                    // Engine Source Badge (Cloud AI vs Local 114MB AI vs YOLOv11 NPU vs Apple ANE)
                    if let engine = viewModel.activeEngineSource, viewModel.aiSessionState != .idle {
                        HStack(spacing: 3) {
                            Image(systemName: engine.iconName)
                                .font(.system(size: 8, weight: .black))
                            Text(engine.badgeName)
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundColor(engine.badgeColor)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(engine.badgeColor.opacity(0.2))
                        .cornerRadius(6)
                    }
                    
                    // Gemini Active Badge with Latency
                    if viewModel.useGeminiForAnalysis && viewModel.activeEngineSource == nil {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9, weight: .heavy))
                            if viewModel.geminiLatencyMs > 0 {
                                Text("\(viewModel.geminiLatencyMs)ms")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                        }
                        .foregroundColor(viewModel.geminiService.hasAPIKey ? .cyan : .gray)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.18))
                        .cornerRadius(6)
                    }
                    
                    // AI Zoom Badge
                    if let zoom = viewModel.aiSuggestedZoom, zoom > 1.05 {
                        HStack(spacing: 2) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 8, weight: .bold))
                            Text(String(format: "%.1fx", zoom))
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.18))
                        .cornerRadius(6)
                    }
                    
                    // True Natural Color Badge
                    if viewModel.isAIFullColorEnabled {
                        HStack(spacing: 2) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 8, weight: .heavy))
                            Text("LEICA")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.green.opacity(0.18))
                        .cornerRadius(6)
                    }
                    
                    Circle()
                        .fill(viewModel.aiSessionState.accentColor)
                        .frame(width: 5, height: 5)
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.68))
                    .overlay(Capsule().stroke(viewModel.aiSessionState.accentColor.opacity(0.45), lineWidth: 1))
            )
            
            // ARKit Tracking Warning Banner
            if let warning = viewModel.arTrackingWarning, case .targetPlaced = viewModel.aiSessionState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.yellow)
                    Text(warning)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().stroke(Color.yellow.opacity(0.6), lineWidth: 1))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Gemini Live Explanation sub-pill
            if !viewModel.geminiExplanation.isEmpty, case .targetPlaced = viewModel.aiSessionState {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    if !viewModel.activeModelUsedName.isEmpty {
                        Text(viewModel.activeModelUsedName)
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.cyan.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    Text(viewModel.geminiExplanation)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: viewModel.aiSessionState)
        .animation(.easeInOut(duration: 0.3), value: viewModel.geminiExplanation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.arTrackingWarning)
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
        if viewModel.isGeminiAnalyzing { return "Gemini AI đang phân tích bối cảnh & màu..." }
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
