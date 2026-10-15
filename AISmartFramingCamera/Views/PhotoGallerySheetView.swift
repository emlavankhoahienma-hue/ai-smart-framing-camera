import SwiftUI
import Photos
import UIKit

public enum GalleryTab: String, CaseIterable, Identifiable {
    case appAlbum = "Align Studio"
    case recent = "Apple Photos"

    public var id: String { rawValue }
}

public struct PhotoGallerySheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: GalleryTab = .appAlbum
    @State private var storedRecords: [AppPhotoStorageService.StoredPhotoRecord] = []
    @State private var recentAssets: [PHAsset] = []
    @State private var isLoadingRecords: Bool = true
    @State private var isLoadingAssets: Bool = false
    @State private var selectedPreviewItem: CapturedPhotoItem? = nil
    @State private var recordToDelete: AppPhotoStorageService.StoredPhotoRecord? = nil
    @State private var showDeleteConfirmation: Bool = false
    @State private var photoKitAuthorizationStatus: PHAuthorizationStatus = .notDetermined

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AlignTheme.obsidianBlack.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header Bar
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(AlignTheme.platinumWhite.opacity(0.65))
                        }
                        Spacer()
                        Text("Thư viện ảnh")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(AlignTheme.platinumWhite)
                        Spacer()
                        Color.clear.frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    // 2-Tab Custom Minimalist Pill Switcher
                    tabSelectorPill
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    // Tab Content
                    ScrollView {
                        if selectedTab == .appAlbum {
                            appAlbumGrid
                        } else {
                            recentPhotosGrid
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedPreviewItem) { item in
                CapturedPhotoPreviewView(item: item, viewModel: viewModel)
            }
            .confirmationDialog(
                "Xác nhận xóa ảnh này khỏi ứng dụng?",
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
            }
            .onAppear {
                fetchStoredRecords()
                checkPhotoKitStatus()
            }
        }
    }

    // MARK: - Tab Selector Pill
    private var tabSelectorPill: some View {
        HStack(spacing: 0) {
            ForEach(GalleryTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        selectedTab = tab
                        if tab == .recent && recentAssets.isEmpty {
                            fetchRecentPhotos()
                        }
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? AlignTheme.platinumWhite : AlignTheme.platinumWhite.opacity(0.60))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(AlignTheme.graphiteSurface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(AlignTheme.rimGradient, lineWidth: 1.2)
                                        )
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AlignTheme.carbonSurface)
        )
    }

    // MARK: - Tab 1: App Album Grid (Persistent Sandbox Storage)
    private var appAlbumGrid: some View {
        Group {
            if isLoadingRecords {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.electricCyan))
                    .padding(.top, 40)
            } else if storedRecords.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 42))
                        .foregroundColor(AlignTheme.electricCyan.opacity(0.7))

                    Text("Chưa có ảnh trong Align Studio")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AlignTheme.platinumWhite)

                    Text("Các ảnh chụp qua Align Studio sẽ được lưu an toàn tại đây và không bị mất khi thoát ứng dụng.")
                        .font(.system(size: 13))
                        .foregroundColor(AlignTheme.mutedCaption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(storedRecords) { record in
                        StoredRecordThumbnailCell(record: record) {
                            openRecordPreview(record)
                        } onLongPress: {
                            recordToDelete = record
                            showDeleteConfirmation = true
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Tab 2: Recent Device Photos Grid (Apple Photos)
    private var recentPhotosGrid: some View {
        Group {
            if photoKitAuthorizationStatus == .denied || photoKitAuthorizationStatus == .restricted {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 38))
                        .foregroundColor(AlignTheme.irisViolet.opacity(0.8))
                    Text("Chưa cấp quyền xem thư viện Apple Photos")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AlignTheme.platinumWhite)
                    Text("Bạn có thể vào Cài đặt máy > Quyền riêng tư > Ảnh để cho phép ứng dụng hiển thị ảnh gần đây.")
                        .font(.system(size: 12))
                        .foregroundColor(AlignTheme.mutedCaption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 60)
            } else if isLoadingAssets {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.electricCyan))
                    .padding(.top, 40)
            } else if recentAssets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundColor(AlignTheme.platinumWhite.opacity(0.35))
                    Text("Không tìm thấy ảnh trong Apple Photos")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AlignTheme.mutedCaption)
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(recentAssets, id: \.localIdentifier) { asset in
                        AssetThumbnailCell(asset: asset) {
                            loadFullPhotoAndPreview(asset: asset)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
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

    private func checkPhotoKitStatus() {
        photoKitAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if photoKitAuthorizationStatus == .authorized || photoKitAuthorizationStatus == .limited {
            fetchRecentPhotos()
        }
    }

    private func fetchRecentPhotos() {
        guard photoKitAuthorizationStatus == .authorized || photoKitAuthorizationStatus == .limited else {
            return
        }
        isLoadingAssets = true
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 90
            let results = PHAsset.fetchAssets(with: .image, options: options)
            var assets: [PHAsset] = []
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
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fullImage = AppPhotoStorageService.shared.loadFullImage(for: record) else { return }
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
                self.selectedPreviewItem = item
            }
        }
    }

    private func loadFullPhotoAndPreview(asset: PHAsset) {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, _ in
            guard let uiImage = image, let cgImage = uiImage.cgImage else { return }
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
                self.selectedPreviewItem = item
            }
        }
    }
}

// MARK: - Stored Record Thumbnail Cell
struct StoredRecordThumbnailCell: View {
    let record: AppPhotoStorageService.StoredPhotoRecord
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var thumbnailImage: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                AlignTheme.carbonSurface

                if let thumb = thumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 124)
                        .clipped()
                } else {
                    ProgressView()
                        .scaleEffect(0.65)
                        .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.electricCyan))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Format & info badge
                HStack(spacing: 4) {
                    Text(record.format)
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            record.isDNG ?
                            AnyView(Capsule().fill(AlignTheme.amberGold)) :
                            AnyView(Capsule().fill(AlignTheme.electricCyan))
                        )
                        .foregroundColor(.black)

                    Text(record.preset)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(AlignTheme.platinumWhite.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(4)
                .background(Color.black.opacity(0.65))
                .cornerRadius(4)
                .padding(4)
            }
            .frame(height: 124)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onLongPress) {
                Label("Xóa ảnh khỏi Align Studio", systemImage: "trash")
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if let cgThumb = AppPhotoStorageService.shared.loadThumbnailImage(for: record) {
                let uiThumb = UIImage(cgImage: cgThumb)
                DispatchQueue.main.async {
                    self.thumbnailImage = uiThumb
                }
            }
        }
    }
}

// MARK: - Asset Thumbnail Cell (Apple Photos)
struct AssetThumbnailCell: View {
    let asset: PHAsset
    let onTap: () -> Void

    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack {
                AlignTheme.carbonSurface

                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 124)
                        .clipped()
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.electricCyan))
                }
            }
            .frame(height: 124)
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: 240, height: 240)

        manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
            if let img = image {
                DispatchQueue.main.async {
                    self.thumbnail = img
                }
            }
        }
    }
}
