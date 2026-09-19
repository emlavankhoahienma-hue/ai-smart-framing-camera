import SwiftUI
import Photos
import UIKit

public struct CapturedPhotoPreviewView: View {
    let item: CapturedPhotoItem
    var viewModel: CameraViewModel? = nil
    @Environment(\.presentationMode) var presentationMode

    @State private var currentProcessedImage: CGImage
    @State private var baseProcessedImage: CGImage
    @State private var isAISharpnessEnabled: Bool = false
    @State private var isSharpeningProcessing: Bool = false
    @State private var splitOffset: CGFloat = 0.5
    @State private var isShowingOriginalOnly: Bool = false
    @State private var isOptimizingWithAI: Bool = false
    @State private var aiOptimizationSuccessNote: String? = nil
    @State private var aiErrorMessage: String? = nil
    @State private var aiLatency: Int = 0
    @State private var hasSavedNewEnhancement: Bool = false
    @State private var selectedPreviewPreset: FilmPreset
    @State private var currentAIParams: AIColorParameters?
    @State private var aiRecommendedPreset: FilmPreset? = nil

    // MARK: - Zoom & Pan Inspection States (Modern iPhone Style)
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanOffset: CGSize = .zero
    @State private var isPinching: Bool = false
    @State private var isPanning: Bool = false

    private var effectiveScale: CGFloat {
        max(0.88, min(7.0, zoomScale * gestureScale))
    }

    private var effectiveOffset: CGSize {
        CGSize(
            width: panOffset.width + gesturePanOffset.width,
            height: panOffset.height + gesturePanOffset.height
        )
    }

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    public init(item: CapturedPhotoItem, viewModel: CameraViewModel? = nil) {
        self.item = item
        self.viewModel = viewModel
        _currentProcessedImage = State(initialValue: item.processedImage)
        _baseProcessedImage = State(initialValue: item.processedImage)
        _selectedPreviewPreset = State(initialValue: item.appliedPreset)
        _currentAIParams = State(initialValue: item.aiColorParameters)
    }

