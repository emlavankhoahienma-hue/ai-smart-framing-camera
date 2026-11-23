import SwiftUI
import UIKit
import PhotosUI
import AVKit
import AVFoundation

private enum PhotoboothFocusedDrawer: Equatable {
    case frames
    case stickers
}

/// Màn Hình Xem & Chỉnh Bản In Photobooth (Thiết kế tối giản chuẩn Gallery/Studio):
/// - Mặc định mở ra là không gian xem ảnh rộng thoáng (>80% màn hình), hỗ trợ phóng to 1.0x–4.5x, kéo 4 hướng, chạm đúp phóng to từng ảnh
/// - Thanh công cụ dưới chỉ có 4 mục gọn gàng: Khung · Sticker · Video · Thêm (ngăn kéo chỉ mở khi cần, bấm Xong để thu gọn)
/// - Ô ảnh vuông sắc cạnh 90° chuẩn máy in tiệm thật, đầy đủ 8 bố cục (gồm 2×4 & 2×4 Đôi) và 25 khung có chất liệu giấy/vải thật
public struct PhotoboothEditorSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var assetManager = PhotoboothAssetManager.shared
    @Environment(\.dismiss) private var dismiss

    // Focused Drawer & Secondary Sheet
    @State private var activeDrawer: PhotoboothFocusedDrawer? = nil
    @State private var showMoreOptionsSheet: Bool = false

    // Zoom & Pan Inspection State (1.0x -> 4.5x Smooth Gallery Viewer)
    @State private var stripZoomScale: CGFloat = 1.0
    @State private var stripLastZoomScale: CGFloat = 1.0
    @State private var stripPanOffset: CGSize = .zero
    @State private var stripLastPanOffset: CGSize = .zero

    // Sticker & Slot Actions
    @State private var selectedStickerID: UUID? = nil
    @State private var selectedSlotForAction: Int? = nil
    @State private var showSlotActionDialog: Bool = false
    @State private var showReplacePhotoPicker: Bool = false
    @State private var replacePhotoItem: PhotosPickerItem? = nil

    // Frame & Sticker Browser State
    @State private var selectedFrameCategory: PhotoboothFrameCategory = .all
    @State private var stickerCategory: PhotoboothAssetCategory = .coquette
    @State private var selectedOnlinePack: PhotoboothOnlinePackCategory = .bowsPastel

    // AI Studio State (Housed Cleanly Inside "Thêm" Sheet — Powered by Gemini Photo System Prompt Engine)
    @State private var aiStickerPrompt: String = ""
    @State private var aiFramePrompt: String = ""
    @State private var selectedAIStickerPreset: PhotoboothAIStickerPreset = .catRibbon
    @State private var selectedAIFramePreset: PhotoboothAIFramePreset = .seoulMinimalLinen
    @State private var selectedAIPortraitStyle: PhotoboothAIStylePreset = .koreanStudio
    @State private var aiFeedbackMessage: String? = nil
    @State private var isStylizingSlots: Bool = false

    // Save / Share / Timelapse
    @State private var isSavingStrip: Bool = false
    @State private var justSavedStrip: Bool = false
    @State private var shareImage: UIImage? = nil
    @State private var showShareSheet: Bool = false
    @State private var showTimelapseSheet: Bool = false

    // 120Hz Cached Base Strip Preview (960px Crisp for Deep Zoom) + Vision Anchors
    @State private var cachedBaseStripImage: UIImage? = nil
    @State private var baseStripRevision: Int = 0
    @State private var slotSemanticMaps: [PhotoboothSlotSemanticMap] = []
    @State private var isSmartAnchorEnabled: Bool = true
    @State private var isAnalyzingFaces: Bool = false

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 0) {
                    calmTopHeaderBar

                    zoomableStripStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let drawer = activeDrawer {
                        focusedDrawerContainer(drawer)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        calmBottomActionBar
                            .transition(.opacity)
                    }
                }

                // Lớp thông báo tiến trình khi lưu bản in 300 DPI hoặc xử lý AI
                if isSavingStrip || assetManager.isGeneratingAI || isStylizingSlots {
                    ZStack {
                        Color.black.opacity(0.48).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.05)
                            Text(isSavingStrip ? "Đang lưu ảnh 300 DPI..." : "Đang xử lý tài nguyên...")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                        )
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Ảnh khung #\(selectedSlotForAction.map { $0 + 1 } ?? 1)",
                isPresented: $showSlotActionDialog,
                titleVisibility: .visible
            ) {
                if let idx = selectedSlotForAction {
                    Button("Chụp lại khung này") {
                        dismiss()
                        viewModel.retakePhotoboothSlot(idx)
                    }
                    Button("Chọn ảnh khác từ Thư viện") {
                        showReplacePhotoPicker = true
                    }
                    Button("Lật gương ngang") {
                        toggleMirrorSlot(idx)
                    }
                    if idx < viewModel.photoboothSlots.count, let slot = viewModel.photoboothSlots[idx] {
                        Button("Tách chủ thể làm Sticker") {
                            Task {
                                if let created = await assetManager.createCutoutStickerFromPhoto(slot.displayImage, title: "Tự tách #\(idx + 1)") {
                                    placeSticker(created)
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        resetStripZoom()
                                        activeDrawer = .stickers
                                        stickerCategory = .myStickers
                                    }
                                }
                            }
                        }
                        if slot.aiStyledImage != nil {
                            Button(slot.isAIStyleActive ? "Dùng lại ảnh gốc" : "Bật ảnh chân dung AI") {
                                toggleSlotAIStyle(idx)
                            }
                        }
                    }
                    Button("Hủy", role: .cancel) {}
                }
            }
            .photosPicker(isPresented: $showReplacePhotoPicker, selection: $replacePhotoItem, matching: .images)
            .onChangeCompatible(of: replacePhotoItem) { item in
                guard let item, let idx = selectedSlotForAction else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data),
                       let cg = Self.normalizedUprightCGImage(ui) {
                        viewModel.replacePhotoboothSlot(idx, cgImage: cg)
                        baseStripRevision &+= 1
                    }
                    replacePhotoItem = nil
                }
            }
            .sheet(isPresented: $showMoreOptionsSheet) {
                moreOptionsSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareImage {
                    PhotoboothShareSheet(items: [shareImage])
                }
            }
            .fullScreenCover(isPresented: $showTimelapseSheet) {
                PhotoboothTimelapsePreviewSheet(
                    viewModel: viewModel,
                    assetManager: assetManager
                )
            }
            .onAppear {
                rebuildBaseStripPreviewCache()
                refreshVisionSlotAnchors()
            }
            .onChangeCompatible(of: viewModel.photoboothStripConfig) { _ in
                justSavedStrip = false
                rebuildBaseStripPreviewCache()
                refreshVisionSlotAnchors()
            }
            .onChangeCompatible(of: baseStripRevision) { _ in
                justSavedStrip = false
                rebuildBaseStripPreviewCache()
                refreshVisionSlotAnchors()
            }
        }
    }

    // MARK: - 1. Calm 3-Element Top Header Bar

    private var calmTopHeaderBar: some View {
        let layout = viewModel.photoboothStripConfig.layout
        let frame = viewModel.photoboothStripConfig.frameStyle

        return HStack(spacing: 12) {
            Button(action: {
                viewModel.isShowingPhotoboothEditor = false
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng màn hình xem Photobooth")

            Spacer()

            Text("\(layout.shortBadge) · \(frame.displayName)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)

            Spacer()

            Button(action: saveStrip) {
                HStack(spacing: 4.5) {
                    if justSavedStrip {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    Text(justSavedStrip ? "Đã lưu" : "Lưu")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundColor(justSavedStrip ? .white : .black)
                .padding(.horizontal, 15)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(justSavedStrip ? Color(red: 0.20, green: 0.62, blue: 0.34) : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingStrip)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 2. Full-Screen Spacious Zoomable Strip Viewer (Pinch 1.0x–4.5x · 4-Way Pan · Double-Tap Zoom)

    private var zoomableStripStage: some View {
        let stripAspect = viewModel.photoboothStripConfig.layout.aspectRatio
        let isEditingStickers = (activeDrawer == .stickers)
        let isZoomedIn = stripZoomScale > 1.02

        return GeometryReader { geo in
            let padX: CGFloat = activeDrawer == nil ? 16 : 22
            let padY: CGFloat = activeDrawer == nil ? 10 : 8
            let availW = max(1, geo.size.width - padX * 2)
            let availH = max(1, geo.size.height - padY * 2)
            let stripW = min(availW, availH * stripAspect)
            let stripH = stripW / max(0.2, stripAspect)
            let stripSize = CGSize(width: stripW, height: stripH)
            let slotRects = viewModel.photoboothStripConfig.layout.slotRects(
                in: stripSize,
                marginScale: viewModel.photoboothStripConfig.marginScale
            )

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isEditingStickers else { return }
                        toggleSimpleCenterZoom()
                    }
                    .onTapGesture(count: 1) {
                        selectedStickerID = nil
                    }

                // Dải ảnh Photobooth sắc cạnh chuẩn bản in thật
                ZStack {
                    if let cachedBaseStripImage {
                        Image(uiImage: cachedBaseStripImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: stripSize.width, height: stripSize.height)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: stripSize.width, height: stripSize.height)
                    }

                    // Vùng chạm từng ô ảnh (hỗ trợ cả 2×4 & 2×4 Đôi; chạm đúp phóng to đúng ô, chạm đơn đổi/lật ảnh)
                    ForEach(Array(slotRects.enumerated()), id: \.offset) { rectIdx, r in
                        let photoIdx = viewModel.photoboothStripConfig.layout.photoIndex(forRenderedRectIndex: rectIdx)
                        Color.clear
                            .frame(width: r.width, height: r.height)
                            .contentShape(Rectangle())
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture(count: 2) {
                                guard !isEditingStickers else { return }
                                toggleZoomFocusedOn(pointInStrip: CGPoint(x: r.midX, y: r.midY), stripSize: stripSize, viewportSize: geo.size)
                            }
                            .onTapGesture(count: 1) {
                                if selectedStickerID != nil {
                                    selectedStickerID = nil
                                } else if !isEditingStickers && stripZoomScale <= 1.04 {
                                    selectedSlotForAction = photoIdx
                                    showSlotActionDialog = true
                                }
                            }
                    }

                    // Lớp Sticker tương tác kéo / phóng / xoay
                    ForEach($viewModel.photoboothPlacedStickers) { $sticker in
                        InteractiveStickerView(
                            sticker: $sticker,
                            stripSize: stripSize,
                            assetManager: assetManager,
                            isSelected: selectedStickerID == sticker.id,
                            interactionEnabled: (stripZoomScale <= 1.04),
                            onSelect: { selectedStickerID = sticker.id },
                            onDelete: {
                                viewModel.photoboothPlacedStickers.removeAll { $0.id == sticker.id }
                                selectedStickerID = nil
                            },
                            onDuplicate: { duplicateSticker(sticker) }
                        )
                    }
                }
                .frame(width: stripSize.width, height: stripSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: Color.black.opacity(0.62), radius: 22, y: 10)
                .scaleEffect(stripZoomScale)
                .offset(stripPanOffset)

                // Huy hiệu thu gọn tinh tế chỉ hiện khi người dùng đang phóng to để soi ảnh
                if isZoomedIn {
                    VStack {
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                resetStripZoom()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text(String(format: "%.1fx", stripZoomScale))
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                Text("Thu gọn")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.72))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .coordinateSpace(name: "photoboothStripCanvasSpace")
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        guard !isEditingStickers && selectedStickerID == nil else { return }
                        let nextScale = min(max(stripLastZoomScale * val, 1.0), 4.5)
                        stripZoomScale = nextScale
                        if nextScale <= 1.02 {
                            stripPanOffset = .zero
                        } else {
                            let ratio = nextScale / max(1.0, stripLastZoomScale)
                            let scaled = CGSize(
                                width: stripLastPanOffset.width * ratio,
                                height: stripLastPanOffset.height * ratio
                            )
                            stripPanOffset = clampStripPan(scaled, stripSize: stripSize, viewportSize: geo.size, scale: nextScale)
                        }
                    }
                    .onEnded { _ in
                        guard !isEditingStickers && selectedStickerID == nil else { return }
                        if stripZoomScale < 1.05 {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                resetStripZoom()
                            }
                        } else {
                            stripLastZoomScale = stripZoomScale
                            stripPanOffset = clampStripPan(stripPanOffset, stripSize: stripSize, viewportSize: geo.size, scale: stripZoomScale)
                            stripLastPanOffset = stripPanOffset
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("photoboothStripCanvasSpace"))
                    .onChanged { val in
                        guard !isEditingStickers && selectedStickerID == nil && stripZoomScale > 1.02 else { return }
                        let raw = CGSize(
                            width: stripLastPanOffset.width + val.translation.width,
                            height: stripLastPanOffset.height + val.translation.height
                        )
                        stripPanOffset = clampStripPan(raw, stripSize: stripSize, viewportSize: geo.size, scale: stripZoomScale)
                    }
                    .onEnded { _ in
                        guard !isEditingStickers && selectedStickerID == nil && stripZoomScale > 1.02 else { return }
                        stripLastPanOffset = stripPanOffset
                    }
            )
        }
    }

    // MARK: - 3. Calm 4-Item Bottom Action Bar (Default Spacious Viewer Mode)

    private var calmBottomActionBar: some View {
        HStack(spacing: 0) {
            bottomBarItem(icon: "rectangle.portrait.on.rectangle.portrait", title: "Khung") {
                HapticFeedbackService.shared.triggerSelectionChange()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    activeDrawer = .frames
                }
            }

            bottomBarItem(icon: "face.smiling", title: "Sticker") {
                HapticFeedbackService.shared.triggerSelectionChange()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    resetStripZoom()
                    activeDrawer = .stickers
                }
            }

            bottomBarItem(icon: "play.rectangle", title: "Video", disabled: viewModel.photoboothFilledCount == 0) {
                HapticFeedbackService.shared.triggerLight()
                showTimelapseSheet = true
            }

            bottomBarItem(icon: "ellipsis", title: "Thêm") {
                HapticFeedbackService.shared.triggerSelectionChange()
                showMoreOptionsSheet = true
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            Color(red: 0.055, green: 0.056, blue: 0.064)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func bottomBarItem(icon: String, title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundColor(disabled ? .white.opacity(0.28) : .white.opacity(0.90))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - 4. Focused On-Demand Drawers (Khung & Bố cục / Sticker)

    @ViewBuilder
    private func focusedDrawerContainer(_ drawer: PhotoboothFocusedDrawer) -> some View {
        VStack(spacing: 0) {
            switch drawer {
            case .frames:
                framesFocusedDrawer
            case .stickers:
                stickersFocusedDrawer
            }
        }
        .background(
            Color(red: 0.075, green: 0.077, blue: 0.088)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // Drawer A: Layouts (4×1, 2×4, 2×4 Đôi...) + 25 Real Frames with Physical Textures
    private var framesFocusedDrawer: some View {
        VStack(spacing: 12) {
            // Drawer Header
            HStack {
                Text("Khung & Bố cục")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button(action: applyAutoOutfitColor) {
                    Text("Khớp màu ảnh")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        activeDrawer = nil
                    }
                }) {
                    Text("Xong")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Layout Row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoboothLayout.allCases) { lay in
                        let isSel = viewModel.photoboothStripConfig.layout == lay
                        Button(action: {
                            viewModel.selectPhotoboothLayout(lay)
                        }) {
                            Text(lay.shortBadge)
                                .font(.system(size: 12, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSel ? .black : .white.opacity(0.78))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Category Filter Tabs for 50 Frames (Tất cả · Hàn & Studio · Dễ thương · Y2K & Nhạc · Phim & Cổ điển · Vé & Tạp chí)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(PhotoboothFrameCategory.allCases) { cat in
                        let isSel = selectedFrameCategory == cat
                        Button(action: {
                            HapticFeedbackService.shared.triggerSelectionChange()
                            selectedFrameCategory = cat
                        }) {
                            VStack(spacing: 4) {
                                Text(cat.rawValue)
                                    .font(.system(size: 11.5, weight: isSel ? .semibold : .regular, design: .rounded))
                                    .foregroundColor(isSel ? .white : .white.opacity(0.52))
                                Rectangle()
                                    .fill(isSel ? Color.white : Color.clear)
                                    .frame(height: 1.5)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // 50 Real Frames Swatch Strip (Sharp 90° Cards Showing Actual Fabric/Paper Texture)
            let visibleFrames: [PhotoboothFrameStyle] = selectedFrameCategory == .all
                ? PhotoboothFrameStyle.allCases
                : PhotoboothFrameStyle.allCases.filter { $0.category == selectedFrameCategory }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(visibleFrames) { frame in
                        let isSel = viewModel.photoboothStripConfig.frameStyle == frame
                            && viewModel.photoboothStripConfig.customBackgroundHex == nil
                        Button(action: {
                            HapticFeedbackService.shared.triggerSelectionChange()
                            viewModel.photoboothStripConfig.customBackgroundHex = nil
                            viewModel.photoboothStripConfig.frameStyle = frame
                            if frame == .customAITexture && viewModel.photoboothStripConfig.customAITextureFilename == nil {
                                if let firstSaved = assetManager.customAIFrameFilenames.first {
                                    viewModel.photoboothStripConfig.customAITextureFilename = firstSaved
                                } else {
                                    activeDrawer = nil
                                    showMoreOptionsSheet = true
                                }
                            }
                        }) {
                            VStack(spacing: 5) {
                                ZStack {
                                    if let texName = frame.bundledTextureFilename,
                                       let texImg = assetManager.bundledFrameTextureImage(filename: texName) {
                                        Image(uiImage: texImg)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 52, height: 70)
                                            .clipped()
                                    } else {
                                        Rectangle()
                                            .fill(
                                                LinearGradient(
                                                    colors: frame.swatchColors,
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 52, height: 70)
                                    }

                                    if frame == .kodak35mmSprocket {
                                        VStack(spacing: 8) {
                                            ForEach(0..<4, id: \.self) { _ in
                                                HStack {
                                                    Rectangle().fill(Color.white.opacity(0.65)).frame(width: 4, height: 5.5)
                                                    Spacer()
                                                    Rectangle().fill(Color.white.opacity(0.65)).frame(width: 4, height: 5.5)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 4)
                                    } else if frame == .customAITexture {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                    } else {
                                        VStack(spacing: 3.5) {
                                            Rectangle().fill(Color.black.opacity(0.24)).frame(width: 34, height: 16)
                                            Rectangle().fill(Color.black.opacity(0.24)).frame(width: 34, height: 16)
                                        }
                                        .offset(y: -4)
                                    }
                                }
                                .overlay(
                                    Rectangle()
                                        .stroke(isSel ? Color.white : Color.white.opacity(0.20), lineWidth: isSel ? 2.0 : 0.6)
                                )

                                Text(frame.displayName)
                                    .font(.system(size: 10, weight: isSel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSel ? .white : .white.opacity(0.65))
                                    .lineLimit(1)
                                    .frame(width: 60)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 12)
        }
    }

    // Drawer B: Clean Uncluttered Sticker Browser (Zero Stacked Pill Soup!)
    private var stickersFocusedDrawer: some View {
        let detectedFaceTotal = slotSemanticMaps.reduce(0) { $0 + $1.faces.count }

        return VStack(spacing: 10) {
            // Top Row: Title + Compact Native Menu "Tự dán" + "Xong"
            HStack(spacing: 8) {
                Text("Sticker")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Menu {
                    Section("Tự động trang trí theo khuôn mặt") {
                        ForEach(PhotoboothAutoDecorateStyle.allCases) { autoStyle in
                            Button(autoStyle.rawValue) {
                                applySmartAutoDecorate(style: autoStyle)
                            }
                        }
                    }

                    Section {
                        Button(action: {
                            isSmartAnchorEnabled.toggle()
                            HapticFeedbackService.shared.triggerSelectionChange()
                        }) {
                            Label(
                                isSmartAnchorEnabled
                                    ? (detectedFaceTotal > 0 ? "AI Neo mặt: Đang bật (\(detectedFaceTotal) mặt)" : "AI Neo góc trống: Đang bật")
                                    : "AI Neo mặt: Đang tắt (đặt tự do)",
                                systemImage: isSmartAnchorEnabled ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }

                    if !viewModel.photoboothPlacedStickers.isEmpty {
                        Section {
                            Button("Xóa tất cả sticker", role: .destructive) {
                                viewModel.photoboothPlacedStickers.removeAll()
                                selectedStickerID = nil
                                HapticFeedbackService.shared.triggerLight()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Tự dán")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .disabled(isAnalyzingFaces)

                Spacer()

                Button(action: {
                    selectedStickerID = nil
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        activeDrawer = nil
                    }
                }) {
                    Text("Xong")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Calm Underlined Text Tabs (No Heavy Pills!)
            HStack(spacing: 18) {
                ForEach(PhotoboothAssetCategory.allCases) { cat in
                    let isSel = stickerCategory == cat
                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        stickerCategory = cat
                    }) {
                        VStack(spacing: 5) {
                            Text(cat.rawValue)
                                .font(.system(size: 12, weight: isSel ? .semibold : .regular, design: .rounded))
                                .foregroundColor(isSel ? .white : .white.opacity(0.52))
                            Rectangle()
                                .fill(isSel ? Color.white : Color.clear)
                                .frame(height: 1.5)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            // Spacious 4-Col Sticker Grid
            Group {
                if stickerCategory == .onlinePacks {
                    onlinePacksBrowser
                } else {
                    let items: [PhotoboothStickerAsset] = {
                        switch stickerCategory {
                        case .coquette:
                            return assetManager.bundledStickers.filter { $0.category == .coquette }
                        case .y2k:
                            return assetManager.bundledStickers.filter { $0.category == .y2k }
                        case .myStickers:
                            return assetManager.customStickers
                        case .onlinePacks:
                            return []
                        }
                    }()

                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Text("Chưa có sticker AI hoặc tự tách nền.")
                                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.58))
                            Button(action: {
                                activeDrawer = nil
                                showMoreOptionsSheet = true
                            }) {
                                Text("Tạo trong mục Thêm")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 14)
                                    .frame(height: 30)
                                    .background(Capsule().fill(Color.white))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                                ForEach(items) { asset in
                                    stickerGridTile(asset)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
            .frame(height: 185)
        }
    }

    private var onlinePacksBrowser: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoboothOnlinePackCategory.allCases) { pack in
                        let isSel = selectedOnlinePack == pack
                        Button(action: {
                            selectedOnlinePack = pack
                        }) {
                            Text(pack.rawValue)
                                .font(.system(size: 11, weight: isSel ? .semibold : .regular, design: .rounded))
                                .foregroundColor(isSel ? .black : .white.opacity(0.74))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: {
                        Task { _ = await assetManager.downloadOnlinePack(selectedOnlinePack) }
                    }) {
                        Image(systemName: assetManager.isDownloadingPack == selectedOnlinePack ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(assetManager.isDownloadingPack != nil)
                    .accessibilityLabel("Tải cả gói sticker online")
                }
                .padding(.horizontal, 16)
            }

            let packItems = assetManager.onlineStickers.filter { $0.onlinePack == selectedOnlinePack }
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(packItems) { asset in
                        stickerGridTile(asset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func stickerGridTile(_ asset: PhotoboothStickerAsset) -> some View {
        let img = assetManager.cachedImage(for: asset.source, id: asset.id)
        Button(action: {
            if img != nil {
                placeSticker(asset)
            } else if asset.category == .onlinePacks {
                Task {
                    if await assetManager.downloadOnlineSticker(asset) != nil {
                        placeSticker(asset)
                    }
                }
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 62)

                if let img {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: 62)
                } else if case .online(let urlStr) = asset.source, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fit).padding(8)
                        default:
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 62)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. Clean Native-Style "Thêm" Sheet (Share · New Shot · Print Info · AI Studio)

    private var moreOptionsSheet: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    // Quick Actions: Share & New Session
                    HStack(spacing: 10) {
                        Button(action: {
                            showMoreOptionsSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                prepareShareStrip()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("Chia sẻ ảnh")
                                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            showMoreOptionsSheet = false
                            viewModel.resetPhotoboothSession()
                            viewModel.isShowingPhotoboothEditor = false
                            dismiss()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Text("Chụp lượt mới")
                                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let msg = aiFeedbackMessage ?? assetManager.lastStatusMessage {
                        Text(msg)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.86))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                    }

                    // Section 1: Thông tin bản in
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BẢN IN & CHỮ KÝ")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(0.6)
                            .foregroundColor(.white.opacity(0.52))

                        TextField("ALIGN STUDIO", text: $viewModel.photoboothStripConfig.customCaption)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

                        Toggle(isOn: $viewModel.photoboothStripConfig.showDateStamp) {
                            Text("In dấu ngày ở chân dải ảnh")
                                .font(.system(size: 13.5, weight: .regular, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .tint(Color(red: 0.24, green: 0.72, blue: 0.42))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Chất liệu giấy")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.65))
                            HStack(spacing: 6) {
                                ForEach(PhotoboothPaperFinish.allCases) { finish in
                                    let isSel = viewModel.photoboothStripConfig.paperFinish == finish
                                    Button(action: {
                                        viewModel.photoboothStripConfig.paperFinish = finish
                                    }) {
                                        Text(finish.displayName)
                                            .font(.system(size: 12.5, weight: isSel ? .semibold : .regular, design: .rounded))
                                            .foregroundColor(isSel ? .black : .white.opacity(0.82))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 34)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Color.white : Color.white.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 0.5)

                    // Section 2: Studio AI (Gemini Photo + Built-In System Prompt Guardrail + 1-Tap Presets)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Text("STUDIO AI · GEMINI PHOTO")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .tracking(0.6)
                                .foregroundColor(.white.opacity(0.56))
                            Spacer()
                            Text("System Prompt Tự Động")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(red: 0.35, green: 0.88, blue: 0.56))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 0.16, green: 0.44, blue: 0.28).opacity(0.45)))
                        }

                        // 1. Tạo Sticker AI (Có sẵn 10 mẫu 1 chạm + System Prompt chống chữ rác / nền trắng sạch)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tạo Sticker tách nền (Chạm mẫu có sẵn hoặc nhập tùy ý)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.76))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(PhotoboothAIStickerPreset.allCases) { preset in
                                        let isSel = selectedAIStickerPreset == preset && aiStickerPrompt.isEmpty
                                        Button(action: {
                                            selectedAIStickerPreset = preset
                                            aiStickerPrompt = ""
                                            runGenerateAIStickerPreset(preset)
                                        }) {
                                            Text(preset.displayTitle)
                                                .font(.system(size: 11.5, weight: isSel ? .semibold : .regular, design: .rounded))
                                                .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                                .padding(.horizontal, 11)
                                                .frame(height: 29)
                                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.09)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("Hoặc gõ ngắn gọn (System Prompt tự chuẩn hóa)...", text: $aiStickerPrompt)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

                                Button(action: runGenerateAISticker) {
                                    Text("Tạo")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 16)
                                        .frame(height: 38)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // 2. Tạo Nền Khung In AI (Có sẵn 10 mẫu giấy/vải 1 chạm + System Prompt cấm vẽ chữ/ô giả)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tạo nền khung in AI (Chạm mẫu giấy/vải hoặc nhập tùy ý)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.76))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(PhotoboothAIFramePreset.allCases) { preset in
                                        let isSel = selectedAIFramePreset == preset && aiFramePrompt.isEmpty
                                        Button(action: {
                                            selectedAIFramePreset = preset
                                            aiFramePrompt = ""
                                            runGenerateAIFramePreset(preset)
                                        }) {
                                            Text(preset.displayTitle)
                                                .font(.system(size: 11.5, weight: isSel ? .semibold : .regular, design: .rounded))
                                                .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                                .padding(.horizontal, 11)
                                                .frame(height: 29)
                                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.09)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("Hoặc gõ chất liệu (System Prompt tự khóa phẳng)...", text: $aiFramePrompt)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

                                Button(action: runGenerateAIFrame) {
                                    Text("Áp khung")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 14)
                                        .frame(height: 38)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // 3. Chuyển chân dung Booth bằng Gemini Photo (8 phong cách khóa chặt khuôn mặt)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chuyển chân dung Booth bằng Gemini Photo")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.76))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(PhotoboothAIStylePreset.allCases) { st in
                                        let isSel = selectedAIPortraitStyle == st
                                        Button(action: { selectedAIPortraitStyle = st }) {
                                            Text(st.displayName)
                                                .font(.system(size: 11.5, weight: isSel ? .semibold : .regular, design: .rounded))
                                                .foregroundColor(isSel ? .black : .white.opacity(0.80))
                                                .padding(.horizontal, 11)
                                                .frame(height: 30)
                                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            Button(action: {
                                showMoreOptionsSheet = false
                                runStylizeBoothSlots()
                            }) {
                                Text("Áp dụng phong cách \(selectedAIPortraitStyle.displayName)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.11)))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.photoboothFilledCount == 0)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(Color(red: 0.075, green: 0.077, blue: 0.086).ignoresSafeArea())
            .navigationTitle("Tùy chọn bản in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") {
                        showMoreOptionsSheet = false
                    }
                    .foregroundColor(.white)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Zoom & Pan Geometry Helpers

    private func resetStripZoom() {
        stripZoomScale = 1.0
        stripLastZoomScale = 1.0
        stripPanOffset = .zero
        stripLastPanOffset = .zero
    }

    private func clampStripPan(_ offset: CGSize, stripSize: CGSize, viewportSize: CGSize, scale: CGFloat) -> CGSize {
        let scaledW = stripSize.width * scale
        let scaledH = stripSize.height * scale
        let maxX = max(0, (scaledW - viewportSize.width) * 0.5 + 24)
        let maxY = max(0, (scaledH - viewportSize.height) * 0.5 + 24)
        return CGSize(
            width: max(-maxX, min(maxX, offset.width)),
            height: max(-maxY, min(maxY, offset.height))
        )
    }

    private func toggleSimpleCenterZoom() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            if stripZoomScale > 1.05 {
                resetStripZoom()
            } else {
                stripZoomScale = 2.4
                stripLastZoomScale = 2.4
                stripPanOffset = .zero
                stripLastPanOffset = .zero
            }
        }
    }

    private func toggleZoomFocusedOn(pointInStrip: CGPoint, stripSize: CGSize, viewportSize: CGSize) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            if stripZoomScale > 1.05 {
                resetStripZoom()
            } else {
                let targetScale: CGFloat = 2.6
                let dx = (stripSize.width * 0.5 - pointInStrip.x) * targetScale
                let dy = (stripSize.height * 0.5 - pointInStrip.y) * targetScale
                stripZoomScale = targetScale
                stripLastZoomScale = targetScale
                let clamped = clampStripPan(CGSize(width: dx, height: dy), stripSize: stripSize, viewportSize: viewportSize, scale: targetScale)
                stripPanOffset = clamped
                stripLastPanOffset = clamped
            }
        }
    }

    // MARK: - Interactive Logic Helpers

    private func rebuildBaseStripPreviewCache() {
        // Kết xuất bản xem trước 960px để phóng to soi chi tiết tới 4.5x vẫn sắc nét và mượt 120Hz
        let stripCG = PhotoboothStripRenderer.renderStrip(
            slots: viewModel.photoboothSlots,
            config: viewModel.photoboothStripConfig,
            stickers: [],
            assetManager: assetManager,
            targetWidth: 960
        )
        if let stripCG {
            cachedBaseStripImage = UIImage(cgImage: stripCG)
        }
    }

    private func refreshVisionSlotAnchors() {
        let currentSlots = viewModel.photoboothSlots
        let currentConfig = viewModel.photoboothStripConfig
        isAnalyzingFaces = true
        Task {
            let maps = await PhotoboothSmartPlacementEngine.analyzeSlots(
                slots: currentSlots,
                config: currentConfig
            )
            await MainActor.run {
                self.slotSemanticMaps = maps
                self.isAnalyzingFaces = false
            }
        }
    }

    private func applySmartAutoDecorate(style: PhotoboothAutoDecorateStyle) {
        HapticFeedbackService.shared.triggerMedium()
        Task {
            var maps = slotSemanticMaps
            if maps.isEmpty {
                maps = await PhotoboothSmartPlacementEngine.analyzeSlots(
                    slots: viewModel.photoboothSlots,
                    config: viewModel.photoboothStripConfig
                )
            }
            let available = assetManager.bundledStickers
                + assetManager.onlineStickers.filter { assetManager.downloadedOnlineIDs.contains($0.id) }
            let generated = PhotoboothSmartPlacementEngine.generateAutoDecoratedStickers(
                style: style,
                maps: maps,
                availableAssets: available,
                config: viewModel.photoboothStripConfig
            )
            await MainActor.run {
                self.slotSemanticMaps = maps
                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                    self.viewModel.photoboothPlacedStickers = generated
                    self.selectedStickerID = generated.last?.id
                }
            }
        }
    }

    private func placeSticker(_ asset: PhotoboothStickerAsset) {
        HapticFeedbackService.shared.triggerLight()
        if isSmartAnchorEnabled && !slotSemanticMaps.isEmpty {
            let placed = PhotoboothSmartPlacementEngine.suggestPlacement(
                for: asset,
                maps: slotSemanticMaps,
                existingStickers: viewModel.photoboothPlacedStickers,
                config: viewModel.photoboothStripConfig
            )
            viewModel.photoboothPlacedStickers.append(placed)
            selectedStickerID = placed.id
            return
        }
        let jitterX = CGFloat.random(in: -0.06...0.06)
        let jitterY = CGFloat.random(in: -0.06...0.06)
        let newSticker = PlacedPhotoboothSticker(
            assetID: asset.id,
            assetSource: asset.source,
            normalizedX: 0.5 + jitterX,
            normalizedY: 0.5 + jitterY,
            scale: 0.22,
            rotationDegrees: Double.random(in: -8...8),
            opacity: 1.0
        )
        viewModel.photoboothPlacedStickers.append(newSticker)
        selectedStickerID = newSticker.id
    }

    private func duplicateSticker(_ st: PlacedPhotoboothSticker) {
        HapticFeedbackService.shared.triggerLight()
        let copy = PlacedPhotoboothSticker(
            assetID: st.assetID,
            assetSource: st.assetSource,
            normalizedX: min(0.92, st.normalizedX + 0.06),
            normalizedY: min(0.92, st.normalizedY + 0.04),
            scale: st.scale,
            rotationDegrees: st.rotationDegrees,
            opacity: st.opacity
        )
        viewModel.photoboothPlacedStickers.append(copy)
        selectedStickerID = copy.id
    }

    private func toggleMirrorSlot(_ index: Int) {
        guard index >= 0 && index < viewModel.photoboothSlots.count,
              var slot = viewModel.photoboothSlots[index] else { return }
        slot.isMirrored.toggle()
        viewModel.photoboothSlots[index] = slot
        baseStripRevision &+= 1
    }

    private func toggleSlotAIStyle(_ index: Int) {
        guard index >= 0 && index < viewModel.photoboothSlots.count,
              var slot = viewModel.photoboothSlots[index] else { return }
        slot.isAIStyleActive.toggle()
        viewModel.photoboothSlots[index] = slot
        baseStripRevision &+= 1
    }

    private func applyAutoOutfitColor() {
        let images = viewModel.photoboothSlots.compactMap { $0?.displayImage }
        let harmony = PhotoboothAssetManager.extractHarmoniousColors(from: images)
        var r: CGFloat = 0.96, g: CGFloat = 0.94, b: CGFloat = 0.90, a: CGFloat = 1.0
        harmony.uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        viewModel.photoboothStripConfig.customBackgroundHex = hex
        HapticFeedbackService.shared.triggerLight()
    }

    private func runGenerateAISticker() {
        let prompt = aiStickerPrompt
        let preset = selectedAIStickerPreset
        aiFeedbackMessage = nil
        Task {
            let result = await assetManager.generateAISticker(prompt: prompt, preset: preset)
            if let created = result.asset {
                placeSticker(created)
                aiStickerPrompt = ""
                aiFeedbackMessage = "Đã tạo sticker '\(created.title)' bằng \(result.backendUsed) và đặt lên khung."
            } else {
                aiFeedbackMessage = assetManager.lastStatusMessage
            }
        }
    }

    private func runGenerateAIStickerPreset(_ preset: PhotoboothAIStickerPreset) {
        HapticFeedbackService.shared.triggerLight()
        aiFeedbackMessage = nil
        Task {
            let result = await assetManager.generateAISticker(prompt: "", preset: preset)
            if let created = result.asset {
                placeSticker(created)
                aiFeedbackMessage = "Đã tạo mẫu '\(preset.displayTitle)' qua \(result.backendUsed) và đặt lên khung."
            } else {
                aiFeedbackMessage = assetManager.lastStatusMessage
            }
        }
    }

    private func runGenerateAIFrame() {
        let prompt = aiFramePrompt
        let preset = selectedAIFramePreset
        aiFeedbackMessage = nil
        let slotImgs = viewModel.photoboothSlots.compactMap { $0?.displayImage }
        Task {
            let result = await assetManager.generateAIFrameTexture(prompt: prompt, preset: preset, slotImages: slotImgs)
            if let fname = result.filename {
                viewModel.photoboothStripConfig.customBackgroundHex = nil
                viewModel.photoboothStripConfig.customAITextureFilename = fname
                viewModel.photoboothStripConfig.frameStyle = .customAITexture
                aiFramePrompt = ""
                aiFeedbackMessage = "Đã áp dụng khung nền từ \(result.backendUsed)."
            } else {
                aiFeedbackMessage = assetManager.lastStatusMessage
            }
        }
    }

    private func runGenerateAIFramePreset(_ preset: PhotoboothAIFramePreset) {
        HapticFeedbackService.shared.triggerLight()
        aiFeedbackMessage = nil
        let slotImgs = viewModel.photoboothSlots.compactMap { $0?.displayImage }
        Task {
            let result = await assetManager.generateAIFrameTexture(prompt: "", preset: preset, slotImages: slotImgs)
            if let fname = result.filename {
                viewModel.photoboothStripConfig.customBackgroundHex = nil
                viewModel.photoboothStripConfig.customAITextureFilename = fname
                viewModel.photoboothStripConfig.frameStyle = .customAITexture
                aiFeedbackMessage = "Đã áp dụng khung mẫu '\(preset.displayTitle)' qua \(result.backendUsed)."
            } else {
                aiFeedbackMessage = assetManager.lastStatusMessage
            }
        }
    }

    private func runStylizeBoothSlots() {
        aiFeedbackMessage = nil
        isStylizingSlots = true
        let targetStyle = selectedAIPortraitStyle
        Task {
            var updatedCount = 0
            var firstError: String? = nil
            for i in 0..<viewModel.photoboothSlots.count {
                guard var slot = viewModel.photoboothSlots[i] else { continue }
                let res = await assetManager.stylizeBoothPhotoWithAI(slot.originalImage, style: targetStyle)
                if let outCG = res.image {
                    slot.aiStyledImage = outCG
                    slot.isAIStyleActive = true
                    viewModel.photoboothSlots[i] = slot
                    updatedCount += 1
                } else if firstError == nil {
                    firstError = res.errorMessage
                    break
                }
            }
            isStylizingSlots = false
            if updatedCount > 0 {
                baseStripRevision &+= 1
                aiFeedbackMessage = "Đã chuyển đổi \(updatedCount) khung sang \(targetStyle.displayName)."
            } else {
                aiFeedbackMessage = firstError ?? "Không thể chuyển đổi phong cách AI lúc này."
            }
        }
    }

    private func saveStrip() {
        isSavingStrip = true
        viewModel.savePhotoboothStripToLibrary { success in
            isSavingStrip = false
            if success {
                withAnimation(.easeInOut(duration: 0.2)) {
                    justSavedStrip = true
                }
            } else {
                aiFeedbackMessage = "Chưa có quyền lưu ảnh hoặc bộ nhớ bận."
            }
        }
    }

    private func prepareShareStrip() {
        if let cg = viewModel.renderFinalPhotoboothStrip() {
            shareImage = UIImage(cgImage: cg)
            showShareSheet = true
        }
    }

    private static func normalizedUprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

// MARK: - Interactive Sticker Gesture Overlay (Drag, Pinch Scale, Rotate, Duplicate, Delete)

private struct InteractiveStickerView: View {
    @Binding var sticker: PlacedPhotoboothSticker
    let stripSize: CGSize
    @ObservedObject var assetManager: PhotoboothAssetManager
    let isSelected: Bool
    let interactionEnabled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var dragStartNorm: CGPoint? = nil
    @State private var scaleStart: CGFloat? = nil
    @State private var rotStart: Double? = nil

    var body: some View {
        let widthPx = max(24.0, stripSize.width * sticker.scale)
        let img = assetManager.cachedImage(for: sticker.assetSource, id: sticker.assetID)

        ZStack {
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: widthPx)
                    .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1.5)
            } else {
                ProgressView()
                    .frame(width: widthPx, height: widthPx)
            }
        }
        .padding(8)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.88), style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
                    .overlay(alignment: .topTrailing) {
                        Button(action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black))
                        }
                        .offset(x: 7, y: -7)
                    }
                    .overlay(alignment: .topLeading) {
                        Button(action: onDuplicate) {
                            Image(systemName: "plus.square.on.square.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black))
                        }
                        .offset(x: -7, y: -7)
                    }
            }
        }
        .rotationEffect(.degrees(sticker.rotationDegrees))
        .position(x: sticker.normalizedX * stripSize.width, y: sticker.normalizedY * stripSize.height)
        .allowsHitTesting(interactionEnabled)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    onSelect()
                    if dragStartNorm == nil {
                        dragStartNorm = CGPoint(x: sticker.normalizedX, y: sticker.normalizedY)
                    }
                    guard let base = dragStartNorm else { return }
                    let nx = base.x + val.translation.width / max(1.0, stripSize.width)
                    let ny = base.y + val.translation.height / max(1.0, stripSize.height)
                    sticker.normalizedX = max(0.03, min(0.97, nx))
                    sticker.normalizedY = max(0.03, min(0.97, ny))
                }
                .onEnded { _ in
                    dragStartNorm = nil
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { val in
                    onSelect()
                    if scaleStart == nil { scaleStart = sticker.scale }
                    if let base = scaleStart {
                        sticker.scale = max(0.08, min(0.65, base * val))
                    }
                }
                .onEnded { _ in scaleStart = nil }
        )
        .simultaneousGesture(
            RotateGesture()
                .onChanged { value in
                    onSelect()
                    if rotStart == nil { rotStart = sticker.rotationDegrees }
                    if let base = rotStart {
                        sticker.rotationDegrees = base + value.rotation.degrees
                    }
                }
                .onEnded { _ in rotStart = nil }
        )
        .onTapGesture {
            onSelect()
        }
    }
}

private struct PhotoboothShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Calm Photobooth 9:16 Video Preview & Export Sheet (Mặc định tốc độ 2x chậm rãi mượt mà, 720p@24fps dựng nhanh)
private struct PhotoboothTimelapsePreviewSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var assetManager: PhotoboothAssetManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStyle: PhotoboothTimelapseStyle = .movingStrip
    @State private var selectedSpeed: PhotoboothTimelapseSpeed = .x2
    @State private var isRendering: Bool = true
    @State private var renderProgress: Double = 0.0
    @State private var exportedVideoURL: URL? = nil
    @State private var player: AVPlayer? = nil
    @State private var errorMessage: String? = nil
    @State private var isSavingVideo: Bool = false
    @State private var hasSavedVideo: Bool = false
    @State private var showShareSheet: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 14) {
                    // Calm 3-Element Header
                    HStack {
                        Button(action: {
                            player?.pause()
                            dismiss()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.white.opacity(0.09)))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        VStack(spacing: 2) {
                            Text("Video Photobooth")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Text("9:16 HD · 24 fps")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.50))
                        }

                        Spacer()

                        Color.clear.frame(width: 34, height: 34)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    // 9:16 Video Player Viewport
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                            )

                        if let player, !isRendering {
                            VideoPlayer(player: player)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onAppear { player.play() }
                        } else if isRendering {
                            VStack(spacing: 10) {
                                ProgressView(value: renderProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                                    .tint(.white)
                                    .frame(width: 170)
                                Text("Đang dựng video \(Int(round(renderProgress * 100)))%...")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(24)
                        } else if let errorMessage {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white.opacity(0.75))
                                Text(errorMessage)
                                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                                    .foregroundColor(.white.opacity(0.82))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        }
                    }
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 22)

                    // Minimal Monochrome Controls
                    VStack(spacing: 12) {
                        HStack(spacing: 6) {
                            ForEach(PhotoboothTimelapseStyle.allCases) { st in
                                let isSel = selectedStyle == st
                                Button(action: {
                                    guard selectedStyle != st else { return }
                                    selectedStyle = st
                                    regenerateVideo()
                                }) {
                                    Text(st.rawValue)
                                        .font(.system(size: 12, weight: isSel ? .semibold : .regular, design: .rounded))
                                        .foregroundColor(isSel ? .black : .white.opacity(0.78))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 34)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(isSel ? Color.white : Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRendering)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Tốc độ")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.58))

                            Spacer()

                            ForEach(PhotoboothTimelapseSpeed.allCases) { spd in
                                let isSel = selectedSpeed == spd
                                Button(action: {
                                    guard selectedSpeed != spd else { return }
                                    selectedSpeed = spd
                                    regenerateVideo()
                                }) {
                                    Text(spd.label)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(isSel ? .black : .white.opacity(0.80))
                                        .padding(.horizontal, 14)
                                        .frame(height: 30)
                                        .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRendering)
                            }
                        }

                        HStack(spacing: 10) {
                            Button(action: saveVideoToPhotos) {
                                HStack(spacing: 6) {
                                    if isSavingVideo {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: hasSavedVideo ? "checkmark" : "square.and.arrow.down")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    Text(hasSavedVideo ? "Đã lưu Video" : "Lưu Video")
                                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                }
                                .foregroundColor(hasSavedVideo ? .white : .black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(hasSavedVideo ? Color(red: 0.20, green: 0.62, blue: 0.34) : Color.white)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRendering || exportedVideoURL == nil || isSavingVideo)

                            Button(action: { showShareSheet = true }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 13.5, weight: .semibold))
                                    Text("Chia sẻ")
                                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.11))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRendering || exportedVideoURL == nil)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onAppear {
                regenerateVideo()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                guard let finishedItem = notification.object as? AVPlayerItem,
                      finishedItem == player?.currentItem else { return }
                player?.seek(to: .zero)
                player?.play()
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedVideoURL {
                    PhotoboothShareSheet(items: [url])
                }
            }
        }
    }

    private func regenerateVideo() {
        player?.pause()
        player = nil
        isRendering = true
        hasSavedVideo = false
        renderProgress = 0.02
        errorMessage = nil

        let slots = viewModel.photoboothSlots
        let config = viewModel.photoboothStripConfig
        let stickers = viewModel.photoboothPlacedStickers
        let recorded = PhotoboothTimelapseRecorder.shared.snapshotFramesBySlot()
        let style = selectedStyle
        let speed = selectedSpeed

        Task {
            do {
                let url = try await PhotoboothTimelapseExporter.exportTimelapseVideo(
                    slots: slots,
                    config: config,
                    stickers: stickers,
                    assetManager: assetManager,
                    recordedFramesBySlot: recorded,
                    style: style,
                    speed: speed
                ) { pct in
                    self.renderProgress = pct
                }
                await MainActor.run {
                    self.exportedVideoURL = url
                    let avPlayer = AVPlayer(url: url)
                    self.player = avPlayer
                    self.isRendering = false
                    avPlayer.play()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRendering = false
                }
            }
        }
    }

    private func saveVideoToPhotos() {
        guard let url = exportedVideoURL else { return }
        isSavingVideo = true
        viewModel.savePhotoboothTimelapseVideoToLibrary(url: url) { ok in
            isSavingVideo = false
            hasSavedVideo = ok
        }
    }
}
