import SwiftUI
import UIKit
import PhotosUI
import AVKit
import AVFoundation

private enum PhotoboothEditorTab: String, CaseIterable, Identifiable {
    case frames = "Khung"
    case stickers = "Sticker"
    case aiStudio = "AI Studio"
    case printMeta = "In & Chữ"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .frames: return "photo.artframe"
        case .stickers: return "sparkles"
        case .aiStudio: return "wand.and.stars"
        case .printMeta: return "printer"
        }
    }
}

/// Studio Trang Trí & Xuất In Photobooth 300 DPI:
/// - Chạm khung ảnh để Chụp lại / Đổi ảnh từ Thư viện / Lật gương / Đổi sang chân dung AI / Tách chủ thể làm sticker
/// - Kho Sticker 24 hình đóng gói sẵn + 36+ gói tải Online + Tạo Sticker AI + Tạo Khung AI đồng bộ màu trang phục
/// - Tương tác kéo / phóng to / xoay / nhân bản / xóa sticker mượt mà trên nền dải ảnh thật
public struct PhotoboothEditorSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var assetManager = PhotoboothAssetManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: PhotoboothEditorTab = .frames
    @State private var selectedStickerID: UUID? = nil
    @State private var selectedSlotForAction: Int? = nil
    @State private var showSlotActionDialog: Bool = false
    @State private var showReplacePhotoPicker: Bool = false
    @State private var replacePhotoItem: PhotosPickerItem? = nil

    // Sticker browser sub-tabs
    @State private var stickerCategory: PhotoboothAssetCategory = .coquette
    @State private var selectedOnlinePack: PhotoboothOnlinePackCategory = .bowsPastel

    // AI Studio prompts & status
    @State private var aiStickerPrompt: String = ""
    @State private var aiFramePrompt: String = ""
    @State private var selectedAIPortraitStyle: PhotoboothAIStylePreset = .koreanStudio
    @State private var aiFeedbackMessage: String? = nil
    @State private var isStylizingSlots: Bool = false

    // Saving / Sharing / 9:16 Timelapse Video
    @State private var isSavingStrip: Bool = false
    @State private var shareImage: UIImage? = nil
    @State private var showShareSheet: Bool = false
    @State private var showTimelapseSheet: Bool = false

    // 120Hz Cached Base Strip Preview + On-Device Vision Semantic Face/Space Anchors
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
                Color(red: 0.045, green: 0.047, blue: 0.056).ignoresSafeArea()

                VStack(spacing: 0) {
                    editorHeaderBar

                    interactiveStripCanvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)

                    bottomStudioToolbox
                }

                if isSavingStrip || assetManager.isGeneratingAI || isStylizingSlots {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                                .scaleEffect(1.15)
                            Text(isSavingStrip ? "Đang xuất bản in 300 DPI..." : "Đang xử lý tài nguyên Studio AI...")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.7))
                        )
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Tùy chỉnh Khung ảnh #\(selectedSlotForAction.map { $0 + 1 } ?? 1)",
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
                        Button("Tách người / vật làm Sticker viền trắng") {
                            Task {
                                if let created = await assetManager.createCutoutStickerFromPhoto(slot.displayImage, title: "Tự tách #\(idx + 1)") {
                                    placeSticker(created)
                                    withAnimation { activeTab = .stickers; stickerCategory = .myStickers }
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
                rebuildBaseStripPreviewCache()
                refreshVisionSlotAnchors()
            }
            .onChangeCompatible(of: baseStripRevision) { _ in
                rebuildBaseStripPreviewCache()
                refreshVisionSlotAnchors()
            }
        }
    }

    // MARK: - 1. Top Editor Bar

    private var editorHeaderBar: some View {
        HStack(spacing: 10) {
            Button(action: {
                viewModel.isShowingPhotoboothEditor = false
                dismiss()
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button(action: {
                viewModel.resetPhotoboothSession()
                viewModel.isShowingPhotoboothEditor = false
                dismiss()
            }) {
                Text("Chụp mới")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Spacer()

            // Nút xem & xuất Video Tua Nhanh Hậu Trường 9:16 kiểu Life4Cuts / Reels
            Button(action: {
                HapticFeedbackService.shared.triggerLight()
                showTimelapseSheet = true
            }) {
                HStack(spacing: 4.5) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Video")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
                .foregroundColor(AlignTheme.studioAccent)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioAccentSoft)
                        .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.7))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.photoboothFilledCount == 0)
            .accessibilityLabel("Xem video tua nhanh quá trình chụp")

            Button(action: prepareShareStrip) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button(action: saveStrip) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .bold))
                    Text("Lưu Ảnh")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(AlignTheme.studioAccent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 2. Interactive Live Print Strip Preview Canvas

    private var interactiveStripCanvasArea: some View {
        let stripAspect = viewModel.photoboothStripConfig.layout.aspectRatio

        return GeometryReader { geo in
            let availW = max(1, geo.size.width)
            let availH = max(1, geo.size.height)
            let stripW = min(availW, availH * stripAspect)
            let stripH = stripW / max(0.2, stripAspect)
            let stripSize = CGSize(width: stripW, height: stripH)
            let slotRects = viewModel.photoboothStripConfig.layout.slotRects(
                in: stripSize,
                marginScale: viewModel.photoboothStripConfig.marginScale
            )

            // Sử dụng ảnh dải nền đã cache trong @State để kéo/phóng/xoay sticker mượt 120Hz không giật
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedStickerID = nil
                    }

                ZStack {
                    if let cachedBaseStripImage {
                        Image(uiImage: cachedBaseStripImage)
                            .resizable()
                            .frame(width: stripSize.width, height: stripSize.height)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: stripSize.width, height: stripSize.height)
                    }

                    // Interactive tap hit targets trên từng ô ảnh
                    ForEach(Array(slotRects.enumerated()), id: \.offset) { idx, r in
                        Color.clear
                            .frame(width: r.width, height: r.height)
                            .contentShape(Rectangle())
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture {
                                selectedStickerID = nil
                                selectedSlotForAction = idx
                                showSlotActionDialog = true
                            }
                    }

                    // Interactive Draggable / Pinchable / Rotatable Stickers Layer
                    ForEach($viewModel.photoboothPlacedStickers) { $sticker in
                        InteractiveStickerView(
                            sticker: $sticker,
                            stripSize: stripSize,
                            assetManager: assetManager,
                            isSelected: selectedStickerID == sticker.id,
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
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: Color.black.opacity(0.55), radius: 18, y: 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 3. Bottom Studio Toolbox

    private var bottomStudioToolbox: some View {
        VStack(spacing: 0) {
            // Segmented Tabs
            HStack(spacing: 4) {
                ForEach(PhotoboothEditorTab.allCases) { tab in
                    let isSel = activeTab == tab
                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                            activeTab = tab
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: isSel ? .bold : .medium, design: .rounded))
                        }
                        .foregroundColor(isSel ? .black : .white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Capsule().fill(isSel ? AlignTheme.studioAccent : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Active Tab Content (Compact Fixed Studio Height ~218pt)
            Group {
                switch activeTab {
                case .frames:
                    framesTabPanel
                case .stickers:
                    stickersTabPanel
                case .aiStudio:
                    aiStudioTabPanel
                case .printMeta:
                    printMetaTabPanel
                }
            }
            .frame(height: 215)
        }
        .background(
            Color(red: 0.085, green: 0.088, blue: 0.102)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.6)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Tab 1: Layout + 16 Editorial Frames + Harmony Auto Color

    private var framesTabPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Layout strip row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoboothLayout.allCases) { lay in
                        let isSel = viewModel.photoboothStripConfig.layout == lay
                        Button(action: {
                            viewModel.selectPhotoboothLayout(lay)
                        }) {
                            Text(lay.shortBadge)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: applyAutoOutfitColor) {
                        HStack(spacing: 4) {
                            Image(systemName: "eyedropper.halffull")
                                .font(.system(size: 11, weight: .bold))
                            Text("Khớp màu trang phục")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(
                            Capsule()
                                .fill(AlignTheme.studioAccentSoft)
                                .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.7))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            }

            // 16 Editorial Frame Swatches
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PhotoboothFrameStyle.allCases) { frame in
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
                                    withAnimation { activeTab = .aiStudio }
                                }
                            }
                        }) {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: frame.swatchColors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 56, height: 76)

                                    if frame == .kodak35mmSprocket {
                                        VStack(spacing: 8) {
                                            ForEach(0..<4, id: \.self) { _ in
                                                HStack {
                                                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.65)).frame(width: 4, height: 6)
                                                    Spacer()
                                                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.65)).frame(width: 4, height: 6)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 4)
                                    } else if frame == .customAITexture {
                                        Image(systemName: "wand.and.stars")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(isSel ? AlignTheme.studioAccent : Color.white.opacity(0.18), lineWidth: isSel ? 2.2 : 0.7)
                                )

                                Text(frame.displayName)
                                    .font(.system(size: 10, weight: isSel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSel ? AlignTheme.studioAccent : .white.opacity(0.75))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Tab 2: Stickers (24 Bundled + 48 Live Online Packs + Vision Smart Placement + Custom AI/Cutouts)

    private var stickersTabPanel: some View {
        let detectedFaceTotal = slotSemanticMaps.reduce(0) { $0 + $1.faces.count }

        return VStack(spacing: 6.5) {
            // Dải AI Vision Tự Dán Thông Minh Đa Vùng (Đỉnh đầu · Mắt · Kẹp tóc · Gò má · Vai · Góc trống không che mặt)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(action: {
                        isSmartAnchorEnabled.toggle()
                        HapticFeedbackService.shared.triggerSelectionChange()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isSmartAnchorEnabled ? "face.smiling.inverse" : "hand.draw")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(isSmartAnchorEnabled
                                ? (detectedFaceTotal > 0 ? "AI Neo (\(detectedFaceTotal) mặt)" : "AI Neo góc trống")
                                : "Đặt tự do")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(isSmartAnchorEnabled ? .black : .white.opacity(0.78))
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(Capsule().fill(isSmartAnchorEnabled ? AlignTheme.studioAccent : Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    ForEach(PhotoboothAutoDecorateStyle.allCases) { autoStyle in
                        Button(action: {
                            applySmartAutoDecorate(style: autoStyle)
                        }) {
                            HStack(spacing: 3.5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text(autoStyle.rawValue)
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioAccent)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(
                                Capsule()
                                    .fill(AlignTheme.studioAccentSoft)
                                    .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.65))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isAnalyzingFaces)
                    }

                    if !viewModel.photoboothPlacedStickers.isEmpty {
                        Button(action: {
                            viewModel.photoboothPlacedStickers.removeAll()
                            selectedStickerID = nil
                            HapticFeedbackService.shared.triggerLight()
                        }) {
                            Text("Xóa hết")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 9)
                                .frame(height: 25)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            // Category pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoboothAssetCategory.allCases) { cat in
                        let isSel = stickerCategory == cat
                        Button(action: {
                            stickerCategory = cat
                        }) {
                            Text(cat.rawValue)
                                .font(.system(size: 11, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSel ? .black : .white.opacity(0.80))
                                .padding(.horizontal, 11)
                                .frame(height: 28)
                                .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

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
                        Text("Chưa có sticker AI hoặc sticker tự tách nền.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.62))
                        Button(action: {
                            withAnimation { activeTab = .aiStudio }
                        }) {
                            Text("Mở AI Studio để tạo ngay")
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Capsule().fill(AlignTheme.studioAccent))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(items) { asset in
                                stickerGridTile(asset)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .padding(.top, 4)
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
                                .font(.system(size: 10.5, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSel ? AlignTheme.studioAccent : .white.opacity(0.75))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(
                                    Capsule()
                                        .fill(isSel ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                                        .overlay(Capsule().stroke(isSel ? AlignTheme.studioAccentBorder : Color.clear, lineWidth: 0.7))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: {
                        Task { _ = await assetManager.downloadOnlinePack(selectedOnlinePack) }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: assetManager.isDownloadingPack == selectedOnlinePack ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                                .font(.system(size: 11))
                            Text(assetManager.isDownloadingPack == selectedOnlinePack ? "Đang tải..." : "Tải cả gói")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(AlignTheme.studioAccent))
                    }
                    .buttonStyle(.plain)
                    .disabled(assetManager.isDownloadingPack != nil)
                }
                .padding(.horizontal, 14)
            }

            let packItems = assetManager.onlineStickers.filter { $0.onlinePack == selectedOnlinePack }
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(packItems) { asset in
                        stickerGridTile(asset)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
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
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
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
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 62)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 3: In-App AI Studio (Tạo Sticker AI + Tạo Khung AI + Đổi Chân Dung Booth AI)

    private var aiStudioTabPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                if let msg = aiFeedbackMessage ?? assetManager.lastStatusMessage {
                    Text(msg)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AlignTheme.studioAccentSoft))
                }

                // 1. Tạo Sticker AI nền trong suốt
                VStack(alignment: .leading, spacing: 6) {
                    Text("TẠO STICKER AI NỀN TRONG SUỐT")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 8) {
                        TextField("vd: chú mèo đeo kính râm, nơ bạc...", text: $aiStickerPrompt)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))

                        Button(action: runGenerateAISticker) {
                            Text("Tạo")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 10).fill(AlignTheme.studioAccent))
                        }
                        .buttonStyle(.plain)
                        .disabled(aiStickerPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // 2. Tạo Nền Khung AI sạch chữ, khớp trang phục
                VStack(alignment: .leading, spacing: 6) {
                    Text("TẠO NỀN KHUNG IN AI (KHÔNG RÁC CHỮ)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 8) {
                        TextField("vd: lụa pastel tối giản, hoa cúc nhẹ...", text: $aiFramePrompt)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))

                        Button(action: runGenerateAIFrame) {
                            Text("Áp khung")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        }
                        .buttonStyle(.plain)
                        .disabled(aiFramePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // 3. Biến ảnh chụp Photobooth thành chân dung Studio AI (Gemini Image-to-Image)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CHUYỂN CHÂN DUNG BOOTH BẰNG AI")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.62))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PhotoboothAIStylePreset.allCases) { st in
                                let isSel = selectedAIPortraitStyle == st
                                Button(action: { selectedAIPortraitStyle = st }) {
                                    Text(st.displayName)
                                        .font(.system(size: 11, weight: isSel ? .bold : .medium, design: .rounded))
                                        .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                        .padding(.horizontal, 10)
                                        .frame(height: 28)
                                        .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button(action: runStylizeBoothSlots) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 12, weight: .bold))
                            Text("Biến đổi các ảnh đang chụp thành \(selectedAIPortraitStyle.displayName)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.photoboothFilledCount == 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Tab 4: Print & Typography Options

    private var printMetaTabPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CHỮ KÝ CHÂN TRANG IN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.62))

                    TextField("ALIGN STUDIO", text: $viewModel.photoboothStripConfig.customCaption)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
                }

                Toggle(isOn: $viewModel.photoboothStripConfig.showDateStamp) {
                    Text("In dấu ngày ở chân dải ảnh")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                }
                .tint(AlignTheme.studioAccent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CHẤT LIỆU GIẤY IN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 8) {
                        ForEach(PhotoboothPaperFinish.allCases) { finish in
                            let isSel = viewModel.photoboothStripConfig.paperFinish == finish
                            Button(action: {
                                viewModel.photoboothStripConfig.paperFinish = finish
                            }) {
                                Text(finish.displayName)
                                    .font(.system(size: 12, weight: isSel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Interactive Logic Helpers

    private func rebuildBaseStripPreviewCache() {
        let stripCG = PhotoboothStripRenderer.renderStrip(
            slots: viewModel.photoboothSlots,
            config: viewModel.photoboothStripConfig,
            stickers: [],
            assetManager: assetManager,
            targetWidth: 720
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
        aiFeedbackMessage = nil
        Task {
            let result = await assetManager.generateAISticker(prompt: prompt)
            if let created = result.asset {
                placeSticker(created)
                aiStickerPrompt = ""
                aiFeedbackMessage = "Đã tạo sticker bằng \(result.backendUsed) và đặt lên khung!"
            } else {
                aiFeedbackMessage = assetManager.lastStatusMessage
            }
        }
    }

    private func runGenerateAIFrame() {
        let prompt = aiFramePrompt
        aiFeedbackMessage = nil
        let slotImgs = viewModel.photoboothSlots.compactMap { $0?.displayImage }
        Task {
            let result = await assetManager.generateAIFrameTexture(prompt: prompt, slotImages: slotImgs)
            if let fname = result.filename {
                viewModel.photoboothStripConfig.customBackgroundHex = nil
                viewModel.photoboothStripConfig.customAITextureFilename = fname
                viewModel.photoboothStripConfig.frameStyle = .customAITexture
                aiFramePrompt = ""
                aiFeedbackMessage = "Đã áp dụng khung nền từ \(result.backendUsed)!"
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
                aiFeedbackMessage = "Đã chuyển đổi \(updatedCount) khung sang phong cách \(targetStyle.displayName)!"
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
                aiFeedbackMessage = "Đã lưu bản in 300 DPI vào Thư viện Ảnh!"
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AlignTheme.studioAccent, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
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
                                .foregroundColor(AlignTheme.studioAccent)
                                .background(Circle().fill(Color.black))
                        }
                        .offset(x: -7, y: -7)
                    }
            }
        }
        .rotationEffect(.degrees(sticker.rotationDegrees))
        .position(x: sticker.normalizedX * stripSize.width, y: sticker.normalizedY * stripSize.height)
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

// MARK: - Photobooth 9:16 Behind-the-Scenes Timelapse Video Preview & Social Export Sheet
private struct PhotoboothTimelapsePreviewSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var assetManager: PhotoboothAssetManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedStyle: PhotoboothTimelapseStyle = .movingStrip
    @State private var selectedSpeed: PhotoboothTimelapseSpeed = .x3
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
                Color(red: 0.04, green: 0.042, blue: 0.052).ignoresSafeArea()

                VStack(spacing: 12) {
                    // Header Bar
                    HStack {
                        Button(action: {
                            player?.pause()
                            dismiss()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        VStack(spacing: 2) {
                            Text("Video Tua Nhanh Photobooth")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("9:16 Full HD · Sẵn sàng đăng TikTok / Reels")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.58))
                        }

                        Spacer()

                        Color.clear.frame(width: 34, height: 34)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    // 9:16 Video Player Viewport
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                            )

                        if let player, !isRendering {
                            VideoPlayer(player: player)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .onAppear { player.play() }
                        } else if isRendering {
                            VStack(spacing: 12) {
                                ProgressView(value: renderProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                                    .tint(AlignTheme.studioAccent)
                                    .frame(width: 180)
                                Text("Đang dựng video tua nhanh \(Int(round(renderProgress * 100)))%...")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text("Ghép khung in thật + sticker + quá trình tạo dáng")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.58))
                            }
                            .padding(24)
                        } else if let errorMessage {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(AlignTheme.studioAccent)
                                Text(errorMessage)
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.85))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        }
                    }
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 20)

                    // Style & Speed Controls
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(PhotoboothTimelapseStyle.allCases) { st in
                                let isSel = selectedStyle == st
                                Button(action: {
                                    guard selectedStyle != st else { return }
                                    selectedStyle = st
                                    regenerateVideo()
                                }) {
                                    Text(st.rawValue)
                                        .font(.system(size: 11.5, weight: isSel ? .bold : .medium, design: .rounded))
                                        .foregroundColor(isSel ? .black : .white.opacity(0.82))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 32)
                                        .background(Capsule().fill(isSel ? Color.white : Color.white.opacity(0.09)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRendering)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Tốc độ tua")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.65))

                            Spacer()

                            ForEach(PhotoboothTimelapseSpeed.allCases) { spd in
                                let isSel = selectedSpeed == spd
                                Button(action: {
                                    guard selectedSpeed != spd else { return }
                                    selectedSpeed = spd
                                    regenerateVideo()
                                }) {
                                    Text(spd.label)
                                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(isSel ? .black : .white.opacity(0.84))
                                        .padding(.horizontal, 14)
                                        .frame(height: 28)
                                        .background(Capsule().fill(isSel ? AlignTheme.studioAccent : Color.white.opacity(0.09)))
                                }
                                .buttonStyle(.plain)
                                .disabled(isRendering)
                            }
                        }

                        // Save & Share Actions
                        HStack(spacing: 10) {
                            Button(action: saveVideoToPhotos) {
                                HStack(spacing: 6) {
                                    if isSavingVideo {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: hasSavedVideo ? "checkmark" : "square.and.arrow.down")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    Text(hasSavedVideo ? "Đã lưu Video" : "Lưu Video")
                                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(hasSavedVideo ? .white : .black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Capsule().fill(hasSavedVideo ? Color.green.opacity(0.78) : AlignTheme.studioAccent))
                            }
                            .buttonStyle(.plain)
                            .disabled(isRendering || exportedVideoURL == nil || isSavingVideo)

                            Button(action: { showShareSheet = true }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 13.5, weight: .bold))
                                    Text("Đăng MXH")
                                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 44)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.13))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
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
