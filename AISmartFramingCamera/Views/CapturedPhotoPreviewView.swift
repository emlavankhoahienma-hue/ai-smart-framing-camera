import SwiftUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO

// MARK: - Edit Drawer Tabs & Detail Levels
private enum PhotoEditPanelTab: String, CaseIterable, Identifiable {
    case film = "Màu phim"
    case detail = "Độ nét"
    case frame = "Khung ảnh"

    var id: String { rawValue }
}

private enum PhotoMicroDetailLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case natural = 1
    case ultra = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Gốc"
        case .natural: return "Tự nhiên"
        case .ultra: return "Ultra Nét"
        }
    }

    var unsharpIntensity: Float {
        switch self {
        case .off: return 0.0
        case .natural: return 0.34
        case .ultra: return 0.62
        }
    }

    var luminanceSharpness: Float {
        switch self {
        case .off: return 0.0
        case .natural: return 0.22
        case .ultra: return 0.45
        }
    }

    var microContrast: Float {
        switch self {
        case .off: return 1.0
        case .natural: return 1.022
        case .ultra: return 1.042
        }
    }
}

// MARK: - Real RGB + Luminance Histogram Snapshot (Shown Cleanly Inside Info Sheet)
private struct PhotoDetailHistogramSnapshot: Sendable {
    let lumaBins: [Double]
    let redBins: [Double]
    let greenBins: [Double]
    let blueBins: [Double]
    let meanLuminance: Double
    let shadowClipPercent: Double
    let highlightClipPercent: Double

    static let empty = PhotoDetailHistogramSnapshot(
        lumaBins: Array(repeating: 0.05, count: 48),
        redBins: Array(repeating: 0.05, count: 48),
        greenBins: Array(repeating: 0.05, count: 48),
        blueBins: Array(repeating: 0.05, count: 48),
        meanLuminance: 0.5,
        shadowClipPercent: 0.0,
        highlightClipPercent: 0.0
    )

    static func compute(from cgImage: CGImage, binCount: Int = 48) -> PhotoDetailHistogramSnapshot {
        let sampleW = min(256, max(32, cgImage.width / 8))
        let sampleH = min(256, max(32, cgImage.height / 8))
        let bytesPerRow = sampleW * 4
        var raw = [UInt8](repeating: 0, count: sampleH * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: &raw,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .empty
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var lHist = [Double](repeating: 0, count: binCount)
        var rHist = [Double](repeating: 0, count: binCount)
        var gHist = [Double](repeating: 0, count: binCount)
        var bHist = [Double](repeating: 0, count: binCount)

        let totalPixels = sampleW * sampleH
        guard totalPixels > 0 else { return .empty }
        var lumaSum = 0.0
        var shadowClip = 0
        var highlightClip = 0
        let scale = Double(binCount - 1) / 255.0

        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Double(raw[offset])
            let g = Double(raw[offset + 1])
            let b = Double(raw[offset + 2])
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b

            lumaSum += y / 255.0
            if y <= 4.0 { shadowClip += 1 }
            if y >= 251.0 { highlightClip += 1 }

            rHist[max(0, min(binCount - 1, Int((r * scale).rounded())))] += 1
            gHist[max(0, min(binCount - 1, Int((g * scale).rounded())))] += 1
            bHist[max(0, min(binCount - 1, Int((b * scale).rounded())))] += 1
            lHist[max(0, min(binCount - 1, Int((y * scale).rounded())))] += 1
        }

        func normalize(_ arr: [Double]) -> [Double] {
            let interiorMax = arr.dropFirst().dropLast().max() ?? 1.0
            let peak = max(1.0, max(interiorMax, (arr.max() ?? 1.0) * 0.65))
            return arr.map { min(1.0, max(0.03, pow($0 / peak, 0.72))) }
        }

        return PhotoDetailHistogramSnapshot(
            lumaBins: normalize(lHist),
            redBins: normalize(rHist),
            greenBins: normalize(gHist),
            blueBins: normalize(bHist),
            meanLuminance: lumaSum / Double(totalPixels),
            shadowClipPercent: (Double(shadowClip) / Double(totalPixels)) * 100.0,
            highlightClipPercent: (Double(highlightClip) / Double(totalPixels)) * 100.0
        )
    }
}

// MARK: - Clean Minimalist Photo Detail View (Calm, Spacious, Uncluttered Form)
public struct CapturedPhotoPreviewView: View {
    public let item: CapturedPhotoItem
    public var viewModel: CameraViewModel?
    @Environment(\.dismiss) private var dismiss

    // Non-destructive Editing States
    @State private var currentProcessedImage: CGImage
    @State private var activePreset: FilmPreset
    @State private var activeFilmIntensity: Double = 1.0
    @State private var selectedCategory: FilmPresetCategory
    @State private var isAIEnhanced: Bool = false
    @State private var activeAIColorParams: AIColorParameters? = nil
    @State private var microDetailLevel: PhotoMicroDetailLevel = .off
    @State private var isMasterFrameApplied: Bool = false
    @State private var masterFrameTheme: WatermarkTheme = .white
    @State private var masterFrameLogo: WatermarkLogoStyle = .alignStudio

