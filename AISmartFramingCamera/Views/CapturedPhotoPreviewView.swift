import SwiftUI
import Photos
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
import Combine

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
    @State private var renderGeneration = 0
    @State private var hasSavedNewEnhancement: Bool = false
    @State private var selectedPreviewPreset: FilmPreset
    @State private var currentAIParams: AIColorParameters?
    @State private var aiRecommendedPreset: FilmPreset? = nil


    private var shareButtonLabel: some View {
        Label("Chia sẻ", systemImage: "square.and.arrow.up")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.12))
            .cornerRadius(10)
    }

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

    public var body: some View {
        NavigationStack {
            ZStack {
                darkBg.edgesIgnoringSafeArea(.all)

                VStack(spacing: 14) {
                    // 1. Photo Viewport with Interactive Smooth Zoom & Comparison
                    GeometryReader { proxy in
                        let size = proxy.size
                        ZStack(alignment: .topLeading) {
                            // 1.1 Zoomable & Pannable Base Layers
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
                            }
                            .scaleEffect(effectiveScale)
                            .offset(effectiveOffset)
                            .contentShape(Rectangle())
                            .gesture(zoomPanGesture(in: size))
                            .simultaneousGesture(
                                SpatialTapGesture(count: 2)
                                    .onEnded { event in
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            if effectiveScale > 1.15 {
                                                // Đang zoom: thu về 1.0x ở chính giữa
                                                zoomScale = 1.0
                                                gestureScale = 1.0
                                                panOffset = .zero
                                                gesturePanOffset = .zero
                                            } else {
                                                // Zoom 2.8x hướng thẳng vào toạ độ vừa chạm (góc, cạnh, chủ thể)
                                                let targetScale: CGFloat = 2.8
                                                let dx = event.location.x - size.width / 2.0
                                                let dy = event.location.y - size.height / 2.0
                                                let targetOffset = CGSize(
                                                    width: -dx * (targetScale - 1.0),
                                                    height: -dy * (targetScale - 1.0)
                                                )
                                                zoomScale = targetScale
                                                gestureScale = 1.0
                                                panOffset = clampOffset(targetOffset, scale: targetScale, viewportSize: size)
                                                gesturePanOffset = .zero
                                            }
                                        }
                                    }
                            )

                            // 1.2 Split Comparison Divider & Handle (Chỉ hiện khi ở mức 1.0x để không cản trở lúc zoom)
                            if !isShowingOriginalOnly && effectiveScale <= 1.05 {
                                splitComparisonControls(size: size)
                            }

                            // 1.3 Mini-Map hiển thị vùng đang zoom theo phong cách iPhone đời mới
                            zoomRegionMiniMap(viewportSize: size)
                                .padding(10)

                            // 1.4 Nút Chuyển nhanh Ảnh Gốc / Đã chỉnh khi đang zoom chi tiết
                            if effectiveScale > 1.05 {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Button(action: {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                isShowingOriginalOnly.toggle()
                                            }
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: isShowingOriginalOnly ? "photo.fill" : "wand.and.stars")
                                                    .font(.system(size: 10, weight: .semibold))
                                                Text(isShowingOriginalOnly ? "Ảnh gốc" : "Đã chỉnh")
                                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                            }
                                            .foregroundColor(isShowingOriginalOnly ? .yellow : champagne)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(Color.black.opacity(0.74)))
                                            .overlay(Capsule().stroke(champagne.opacity(0.4), lineWidth: 1))
                                            .shadow(color: Color.black.opacity(0.5), radius: 4)
                                        }
                                        .padding(10)
                                    }
                                }
                            }

                            // 1.5 AI Processing Loading Overlay
                            if isOptimizingWithAI {
                                aiLoadingOverlay
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                                    Text(selectedPreviewPreset.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("•").foregroundColor(.white.opacity(0.3))
                                    Text(item.sceneType.rawValue)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                Text(item.saveFormat == .dng ? "DNG gốc · Ảnh hiển thị là bản xem trước" : item.resolutionDescription)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.7))
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

                    // 4. Horizontal Film Preset Selector (Thử trực quan 18 bộ màu điện ảnh)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilmPreset.selectablePresets) { preset in
                                let isCurrent = selectedPreviewPreset == preset
                                let isAIChosen = aiRecommendedPreset == preset

                                Button(action: {
                                    applyPresetToPreview(preset)
                                }) {
                                    HStack(spacing: 5) {
                                        if isAIChosen {
                                            Image(systemName: "wand.and.stars")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(isCurrent ? .black : champagne)
                                        } else if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        Text(preset.displayName)
                                            .font(.system(size: 12, weight: isCurrent ? .bold : .medium, design: .rounded))
                                    }
                                    .foregroundColor(isCurrent ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule()
                                            .fill(isCurrent ? champagne : (isAIChosen ? Color.yellow.opacity(0.18) : Color.white.opacity(0.08)))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(isAIChosen ? champagne : (isCurrent ? champagne : Color.white.opacity(0.12)), lineWidth: isAIChosen ? 1.5 : 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // 5. Tool & Action Buttons
                    VStack(spacing: 10) {
                        // 5.1 AI Enhancement Row: [AI Chỉnh màu] & [Làm nét]
                        HStack(spacing: 10) {
                            // Nút AI Chỉnh màu
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
                                    Text(isOptimizingWithAI ? "Đang chọn màu…" : "AI Chỉnh màu")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(10)
                            }
                            .disabled(isOptimizingWithAI)

                            // Nút Làm nét AI (Bật / Tắt - Bảo toàn 100% màu & chất ảnh)
                            Button(action: toggleAISharpness) {
                                HStack(spacing: 6) {
                                    if isSharpeningProcessing {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: isAISharpnessEnabled ? .black : .white))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: isAISharpnessEnabled ? "sparkle.magnifyingglass" : "sparkles")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    Text(isAISharpnessEnabled ? "Đang làm nét" : "Làm nét")
                                        .font(.system(size: 13, weight: .semibold))
                                    if isAISharpnessEnabled && !isSharpeningProcessing {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                }
                                .foregroundColor(isAISharpnessEnabled ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(isAISharpnessEnabled ? champagne : Color.white.opacity(0.12))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isAISharpnessEnabled ? champagne : Color.white.opacity(0.15), lineWidth: 1)
                                )
                            }
                        }

                        // 5.2 Action Row: [Lưu ảnh] & [Chia sẻ]
                        HStack(spacing: 10) {
                            // Nút Lưu ảnh
                            Button(action: {
                                saveEnhancedImageToPhotos(currentProcessedImage)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: hasSavedNewEnhancement ? "checkmark" : "arrow.down")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(hasSavedNewEnhancement ? "Đã lưu" : "Lưu ảnh")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(champagne)
                                .cornerRadius(10)
                            }

                            // Nút Chia sẻ
                            if item.saveFormat == .dng, let data = item.rawPhotoData {
                                ShareLink(item: OriginalDNGShare(data: data),
                                    preview: SharePreview("AlignAI DNG", image: Image(decorative: item.originalImage, scale: 1, orientation: .up))) {
                                    shareButtonLabel
                                }
                            } else {
                                ShareLink(item: Image(decorative: currentProcessedImage, scale: 1, orientation: .up),
                                    preview: SharePreview("AlignAI Photo", image: Image(decorative: currentProcessedImage, scale: 1, orientation: .up))) {
                                    shareButtonLabel
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .onReceive(viewModel.map { $0.$saveErrorMessage.eraseToAnyPublisher() } ??
                Just<String?>(nil).eraseToAnyPublisher()) { message in
                if let message { aiErrorMessage = message }
            }
            .navigationTitle("Chi tiết ảnh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(champagne)
                }
            }
        }
    }

    // MARK: - Zoom & Pan Gesture Builder
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

    // MARK: - Split Comparison Controls (Active only at 1.0x)
    @ViewBuilder
    private func splitComparisonControls(size: CGSize) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.8))
            .frame(width: 1.5, height: size.height)
            .position(x: size.width * splitOffset, y: size.height / 2)
            .shadow(color: .black.opacity(0.6), radius: 3)

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

    // MARK: - Modern iPhone Style Mini-Map (Vùng đang zoom)
    @ViewBuilder
    private func zoomRegionMiniMap(viewportSize: CGSize) -> some View {
        if effectiveScale > 1.05 {
            let imgW = CGFloat(item.originalImage.width)
            let imgH = CGFloat(max(1, item.originalImage.height))
            let imgAspect = imgW / imgH
            let vpAspect = viewportSize.width / max(1, viewportSize.height)

            let baseW: CGFloat = (vpAspect > imgAspect) ? (viewportSize.height * imgAspect) : viewportSize.width
            let baseH: CGFloat = (vpAspect > imgAspect) ? viewportSize.height : (viewportSize.width / imgAspect)
            let renderedW = baseW * effectiveScale
            let renderedH = baseH * effectiveScale
            let maxPanX = max(1.0, (renderedW - viewportSize.width) / 2)
            let maxPanY = max(1.0, (renderedH - viewportSize.height) / 2)

            let miniWidth: CGFloat = imgAspect >= 1.0 ? 74 : 56
            let miniHeight: CGFloat = max(40, min(86, miniWidth / imgAspect))

            // Viewport indicator dimensions in mini-map
            let indicatorW = max(10.0, miniWidth / effectiveScale)
            let indicatorH = max(10.0, miniHeight / effectiveScale)

            let maxIndicatorShiftX = max(0, (miniWidth - indicatorW) / 2)
            let maxIndicatorShiftY = max(0, (miniHeight - indicatorH) / 2)

            let currOffset = effectiveOffset
            let normX = max(-1.0, min(1.0, currOffset.width / maxPanX))
            let normY = max(-1.0, min(1.0, currOffset.height / maxPanY))

            let indicatorOffsetX = -normX * maxIndicatorShiftX
            let indicatorOffsetY = -normY * maxIndicatorShiftY

            VStack(alignment: .leading, spacing: 5) {
                // Header: Zoom Level Badge & 1.0x Reset Button
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 8, weight: .bold))
                        Text(String(format: "%.1f×", effectiveScale))
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    }
                    .foregroundColor(champagne)

                    Spacer(minLength: 2)

                    Button(action: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            zoomScale = 1.0
                            gestureScale = 1.0
                            panOffset = .zero
                            gesturePanOffset = .zero
                        }
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(3)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                }
                .frame(width: miniWidth)

                // Thumbnail with Live Viewport Box
                ZStack {
                    Image(decorative: currentProcessedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: miniWidth, height: miniHeight)
                        .cornerRadius(5)

                    // Darkened backdrop so illuminated box stands out
                    Color.black.opacity(0.35)
                        .frame(width: miniWidth, height: miniHeight)
                        .cornerRadius(5)

                    // Illuminated viewport rectangle
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.white.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5)
                                .stroke(champagne, lineWidth: 1.5)
                        )
                        .frame(width: indicatorW, height: indicatorH)
                        .offset(x: indicatorOffsetX, y: indicatorOffsetY)
                        .shadow(color: Color.black.opacity(0.6), radius: 2)
                }
                .frame(width: miniWidth, height: miniHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
                )
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.55), radius: 6, x: 0, y: 3)
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.88).combined(with: .opacity),
                removal: .scale(scale: 0.92).combined(with: .opacity)
            ))
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: effectiveScale)
        }
    }

    // MARK: - AI Loading Overlay
    private var aiLoadingOverlay: some View {
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

    // MARK: - Subtle AI Sharpness Action (Làm nét nhẹ AI - Giữ 100% màu sắc & chất ảnh)
    private func toggleAISharpness() {
        guard item.saveFormat != .dng else {
            aiOptimizationSuccessNote = "DNG giữ nguyên dữ liệu gốc. Chọn JPEG/HEIF để dùng bộ lọc."
            return
        }
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
                        self.aiOptimizationSuccessNote = "\u{2728} Đã bật làm nét nhẹ AI (bảo toàn 100% màu sắc)"
                    }
                }
            }
        }
    }

    // MARK: - Preset Switcher Action
    private func applyPresetToPreview(_ preset: FilmPreset) {
        guard item.saveFormat != .dng else {
            aiOptimizationSuccessNote = "DNG giữ nguyên dữ liệu gốc. Chọn JPEG/HEIF để dùng bộ lọc."
            return
        }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()

        renderGeneration += 1
        let generation = renderGeneration
        let sharpen = isAISharpnessEnabled
        selectedPreviewPreset = preset
        let original = item.originalImage
        let params = currentAIParams
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = FilmFilterEngine.shared.applyPresetAndAIParameters(to: original, preset: preset, params: params) ?? original
            let finalImage: CGImage
            if sharpen {
                finalImage = FilmFilterEngine.shared.applySubtleAISharpness(to: rendered, intensity: 0.50) ?? rendered
            } else {
                finalImage = rendered
            }
            DispatchQueue.main.async {
                guard self.renderGeneration == generation else { return }
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
        guard item.saveFormat != .dng else {
            aiOptimizationSuccessNote = "DNG giữ nguyên dữ liệu gốc. Chọn JPEG/HEIF để dùng bộ lọc."
            return
        }
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
                        self.aiOptimizationSuccessNote = "\u{2728} AI khuyên dùng \(chosenPreset.displayName): \(explanation) (\(latency)ms)"
                        self.saveEnhancedImageToPhotos(finalImage, appliedPreset: chosenPreset, aiParams: aiParams)
                    }
                case .failure(let error):
                    self.aiErrorMessage = "Lỗi: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveEnhancedImageToPhotos(_ cgImage: CGImage, appliedPreset: FilmPreset? = nil, aiParams: AIColorParameters? = nil) {
        if item.saveFormat == .dng {
            if let vm = viewModel {
                vm.savePhotoToLibrary(item) { success in
                    self.hasSavedNewEnhancement = success
                    if !success { self.aiErrorMessage = vm.saveErrorMessage }
                }
            } else if let data = item.rawPhotoData, SuperResolutionRAWEngine.isDNGData(data) {
                let access: PHAccessLevel = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil ? .addOnly : .readWrite
                PHPhotoLibrary.requestAuthorization(for: access) { status in
                    guard status == .authorized || status == .limited else { return }
                    PHPhotoLibrary.shared().performChanges({
                        let options = PHAssetResourceCreationOptions()
                        options.uniformTypeIdentifier = "com.adobe.raw-image"
                        options.originalFilename = "AlignAI.dng"
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
                    }) { success, _ in
                        DispatchQueue.main.async { self.hasSavedNewEnhancement = success }
                    }
                }
            }
            return
        }
        let presetToSave = appliedPreset ?? selectedPreviewPreset
        let paramsToSave = aiParams ?? currentAIParams ?? item.aiColorParameters

        if let vm = viewModel {
            // Giữ trọn vẹn Live Photo: ghép đôi với video pairedMovie gốc và nhúng Content Identifier
            let updatedItem = CapturedPhotoItem(
                originalImage: item.originalImage,
                processedImage: cgImage,
                rawPhotoData: item.rawPhotoData,
                saveFormat: item.saveFormat,
                preservesOriginalFile: false,
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
            vm.savePhotoToLibrary(updatedItem) { success in
                self.hasSavedNewEnhancement = success
                if !success { self.aiErrorMessage = vm.saveErrorMessage }
            }
        } else {
            let uiImage = UIImage(cgImage: cgImage)
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, error in
                DispatchQueue.main.async {
                    self.hasSavedNewEnhancement = success
                    if !success { self.aiErrorMessage = error?.localizedDescription }
                }
            }
        }
    }
}

private struct OriginalDNGShare: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "dng") ?? .rawImage) { value in
            value.data
        }
        .suggestedFileName("AlignAI.dng")
    }
}