    @State private var showShare = false
    @State private var showDetails = false
    @State private var showTools = false
    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 12) {
                    photoCanvas.frame(maxHeight: .infinity)
                    VStack(spacing: 10) {
                        HStack {
                            Text(isShowingOriginalOnly ? "Ảnh gốc" : selectedPreviewPreset.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(isShowingOriginalOnly ? "Xem bản chỉnh" : "Xem ảnh gốc") { isShowingOriginalOnly.toggle() }
                                .font(.caption).frame(minHeight: 44)
                        }
                        if showTools {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Màu film", selection: Binding(get: { selectedPreviewPreset }, set: { applyPresetToPreview($0) })) {
                                        ForEach(FilmPreset.allCases) { Text($0.displayName).tag($0) }
                                    }
                                    Toggle("Làm nét nhẹ", isOn: Binding(get: { isAISharpnessEnabled }, set: { _ in toggleAISharpness() }))
                                        .disabled(isSharpeningProcessing)
                                    Button(isOptimizingWithAI ? "Đang tối ưu…" : "AI đề xuất màu & lưu bản mới", action: optimizeWithAIStudio)
                                        .disabled(isOptimizingWithAI).frame(minHeight: 44)
                                    if let note = aiOptimizationSuccessNote { Text(note).font(.caption).foregroundColor(.secondary) }
                                    if let error = aiErrorMessage { Text(error).font(.caption).foregroundColor(.orange) }
                                }
                            }.frame(height: min(200, proxy.size.height * 0.3))
                        }
                        HStack(spacing: 12) {
                            Button { showTools.toggle() } label: { Label("Chỉnh màu", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 44) }
                                .buttonStyle(.bordered)
                            Button { saveEnhancedImageToPhotos(currentProcessedImage) } label: {
                                Label("Lưu bản mới", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderedProminent)
                        }.font(.subheadline)
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            .background(CameraUI.canvas).navigationTitle("Ảnh vừa chụp").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Xong") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showDetails = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Thông tin ảnh")
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Chia sẻ ảnh")
                }
            }
            .sheet(isPresented: $showShare) { ActivityShareView(items: [UIImage(cgImage: currentProcessedImage)]) }
            .sheet(isPresented: $showDetails) {
                NavigationStack {
                    Form {
                        LabeledContent("Thời gian", value: item.timestamp.formatted())
                        LabeledContent("Bố cục", value: item.compositionRule.displayNameVietnamese)
                        LabeledContent("Điểm căn khung", value: "\(Int(item.alignmentScore * 100))%")
                        LabeledContent("ISO", value: String(format: "%.0f", item.iso))
                        LabeledContent("Phơi sáng", value: String(format: "%.4f s", item.shutterSpeed))
                        LabeledContent("Live Photo", value: item.isLivePhoto ? "Có" : "Không")
                    }.navigationTitle("Thông tin ảnh").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { showDetails = false } } }
                }
            }
        }.preferredColorScheme(.dark).tint(CameraUI.accent)
    }

    private var photoCanvas: some View {
        GeometryReader { proxy in
            Image(decorative: isShowingOriginalOnly ? item.originalImage : currentProcessedImage, scale: 1)
                .resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(effectiveScale).offset(effectiveOffset)
                .contentShape(Rectangle()).gesture(zoomPanGesture(in: proxy.size))
                .onTapGesture(count: 2) {
                    zoomScale = effectiveScale > 1.05 ? 1 : 2
                    gestureScale = 1; panOffset = .zero; gesturePanOffset = .zero
                }
                .overlay(alignment: .topTrailing) {
                    if effectiveScale > 1.05 {
                        Button("Thu về 1×") { zoomScale = 1; gestureScale = 1; panOffset = .zero; gesturePanOffset = .zero }
                            .font(.caption).padding(12).background(.black.opacity(0.7), in: Capsule()).padding(12)
                    }
                }
                .clipped().accessibilityLabel(isShowingOriginalOnly ? "Ảnh gốc" : "Ảnh đã chỉnh màu")
        }
    }
    private func zoomPanGesture(in size: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { val in
                    isPinching = true
                    gestureScale = val
                }
                .onEnded { val in
                    isPinching = false
                    let targetScale = zoomScale * val
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        if targetScale < 1.05 {
                            zoomScale = 1.0
                            gestureScale = 1.0
                            panOffset = .zero
                            gesturePanOffset = .zero
                        } else {
                            let newScale = min(6.0, max(1.0, targetScale))
                            zoomScale = newScale
                            gestureScale = 1.0
                            let combined = CGSize(
                                width: panOffset.width + gesturePanOffset.width,
                                height: panOffset.height + gesturePanOffset.height
                            )
                            panOffset = clampOffset(combined, scale: newScale, viewportSize: size)
                            gesturePanOffset = .zero
                        }
                    }
                },
            DragGesture(minimumDistance: 4)
                .onChanged { val in
                    if effectiveScale > 1.05 {
                        isPanning = true
                        gesturePanOffset = val.translation
                    }
                }
                .onEnded { val in
                    if effectiveScale > 1.05 {
                        isPanning = false
                        let combined = CGSize(
                            width: panOffset.width + val.translation.width,
                            height: panOffset.height + val.translation.height
                        )
                        let clamped = clampOffset(combined, scale: effectiveScale, viewportSize: size)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            panOffset = clamped
                            gesturePanOffset = .zero
                        }
                    }
                }
        )
    }

    // MARK: - Pan & Bounds Clamping Helper
    private func clampOffset(_ offset: CGSize, scale: CGFloat, viewportSize: CGSize) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let imgW = CGFloat(item.originalImage.width)
        let imgH = CGFloat(max(1, item.originalImage.height))
        let imgAspect = imgW / imgH
        let vpAspect = viewportSize.width / max(1, viewportSize.height)

        let baseW: CGFloat = (vpAspect > imgAspect) ? (viewportSize.height * imgAspect) : viewportSize.width
        let baseH: CGFloat = (vpAspect > imgAspect) ? viewportSize.height : (viewportSize.width / imgAspect)

        let renderedW = baseW * scale
        let renderedH = baseH * scale

        let maxPanX = max(0, (renderedW - viewportSize.width) / 2)
        let maxPanY = max(0, (renderedH - viewportSize.height) / 2)

        let clampedX = min(maxPanX, max(-maxPanX, offset.width))
        let clampedY = min(maxPanY, max(-maxPanY, offset.height))

        return CGSize(width: clampedX, height: clampedY)
    }

    private func toggleAISharpness() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()

        if isAISharpnessEnabled {
            withAnimation(.easeInOut(duration: 0.2)) {
                isAISharpnessEnabled = false
                currentProcessedImage = baseProcessedImage
                aiOptimizationSuccessNote = "Đã tắt làm nét AI"
            }
        } else {
            isSharpeningProcessing = true
            let input = baseProcessedImage
            DispatchQueue.global(qos: .userInitiated).async {
                let sharpened = FilmFilterEngine.shared.applySubtleAISharpness(to: input, intensity: 0.50) ?? input
                DispatchQueue.main.async {
                    self.isSharpeningProcessing = false
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.isAISharpnessEnabled = true
                        self.currentProcessedImage = sharpened
                        self.aiOptimizationSuccessNote = "✨ Đã bật làm nét nhẹ AI (bảo toàn 100% màu sắc)"
                    }
                }
            }
        }
    }

    // MARK: - Preset Switcher Action
    private func applyPresetToPreview(_ preset: FilmPreset) {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()

        selectedPreviewPreset = preset
        let original = item.originalImage
        let params = currentAIParams
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = FilmFilterEngine.shared.applyPresetAndAIParameters(to: original, preset: preset, params: params) ?? original
            let finalImage: CGImage
            if self.isAISharpnessEnabled {
                finalImage = FilmFilterEngine.shared.applySubtleAISharpness(to: rendered, intensity: 0.50) ?? rendered
            } else {
                finalImage = rendered
            }
            DispatchQueue.main.async {
                self.baseProcessedImage = rendered
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.currentProcessedImage = finalImage
                    self.splitOffset = 1.0
                }
            }
        }
    }

    // MARK: - Post-Capture AI Color Optimization (AI Color Director)

    private func optimizeWithAIStudio() {
        guard !isOptimizingWithAI else { return }
        isOptimizingWithAI = true
        aiErrorMessage = nil
        aiOptimizationSuccessNote = nil

        let metrics = GeminiService.extractColorMetrics(from: item.originalImage)

        GeminiService.shared.analyzeAndSelectBestFilmPreset(
            image: item.originalImage,
            sceneContext: item.sceneType,
            colorMetrics: metrics
        ) { result in
            DispatchQueue.main.async {
                self.isOptimizingWithAI = false
                switch result {
                case .success(let data):
                    let chosenPreset = data.preset
                    let recipe = data.recipe
                    let explanation = data.explanation
                    let latency = data.latencyMs
                    let aiParams = recipe.asAIColorParameters

                    self.aiRecommendedPreset = chosenPreset
                    self.selectedPreviewPreset = chosenPreset
                    self.currentAIParams = aiParams

                    if let enhanced = FilmFilterEngine.shared.applyPresetAndAIParameters(to: self.item.originalImage, preset: chosenPreset, params: aiParams) {
                        self.baseProcessedImage = enhanced
                        let finalImage: CGImage
                        if self.isAISharpnessEnabled {
                            finalImage = FilmFilterEngine.shared.applySubtleAISharpness(to: enhanced, intensity: 0.50) ?? enhanced
                        } else {
                            finalImage = enhanced
                        }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.currentProcessedImage = finalImage
                            self.splitOffset = 1.0
                        }
                        self.aiOptimizationSuccessNote = "✨ AI khuyên dùng \(chosenPreset.displayName): \(explanation) (\(latency)ms)"
                        self.saveEnhancedImageToPhotos(finalImage, appliedPreset: chosenPreset, aiParams: aiParams)
                    }
                case .failure(let error):
                    self.aiErrorMessage = "Lỗi: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveEnhancedImageToPhotos(_ cgImage: CGImage, appliedPreset: FilmPreset? = nil, aiParams: AIColorParameters? = nil) {
        let presetToSave = appliedPreset ?? selectedPreviewPreset
        let paramsToSave = aiParams ?? currentAIParams ?? item.aiColorParameters

        if let vm = viewModel {
            // Giữ trọn vẹn Live Photo: ghép đôi với video pairedMovie gốc và nhúng Content Identifier
            let updatedItem = CapturedPhotoItem(
                originalImage: item.originalImage,
                processedImage: cgImage,
                rawPhotoData: item.rawPhotoData,
                livePhotoMovieURL: item.livePhotoMovieURL,
                sceneType: item.sceneType,
                appliedPreset: presetToSave,
                compositionRule: item.compositionRule,
                alignmentScore: item.alignmentScore,
                timestamp: Date(),
                iso: item.iso,
                shutterSpeed: item.shutterSpeed,
                aiColorParameters: paramsToSave
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