    // Quiet Drawer & Info Sheet States (Both Closed by Default so Photo Shines!)
    @State private var isEditDrawerOpen: Bool = false
    @State private var selectedEditTab: PhotoEditPanelTab = .film
    @State private var isShowingInfoSheet: Bool = false
    @State private var histogramSnapshot: PhotoDetailHistogramSnapshot = .empty

    @State private var isProcessingFilter: Bool = false
    @State private var isSavingToLibrary: Bool = false
    @State private var hasSavedNewEnhancement: Bool = false

    // Pre-decoded Display & Mini-Map Image Caches (Zero per-frame 48MP decoding or main-thread HEIC export!)
    @State private var cachedFullResUIImage: UIImage
    @State private var cachedDisplayUIImage: UIImage
    @State private var cachedOriginalDisplayUIImage: UIImage
    @State private var cachedMiniMapUIImage: UIImage
    @State private var isHistogramStale: Bool = true
    @State private var cachedShareURL: URL? = nil
    @State private var isPreparingShare: Bool = false
    @State private var isShowingShareSheet: Bool = false

    // Comparison & Zoom States
    @State private var isSplitCompareMode: Bool = false
    @State private var splitRatio: CGFloat = 0.5
    @State private var isPeekingOriginal: Bool = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissDragOffsetY: CGFloat = 0.0

