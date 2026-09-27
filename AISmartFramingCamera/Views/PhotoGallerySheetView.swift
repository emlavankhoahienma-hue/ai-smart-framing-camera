import SwiftUI
import Photos
import UIKit

public enum GalleryTab: String, CaseIterable, Identifiable {
    case recent = "Gần đây"
    case appAlbum = "AlignAI Studio"

    public var id: String { rawValue }
}

public struct PhotoGallerySheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: GalleryTab = .recent
    @State private var recentAssets: [PHAsset] = []
    @State private var savedRawURLs: [URL] = []
    @State private var isLoadingAssets: Bool = true
    @State private var selectedPreviewItem: CapturedPhotoItem? = nil

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)
    private let darkBg = Color(red: 0.031, green: 0.035, blue: 0.043)
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
                darkBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header Bar
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        Spacer()
                        Text("Thư viện ảnh")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Color.clear.frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    // 2-Tab Segmented Switcher (Recent vs AlignAI Studio)
                    Picker("Tab", selection: $selectedTab) {
                        ForEach(GalleryTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // Tab Content
                    ScrollView {
                        if selectedTab == .recent {
                            recentPhotosGrid
                        } else {
                            appAlbumGrid
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedPreviewItem) { item in
                CapturedPhotoPreviewView(item: item, viewModel: viewModel)
            }
            .onAppear {
                fetchRecentPhotos()
                fetchSavedRawFiles()
            }
        }
    }

    // MARK: - Tab 1: Recent Photos Grid
    private var recentPhotosGrid: some View {
        Group {
            if isLoadingAssets {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: amberGold))
                    .padding(.top, 40)
            } else if recentAssets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Không tìm thấy ảnh trong thư viện")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
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

    // MARK: - Tab 2: App Album & RAW Storage Grid
    private var appAlbumGrid: some View {
        Group {
            if viewModel.latestCapturedPhoto != nil || !savedRawURLs.isEmpty {
                LazyVGrid(columns: columns, spacing: 2) {
                    if let latest = viewModel.latestCapturedPhoto {
                        Button(action: {
                            selectedPreviewItem = latest
                        }) {
                            Image(decorative: latest.processedImage, scale: 1.0, orientation: .up)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .frame(height: 124)
                                .clipped()
                        }
                    }

                    ForEach(savedRawURLs, id: \.self) { url in
                        RawFileThumbnailCell(url: url) {
                            loadRawFileAndPreview(url: url)
                        }
                    }
                }
                .padding(.horizontal, 2)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 40))
                        .foregroundColor(amberGold.opacity(0.6))
                    Text("Chưa có ảnh trong album AlignAI Studio")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text("Chụp ảnh RAW hoặc ảnh màu để lưu an toàn vào ứng dụng.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.50))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 60)
            }
        }
    }

    private func fetchRecentPhotos() {
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

    private func fetchSavedRawFiles() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let rawDirectory = documentsURL.appendingPathComponent("RAW", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: rawDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) else {
            return
        }
        self.savedRawURLs = files.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return d1 > d2
            }
    }

    private func loadRawFileAndPreview(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            let previewOptions = [
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 2048,
                kCGImageSourceShouldCacheImmediately as String: false
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, previewOptions)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

            let item = CapturedPhotoItem(
                originalImage: cgImage,
                processedImage: cgImage,
                rawPhotoData: data,
                saveFormat: .dng,
                preservesOriginalFile: true,
                rawLocalFileURL: url,
                sceneType: .general,
                appliedPreset: .standard,
                compositionRule: .ruleOfThirds,
                alignmentScore: 1.0,
                timestamp: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
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

// MARK: - RAW File Thumbnail Cell
struct RawFileThumbnailCell: View {
    let url: URL
    let onTap: () -> Void

    @State private var thumbnail: UIImage? = nil
    @State private var fileSizeString: String = ""

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                Color(red: 0.10, green: 0.11, blue: 0.14)

                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 124)
                        .clipped()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 26))
                            .foregroundColor(amberGold)
                        Text("RAW DNG")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Bottom badge
                HStack(spacing: 4) {
                    Text("RAW")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(amberGold)
                        .foregroundColor(.black)
                        .cornerRadius(3)

                    if !fileSizeString.isEmpty {
                        Text(fileSizeString)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(5)
                .background(Color.black.opacity(0.65))
                .cornerRadius(4)
                .padding(4)
            }
            .frame(height: 124)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnailAndSize()
        }
    }

    private func loadThumbnailAndSize() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                let mb = Double(size) / (1024.0 * 1024.0)
                DispatchQueue.main.async {
                    self.fileSizeString = String(format: "%.1fMB", mb)
                }
            }
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            let thumbOptions = [
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 240,
                kCGImageSourceShouldCacheImmediately as String: false
            ] as CFDictionary
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) {
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    self.thumbnail = uiImage
                }
            }
        }
    }
}

// MARK: - Asset Thumbnail Cell
struct AssetThumbnailCell: View {
    let asset: PHAsset
    let onTap: () -> Void

    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Color(red: 0.10, green: 0.11, blue: 0.14)

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
