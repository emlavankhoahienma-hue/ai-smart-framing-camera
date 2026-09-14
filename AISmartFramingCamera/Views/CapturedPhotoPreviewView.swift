import SwiftUI
import Photos
import UIKit

public struct CapturedPhotoPreviewView: View {
    let item: CapturedPhotoItem
    var viewModel: CameraViewModel? = nil
    @Environment(\.presentationMode) var presentationMode

    @State private var currentProcessedImage: CGImage
    @State private var splitOffset: CGFloat = 0.5
    @State private var isShowingOriginalOnly: Bool = false
    @State private var isOptimizingWithAI: Bool = false
    @State private var aiOptimizationSuccessNote: String? = nil
    @State private var aiErrorMessage: String? = nil
    @State private var aiLatency: Int = 0
    @State private var hasSavedNewEnhancement: Bool = false

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    public init(item: CapturedPhotoItem, viewModel: CameraViewModel? = nil) {
        self.item = item
        self.viewModel = viewModel
        _currentProcessedImage = State(initialValue: item.processedImage)
    }

    public var body: some View {
        NavigationView {
            ZStack {
                darkBg.edgesIgnoringSafeArea(.all)

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

                            // Processed Image (Overlaid with Clipping Mask)
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
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 1.5, height: size.height)
                                    .position(x: size.width * splitOffset, y: size.height / 2)
                                    .shadow(color: .black.opacity(0.6), radius: 3)

                                // Drag Handle
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 11, weight: .bold))
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
                                    Color.black.opacity(0.6)
                                    VStack(spacing: 10) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: champagne))
                                            .scaleEffect(1.2)
                                        Text("Đang tối ưu màu…")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                    }
                                    .padding(18)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)

                    // 2. Status Notifications (Subtle)
                    if let note = aiOptimizationSuccessNote {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(champagne)
                            Text(note)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }

                    if let err = aiErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }

                    // 3. Metadata Dashboard (Quiet Pro style)
                    VStack(spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if item.isLivePhoto {
                                        HStack(spacing: 3) {
                                             Image(systemName: "livephoto")
                                                 .font(.system(size: 10, weight: .bold))
                                             Text("LIVE PHOTO")
                                                 .font(.system(size: 9, weight: .heavy, design: .rounded))
                                        }
                                        .foregroundColor(.yellow)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.yellow.opacity(0.18)))
                                    }
                                    Text(item.appliedPreset.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("•").foregroundColor(.white.opacity(0.3))
                                    Text(item.sceneType.rawValue)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                Text("Bố cục: \(item.compositionRule.rawValue) · Điểm: \(Int(item.alignmentScore * 100))%")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }

                            Spacer()

                            // EXIF Capsule
                            HStack(spacing: 8) {
                                Text("ISO \(Int(item.iso))")
                                Text(String(format: "1/%.0fs", 1.0 / max(0.0001, item.shutterSpeed)))
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(6)
                        }
                        .padding(.horizontal, 20)
                    }

                    // 4. Action Buttons: [Chỉnh màu], [Lưu], [Chia sẻ]
                    HStack(spacing: 12) {
                        // Nút Chỉnh màu
                        Button(action: optimizeWithAIStudio) {
                            HStack(spacing: 6) {
                                if isOptimizingWithAI {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isOptimizingWithAI ? "Đang chỉnh…" : "Chỉnh màu")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isOptimizingWithAI)

                        // Nút Lưu
                        Button(action: {
                            saveEnhancedImageToPhotos(currentProcessedImage)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: hasSavedNewEnhancement ? "checkmark" : "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(hasSavedNewEnhancement ? "Đã lưu" : "Lưu")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(champagne)
                            .cornerRadius(10)
                        }

                        // Nút Chia sẻ
                        ShareLink(
                            item: Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up),
                            preview: SharePreview("AlignAI Photo", image: Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up))
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Chia sẻ")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .navigationBarTitle("Chi tiết ảnh", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Đóng") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(champagne)
            )
        }
    }

    // MARK: - Post-Capture AI Color Optimization

    private func optimizeWithAIStudio() {
        guard !isOptimizingWithAI else { return }
        isOptimizingWithAI = true
        aiErrorMessage = nil
        aiOptimizationSuccessNote = nil

        let metrics = GeminiService.extractColorMetrics(from: item.originalImage)

        guard GeminiService.shared.hasAPIKey else {
            // Chưa thiết lập API Key -> Tự động dùng AI Cục bộ cao cấp dựa trên cảm biến ảnh
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.isOptimizingWithAI = false
                let localRecipe = GeminiService.generateLocalColorRecipe(from: metrics, sceneType: self.item.sceneType)
                let localParams = localRecipe.asAIColorParameters
                if let enhanced = FilmFilterEngine.shared.applyAIColorParameters(to: self.item.originalImage, params: localParams) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.currentProcessedImage = enhanced
                        self.splitOffset = 1.0
                    }
                    self.aiOptimizationSuccessNote = "\(localRecipe.diagnosis)"
                    self.saveEnhancedImageToPhotos(enhanced, aiParams: localParams)
                }
            }
            return
        }

        GeminiService.shared.analyzeForComposition(image: item.originalImage, sceneContext: item.sceneType, colorMetrics: metrics) { result in
            DispatchQueue.main.async {
                self.isOptimizingWithAI = false
                switch result {
                case .success(let response):
                    let aiParams = response.colorRecipe.asAIColorParameters
                    if let enhanced = FilmFilterEngine.shared.applyAIColorParameters(to: self.item.originalImage, params: aiParams) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.currentProcessedImage = enhanced
                            self.splitOffset = 1.0
                        }
                        self.aiOptimizationSuccessNote = "\(response.colorRecipe.diagnosis) (\(response.latencyMs)ms)"
                        self.saveEnhancedImageToPhotos(enhanced, aiParams: aiParams)
                    }
                case .failure(let error):
                    // Khi mạng gián đoạn hoặc Gemini bận -> Tự động fallback sang AI Cục bộ ngay lập tức
                    let fallbackRecipe = GeminiService.generateLocalColorRecipe(from: metrics, sceneType: self.item.sceneType)
                    let fallbackParams = fallbackRecipe.asAIColorParameters
                    if let enhanced = FilmFilterEngine.shared.applyAIColorParameters(to: self.item.originalImage, params: fallbackParams) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.currentProcessedImage = enhanced
                            self.splitOffset = 1.0
                        }
                        self.aiOptimizationSuccessNote = "\(fallbackRecipe.diagnosis)"
                        self.saveEnhancedImageToPhotos(enhanced, aiParams: fallbackParams)
                    } else {
                        self.aiErrorMessage = "Lỗi: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func saveEnhancedImageToPhotos(_ cgImage: CGImage, aiParams: AIColorParameters? = nil) {
        if let vm = viewModel {
            // Giữ trọn vẹn Live Photo: ghép đôi với video pairedMovie gốc và nhúng Content Identifier
            let updatedItem = CapturedPhotoItem(
                originalImage: item.originalImage,
                processedImage: cgImage,
                rawPhotoData: item.rawPhotoData,
                livePhotoMovieURL: item.livePhotoMovieURL,
                sceneType: item.sceneType,
                appliedPreset: item.appliedPreset,
                compositionRule: item.compositionRule,
                alignmentScore: item.alignmentScore,
                timestamp: Date(),
                iso: item.iso,
                shutterSpeed: item.shutterSpeed,
                aiColorParameters: aiParams ?? item.aiColorParameters
            )
            vm.savePhotoToLibrary(updatedItem)
            self.hasSavedNewEnhancement = true
        } else {
            // Fallback lưu độc lập: vẫn giữ Live Photo nếu có video movieURL
            if let liveMovieURL = item.livePhotoMovieURL, FileManager.default.fileExists(atPath: liveMovieURL.path) {
                PHPhotoLibrary.shared().performChanges({
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    let photoOptions = PHAssetResourceCreationOptions()
                    let uiImage = UIImage(cgImage: cgImage)
                    if let jpegData = uiImage.jpegData(compressionQuality: 0.95) {
                        creationRequest.addResource(with: .photo, data: jpegData, options: photoOptions)
                    }
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.shouldMoveFile = false
                    creationRequest.addResource(with: .pairedVideo, fileURL: liveMovieURL, options: videoOptions)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            self.hasSavedNewEnhancement = true
                        }
                    }
                }
            } else {
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
    }
}
