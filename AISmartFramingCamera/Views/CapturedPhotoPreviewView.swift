import SwiftUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO

// MARK: - Inspector Tabs & Detail Levels
private enum PhotoDetailInspectorTab: String, CaseIterable, Identifiable {
    case telemetryAndDetail = "Thông số & Nét"
    case filmPresets = "Màu Phim"
    case masterFrame = "Khung Master"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .telemetryAndDetail: return "waveform.path.ecg.rectangle"
        case .filmPresets: return "camera.filters"
        case .masterFrame: return "photo.artframe"
        }
    }
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
        case .natural: return 0.36
        case .ultra: return 0.68
        }
    }

    var luminanceSharpness: Float {
        switch self {
        case .off: return 0.0
        case .natural: return 0.24
        case .ultra: return 0.48
        }
    }

    var microContrast: Float {
        switch self {
        case .off: return 1.0
        case .natural: return 1.025
        case .ultra: return 1.048
        }
    }
}

// MARK: - Real RGB + Luminance Histogram Model for Photo Detail
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

            let rBin = max(0, min(binCount - 1, Int((r * scale).rounded())))
            let gBin = max(0, min(binCount - 1, Int((g * scale).rounded())))
            let bBin = max(0, min(binCount - 1, Int((b * scale).rounded())))
            let lBin = max(0, min(binCount - 1, Int((y * scale).rounded())))

            rHist[rBin] += 1
            gHist[gBin] += 1
            bHist[bBin] += 1
            lHist[lBin] += 1
        }

        func normalize(_ arr: [Double]) -> [Double] {
            // Bỏ qua 2 bin đầu/cuối khi tìm đỉnh để biểu đồ không bị dẹt khi có vùng cháy/tối thuần
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

// MARK: - Flagship Pro Studio Photo Detail & Inspection View
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
    @State private var masterFrameTheme: MasterWatermarkTheme = .classicWhite
    @State private var masterFrameLogo: MasterWatermarkLogoStyle = .leicaRedDot

    @State private var isProcessingFilter: Bool = false
    @State private var isSavingToLibrary: Bool = false
    @State private var hasSavedNewEnhancement: Bool = false
    @State private var selectedInspectorTab: PhotoDetailInspectorTab = .telemetryAndDetail
    @State private var isInspectorCollapsed: Bool = false
    @State private var histogramSnapshot: PhotoDetailHistogramSnapshot = .empty
    @State private var showRGBChannelsInHistogram: Bool = true

    // Split-Screen & Hold-Original Comparison States
    @State private var isSplitCompareMode: Bool = false
    @State private var splitRatio: CGFloat = 0.5
    @State private var isHoldingOriginal: Bool = false

    // Zoom & Pan States (1.0x -> 8.0x)
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    private static let detailCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true,
        .cacheIntermediates: false
    ])

    public init(item: CapturedPhotoItem, viewModel: CameraViewModel? = nil) {
        self.item = item
        self.viewModel = viewModel
        _currentProcessedImage = State(initialValue: item.processedImage)
        _activePreset = State(initialValue: item.appliedFilter)
        _selectedCategory = State(initialValue: item.appliedFilter.category)
        if let vm = viewModel {
            _masterFrameTheme = State(initialValue: vm.masterWatermarkTheme)
            _masterFrameLogo = State(initialValue: vm.masterWatermarkLogoStyle)
        }
    }

    private var hasModifiedSinceOpen: Bool {
        activePreset != item.appliedFilter ||
        abs(activeFilmIntensity - 1.0) > 0.02 ||
        isAIEnhanced ||
        microDetailLevel != .off ||
        isMasterFrameApplied
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.031, green: 0.035, blue: 0.047).ignoresSafeArea()

                VStack(spacing: 0) {
                    topStudioHeaderBar

                    interactivePhotoViewport
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isInspectorCollapsed {
                        studioInspectorDeck
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    bottomPrimaryActionBar
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                refreshHistogram(for: currentProcessedImage)
            }
        }
    }

    // MARK: - 1. Top Studio Header Bar
    private var topStudioHeaderBar: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                    Text("Đóng")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            // Format & Resolution Pill
            HStack(spacing: 6) {
                Circle()
                    .fill(formatAccentColor)
                    .frame(width: 6.5, height: 6.5)

                Text(formatBadgeTitle)
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(formatAccentColor)

                Text("•")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))

                Text("\(megapixelsString) · \(currentProcessedImage.width)×\(currentProcessedImage.height)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.82))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.7))
            )

            Spacer(minLength: 4)

            // Quick Loupe 1x / 2.5x / 5x Button
            Button(action: {
                cycleQuickLoupeZoom()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: zoomScale > 1.05 ? "plus.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 11, weight: .bold))
                    Text(String(format: "%.1fx", zoomScale))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(zoomScale > 1.05 ? AlignTheme.electricCyan : .white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(zoomScale > 1.05 ? AlignTheme.electricCyan.opacity(0.18) : Color.white.opacity(0.08))
                        .overlay(
                            Capsule().stroke(zoomScale > 1.05 ? AlignTheme.electricCyan.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)

            // Collapse/Expand Inspector Button
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                    isInspectorCollapsed.toggle()
                }
            }) {
                Image(systemName: isInspectorCollapsed ? "slider.horizontal.below.rectangle" : "rectangle.expand.vertical")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isInspectorCollapsed ? AlignTheme.amberGold : .white.opacity(0.82))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ẩn hiện bảng chi tiết")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.04, green: 0.045, blue: 0.06))
    }

    // MARK: - 2. Interactive Photo Inspection Viewport
    private var interactivePhotoViewport: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.02, green: 0.022, blue: 0.03)

                if isSplitCompareMode && zoomScale <= 1.05 && item.saveFormat != .dng {
                    splitScreenComparisonCanvas(in: geo.size)
                } else {
                    zoomableSingleCanvas(in: geo.size)
                }

                // Processing Shimmer Overlay
                if isProcessingFilter {
                    ZStack {
                        Color.black.opacity(0.32)
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.electricCyan))
                            Text("Đang kết xuất quang học...")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.82))
                                .overlay(Capsule().stroke(AlignTheme.electricCyan.opacity(0.5), lineWidth: 1))
                        )
                    }
                    .transition(.opacity)
                }

                // Top-Right Zoom Mini-Map
                if zoomScale > 1.05 {
                    VStack {
                        HStack {
                            Spacer()
                            zoomMiniMapOverlay(viewportSize: geo.size)
                                .padding(.top, 12)
                                .padding(.trailing, 12)
                        }
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }

                // Bottom Viewport Floating Quick Bar (EXIF Pill + Split/Hold Original Controls)
                VStack {
                    Spacer()
                    HStack(alignment: .center, spacing: 8) {
                        // Quick Optical EXIF Pill
                        HStack(spacing: 6) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(AlignTheme.amberGold)
                            Text(opticalSummaryLine)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.72))
                                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                        )

                        Spacer()

                        if item.saveFormat != .dng {
                            // Split Curtain Toggle
                            if zoomScale <= 1.05 {
                                Button(action: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        isSplitCompareMode.toggle()
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.split.2x1")
                                            .font(.system(size: 10.5, weight: .bold))
                                        Text(isSplitCompareMode ? "Tắt chia đôi" : "So sánh")
                                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    }
                                    .foregroundColor(isSplitCompareMode ? .black : .white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(
                                        Capsule().fill(isSplitCompareMode ? AlignTheme.amberGold : Color.black.opacity(0.72))
                                    )
                                    .overlay(
                                        Capsule().stroke(Color.white.opacity(isSplitCompareMode ? 0 : 0.16), lineWidth: 0.7)
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            // Hold / Toggle Original Button
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isHoldingOriginal.toggle()
                                }
                            }) {
                                Text(isHoldingOriginal ? "ĐANG XEM GỐC" : "Xem gốc")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundColor(isHoldingOriginal ? .black : .white.opacity(0.92))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(
                                        Capsule().fill(isHoldingOriginal ? AlignTheme.electricCyan : Color.black.opacity(0.72))
                                    )
                                    .overlay(
                                        Capsule().stroke(Color.white.opacity(isHoldingOriginal ? 0 : 0.16), lineWidth: 0.7)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func zoomableSingleCanvas(in size: CGSize) -> some View {
        let displayCG = isHoldingOriginal ? item.originalImage : currentProcessedImage
        Image(uiImage: UIImage(cgImage: displayCG))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        let nextScale = lastZoomScale * val
                        zoomScale = min(max(nextScale, 1.0), 8.0)
                        if zoomScale <= 1.02 {
                            panOffset = .zero
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
                DragGesture(minimumDistance: zoomScale > 1.02 ? 2 : 1000)
                    .onChanged { val in
                        guard zoomScale > 1.02 else { return }
                        let rawOffset = CGSize(
                            width: lastPanOffset.width + val.translation.width,
                            height: lastPanOffset.height + val.translation.height
                        )
                        panOffset = clampPanOffset(rawOffset, in: size, scale: zoomScale)
                    }
                    .onEnded { _ in
                        guard zoomScale > 1.02 else { return }
                        lastPanOffset = panOffset
                    }
            )
            .highPriorityGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { event in
                        handleDoubleTap(at: event.location, in: size)
                    }
            )
    }

    @ViewBuilder
    private func splitScreenComparisonCanvas(in size: CGSize) -> some View {
        let splitX = size.width * splitRatio
        ZStack {
            Image(uiImage: UIImage(cgImage: currentProcessedImage))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Image(uiImage: UIImage(cgImage: item.originalImage))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().frame(width: splitX)
                        Spacer(minLength: 0)
                    }
                )

            // Vertical Curtain Handle
            ZStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: size.height)
                    .shadow(color: .black.opacity(0.6), radius: 3)

                Circle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(AlignTheme.amberGold, lineWidth: 1.5))
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AlignTheme.amberGold)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 5)
            }
            .position(x: splitX, y: size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newRatio = value.location.x / max(1, size.width)
                        splitRatio = min(max(newRatio, 0.05), 0.95)
                    }
            )

            VStack {
                HStack {
                    Text("ẢNH GỐC")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(.leading, 12)

                    Spacer()

                    Text("ĐÃ CHỈNH")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AlignTheme.amberGold))
                        .padding(.trailing, 12)
                }
                .padding(.top, 12)
                Spacer()
            }
        }
    }

    private func zoomMiniMapOverlay(viewportSize: CGSize) -> some View {
        let thumbW: CGFloat = 76
        let thumbH: CGFloat = 96
        let visibleFraction = 1.0 / zoomScale
        let maxPanX = max(1.0, (viewportSize.width * (zoomScale - 1.0)) / 2.0)
        let maxPanY = max(1.0, (viewportSize.height * (zoomScale - 1.0)) / 2.0)
        let normOffsetX = -panOffset.width / maxPanX
        let normOffsetY = -panOffset.height / maxPanY
        let boxW = thumbW * visibleFraction
        let boxH = thumbH * visibleFraction
        let centerX = (thumbW / 2.0) + (normOffsetX * (thumbW - boxW) / 2.0)
        let centerY = (thumbH / 2.0) + (normOffsetY * (thumbH - boxH) / 2.0)

        return VStack(alignment: .trailing, spacing: 5) {
            ZStack {
                Image(uiImage: UIImage(cgImage: currentProcessedImage))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbW, height: thumbH)
                    .clipped()
                    .overlay(Color.black.opacity(0.32))

                Rectangle()
                    .stroke(AlignTheme.electricCyan, lineWidth: 1.5)
                    .frame(width: boxW, height: boxH)
                    .position(x: centerX, y: centerY)
            }
            .frame(width: thumbW, height: thumbH)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )

            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                    resetZoomAndPan()
                }
            }) {
                Text("Đặt lại 1.0x")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(AlignTheme.electricCyan))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 3. Tabbed Studio Inspector Deck
    private var studioInspectorDeck: some View {
        VStack(spacing: 10) {
            // Segmented Inspector Tab Bar
            if item.saveFormat != .dng {
                HStack(spacing: 6) {
                    ForEach(PhotoDetailInspectorTab.allCases) { tab in
                        let isSelected = selectedInspectorTab == tab
                        Button(action: {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                selectedInspectorTab = tab
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(tab.rawValue)
                                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                            }
                            .foregroundColor(isSelected ? .white : .white.opacity(0.58))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(isSelected ? AlignTheme.electricCyan.opacity(0.45) : Color.clear, lineWidth: 0.9)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .padding(.horizontal, 14)
            }

            // Tab Content
            Group {
                if item.saveFormat == .dng || selectedInspectorTab == .telemetryAndDetail {
                    telemetryAndDetailTabContent
                } else if selectedInspectorTab == .filmPresets {
                    filmPresetsTabContent
                } else {
                    masterFrameTabContent
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Color(red: 0.055, green: 0.06, blue: 0.078)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.8)
                }
        )
    }

    // MARK: - Tab 1: Optical Telemetry, RGB/Luma Histogram & Micro-Detail Studio
    private var telemetryAndDetailTabContent: some View {
        VStack(spacing: 10) {
            // Row A: Real RGB/Luma Histogram + Exposure Telemetry
            HStack(spacing: 12) {
                // Histogram Canvas
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(showRGBChannelsInHistogram ? "BIỂU ĐỒ QUANG PHỔ RGB + LUMA" : "BIỂU ĐỒ ĐỘ SÁNG LUMA")
                            .font(.system(size: 9.0, weight: .heavy, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                        Spacer()
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showRGBChannelsInHistogram.toggle()
                            }
                        }) {
                            Text(showRGBChannelsInHistogram ? "RGB" : "LUMA")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(AlignTheme.electricCyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(AlignTheme.electricCyan.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }

                    PhotoDetailHistogramCanvasView(
                        snapshot: histogramSnapshot,
                        showRGB: showRGBChannelsInHistogram
                    )
                    .frame(height: 46)

                    HStack(spacing: 8) {
                        Text("TB: \(Int(round(histogramSnapshot.meanLuminance * 100)))%")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.70))
                        Text("Tối: \(String(format: "%.1f%%", histogramSnapshot.shadowClipPercent))")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.60))
                        Text("Cháy: \(String(format: "%.1f%%", histogramSnapshot.highlightClipPercent))")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(histogramSnapshot.highlightClipPercent > 3.5 ? AlignTheme.amberGold : .white.opacity(0.60))
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                        )
                )

                // 2x2 EXIF Telemetry Grid
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        exifMiniTile(title: "TIÊU CỰ", value: focalLengthDisplayString, accent: AlignTheme.amberGold)
                        exifMiniTile(title: "KHẨU ĐỘ", value: String(format: "f/%.1f", item.aperture > 0 ? item.aperture : 1.8), accent: .white)
                    }
                    HStack(spacing: 6) {
                        exifMiniTile(title: "TỐC ĐỘ", value: formattedShutterSpeed, accent: AlignTheme.electricCyan)
                        exifMiniTile(title: "ĐỘ NHẠY", value: "ISO \(Int(round(max(25, item.iso))))", accent: .white)
                    }
                }
                .frame(width: 158)
            }
            .padding(.horizontal, 14)

            // Row B: AI Scene & Composition Telemetry Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    telemetryBadgeChip(
                        icon: "sparkles",
                        label: "Bối cảnh: \(item.sceneType.rawValue)",
                        tint: AlignTheme.electricCyan
                    )
                    telemetryBadgeChip(
                        icon: "viewfinder",
                        label: "Bố cục: \(item.compositionRule.rawValue) (\(Int(round(item.alignmentScore * 100)))%)",
                        tint: AlignTheme.amberGold
                    )
                    telemetryBadgeChip(
                        icon: "camera.filters",
                        label: "Màu: \(activePreset.rawValue)",
                        tint: .white.opacity(0.9)
                    )
                    telemetryBadgeChip(
                        icon: "doc.richtext",
                        label: estimatedFileSizeString,
                        tint: .white.opacity(0.75)
                    )
                }
                .padding(.horizontal, 14)
            }

            // Row C: Optical Micro-Detail & AI Auto Color Controls (for non-DNG)
            if item.saveFormat != .dng {
                HStack(spacing: 8) {
                    // 3-Level Micro-Detail Selector
                    HStack(spacing: 3) {
                        Image(systemName: "dial.high.fill")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(AlignTheme.amberGold)
                            .padding(.leading, 6)

                        ForEach(PhotoMicroDetailLevel.allCases) { level in
                            let selected = microDetailLevel == level
                            Button(action: {
                                guard microDetailLevel != level else { return }
                                microDetailLevel = level
                                rebuildEditedImage()
                            }) {
                                Text(level.title)
                                    .font(.system(size: 10.5, weight: selected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(selected ? .black : .white.opacity(0.80))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? AlignTheme.amberGold : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7))
                    )

                    Spacer(minLength: 4)

                    // AI Auto Color Enhancement Toggle
                    Button(action: {
                        toggleAIFullColorEnhancement()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11, weight: .bold))
                            Text(isAIEnhanced ? "AI Màu: Bật" : "AI Cân Màu")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(isAIEnhanced ? .black : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(
                                    isAIEnhanced
                                    ? LinearGradient(colors: [AlignTheme.electricCyan, AlignTheme.amberGold], startPoint: .leading, endPoint: .trailing)
                                    : LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingFilter)
                }
                .padding(.horizontal, 14)
            }
        }
    }

    // MARK: - Tab 2: Film Presets & Live Intensity Studio
    private var filmPresetsTabContent: some View {
        VStack(spacing: 8) {
            // Intensity Slider Row
            HStack(spacing: 10) {
                Text("CƯỜNG ĐỘ MÀU")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.60))

                Slider(
                    value: $activeFilmIntensity,
                    in: 0.15...1.0,
                    step: 0.05,
                    onEditingChanged: { editing in
                        if !editing {
                            rebuildEditedImage()
                        }
                    }
                )
                .tint(AlignTheme.electricCyan)
                .disabled(activePreset == .standard)

                Text("\(Int(round(activeFilmIntensity * 100)))%")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(AlignTheme.electricCyan)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 16)

            // Category Filter Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilmPresetCategory.allCases) { category in
                        let isSelected = selectedCategory == category
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedCategory = category
                            }
                        }) {
                            Text(category.displayName)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSelected ? .black : .white.opacity(0.75))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? AlignTheme.electricCyan : Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            // Preset Cards Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(selectedCategory.presets) { preset in
                        let isSelected = activePreset == preset
                        Button(action: {
                            activePreset = preset
                            rebuildEditedImage()
                        }) {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(preset.previewColor.opacity(isSelected ? 0.35 : 0.18))
                                        .frame(width: 64, height: 42)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .stroke(isSelected ? AlignTheme.electricCyan : Color.white.opacity(0.14), lineWidth: isSelected ? 1.8 : 0.8)
                                        )

                                    VStack(spacing: 2) {
                                        Image(systemName: preset.deviceIconSF)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(isSelected ? AlignTheme.electricCyan : .white.opacity(0.9))
                                        Text(preset.deviceBadge)
                                            .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                                            .foregroundColor(preset.previewColor)
                                    }
                                }

                                Text(preset.shortTitle)
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? .white : .white.opacity(0.70))
                                    .lineLimit(1)
                                    .frame(width: 66)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingFilter)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    // MARK: - Tab 3: Master Frame Watermark Studio
    private var masterFrameTabContent: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KHUNG NGHỆ THUẬT MASTER")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("Đính kèm thông số tiêu cự, khẩu độ, ISO & chữ ký quang học")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
                Spacer()
                Button(action: {
                    isMasterFrameApplied.toggle()
                    rebuildEditedImage()
                }) {
                    Text(isMasterFrameApplied ? "ĐANG BẬT" : "BẬT KHUNG")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(isMasterFrameApplied ? .black : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isMasterFrameApplied ? AlignTheme.amberGold : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)

            // Theme Picker Row
            HStack(spacing: 8) {
                ForEach(MasterWatermarkTheme.allCases) { theme in
                    let isSelected = masterFrameTheme == theme
                    Button(action: {
                        masterFrameTheme = theme
                        isMasterFrameApplied = true
                        rebuildEditedImage()
                    }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(theme == .classicWhite ? Color.white : (theme == .obsidianBlack ? Color(white: 0.18) : AlignTheme.amberGold))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.6))
                            Text(theme.rawValue)
                                .font(.system(size: 10.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.72))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(isSelected ? AlignTheme.amberGold : Color.clear, lineWidth: 1.0)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: - 4. Bottom Primary Action Bar
    private var bottomPrimaryActionBar: some View {
        HStack(spacing: 10) {
            // Reset to Original Button (when modified)
            if hasModifiedSinceOpen && item.saveFormat != .dng {
                Button(action: {
                    resetToOriginalPhoto()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .bold))
                        Text("Gốc")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.11))
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.8))
                    )
                }
                .buttonStyle(.plain)
            }

            // Save to Apple Photos Button
            Button(action: {
                saveCurrentVersionToPhotos()
            }) {
                HStack(spacing: 7) {
                    if isSavingToLibrary {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: hasSavedNewEnhancement ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                            .font(.system(size: 13.5, weight: .bold))
                    }
                    Text(hasSavedNewEnhancement ? "Đã lưu vào Photos" : (hasModifiedSinceOpen ? "Lưu bản chỉnh sửa" : "Lưu vào Photos"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .foregroundColor(hasSavedNewEnhancement ? .white : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(
                            hasSavedNewEnhancement
                            ? Color.green.opacity(0.75)
                            : AlignTheme.electricCyan
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingToLibrary || isProcessingFilter)

            // Share Link (Preserving OriginalDNGShare contract for RAW DNG)
            if item.saveFormat == .dng {
                if let url = item.rawLocalFileURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) {
                        shareButtonLabel(title: "RAW")
                    }
                } else if let data = item.rawPhotoData, SuperResolutionRAWEngine.isDNGData(data) {
                    ShareLink(item: OriginalDNGShare(data: data),
                              preview: SharePreview("AlignAI True RAW DNG")) {
                        shareButtonLabel(title: "RAW")
                    }
                }
            } else if let shareURL = currentPhotoShareURL {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(
                        "AlignAI Studio • \(activePreset.rawValue)",
                        image: Image(uiImage: UIImage(cgImage: currentProcessedImage))
                    )
                ) {
                    shareButtonLabel(title: "Chia sẻ")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
    }

    private func shareButtonLabel(title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12.5, weight: .bold))
            Text(title)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
        )
    }

    // MARK: - Helper Subviews
    private func exifMiniTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                )
        )
    }

    private func telemetryBadgeChip(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.6))
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
            focalLength: item.focalLength > 0 ? item.focalLength : 24.0,
            aperture: Double(item.aperture > 0 ? item.aperture : 1.8)
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var working = baseImage

            // 1. Film Simulation & AI Color Parameters
            if preset != .standard || aiParams != nil {
                working = FilmFilterEngine.shared.applyPresetAndAIParameters(
                    to: working,
                    preset: preset,
                    params: aiParams,
                    intensity: intensity
                ) ?? working
            }

            // 2. Optical Micro-Detail & Clarity
            if detailLevel != .off {
                working = Self.applyMicroDetailEnhancement(to: working, level: detailLevel)
            }

            // 3. Master Art Frame Watermark
            if applyMaster {
                working = MasterWatermarkRenderer.shared.renderMasterFrame(
                    on: working,
                    deviceName: deviceName,
                    specs: specs,
                    theme: theme,
                    logoStyle: logo,
                    customLogo: customLogo
                ) ?? working
            }

            let hist = PhotoDetailHistogramSnapshot.compute(from: working)

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.currentProcessedImage = working
                    self.histogramSnapshot = hist
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
        isHoldingOriginal = false
        currentProcessedImage = item.originalImage
        hasSavedNewEnhancement = false
        refreshHistogram(for: item.originalImage)
    }

    private func refreshHistogram(for image: CGImage) {
        DispatchQueue.global(qos: .utility).async {
            let snap = PhotoDetailHistogramSnapshot.compute(from: image)
            DispatchQueue.main.async {
                self.histogramSnapshot = snap
            }
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
            preservesOriginalFile: preserveOriginal,
            rawLocalFileURL: item.rawLocalFileURL,
            livePhotoMovieURL: item.livePhotoMovieURL,
            sceneType: item.sceneType,
            compositionRule: item.compositionRule,
            appliedFilter: activePreset,
            alignmentScore: item.alignmentScore,
            iso: item.iso,
            shutterSpeed: item.shutterSpeed,
            focalLength: item.focalLength,
            aperture: item.aperture,
            saveFormat: item.saveFormat
        )

        vm.savePhotoToLibrary(updatedItem) { success in
            self.isSavingToLibrary = false
            self.hasSavedNewEnhancement = success
        }
    }

    // MARK: - Zoom & Pan Helpers
    private func cycleQuickLoupeZoom() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            if zoomScale < 1.5 {
                zoomScale = 2.5
                lastZoomScale = 2.5
            } else if zoomScale < 4.0 {
                zoomScale = 5.0
                lastZoomScale = 5.0
            } else {
                resetZoomAndPan()
            }
        }
    }

    private func resetZoomAndPan() {
        zoomScale = 1.0
        lastZoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func clampPanOffset(_ offset: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.0 else { return .zero }
        let maxX = (size.width * (scale - 1.0)) / 2.0
        let maxY = (size.height * (scale - 1.0)) / 2.0
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
            let nextScale: CGFloat
            if zoomScale < 1.5 {
                nextScale = 2.8
            } else if zoomScale < 4.2 {
                nextScale = 5.0
            } else {
                resetZoomAndPan()
                return
            }

            let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
            let dx = center.x - location.x
            let dy = center.y - location.y
            let targetOffset = CGSize(width: dx * (nextScale - 1.0), height: dy * (nextScale - 1.0))

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

    private var originalPhotoShareURL: URL? {
        guard item.preservesOriginalFile, !hasModifiedSinceOpen,
              currentProcessedImage === item.processedImage,
              let data = item.rawPhotoData else { return nil }
        let ext = item.saveFormat == .jpeg ? "jpg" : "heic"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AlignAI_Original_\(item.id.uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private var currentPhotoShareURL: URL? {
        if let originalURL = originalPhotoShareURL {
            return originalURL
        }
        let tempDir = FileManager.default.temporaryDirectory
        let isHEIC = item.saveFormat == .heif || item.saveFormat == .heic
        let ext = isHEIC ? "heic" : "jpg"
        let utType = isHEIC ? UTType.heic : UTType.jpeg
        let fileURL = tempDir.appendingPathComponent("AlignAI_Studio_\(item.id.uuidString).\(ext)")
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.96,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(dest, currentProcessedImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        do {
            try (data as Data).write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private var formatBadgeTitle: String {
        if item.saveFormat == .dng { return "TRUE RAW DNG" }
        if item.livePhotoMovieURL != nil { return "LIVE • \(item.saveFormat.rawValue)" }
        return item.saveFormat.rawValue
    }

    private var formatAccentColor: Color {
        if item.saveFormat == .dng { return AlignTheme.amberGold }
        if item.livePhotoMovieURL != nil { return AlignTheme.electricCyan }
        return .white
    }

    private var megapixelsString: String {
        let mp = Double(currentProcessedImage.width * currentProcessedImage.height) / 1_000_000.0
        return String(format: "%.1fMP", mp)
    }

    private var focalLengthDisplayString: String {
        let fl = item.focalLength > 0 ? item.focalLength : 24.0
        return "\(Int(round(fl)))mm"
    }

    private var formattedShutterSpeed: String {
        let s = item.shutterSpeed
        guard s > 0 else { return "1/120s" }
        if s >= 1.0 {
            return String(format: "%.1fs", s)
        }
        let denom = max(1, Int(round(1.0 / s)))
        return "1/\(denom)s"
    }

    private var opticalSummaryLine: String {
        let ap = item.aperture > 0 ? item.aperture : 1.8
        let isoVal = Int(round(max(25, item.iso)))
        return "\(focalLengthDisplayString) · f/\(String(format: "%.1f", ap)) · \(formattedShutterSpeed) · ISO \(isoVal)"
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
    let showRGB: Bool

    private func buildSmoothPath(bins: [Double], in size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard bins.count >= 2 else { return path }
        let stepX = size.width / CGFloat(bins.count - 1)
        if closed {
            path.move(to: CGPoint(x: 0, y: size.height))
            for (idx, val) in bins.enumerated() {
                let x = CGFloat(idx) * stepX
                let y = size.height * (1.0 - CGFloat(min(1.0, max(0.0, val))))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        } else {
            for (idx, val) in bins.enumerated() {
                let x = CGFloat(idx) * stepX
                let y = size.height * (1.0 - CGFloat(min(1.0, max(0.0, val))))
                if idx == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Subtle EV Zone Grid Lines (25%, 50%, 75%)
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.7)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.7)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.7)
                    Spacer()
                }

                if showRGB {
                    buildSmoothPath(bins: snapshot.redBins, in: size, closed: true)
                        .fill(Color.red.opacity(0.22))
                    buildSmoothPath(bins: snapshot.greenBins, in: size, closed: true)
                        .fill(Color.green.opacity(0.22))
                    buildSmoothPath(bins: snapshot.blueBins, in: size, closed: true)
                        .fill(Color.cyan.opacity(0.24))

                    buildSmoothPath(bins: snapshot.redBins, in: size, closed: false)
                        .stroke(Color.red.opacity(0.80), lineWidth: 1.0)
                    buildSmoothPath(bins: snapshot.greenBins, in: size, closed: false)
                        .stroke(Color.green.opacity(0.80), lineWidth: 1.0)
                    buildSmoothPath(bins: snapshot.blueBins, in: size, closed: false)
                        .stroke(Color.cyan.opacity(0.85), lineWidth: 1.0)
                }

                buildSmoothPath(bins: snapshot.lumaBins, in: size, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(showRGB ? 0.22 : 0.42), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                buildSmoothPath(bins: snapshot.lumaBins, in: size, closed: false)
                    .stroke(Color.white.opacity(0.92), lineWidth: 1.25)
            }
        }
    }
}
