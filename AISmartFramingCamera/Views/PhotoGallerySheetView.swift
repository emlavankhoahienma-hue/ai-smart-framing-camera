import SwiftUI
import Photos
import AVFoundation
import UIKit

public enum GalleryTab: String, CaseIterable, Identifiable {
    case appAlbum = "Align Studio"
    case recent = "Apple Photos"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .appAlbum: return "camera.aperture"
        case .recent: return "photo.on.rectangle"
        }
    }
}

private enum ApplePhotosMediaFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case photos = "Ảnh"
    case videos = "Video"

    var id: String { rawValue }
}

private struct GalleryVideoPreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
}

public struct PhotoGallerySheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Namespace private var tabNamespace

    @State private var selectedTab: GalleryTab = .appAlbum
    @State private var appleFilter: ApplePhotosMediaFilter = .all
    @State private var storedRecords: [AppPhotoStorageService.StoredPhotoRecord] = []
    @State private var recentAssets: [PHAsset] = []
    @State private var isLoadingRecords: Bool = true
    @State private var isLoadingAssets: Bool = false
    @State private var isOpeningMedia: Bool = false
    @State private var openingStatusText: String = "Đang mở..."
    @State private var galleryErrorBanner: String? = nil

    @State private var selectedPreviewItem: CapturedPhotoItem? = nil
    @State private var selectedVideoTarget: GalleryVideoPreviewTarget? = nil
    @State private var recordToDelete: AppPhotoStorageService.StoredPhotoRecord? = nil
    @State private var showDeleteConfirmation: Bool = false
    @State private var photoKitAuthorizationStatus: PHAuthorizationStatus = .notDetermined

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    private var filteredRecentAssets: [PHAsset] {
        switch appleFilter {
        case .all:
            return recentAssets
        case .photos:
            return recentAssets.filter { $0.mediaType == .image }
        case .videos:
            return recentAssets.filter { $0.mediaType == .video }
        }
    }

    private var activeCountSubtitle: String {
        if selectedTab == .appAlbum {
            return "\(storedRecords.count) ảnh · Align Studio"
        }
        let count = filteredRecentAssets.count
        switch appleFilter {
        case .all: return "\(count) mục · Apple Photos"
        case .photos: return "\(count) ảnh · Apple Photos"
        case .videos: return "\(count) video · Apple Photos"
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AlignTheme.studioCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    studioHeaderBar

                    tabSelectorBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, selectedTab == .recent ? 10 : 12)

                    if selectedTab == .recent && (photoKitAuthorizationStatus == .authorized || photoKitAuthorizationStatus == .limited) {
                        applePhotosFilterBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }

                    if selectedTab == .recent && photoKitAuthorizationStatus == .limited {
                        limitedAccessBanner
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }

                    GeometryReader { geo in
                        let spacing: CGFloat = 2
                        let totalHorizontalPadding: CGFloat = 4
                        let cellSide = max(60, floor((geo.size.width - totalHorizontalPadding - spacing * 2) / 3.0))
                        let gridColumns = Array(repeating: GridItem(.fixed(cellSide), spacing: spacing), count: 3)

                        ScrollView(.vertical, showsIndicators: true) {
                            if selectedTab == .appAlbum {
                                appAlbumContent(columns: gridColumns, cellSide: cellSide)
                            } else {
                                recentPhotosContent(columns: gridColumns, cellSide: cellSide)
                            }
                        }
                    }
                }

                // Subtle Frosted Loading Overlay When Opening High-Res / iCloud Media
                if isOpeningMedia {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                            .scaleEffect(0.85)
                        Text(openingStatusText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(StudioGlassCapsule(tintOpacity: 0.78, borderOpacity: 0.16))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }

                // Non-Blocking Error Toast
                if let err = galleryErrorBanner {
                    VStack {
                        Spacer()
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AlignTheme.studioRecordRed)
                            Text(err)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(StudioGlassCapsule(tintOpacity: 0.76, borderOpacity: 0.16))
                        .padding(.bottom, 24)
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .fullScreenCover(item: $selectedPreviewItem) { item in
                CapturedPhotoPreviewView(item: item, viewModel: viewModel)
            }
            .fullScreenCover(item: $selectedVideoTarget) { target in
                VideoPreviewSheetView(videoURL: target.url, viewModel: viewModel, isAlreadySavedInPhotos: true)
            }
            .confirmationDialog(
                "Xác nhận xóa ảnh này khỏi Align Studio?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Xóa ảnh", role: .destructive) {
                    if let record = recordToDelete {
                        AppPhotoStorageService.shared.deleteRecord(record)
                        fetchStoredRecords()
                        recordToDelete = nil
                    }
                }
                Button("Hủy", role: .cancel) {
                    recordToDelete = nil
                }
            } message: {
                Text("Ảnh chỉ bị xóa khỏi kho nội bộ của ứng dụng; bản đã lưu trong Apple Photos vẫn được giữ nguyên.")
            }
            .onAppear {
                CameraLogger.lifecycle("VIEW_APPEAR", detail: "PhotoGallerySheetView", category: .photoKit)
                fetchStoredRecords()
                checkPhotoKitStatus()
            }
            .onDisappear {
                CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "PhotoGallerySheetView", category: .photoKit)
            }
        }
    }

    // MARK: - 1. Clean Unified Studio Header Bar
    private var studioHeaderBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng thư viện")

            Spacer()

            VStack(spacing: 2) {
                Text("Thư viện")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkPrimary)

                Text(activeCountSubtitle)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(AlignTheme.studioInkSecondary)
            }

            Spacer()

            Button(action: {
                viewModel.haptics.triggerSelectionChange()
                if selectedTab == .appAlbum {
                    fetchStoredRecords()
                } else {
                    checkPhotoKitStatus(forceRefresh: true)
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Làm mới thư viện")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 2. Refined Segmented Tab Bar (Matched Geometry, Monochrome + Warm Titanium)
    private var tabSelectorBar: some View {
        HStack(spacing: 4) {
            ForEach(GalleryTab.allCases) { tab in
                let isSelected = (selectedTab == tab)
                Button(action: {
                    viewModel.haptics.triggerSelectionChange()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                        if tab == .recent && recentAssets.isEmpty {
                            checkPhotoKitStatus()
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)

                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8.5)
                    .background(
                        ZStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(AlignTheme.studioElevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(AlignTheme.studioHairline, lineWidth: 0.65)
                                    )
                                    .matchedGeometryEffect(id: "gallery_active_tab", in: tabNamespace)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3.5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AlignTheme.studioSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                )
        )
    }

    // MARK: - Apple Photos Sub-Filter Pills (Tất cả · Ảnh · Video)
    private var applePhotosFilterBar: some View {
        HStack(spacing: 8) {
            ForEach(ApplePhotosMediaFilter.allCases) { filter in
                let isSelected = (appleFilter == filter)
                Button(action: {
                    viewModel.haptics.triggerSelectionChange()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        appleFilter = filter
                    }
                }) {
                    Text(filter.rawValue)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(isSelected ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var limitedAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AlignTheme.studioAccent)
            Text("Chỉ hiển thị các mục bạn đã cho phép")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundColor(AlignTheme.studioInkSecondary)
            Spacer()
            Button("Cài đặt") {
                openAppSettings()
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundColor(AlignTheme.studioInkPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AlignTheme.studioSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                )
        )
    }

    // MARK: - Tab 1: Align Studio Album Grid
    @ViewBuilder
    private func appAlbumContent(columns: [GridItem], cellSide: CGFloat) -> some View {
        if isLoadingRecords {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
        } else if storedRecords.isEmpty {
            studioEmptyState(
                icon: "camera.viewfinder",
                title: "Chưa có ảnh trong Align Studio",
                subtitle: "Mọi ảnh chụp từ Align Studio được lưu an toàn tại đây với chất lượng gốc để mở chỉnh màu bất cứ lúc nào."
            )
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(storedRecords) { record in
                    StoredRecordThumbnailCell(
                        record: record,
                        sideLength: cellSide,
                        onTap: { openRecordPreview(record) },
                        onDeleteRequest: {
                            recordToDelete = record
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Tab 2: Apple Photos & Videos Grid
    @ViewBuilder
    private func recentPhotosContent(columns: [GridItem], cellSide: CGFloat) -> some View {
        if photoKitAuthorizationStatus == .notDetermined {
            studioEmptyState(
                icon: "photo.on.rectangle.angled",
                title: "Kết nối thư viện Apple Photos",
                subtitle: "Cho phép truy cập để xem nhanh ảnh và video gần đây ngay trong giao diện Darkroom của Align Studio.",
                ctaTitle: "Cho phép truy cập"
            ) {
                requestPhotoKitAuthorization()
            }
        } else if photoKitAuthorizationStatus == .denied || photoKitAuthorizationStatus == .restricted {
            studioEmptyState(
                icon: "lock.shield",
                title: "Chưa có quyền truy cập Ảnh",
                subtitle: "Mở Cài đặt > Quyền riêng tư > Ảnh để cho phép Align Studio hiển thị ảnh và video gần đây của bạn.",
                ctaTitle: "Mở Cài đặt"
            ) {
                openAppSettings()
            }
        } else if isLoadingAssets {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
        } else if filteredRecentAssets.isEmpty {
            let emptyLabel = appleFilter == .videos
                ? "Chưa có video trong Apple Photos"
                : "Không tìm thấy ảnh trong Apple Photos"
            studioEmptyState(
                icon: appleFilter == .videos ? "video" : "photo.on.rectangle.angled",
                title: emptyLabel,
                subtitle: "Ảnh và video bạn chụp hoặc lưu gần đây sẽ xuất hiện tự động tại đây."
            )
        } else {
            let pixelSize = CGSize(width: cellSide * max(displayScale, 2.0), height: cellSide * max(displayScale, 2.0))
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(filteredRecentAssets, id: \.localIdentifier) { asset in
                    AssetThumbnailCell(
                        asset: asset,
                        sideLength: cellSide,
                        targetPixelSize: pixelSize
                    ) {
                        openApplePhotosAsset(asset)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 28)
        }
    }

    private func studioEmptyState(
        icon: String,
        title: String,
        subtitle: String,
        ctaTitle: String? = nil,
        ctaAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AlignTheme.studioSurface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle().stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                    )
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(AlignTheme.studioAccent)
            }

            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(AlignTheme.studioInkPrimary)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(AlignTheme.studioInkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 36)

            if let ctaTitle, let ctaAction {
                Button(action: ctaAction) {
                    Text(ctaTitle)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(AlignTheme.studioInkPrimary))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    // MARK: - Data Operations
    private func fetchStoredRecords() {
        isLoadingRecords = true
        DispatchQueue.global(qos: .userInitiated).async {
            let records = AppPhotoStorageService.shared.fetchAllRecords()
            DispatchQueue.main.async {
                self.storedRecords = records
                self.isLoadingRecords = false
            }
        }
    }

    private func checkPhotoKitStatus(forceRefresh: Bool = false) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoKitAuthorizationStatus = status
        if status == .authorized || status == .limited {
            if forceRefresh || recentAssets.isEmpty {
                fetchRecentMedia()
            }
        }
    }

    private func requestPhotoKitAuthorization() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await MainActor.run {
                self.photoKitAuthorizationStatus = status
                if status == .authorized || status == .limited {
                    self.fetchRecentMedia()
                }
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func fetchRecentMedia() {
        guard photoKitAuthorizationStatus == .authorized || photoKitAuthorizationStatus == .limited else {
            return
        }
        isLoadingAssets = true
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
            options.fetchLimit = 120
            let results = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(results.count)
            results.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            DispatchQueue.main.async {
                self.recentAssets = assets
                self.isLoadingAssets = false
            }
        }
    }

    private func openRecordPreview(_ record: AppPhotoStorageService.StoredPhotoRecord) {
        guard !isOpeningMedia else { return }
        openingStatusText = "Đang mở ảnh gốc..."
        isOpeningMedia = true

        DispatchQueue.global(qos: .userInitiated).async {
            guard let fullImage = AppPhotoStorageService.shared.loadFullImage(for: record) else {
                DispatchQueue.main.async {
                    self.isOpeningMedia = false
                    self.showTemporaryError("Không thể đọc tệp ảnh này")
                }
                return
            }
            let photoData = try? Data(contentsOf: AppPhotoStorageService.shared.photoURL(for: record))
            let item = CapturedPhotoItem(
                originalImage: fullImage,
                processedImage: fullImage,
                rawPhotoData: photoData,
                saveFormat: record.isDNG ? .dng : .jpeg,
                preservesOriginalFile: true,
                rawLocalFileURL: record.isDNG ? AppPhotoStorageService.shared.photoURL(for: record) : nil,
                sceneType: .general,
                appliedPreset: .standard,
                compositionRule: .ruleOfThirds,
                alignmentScore: record.alignmentScore,
                timestamp: record.timestamp,
                iso: record.iso,
                shutterSpeed: record.shutterSpeed
            )
            DispatchQueue.main.async {
                self.isOpeningMedia = false
                self.selectedPreviewItem = item
            }
        }
    }

    private func openApplePhotosAsset(_ asset: PHAsset) {
        guard !isOpeningMedia else { return }
        if asset.mediaType == .video {
            loadVideoAndPreview(asset: asset)
        } else {
            loadFullPhotoAndPreview(asset: asset)
        }
    }

    private func loadFullPhotoAndPreview(asset: PHAsset) {
        openingStatusText = "Đang tải ảnh gốc..."
        isOpeningMedia = true

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, _ in
            guard let uiImage = image else {
                DispatchQueue.main.async {
                    self.isOpeningMedia = false
                    self.showTemporaryError("Không thể tải ảnh từ Apple Photos")
                }
                return
            }
            let cgImage: CGImage
            if uiImage.imageOrientation == .up, let directCG = uiImage.cgImage {
                cgImage = directCG
            } else {
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1.0
                let normalized = UIGraphicsImageRenderer(size: uiImage.size, format: format).image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
                }
                guard let normCG = normalized.cgImage ?? uiImage.cgImage else {
                    DispatchQueue.main.async {
                        self.isOpeningMedia = false
                        self.showTemporaryError("Không thể giải mã ảnh")
                    }
                    return
                }
                cgImage = normCG
            }
            let item = CapturedPhotoItem(
                originalImage: cgImage,
                processedImage: cgImage,
                sceneType: .general,
                appliedPreset: .standard,
                compositionRule: .ruleOfThirds,
                alignmentScore: 1.0,
                timestamp: asset.creationDate ?? Date()
            )
            DispatchQueue.main.async {
                self.isOpeningMedia = false
                self.selectedPreviewItem = item
            }
        }
    }

    private func loadVideoAndPreview(asset: PHAsset) {
        openingStatusText = "Đang tải video..."
        isOpeningMedia = true

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            let resolvedURL = (avAsset as? AVURLAsset)?.url
            DispatchQueue.main.async {
                self.isOpeningMedia = false
                if let resolvedURL {
                    self.selectedVideoTarget = GalleryVideoPreviewTarget(url: resolvedURL)
                } else {
                    self.showTemporaryError("Video này cần được tải về máy trước khi phát")
                }
            }
        }
    }

    private func showTemporaryError(_ message: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            galleryErrorBanner = message
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeInOut(duration: 0.22)) {
                if galleryErrorBanner == message {
                    galleryErrorBanner = nil
                }
            }
        }
    }
}

// MARK: - Bounded NSCache for Align Studio Gallery Thumbnails (Prevents Re-Decode Spikes & RAM Bloat)
public final class GalleryThumbnailMemoryCache: @unchecked Sendable {
    public static let shared = GalleryThumbnailMemoryCache()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    public func store(_ image: UIImage, forKey key: String) {
        let cost: Int
        if let cg = image.cgImage {
            cost = max(4096, cg.bytesPerRow * cg.height)
        } else {
            cost = max(4096, Int(image.size.width * image.size.height * image.scale * image.scale * 4.0))
        }
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    public static func clearAll() {
        shared.cache.removeAllObjects()
    }
}

// MARK: - Stored Record Square Thumbnail Cell (Quiet Darkroom Rhythm)
private struct StoredRecordThumbnailCell: View {
    let record: AppPhotoStorageService.StoredPhotoRecord
    let sideLength: CGFloat
    let onTap: () -> Void
    let onDeleteRequest: () -> Void

    @State private var thumbnailImage: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                AlignTheme.studioSurface

                if let thumb = thumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: sideLength, height: sideLength)
                        .clipped()
                } else {
                    ProgressView()
                        .scaleEffect(0.65)
                        .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioInkTertiary))
                }

                // Quiet Micro-Badge Only for RAW/DNG (keeps 98% of photo unobstructed)
                if record.isDNG {
                    Text("RAW")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.66))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(AlignTheme.studioAccentBorder, lineWidth: 0.5)
                                )
                        )
                        .padding(5)
                }
            }
            .frame(width: sideLength, height: sideLength)
            .clipped()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDeleteRequest) {
                Label("Xóa ảnh khỏi Align Studio", systemImage: "trash")
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil else { return }
        let cacheKey = record.thumbnailFilename.isEmpty ? record.id.uuidString : record.thumbnailFilename
        if let cached = GalleryThumbnailMemoryCache.shared.image(forKey: cacheKey) {
            self.thumbnailImage = cached
            return
        }
        let targetRecord = record
        DispatchQueue.global(qos: .userInitiated).async {
            if let cgThumb = AppPhotoStorageService.shared.loadThumbnailImage(for: targetRecord) {
                let uiThumb = UIImage(cgImage: cgThumb)
                GalleryThumbnailMemoryCache.shared.store(uiThumb, forKey: cacheKey)
                DispatchQueue.main.async {
                    self.thumbnailImage = uiThumb
                }
            }
        }
    }
}

// MARK: - Apple Photos & Videos Square Thumbnail Cell
private struct AssetThumbnailCell: View {
    let asset: PHAsset
    let sideLength: CGFloat
    let targetPixelSize: CGSize
    let onTap: () -> Void

    @State private var thumbnail: UIImage? = nil
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                AlignTheme.studioSurface

                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: sideLength, height: sideLength)
                        .clipped()
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioInkTertiary))
                }

                if asset.mediaType == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7.5, weight: .bold))
                        Text(VideoPreviewMetadata.formatDuration(asset.duration))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.62))
                    )
                    .padding(5)
                }
            }
            .frame(width: sideLength, height: sideLength)
            .clipped()
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
                requestID = PHInvalidImageRequestID
            }
        }
    }

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = manager.requestImage(
            for: asset,
            targetSize: targetPixelSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded {
                DispatchQueue.main.async {
                    self.requestID = PHInvalidImageRequestID
                }
            }
            if let img = image {
                DispatchQueue.main.async {
                    self.thumbnail = img
                }
            }
        }
    }
}
