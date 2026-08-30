import SwiftUI
import Photos
import UIKit

public struct CapturedPhotoPreviewView: View {
    let item: CapturedPhotoItem
    @Environment(\.presentationMode) var presentationMode
    
    @State private var currentProcessedImage: CGImage
    @State private var splitOffset: CGFloat = 0.5
    @State private var isShowingOriginalOnly: Bool = false
    @State private var isOptimizingWithAI: Bool = false
    @State private var aiOptimizationSuccessNote: String? = nil
    @State private var aiErrorMessage: String? = nil
    @State private var aiLatency: Int = 0
    @State private var hasSavedNewEnhancement: Bool = false
    
    public init(item: CapturedPhotoItem) {
        self.item = item
        _currentProcessedImage = State(initialValue: item.processedImage)
    }
    
    public var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 14) {
                    // 1. Photo Viewport with Interactive Comparison
                    GeometryReader { proxy in
                        let size = proxy.size
                        ZStack {
                            // Original Image (Base)
                            Image(decorative: item.originalImage, scale: 1.0, orientation: .up)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size.width, height: size.height)
                            
                            // Processed AI Film Image (Overlaid with Clipping Mask)
                            Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: size.width, height: size.height)
                                .mask(
                                    Rectangle()
                                        .size(
                                            width: isShowingOriginalOnly ? 0 : size.width * splitOffset,
                                            height: size.height
                                        )
                                )
                            
                            // Split Divider Line
                            if !isShowingOriginalOnly {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 2, height: size.height)
                                    .position(x: size.width * splitOffset, y: size.height / 2)
                                    .shadow(color: .black.opacity(0.6), radius: 4)
                                
                                // Drag Handle
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.black)
                                    )
                                    .position(x: size.width * splitOffset, y: size.height / 2)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let newSplit = value.location.x / size.width
                                                splitOffset = max(0.05, min(0.95, newSplit))
                                            }
                                    )
                            }
                            
                            // AI Processing Loading Overlay
                            if isOptimizingWithAI {
                                ZStack {
                                    Color.black.opacity(0.7)
                                    VStack(spacing: 12) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                                            .scaleEffect(1.4)
                                        Text("AI đang đọc phổ màu & tối ưu quang học...")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.cyan)
                                    }
                                    .padding(20)
                                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.85)))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    
                    // 2. AI Optimization Status Toast
                    if let note = aiOptimizationSuccessNote {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.green)
                            Text(note)
                                .font(.caption.bold())
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                    
                    if let err = aiErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption.bold())
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                    }
                    
                    // 3. Post-Capture AI Studio Button
                    Button(action: optimizeWithAIStudio) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 15, weight: .bold))
                            Text(isOptimizingWithAI ? "AI đang tinh chỉnh..." : "✨ Tối ưu màu bằng AI Studio (Gemini + Metal GPU)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.cyan, Color.yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                        .shadow(color: Color.cyan.opacity(0.3), radius: 6)
                    }
                    .disabled(isOptimizingWithAI)
                    .padding(.horizontal, 16)
                    
                    // 4. AI & Exif Metadata Dashboard
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    if item.isLivePhoto {
                                        HStack(spacing: 3) {
                                            Image(systemName: "livephoto")
                                            Text("LIVE")
                                        }
                                        .font(.caption2.bold())
                                        .foregroundColor(.yellow)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.yellow.opacity(0.2)))
                                    }
                                    Text(item.appliedPreset.rawValue)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text("•").foregroundColor(.gray)
                                    Text(item.sceneType.rawValue)
                                        .font(.subheadline)
                                        .foregroundColor(.yellow)
                                }
                                Text("Bố cục: \(item.compositionRule.rawValue) (Điểm khớp: \(Int(item.alignmentScore * 100))%)")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            
                            Spacer()
                            
                            // EXIF Capsule
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("ISO \(Int(item.iso))")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                                Text(String(format: "1/%.0fs", 1.0 / max(0.0001, item.shutterSpeed)))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .padding(.horizontal, 20)
                        
                        Text("Kéo thanh trượt ngang để so sánh ảnh gốc và công thức màu AI")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    
                    // 5. Action Buttons (Lưu vào máy / Xem ảnh gốc / Chia sẻ)
                    HStack(spacing: 10) {
                        // Nút Lưu trực tiếp ảnh đã chỉnh vào Thư viện
                        Button(action: {
                            saveEnhancedImageToPhotos(currentProcessedImage)
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: hasSavedNewEnhancement ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text(hasSavedNewEnhancement ? "Đã lưu!" : "Lưu vào máy")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(hasSavedNewEnhancement ? Color.green : Color.yellow)
                            .cornerRadius(12)
                        }
                        
                        Button(action: {
                            isShowingOriginalOnly.toggle()
                        }) {
                            Label(isShowingOriginalOnly ? "Màu AI" : "Ảnh gốc", systemImage: "eye.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(12)
                        }
                        
                        ShareLink(
                            item: Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up),
                            preview: SharePreview("AlignAI Studio Photo", image: Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up))
                        ) {
                            Label("Chia sẻ", systemImage: "square.and.arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.25))
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .navigationBarTitle("Chi tiết ảnh AI Studio", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Đóng") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.yellow)
            )
        }
    }
    
    // MARK: - Post-Capture AI Color Studio Optimization
    
    private func optimizeWithAIStudio() {
        guard !isOptimizingWithAI else { return }
        isOptimizingWithAI = true
        aiErrorMessage = nil
        aiOptimizationSuccessNote = nil
        
        GeminiService.shared.analyzeForComposition(image: item.originalImage) { result in
            DispatchQueue.main.async {
                self.isOptimizingWithAI = false
                switch result {
                case .success(let response):
                    let aiParams = response.colorRecipe.asAIColorParameters
                    if let enhanced = FilmFilterEngine.shared.applyAIColorParameters(to: self.item.originalImage, params: aiParams) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.currentProcessedImage = enhanced
                            self.splitOffset = 1.0 // Show fully enhanced image
                        }
                        self.aiOptimizationSuccessNote = "✅ Đã tối ưu màu Leica Natural bằng Gemini (\(response.latencyMs)ms)!"
                        self.saveEnhancedImageToPhotos(enhanced)
                    }
                case .failure(let error):
                    self.aiErrorMessage = "Lỗi AI: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveEnhancedImageToPhotos(_ cgImage: CGImage) {
        let uiImage = UIImage(cgImage: cgImage)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.hasSavedNewEnhancement = true
                }
            }
        }
    }
}