    private static let detailCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true,
        .cacheIntermediates: false
    ])

    public init(item: CapturedPhotoItem, viewModel: CameraViewModel? = nil) {
        self.item = item
        self.viewModel = viewModel
        _currentProcessedImage = State(initialValue: item.processedImage)
        let initialDisplayUI: UIImage
        let initialOriginalUI: UIImage
        let initialMiniUI: UIImage
        if let preDisplay = item.predecodedDisplayImage {
            initialDisplayUI = preDisplay
            initialOriginalUI = item.predecodedOriginalDisplayImage ?? preDisplay
            initialMiniUI = item.predecodedMiniMapImage ?? preDisplay
        } else {
            let initSpan = CameraLogger.beginTrace(
                "PREVIEW_INIT_DOWNSAMPLE_FALLBACK",
                detail: "src=\(item.processedImage.width)x\(item.processedImage.height)",
                category: .capture
            )
            initialDisplayUI = Self.downsampleForFastDisplay(item.processedImage, maxSide: 1600)
            initialOriginalUI = (item.originalImage === item.processedImage)
                ? initialDisplayUI
                : Self.downsampleForFastDisplay(item.originalImage, maxSide: 1600)
            initialMiniUI = Self.downsampleForFastDisplay(item.processedImage, maxSide: 220)
            CameraLogger.endTrace(initSpan, detail: "disp=\(Int(initialDisplayUI.size.width))x\(Int(initialDisplayUI.size.height))")
        }
        _cachedFullResUIImage = State(initialValue: initialDisplayUI)
        _cachedDisplayUIImage = State(initialValue: initialDisplayUI)
        _cachedOriginalDisplayUIImage = State(initialValue: initialOriginalUI)
        _cachedMiniMapUIImage = State(initialValue: initialMiniUI)
        _activePreset = State(initialValue: item.appliedPreset)
        _selectedCategory = State(initialValue: item.appliedPreset.category)
        if let vm = viewModel {
            _masterFrameTheme = State(initialValue: vm.masterWatermarkTheme)
            _masterFrameLogo = State(initialValue: vm.masterWatermarkLogoStyle)
        }
    }

    private var hasModifiedSinceOpen: Bool {
        activePreset != item.appliedPreset ||
        abs(activeFilmIntensity - 1.0) > 0.02 ||
        isAIEnhanced ||
        microDetailLevel != .off ||
        isMasterFrameApplied
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.025, green: 0.028, blue: 0.036).ignoresSafeArea()

                VStack(spacing: 0) {
                    cleanTopHeaderBar

                    heroPhotoViewport
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isEditDrawerOpen && item.saveFormat != .dng {
                        compactEditDrawer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    calmBottomActionBar
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .interactiveDismissDisabled(zoomScale > 1.02 || isSplitCompareMode)
            .sheet(isPresented: $isShowingInfoSheet) {
                photoInfoInspectorSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .onAppear {
                        if isHistogramStale {
                            refreshHistogram(for: currentProcessedImage)
                        }
                    }
            }
            .sheet(isPresented: $isShowingShareSheet) {
                if let url = cachedShareURL {
                    CapturedPhotoActivityShareSheet(items: [url])
                }
            }
            .onAppear {
                CameraLogger.lifecycle("VIEW_APPEAR", detail: "CapturedPhotoPreviewView \(item.processedImage.width)x\(item.processedImage.height)", category: .photoKit)
                rebuildDisplayCachesAsync(processed: currentProcessedImage, original: item.originalImage)
            }
            .onDisappear {
                CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "CapturedPhotoPreviewView", category: .photoKit)
            }
            .onChangeCompatible(of: zoomScale > 2.2) { needsFullRes in
                if needsFullRes {
                    cachedFullResUIImage = UIImage(cgImage: currentProcessedImage)
                } else {
                    cachedFullResUIImage = cachedDisplayUIImage
                }
            }
        }
    }

    // MARK: - 1. Clean Top Header Bar (Only Close + Quiet Metadata + Info)
    private var cleanTopHeaderBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng")

            Spacer()

            VStack(spacing: 2) {
                Text("\(formatBadgeTitle) · \(megapixelsString)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text(opticalSummaryLine)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Button(action: {
                isShowingInfoSheet = true
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thông số ảnh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 2. Unobstructed Hero Photo Viewport
    private var heroPhotoViewport: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear

                if isSplitCompareMode && zoomScale <= 1.05 && item.saveFormat != .dng {
                    splitScreenComparisonCanvas(in: geo.size)
                } else {
                    zoomableHeroCanvas(in: geo.size)
                }

                // Subtle Processing Pill
                if isProcessingFilter {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.85)
                        Text("Đang xử lý...")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .transition(.opacity)
                }

                // Only visible while actively peeking original
                if isPeekingOriginal {
                    VStack {
                        Text("ẢNH GỐC")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                            .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Zoom Region Mini-Map (top-leading) + Reset Pill (top-trailing) when zoomed in
                if zoomScale > 1.05 {
                    VStack {
                        HStack(alignment: .top) {
                            zoomRegionMiniMap(viewportSize: geo.size)
                                .padding(.top, 12)
                                .padding(.leading, 14)

                            Spacer()

                            Button(action: {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                                    resetZoomAndPan()
                                }
                            }) {
                                Text(String(format: "%.1fx · Đặt lại", zoomScale))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.black.opacity(0.72)))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.trailing, 14)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func zoomableHeroCanvas(in size: CGSize) -> some View {
        let isZoomedIn = zoomScale > 1.02
        // Sử dụng ảnh đã giải mã trước (<= 2400px) cho 1x..2.3x để kéo/phóng 120Hz siêu mượt,
        // và tự động chuyển sang ảnh full-res đã cache khi zoom sâu (> 2.3x) để soi chi tiết 100%.
        let activeUIImage: UIImage = isPeekingOriginal
            ? cachedOriginalDisplayUIImage
            : (zoomScale > 2.3 ? cachedFullResUIImage : cachedDisplayUIImage)

        // Gắn toàn bộ cử chỉ trên vùng chứa tĩnh (coordinateSpace cố định) để kéo xuống xem vùng trên khi zoom
        // hoàn toàn mượt mà, không bị lệch tọa độ và không bao giờ xung đột với cử chỉ đóng sheet.
        ZStack {
            Color.clear

            Image(uiImage: activeUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(zoomScale)
                .offset(
                    x: panOffset.width,
                    y: isZoomedIn ? panOffset.height : dismissDragOffsetY
                )
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "capturedPhotoHeroSpace")
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { val in
                    let nextScale = min(max(lastZoomScale * val, 1.0), 8.0)
                    zoomScale = nextScale
                    dismissDragOffsetY = 0
                    if nextScale <= 1.02 {
                        panOffset = .zero
                    } else {
                        let scaleRatio = nextScale / max(1.0, lastZoomScale)
                        let scaledPan = CGSize(
                            width: lastPanOffset.width * scaleRatio,
                            height: lastPanOffset.height * scaleRatio
                        )
                        panOffset = clampPanOffset(scaledPan, in: size, scale: nextScale)
                    }
                }
                .onEnded { _ in
                    if zoomScale < 1.05 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            resetZoomAndPan()
                        }
                    } else {
                        lastZoomScale = zoomScale
                        panOffset = clampPanOffset(panOffset, in: size, scale: zoomScale)
                        lastPanOffset = panOffset
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("capturedPhotoHeroSpace"))
                .onChanged { val in
                    if zoomScale > 1.02 {
                        // Đang phóng to: toàn quyền kéo 4 hướng (kéo xuống để xem mép trên ảnh mượt 100%)
                        dismissDragOffsetY = 0
                        let raw = CGSize(
                            width: lastPanOffset.width + val.translation.width,
                            height: lastPanOffset.height + val.translation.height
                        )
                        panOffset = clampPanOffset(raw, in: size, scale: zoomScale)
                    } else if !isEditDrawerOpen && val.translation.height > 12 && abs(val.translation.height) > abs(val.translation.width) * 1.35 {
                        // Chỉ cho vuốt xuống để đóng khi đang ở 1.0x nguyên bản (không zoom)
                        dismissDragOffsetY = max(0, val.translation.height * 0.72)
                    }
                }
                .onEnded { val in
                    if zoomScale > 1.02 {
                        lastPanOffset = panOffset
                    } else if dismissDragOffsetY > 0 {
                        if val.translation.height > 110 || val.predictedEndTranslation.height > 190 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                dismissDragOffsetY = 0
                            }
                        }
                    }
                }
        )
        .highPriorityGesture(
            SpatialTapGesture(count: 2)
                .onEnded { event in
                    dismissDragOffsetY = 0
                    handleDoubleTap(at: event.location, in: size)
                }
        )
        .onLongPressGesture(minimumDuration: 0.28, pressing: { pressing in
            guard item.saveFormat != .dng, zoomScale <= 1.05 else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                isPeekingOriginal = pressing
            }
        }, perform: {})
    }

    @ViewBuilder
    private func splitScreenComparisonCanvas(in size: CGSize) -> some View {
        let splitX = size.width * splitRatio
        ZStack {
            Image(uiImage: cachedDisplayUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Image(uiImage: cachedOriginalDisplayUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().frame(width: splitX)
                        Spacer(minLength: 0)
                    }
                )

            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.8, height: size.height)

                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
            .position(x: splitX, y: size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitRatio = min(max(value.location.x / max(1, size.width), 0.06), 0.94)
                    }
            )
        }
    }

    // MARK: - 3. Optional Compact Edit Drawer (Opens Only On Demand)
    private var compactEditDrawer: some View {
        VStack(spacing: 12) {
            // Quiet Tab Selector + Optional Reset Link
            HStack {
                HStack(spacing: 4) {
                    ForEach(PhotoEditPanelTab.allCases) { tab in
                        let selected = selectedEditTab == tab
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedEditTab = tab
                            }
                        }) {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                                .foregroundColor(selected ? .white : .white.opacity(0.50))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                if hasModifiedSinceOpen {
                    Button("Đặt lại") {
                        resetToOriginalPhoto()
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.amberGold)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            // Active Drawer Body
            Group {
                switch selectedEditTab {
                case .film:
                    filmEditSection
                case .detail:
                    detailEditSection
                case .frame:
                    frameEditSection
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            Color(red: 0.055, green: 0.060, blue: 0.075)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.7)
                }
        )
    }

    private var filmEditSection: some View {
        VStack(spacing: 10) {
            if activePreset != .standard {
                HStack(spacing: 10) {
                    Text("Cường độ")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                    Slider(
                        value: $activeFilmIntensity,
                        in: 0.15...1.0,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing { rebuildEditedImage() }
                        }
                    )
                    .tint(.white)
                    Text("\(Int(round(activeFilmIntensity * 100)))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(FilmPresetCategory.allCases) { category in
                        let selected = selectedCategory == category
                        Button(action: { selectedCategory = category }) {
                            Text(category.displayName)
                                .font(.system(size: 11.5, weight: selected ? .semibold : .regular, design: .rounded))
                                .foregroundColor(selected ? .white : .white.opacity(0.48))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(selectedCategory.presets) { preset in
                        let selected = activePreset == preset
                        Button(action: {
                            activePreset = preset
                            rebuildEditedImage()
                        }) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(preset.previewColor.opacity(selected ? 0.34 : 0.16))
                                    .frame(width: 60, height: 38)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 0.7)
                                    )
                                    .overlay(
                                        Text(preset.deviceBadge)
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.9))
                                    )

                                Text(preset.shortTitle)
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular, design: .rounded))
                                    .foregroundColor(selected ? .white : .white.opacity(0.62))
                                    .lineLimit(1)
                                    .frame(width: 62)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingFilter)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var detailEditSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(PhotoMicroDetailLevel.allCases) { level in
                    let selected = microDetailLevel == level
                    Button(action: {
                        guard microDetailLevel != level else { return }
                        microDetailLevel = level
                        rebuildEditedImage()
                    }) {
                        Text(level.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                            .foregroundColor(selected ? .black : .white.opacity(0.80))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selected ? Color.white : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Button(action: { toggleAIFullColorEnhancement() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isAIEnhanced ? "AI Cân Màu: Bật" : "AI Cân Màu")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(isAIEnhanced ? .black : .white.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isAIEnhanced ? AlignTheme.amberGold : Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        resetZoomAndPan()
                        isSplitCompareMode.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isSplitCompareMode ? "Tắt so sánh" : "So sánh gốc")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(isSplitCompareMode ? .black : .white.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSplitCompareMode ? Color.white : Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    private var frameEditSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: {
                    isMasterFrameApplied = false
                    rebuildEditedImage()
                }) {
                    Text("Tắt khung")
                        .font(.system(size: 12, weight: !isMasterFrameApplied ? .semibold : .medium, design: .rounded))
                        .foregroundColor(!isMasterFrameApplied ? .black : .white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(!isMasterFrameApplied ? Color.white : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)

                ForEach(WatermarkTheme.allCases) { theme in
                    let selected = isMasterFrameApplied && masterFrameTheme == theme
                    Button(action: {
                        masterFrameTheme = theme
                        isMasterFrameApplied = true
                        rebuildEditedImage()
                    }) {
                        Text(theme.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                            .foregroundColor(selected ? .black : .white.opacity(0.78))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selected ? Color.white : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            if isMasterFrameApplied {
                HStack(spacing: 8) {
                    ForEach([WatermarkLogoStyle.alignStudio, .aperturePro, .none]) { logo in
                        let selected = masterFrameLogo == logo
                        Button(action: {
                            masterFrameLogo = logo
                            rebuildEditedImage()
                        }) {
                            Text(logo.rawValue)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .rounded))
                                .foregroundColor(selected ? .white : .white.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 4. Calm Bottom Action Bar (Strictly 3 Clean Controls)
    private var calmBottomActionBar: some View {
        HStack(spacing: 12) {
            if item.saveFormat != .dng {
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        isEditDrawerOpen.toggle()
                        if !isEditDrawerOpen { isSplitCompareMode = false }
                    }
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: isEditDrawerOpen ? "checkmark.circle.fill" : "slider.horizontal.3")
                            .font(.system(size: 17, weight: .medium))
                        Text(isEditDrawerOpen ? "Xong" : "Chỉnh ảnh")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(isEditDrawerOpen ? AlignTheme.amberGold : .white.opacity(0.88))
                    .frame(width: 70, height: 44)
                }
                .buttonStyle(.plain)
            }

            // Primary Save Pill
            Button(action: { saveCurrentVersionToPhotos() }) {
                HStack(spacing: 6) {
                    if isSavingToLibrary {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: hasSavedNewEnhancement ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 13.5, weight: .bold))
                    }
                    Text(hasSavedNewEnhancement ? "Đã lưu" : (item.saveFormat == .dng ? "Lưu RAW" : "Lưu ảnh"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(hasSavedNewEnhancement ? .white : .black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule()
                        .fill(hasSavedNewEnhancement ? Color.green.opacity(0.75) : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingToLibrary || isProcessingFilter)

            // Share Control (Preserving OriginalDNGShare contract; non-DNG encodes lazily on background thread ONLY when tapped!)
            if item.saveFormat == .dng {
                if let url = item.rawLocalFileURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) {
                        shareIconLabel
                    }
                } else if let data = item.rawPhotoData, SuperResolutionRAWEngine.isDNGData(data) {
                    ShareLink(item: OriginalDNGShare(data: data),
                              preview: SharePreview("AlignAI True RAW DNG")) {
                        shareIconLabel
                    }
                }
            } else {
                Button(action: { prepareAndPresentShareSheet() }) {
                    if isPreparingShare {
                        VStack(spacing: 3) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.75)
                            Text("Chuẩn bị...")
                                .font(.system(size: 10.0, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.80))
                        .frame(width: 70, height: 44)
                    } else {
                        shareIconLabel
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparingShare || isProcessingFilter)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(red: 0.03, green: 0.033, blue: 0.045))
    }

    private var shareIconLabel: some View {
        VStack(spacing: 3) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
            Text("Chia sẻ")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
        }
        .foregroundColor(.white.opacity(0.88))
        .frame(width: 70, height: 44)
    }

    // MARK: - 5. Clean Slide-Up EXIF & Histogram Info Sheet (Opened via `i`)
    private var photoInfoInspectorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // RGB + Luminance Histogram Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("BIỂU ĐỒ QUANG PHỔ RGB")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Text("Sáng TB \(Int(round(histogramSnapshot.meanLuminance * 100)))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }

                        PhotoDetailHistogramCanvasView(snapshot: histogramSnapshot)
                            .frame(height: 82)

                        HStack {
                            Text("Vùng tối sâu: \(String(format: "%.1f%%", histogramSnapshot.shadowClipPercent))")
                            Spacer()
                            Text("Cháy sáng: \(String(format: "%.1f%%", histogramSnapshot.highlightClipPercent))")
                                .foregroundColor(histogramSnapshot.highlightClipPercent > 3.5 ? AlignTheme.amberGold : .white.opacity(0.55))
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                    // Optical EXIF Grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("THÔNG SỐ QUANG HỌC")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            infoStatCell(label: "Độ phân giải", value: "\(currentProcessedImage.width) × \(currentProcessedImage.height) (\(megapixelsString))")
                            infoStatCell(label: "Định dạng & Dung lượng", value: "\(formatBadgeTitle) · \(estimatedFileSizeString)")
                            infoStatCell(label: "Tiêu cự & Khẩu độ", value: "\(focalLengthDisplayString) · f/1.8")
                            infoStatCell(label: "Phơi sáng", value: "\(formattedShutterSpeed) · ISO \(Int(round(max(25, item.iso))))")
                            infoStatCell(label: "Bối cảnh AI", value: item.sceneType.rawValue)
                            infoStatCell(label: "Bố cục & Điểm", value: "\(item.compositionRule.rawValue) (\(Int(round(item.alignmentScore * 100)))%)")
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(red: 0.05, green: 0.055, blue: 0.07).ignoresSafeArea())
            .navigationTitle("Thông số ảnh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { isShowingInfoSheet = false }
                        .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoStatCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - Non-Destructive Rendering Pipeline
    private func rebuildEditedImage() {
        isProcessingFilter = true
        hasSavedNewEnhancement = false

        let baseImage = item.originalImage
        let preset = activePreset
        let intensity = Float(activeFilmIntensity)
        let aiParams = isAIEnhanced ? (activeAIColorParams ?? item.sceneType.aiFullColorParameters) : nil
        let detailLevel = microDetailLevel
        let applyMaster = isMasterFrameApplied
        let theme = masterFrameTheme
        let logo = masterFrameLogo
        let deviceName = viewModel?.masterWatermarkDeviceName ?? "ALIGN STUDIO OPTICAL"
        let customLogo = viewModel?.masterWatermarkCustomLogoImage
        let specs = PhotoWatermarkSpecs.from(
            iso: item.iso,
            shutterSpeed: item.shutterSpeed,
            focalLength: 24.0,
            aperture: 1.8
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var working = baseImage

            if preset != .standard || aiParams != nil {
                working = FilmFilterEngine.shared.applyPresetAndAIParameters(
                    to: working,
                    preset: preset,
                    params: aiParams,
                    intensity: intensity
                ) ?? working
            }

            if detailLevel != .off {
                working = Self.applyMicroDetailEnhancement(to: working, level: detailLevel)
            }

            if applyMaster {
                working = MasterWatermarkRenderer.shared.renderWatermark(
                    on: working,
                    deviceName: deviceName,
                    theme: theme,
                    logoStyle: logo,
                    customLogo: customLogo,
                    specs: specs
                ) ?? working
            }

            let previewDisplayUI = Self.downsampleForFastDisplay(working, maxSide: 2400)
            let miniUI = Self.downsampleForFastDisplay(working, maxSide: 220)
            let fullUI = UIImage(cgImage: working)

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.currentProcessedImage = working
                    self.cachedFullResUIImage = fullUI
                    self.cachedDisplayUIImage = previewDisplayUI
                    self.cachedMiniMapUIImage = miniUI
                    self.cachedShareURL = nil
                    self.isHistogramStale = true
                    self.isProcessingFilter = false
                }
            }
        }
    }

    private static func applyMicroDetailEnhancement(to image: CGImage, level: PhotoMicroDetailLevel) -> CGImage {
        guard level != .off, image.width >= 32, image.height >= 32 else { return image }
        return autoreleasepool {
            var ci = CIImage(cgImage: image)
            if let unsharp = CIFilter(name: "CIUnsharpMask") {
                unsharp.setValue(ci, forKey: kCIInputImageKey)
                unsharp.setValue(1.18, forKey: kCIInputRadiusKey)
                unsharp.setValue(level.unsharpIntensity, forKey: kCIInputIntensityKey)
                if let out = unsharp.outputImage { ci = out }
            }
            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(ci, forKey: kCIInputImageKey)
                sharpen.setValue(level.luminanceSharpness, forKey: kCIInputSharpnessKey)
                if let out = sharpen.outputImage { ci = out }
            }
            if let color = CIFilter(name: "CIColorControls") {
                color.setValue(ci, forKey: kCIInputImageKey)
                color.setValue(level.microContrast, forKey: kCIInputContrastKey)
                if let out = color.outputImage { ci = out }
            }
            return detailCIContext.createCGImage(ci, from: ci.extent.integral) ?? image
        }
    }

    private func toggleAIFullColorEnhancement() {
        isAIEnhanced.toggle()
        if isAIEnhanced {
            activeAIColorParams = item.sceneType.aiFullColorParameters
            if activePreset == .standard {
                activePreset = item.sceneType.recommendedFilter
                selectedCategory = activePreset.category
            }
        } else {
            activeAIColorParams = nil
        }
        rebuildEditedImage()
    }

    private func resetToOriginalPhoto() {
        activePreset = .standard
        activeFilmIntensity = 1.0
        selectedCategory = .original
        isAIEnhanced = false
        activeAIColorParams = nil
        microDetailLevel = .off
        isMasterFrameApplied = false
        isPeekingOriginal = false
        isSplitCompareMode = false
        currentProcessedImage = item.originalImage
        cachedFullResUIImage = UIImage(cgImage: item.originalImage)
        cachedDisplayUIImage = cachedOriginalDisplayUIImage
        cachedShareURL = nil
        isHistogramStale = true
        hasSavedNewEnhancement = false
        rebuildDisplayCachesAsync(processed: item.originalImage, original: nil)
    }

    private func refreshHistogram(for image: CGImage) {
        DispatchQueue.global(qos: .utility).async {
            let snap = PhotoDetailHistogramSnapshot.compute(from: image)
            DispatchQueue.main.async {
                self.histogramSnapshot = snap
                self.isHistogramStale = false
            }
        }
    }

    private func rebuildDisplayCachesAsync(processed: CGImage, original: CGImage?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let displayUI = Self.downsampleForFastDisplay(processed, maxSide: 2400)
            let miniUI = Self.downsampleForFastDisplay(processed, maxSide: 220)
            let origUI = original.map { Self.downsampleForFastDisplay($0, maxSide: 2400) }
            DispatchQueue.main.async {
                self.cachedDisplayUIImage = displayUI
                self.cachedMiniMapUIImage = miniUI
                if let origUI {
                    self.cachedOriginalDisplayUIImage = origUI
                }
            }
        }
    }

    private static func downsampleForFastDisplay(_ cgImage: CGImage, maxSide: CGFloat) -> UIImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let longest = max(w, h)
        guard longest > maxSide, w > 0, h > 0 else {
            // Still force eager bitmap decode off main thread so SwiftUI doesn't decode on first zoom frame
            let ui = UIImage(cgImage: cgImage)
            return ui.preparingForDisplay() ?? ui
        }
        let scale = maxSide / longest
        let targetSize = CGSize(width: round(w * scale), height: round(h * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let downsampled = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return downsampled.preparingForDisplay() ?? downsampled
    }

    private func prepareAndPresentShareSheet() {
        if let existing = cachedShareURL, FileManager.default.fileExists(atPath: existing.path) {
            isShowingShareSheet = true
            return
        }
        isPreparingShare = true
        let cgToExport = currentProcessedImage
        let format = item.saveFormat
        let itemID = item.id
        let preserveOrig = item.preservesOriginalFile && !hasModifiedSinceOpen && (currentProcessedImage === item.processedImage)
        let rawData = preserveOrig ? item.rawPhotoData : nil

        DispatchQueue.global(qos: .userInitiated).async {
            let url = Self.writeShareFileOnBackground(
                cgImage: cgToExport,
                saveFormat: format,
                itemID: itemID,
                rawPhotoData: rawData
            )
            DispatchQueue.main.async {
                self.isPreparingShare = false
                if let url {
                    self.cachedShareURL = url
                    self.isShowingShareSheet = true
                }
            }
        }
    }

    private static func writeShareFileOnBackground(
        cgImage: CGImage,
        saveFormat: PhotoSaveFormat,
        itemID: UUID,
        rawPhotoData: Data?
    ) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        if let data = rawPhotoData {
            let ext = saveFormat == .jpeg ? "jpg" : "heic"
            let url = tempDir.appendingPathComponent("AlignAI_Original_\(itemID.uuidString).\(ext)")
            if (try? data.write(to: url, options: .atomic)) != nil {
                return url
            }
        }
        let isHEIC = saveFormat == .heif || saveFormat == .heic
        let ext = isHEIC ? "heic" : "jpg"
        let utType = isHEIC ? UTType.heic : UTType.jpeg
        let fileURL = tempDir.appendingPathComponent("AlignAI_Studio_\(itemID.uuidString).\(ext)")
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        do {
            try (data as Data).write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func saveCurrentVersionToPhotos() {
        guard let vm = viewModel else { return }
        isSavingToLibrary = true

        let preserveOriginal = !hasModifiedSinceOpen && item.preservesOriginalFile &&
            currentProcessedImage === item.processedImage
        let updatedItem = CapturedPhotoItem(
            originalImage: item.originalImage,
            processedImage: currentProcessedImage,
            rawPhotoData: item.rawPhotoData,
            processedCompanionData: preserveOriginal ? item.processedCompanionData : nil,
            saveFormat: item.saveFormat,
            preservesOriginalFile: preserveOriginal,
            rawLocalFileURL: item.rawLocalFileURL,
            livePhotoMovieURL: item.livePhotoMovieURL,
            sceneType: item.sceneType,
            appliedPreset: activePreset,
            compositionRule: item.compositionRule,
            alignmentScore: item.alignmentScore,
            iso: item.iso,
            shutterSpeed: item.shutterSpeed,
            aiColorParameters: isAIEnhanced ? (activeAIColorParams ?? item.sceneType.aiFullColorParameters) : item.aiColorParameters
        )

        vm.savePhotoToLibrary(updatedItem) { success in
            self.isSavingToLibrary = false
            self.hasSavedNewEnhancement = success
        }
    }

    // MARK: - Interactive Zoom Navigator Mini-Map (Khung báo vùng đang zoom)
    @ViewBuilder
    private func zoomRegionMiniMap(viewportSize: CGSize) -> some View {
        let displayCG = isPeekingOriginal ? item.originalImage : currentProcessedImage
        let imgW = CGFloat(max(1, displayCG.width))
        let imgH = CGFloat(max(1, displayCG.height))
        let imgAspect = imgW / imgH
        let vpAspect = viewportSize.width / max(1.0, viewportSize.height)

        let baseW: CGFloat = (vpAspect > imgAspect) ? (viewportSize.height * imgAspect) : viewportSize.width
        let baseH: CGFloat = (vpAspect > imgAspect) ? viewportSize.height : (viewportSize.width / imgAspect)
        let renderedW = max(1.0, baseW * zoomScale)
        let renderedH = max(1.0, baseH * zoomScale)

        let miniW: CGFloat = imgAspect >= 1.0 ? 78 : 58
        let miniH: CGFloat = max(42, min(88, miniW / imgAspect))

        let visibleFracW = min(1.0, viewportSize.width / renderedW)
        let visibleFracH = min(1.0, viewportSize.height / renderedH)
        let indW = max(10.0, miniW * visibleFracW)
        let indH = max(10.0, miniH * visibleFracH)

        let maxShiftX = max(0.0, (miniW - indW) / 2.0)
        let maxShiftY = max(0.0, (miniH - indH) / 2.0)
        let rawIndOffsetX = -(panOffset.width / renderedW) * miniW
        let rawIndOffsetY = -(panOffset.height / renderedH) * miniH
        let indOffsetX = min(maxShiftX, max(-maxShiftX, rawIndOffsetX))
        let indOffsetY = min(maxShiftY, max(-maxShiftY, rawIndOffsetY))

        ZStack {
            Image(uiImage: cachedMiniMapUIImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: miniW, height: miniH)

            Color.black.opacity(0.40)
                .frame(width: miniW, height: miniH)

            // Khung sáng đánh dấu chính xác vùng ảnh đang phóng to
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(AlignTheme.studioAccent, lineWidth: 1.5)
                )
                .frame(width: indW, height: indH)
                .offset(x: indOffsetX, y: indOffsetY)
                .shadow(color: Color.black.opacity(0.65), radius: 2)
        }
        .frame(width: miniW, height: miniH)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.9)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 8, y: 3)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let targetPan = CGSize(
                        width: -((value.location.x - miniW * 0.5) / miniW) * renderedW,
                        height: -((value.location.y - miniH * 0.5) / miniH) * renderedH
                    )
                    let clamped = clampPanOffset(targetPan, in: viewportSize, scale: zoomScale)
                    panOffset = clamped
                    lastPanOffset = clamped
                }
        )
        .accessibilityLabel("Bản đồ vùng đang phóng to \(String(format: "%.1f", zoomScale)) lần")
    }

    // MARK: - Zoom & Pan Helpers
    private func resetZoomAndPan() {
        zoomScale = 1.0
        lastZoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func clampPanOffset(_ offset: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let displayCG = isPeekingOriginal ? item.originalImage : currentProcessedImage
        let imgW = CGFloat(max(1, displayCG.width))
        let imgH = CGFloat(max(1, displayCG.height))
        let imgAspect = imgW / imgH
        let vpAspect = size.width / max(1.0, size.height)
        let baseW: CGFloat = (vpAspect > imgAspect) ? (size.height * imgAspect) : size.width
        let baseH: CGFloat = (vpAspect > imgAspect) ? size.height : (size.width / imgAspect)
        let maxX = max(0, (baseW * scale - size.width) / 2.0)
        let maxY = max(0, (baseH * scale - size.height) / 2.0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            if zoomScale > 1.3 {
                resetZoomAndPan()
                return
            }
            let nextScale: CGFloat = 2.8
            let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
            let targetOffset = CGSize(
                width: (center.x - location.x) * (nextScale - 1.0),
                height: (center.y - location.y) * (nextScale - 1.0)
            )
            zoomScale = nextScale
            lastZoomScale = nextScale
            panOffset = clampPanOffset(targetOffset, in: size, scale: nextScale)
            lastPanOffset = panOffset
        }
    }

    // MARK: - Share & Format Metadata Helpers
    private struct OriginalDNGShare: Transferable {
        let data: Data
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: UTType(filenameExtension: "dng") ?? .rawImage) { value in
                value.data
            }
        }
    }

    private var formatBadgeTitle: String {
        if item.saveFormat == .dng { return "RAW DNG" }
        if item.livePhotoMovieURL != nil { return "LIVE" }
        return item.saveFormat.rawValue
    }

    private var megapixelsString: String {
        let mp = Double(currentProcessedImage.width * currentProcessedImage.height) / 1_000_000.0
        return String(format: "%.1f MP", mp)
    }

    private var focalLengthDisplayString: String {
        if let vm = viewModel {
            if vm.isWindowedZoomActive {
                return "\(Int(round(vm.windowedZoomFocalLength)))mm"
            }
            let z = vm.displayZoom
            if z < 0.75 { return "13mm" }
            if z >= 2.8 { return "77mm" }
            if z >= 1.9 { return "48mm" }
        }
        return "24mm"
    }

    private var formattedShutterSpeed: String {
        let s = item.shutterSpeed
        guard s > 0 else { return "1/120s" }
        if s >= 1.0 { return String(format: "%.1fs", s) }
        return "1/\(max(1, Int(round(1.0 / s))))s"
    }

    private var opticalSummaryLine: String {
        let isoVal = Int(round(max(25, item.iso)))
        return "\(focalLengthDisplayString) · f/1.8 · \(formattedShutterSpeed) · ISO \(isoVal)"
    }

    private var estimatedFileSizeString: String {
        if let rawData = item.rawPhotoData, !hasModifiedSinceOpen {
            let mb = Double(rawData.count) / (1024.0 * 1024.0)
            return String(format: "%.2f MB", mb)
        }
        let pixels = Double(currentProcessedImage.width * currentProcessedImage.height)
        let bytesPerPx = (item.saveFormat == .dng) ? 1.8 : ((item.saveFormat == .jpeg) ? 0.42 : 0.24)
        let estMB = max(0.25, (pixels * bytesPerPx) / (1024.0 * 1024.0))
        return String(format: "~%.1f MB", estMB)
    }
}

// MARK: - Smooth RGB + Luminance Histogram Waveform Canvas
private struct PhotoDetailHistogramCanvasView: View {
    let snapshot: PhotoDetailHistogramSnapshot

    private func buildPath(bins: [Double], in size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard bins.count >= 2 else { return path }
        let stepX = size.width / CGFloat(bins.count - 1)
        if closed {
            path.move(to: CGPoint(x: 0, y: size.height))
            for (idx, val) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(idx) * stepX, y: size.height * (1.0 - CGFloat(min(1.0, max(0.0, val))))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        } else {
            for (idx, val) in bins.enumerated() {
                let pt = CGPoint(x: CGFloat(idx) * stepX, y: size.height * (1.0 - CGFloat(min(1.0, max(0.0, val)))))
                if idx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                buildPath(bins: snapshot.redBins, in: size, closed: true).fill(Color.red.opacity(0.20))
                buildPath(bins: snapshot.greenBins, in: size, closed: true).fill(Color.green.opacity(0.20))
                buildPath(bins: snapshot.blueBins, in: size, closed: true).fill(Color.cyan.opacity(0.22))
                buildPath(bins: snapshot.redBins, in: size, closed: false).stroke(Color.red.opacity(0.75), lineWidth: 1.0)
                buildPath(bins: snapshot.greenBins, in: size, closed: false).stroke(Color.green.opacity(0.75), lineWidth: 1.0)
                buildPath(bins: snapshot.blueBins, in: size, closed: false).stroke(Color.cyan.opacity(0.80), lineWidth: 1.0)
                buildPath(bins: snapshot.lumaBins, in: size, closed: false).stroke(Color.white.opacity(0.90), lineWidth: 1.2)
            }
        }
    }
}

private struct CapturedPhotoActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
