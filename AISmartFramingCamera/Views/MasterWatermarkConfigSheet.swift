import SwiftUI
import PhotosUI

@MainActor
public struct MasterWatermarkConfigSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    private let presetDevices = ["ALIGN STUDIO", "LEICA M11-P", "XIAOMI 15 ULTRA", "IPHONE 16 PRO"]

    // Design Tokens
    private let canvasColor = Color(red: 12/255, green: 12/255, blue: 14/255)
    private let cardColor = Color(red: 24/255, green: 24/255, blue: 27/255)
    private let borderColor = Color(red: 39/255, green: 39/255, blue: 42/255)
    private let accentColor = Color(red: 56/255, green: 189/255, blue: 248/255)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasColor.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        watermarkToggleSection
                        deviceNameSection
                        themeSection
                        logoSection
                        previewSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Khung Chữ Ký Master")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(accentColor)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    // MARK: - 1. Bật tắt Khung Master
    @ViewBuilder
    private var watermarkToggleSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Đóng Khung Master")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Tự động đính kèm chữ ký viền ảnh Leica")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 161/255, green: 161/255, blue: 170/255))
            }
            Spacer()
            Toggle("", isOn: $viewModel.isMasterWatermarkEnabled)
                .labelsHidden()
                .tint(accentColor)
        }
        .padding(16)
        .background(cardColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - 2. Tên Thiết Bị / Chữ Ký
    @ViewBuilder
    private var deviceNameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TÊN THIẾT BỊ / THƯƠNG HIỆU")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 161/255, green: 161/255, blue: 170/255))

            TextField("Nhập tên hiển thị...", text: $viewModel.masterWatermarkDeviceName)
                .font(.system(size: 14, weight: .medium))
                .padding(12)
                .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                .cornerRadius(10)
                .foregroundColor(.white)

            HStack(spacing: 8) {
                ForEach(presetDevices, id: \.self) { name in
                    Button(action: {
                        viewModel.masterWatermarkDeviceName = name
                    }) {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(viewModel.masterWatermarkDeviceName == name ? accentColor.opacity(0.18) : Color(red: 36/255, green: 36/255, blue: 41/255))
                            .foregroundColor(viewModel.masterWatermarkDeviceName == name ? accentColor : Color(red: 228/255, green: 228/255, blue: 231/255))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(viewModel.masterWatermarkDeviceName == name ? accentColor.opacity(0.6) : borderColor, lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(16)
        .background(cardColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - 3. Màu Khung Nền
    @ViewBuilder
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MÀU NỀN KHUNG")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 161/255, green: 161/255, blue: 170/255))

            HStack(spacing: 12) {
                ForEach(WatermarkTheme.allCases) { theme in
                    Button(action: {
                        viewModel.masterWatermarkTheme = theme
                    }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(theme == .white ? Color.white : Color(red: 12/255, green: 12/255, blue: 14/255))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(borderColor, lineWidth: 1))
                            Text(theme.rawValue)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(viewModel.masterWatermarkTheme == theme ? accentColor.opacity(0.18) : Color(red: 36/255, green: 36/255, blue: 41/255))
                        .foregroundColor(viewModel.masterWatermarkTheme == theme ? accentColor : Color(red: 228/255, green: 228/255, blue: 231/255))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(viewModel.masterWatermarkTheme == theme ? accentColor.opacity(0.6) : borderColor, lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(cardColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - 4. Huy Hiệu Logo
    @ViewBuilder
    private var logoSection: some View {
        let hasCustomLogo = viewModel.masterWatermarkCustomLogoImage != nil
        let isCustomStyle = viewModel.masterWatermarkLogoStyle == .customImage

        VStack(alignment: .leading, spacing: 12) {
            Text("HUY HIỆU LOGO")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 161/255, green: 161/255, blue: 170/255))

            HStack(spacing: 8) {
                logoStyleButton(title: "Logo App", style: .alignStudio, icon: "viewfinder")
                logoStyleButton(title: "Apple", style: .appleIcon, icon: "apple.logo")
                logoStyleButton(title: "Ống kính", style: .aperturePro, icon: "camera.aperture")
                logoStyleButton(title: "Ẩn", style: .none, icon: "slash.circle")
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 14))
                    Text(hasCustomLogo ? "Đã chọn ảnh tự chọn (Nhấn để đổi)" : "Tải logo từ Thư viện ảnh")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isCustomStyle ? accentColor.opacity(0.18) : Color(red: 36/255, green: 36/255, blue: 41/255))
                .foregroundColor(isCustomStyle ? accentColor : Color(red: 228/255, green: 228/255, blue: 231/255))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isCustomStyle ? accentColor.opacity(0.6) : borderColor, lineWidth: 1)
                )
            }
            .onChangeCompatible(of: selectedPhotoItem) { newItem in
                handlePhotoSelection(newItem)
            }
        }
        .padding(16)
        .background(cardColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImg = UIImage(data: data) {
                viewModel.setMasterWatermarkCustomLogo(uiImg)
            }
        }
    }

    // MARK: - 5. Xem Trước (Live Preview)
    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("XEM TRƯỚC KHUNG WATERMARK")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 161/255, green: 161/255, blue: 170/255))

            watermarkMockPreview
        }
        .padding(16)
        .background(cardColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func logoStyleButton(title: String, style: WatermarkLogoStyle, icon: String) -> some View {
        let isSelected = viewModel.masterWatermarkLogoStyle == style
        return Button(action: {
            viewModel.masterWatermarkLogoStyle = style
        }) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? accentColor : Color(red: 228/255, green: 228/255, blue: 231/255))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? accentColor.opacity(0.18) : Color(red: 36/255, green: 36/255, blue: 41/255))
            .foregroundColor(isSelected ? accentColor : Color(red: 228/255, green: 228/255, blue: 231/255))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? accentColor.opacity(0.6) : borderColor, lineWidth: 1)
            )
        }
    }

    private var watermarkMockPreview: some View {
        let isNone = viewModel.masterWatermarkLogoStyle == .none

        return HStack {
            Text(viewModel.masterWatermarkDeviceName.isEmpty ? "ALIGN STUDIO" : viewModel.masterWatermarkDeviceName.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundColor(viewModel.masterWatermarkTheme == .white ? Color(red: 0.07, green: 0.07, blue: 0.07) : Color(red: 0.97, green: 0.98, blue: 0.99))

            Spacer()

            HStack(spacing: 8) {
                if !isNone {
                    mockLogoBadgeView

                    Rectangle()
                        .fill(viewModel.masterWatermarkTheme == .white ? Color(red: 0.83, green: 0.83, blue: 0.85) : Color(red: 0.25, green: 0.25, blue: 0.28))
                        .frame(width: 1.5, height: 14)
                }

                Text("70mm  f/1.8  1/250s  ISO800")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(viewModel.masterWatermarkTheme == .white ? Color(red: 0.07, green: 0.07, blue: 0.07) : Color(red: 0.97, green: 0.98, blue: 0.99))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(viewModel.masterWatermarkTheme == .white ? Color.white : Color(red: 0.04, green: 0.04, blue: 0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var mockLogoBadgeView: some View {
        let themeColor = viewModel.masterWatermarkTheme == .white ? Color(red: 0.07, green: 0.07, blue: 0.07) : Color(red: 0.97, green: 0.98, blue: 0.99)

        switch viewModel.masterWatermarkLogoStyle {
        case .alignStudio:
            if let img = UIImage(named: "AppLogo") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "AppLogo", ofType: "png") ?? "") {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                        .frame(width: 18, height: 18)
                    Circle()
                        .stroke(accentColor, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                }
            }
        case .appleIcon:
            Image(systemName: "apple.logo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeColor)
                .frame(width: 18, height: 18)
        case .aperturePro:
            Image(systemName: "camera.aperture")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(themeColor)
                .frame(width: 18, height: 18)
        case .customImage:
            if let img = viewModel.masterWatermarkCustomLogoImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo.circle")
                    .font(.system(size: 14))
                    .foregroundColor(themeColor)
            }
        case .none:
            EmptyView()
        }
    }
}
