import SwiftUI

public struct AIStatusHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    public var body: some View {
        VStack(spacing: 4) {
            // Main HUD pill - Luôn giữ kích thước siêu gọn gàng, không bao giờ phình to
            HStack(spacing: 8) {
                // Session icon + Scene label
                HStack(spacing: 4) {
                    Image(systemName: sessionIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(viewModel.aiSessionState.accentColor)
                    
                    Text(sceneLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.white.opacity(0.12))
                .cornerRadius(10)
                
                // Status message (Tự động cắt ngắn bằng dấu ... nếu quá dài, tuyệt đối không xuống dòng)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Badges Deck (Ngang 1 hàng, chữ ngắn gọn, không bao giờ bẻ dòng)
                HStack(spacing: 4) {
                    // Tracking Quality & Confidence Badge
                    if case .targetPlaced = viewModel.aiSessionState {
                        switch viewModel.trackingQuality {
                        case .locked:
                            if viewModel.lastVisualConfidence > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "scope")
                                        .font(.system(size: 7, weight: .bold))
                                    Text("\(Int(viewModel.lastVisualConfidence * 100))%")
                                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                }
                                .foregroundColor(.green)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .cornerRadius(5)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        case .predicting:
                            HStack(spacing: 2) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 7, weight: .bold))
                                Text("DỰ ĐOÁN")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25))
                            .cornerRadius(5)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        case .reacquiring, .lost:
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 7, weight: .bold))
                                Text("TÌM LẠI")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.red.opacity(0.25))
                            .cornerRadius(5)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    
                    // Street Tracking Mode Badge
                    if viewModel.isStreetTrackingModeEnabled {
                        HStack(spacing: 2) {
                            Image(systemName: "car.fill")
                                .font(.system(size: 7, weight: .bold))
                            Text("ĐI ĐƯỜNG")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.25))
                        .cornerRadius(5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    // Focus Peaking Active Badge
                    if viewModel.isFocusPeakingEnabled {
                        HStack(spacing: 2) {
                            Circle().fill(viewModel.focusPeakingColor.swiftUIColor).frame(width: 4, height: 4)
                            Text("PEAK")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundColor(viewModel.focusPeakingColor.swiftUIColor)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(viewModel.focusPeakingColor.swiftUIColor.opacity(0.2))
                        .cornerRadius(5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    // Engine Source Badge
                    if let engine = viewModel.activeEngineSource, viewModel.aiSessionState != .idle {
                        HStack(spacing: 2) {
                            Image(systemName: engine.iconName)
                                .font(.system(size: 7, weight: .black))
                            Text(engine.badgeName)
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .foregroundColor(engine.badgeColor)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(engine.badgeColor.opacity(0.2))
                        .cornerRadius(5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    // True Natural Color Badge (LEICA)
                    if viewModel.isAIFullColorEnabled {
                        HStack(spacing: 2) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 7, weight: .heavy))
                            Text("LEICA")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.72))
                    .overlay(Capsule().stroke(viewModel.aiSessionState.accentColor.opacity(0.45), lineWidth: 1))
            )
            .frame(maxWidth: 380)
            .minimumScaleFactor(0.80)
            
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
