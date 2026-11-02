import SwiftUI
import PhotosUI

public struct MasterWatermarkConfigSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    private let presetDevices = ["ALIGN STUDIO ULTRA", "XIAOMI 15 ULTRA", "LEICA M11-P", "IPHONE 16 PRO"]

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.10).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        watermarkToggleSection
                        deviceNameSection
                        themeSection
                        logoSection
                        previewSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Khung Chữ Ký Master")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(.yellow)
                        .fontWeight(.bold)
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
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Tự động thêm chữ ký Leica quang học vào ảnh chụp")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            Toggle("", isOn: $viewModel.isMasterWatermarkEnabled)
                .labelsHidden()
                .tint(Color.yellow)
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    // MARK: - 2. Tên Thiết Bị / Chữ Ký
    @ViewBuilder
    private var deviceNameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TÊN THIẾT BỊ / THƯƠNG HIỆU")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            TextField("Nhập tên hiển thị...", text: $viewModel.masterWatermarkDeviceName)
                .font(.system(size: 15, weight: .semibold))
                .padding(12)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
                .foregroundColor(.white)

            HStack(spacing: 8) {
                ForEach(presetDevices, id: \.self) { name in
                    Button(action: {
                        viewModel.masterWatermarkDeviceName = name
                    }) {
                        Text(name)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(viewModel.masterWatermarkDeviceName == name ? Color.yellow.opacity(0.2) : Color.white.opacity(0.06))
                            .foregroundColor(viewModel.masterWatermarkDeviceName == name ? .yellow : .white.opacity(0.8))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    // MARK: - 3. Màu Khung Nền
    @ViewBuilder
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MÀU NỀN KHUNG")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 12) {
                ForEach(WatermarkTheme.allCases) { theme in
                    Button(action: {
                        viewModel.masterWatermarkTheme = theme
                    }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(theme == .white ? Color.white : Color(red: 0.1, green: 0.1, blue: 0.12))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1))
                            Text(theme.rawValue)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(viewModel.masterWatermarkTheme == theme ? Color.yellow.opacity(0.18) : Color.white.opacity(0.06))
                        .foregroundColor(viewModel.masterWatermarkTheme == theme ? .yellow : .white)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(viewModel.masterWatermarkTheme == theme ? Color.yellow : Color.clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    // MARK: - 4. Huy Hiệu Logo
    @ViewBuilder
    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HUY HIỆU LOGO")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 10) {
                logoStyleButton(title: "Chấm Đỏ", style: .leicaRedDot, color: Color(red: 0.89, green: 0.02, blue: 0.07))
                logoStyleButton(title: "Vàng Kim", style: .goldBadge, color: Color(red: 0.83, green: 0.69, blue: 0.22))
                logoStyleButton(title: "Đen Tuyền", style: .monochrome, color: Color(red: 0.15, green: 0.15, blue: 0.15))
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text(viewModel.masterWatermarkCustomLogoImage != nil ? "Đã chọn Logo từ Thư viện (Nhấn để đổi)" : "Tải Logo từ Thư viện ảnh")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(viewModel.masterWatermarkLogoStyle == .custom ? Color.yellow.opacity(0.2) : Color.white.opacity(0.06))
                .foregroundColor(viewModel.masterWatermarkLogoStyle == .custom ? .yellow : .white)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(viewModel.masterWatermarkLogoStyle == .custom ? Color.yellow : Color.clear, lineWidth: 1.5)
                )
            }
            .onChange(of: selectedPhotoItem) { newItem in
                handlePhotoSelection(newItem)
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImg = UIImage(data: data) {
                await MainActor.run {
                    viewModel.setMasterWatermarkCustomLogo(uiImg)
                }
            }
        }
    }

    // MARK: - 5. Xem Trước (Live Preview)
    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("XEM TRƯỚC KHUNG WATERMARK")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            watermarkMockPreview
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private func logoStyleButton(title: String, style: WatermarkLogoStyle, color: Color) -> some View {
        Button(action: {
            viewModel.masterWatermarkLogoStyle = style
        }) {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(viewModel.masterWatermarkLogoStyle == style ? Color.yellow.opacity(0.18) : Color.white.opacity(0.06))
            .foregroundColor(viewModel.masterWatermarkLogoStyle == style ? .yellow : .white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(viewModel.masterWatermarkLogoStyle == style ? Color.yellow : Color.clear, lineWidth: 1.5)
            )
        }
    }

    private var watermarkMockPreview: some View {
        HStack {
            Text(viewModel.masterWatermarkDeviceName.isEmpty ? "ALIGN STUDIO ULTRA" : viewModel.masterWatermarkDeviceName.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundColor(viewModel.masterWatermarkTheme == .white ? Color(red: 0.07, green: 0.07, blue: 0.07) : Color(red: 0.97, green: 0.98, blue: 0.99))

            Spacer()

            HStack(spacing: 8) {
                if viewModel.masterWatermarkLogoStyle == .custom, let img = viewModel.masterWatermarkCustomLogoImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(viewModel.masterWatermarkLogoStyle == .goldBadge ? Color(red: 0.83, green: 0.69, blue: 0.22) : (viewModel.masterWatermarkLogoStyle == .monochrome ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.89, green: 0.02, blue: 0.07)))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Text("A")
                                .font(.system(size: 10, weight: .heavy, design: .serif))
                                .foregroundColor(.white)
                        )
                }

                Rectangle()
                    .fill(viewModel.masterWatermarkTheme == .white ? Color(red: 0.83, green: 0.83, blue: 0.85) : Color(red: 0.25, green: 0.25, blue: 0.28))
                    .frame(width: 1.5, height: 14)

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
}
