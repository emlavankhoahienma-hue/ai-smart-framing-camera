import SwiftUI
import UIKit
import PhotosUI

// MARK: - Photobooth Top Bar (Tối giản chuẩn máy ảnh studio: Thoát · Khung/Hẹn giờ hợp nhất · Thư viện)
public struct PhotoboothTopBar: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    @State private var selectedPickerItems: [PhotosPickerItem] = []

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    public var body: some View {
        let layout = viewModel.photoboothStripConfig.layout
        let frameOpen = viewModel.isPhotoboothLiveFramePickerOpen

        HStack(spacing: 10) {
            // 1. Nút thoát gọn sắc nét
            Button(action: {
                viewModel.exitPhotoboothMode()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thoát Photobooth")

            Spacer(minLength: 4)

            // 2. Thanh điều khiển trung tâm hợp nhất: Bố cục & Khung | Hẹn giờ (6s mặc định)
            HStack(spacing: 0) {
                Button(action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        viewModel.isPhotoboothLiveFramePickerOpen.toggle()
                    }
                }) {
                    HStack(spacing: 5) {
                        Text(layout.shortBadge)
                            .font(.system(size: compact ? 11.5 : 12, weight: .semibold, design: .rounded))
                            .foregroundColor(frameOpen ? .black : .white)
                        Image(systemName: frameOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(frameOpen ? .black.opacity(0.75) : .white.opacity(0.60))
                    }
                    .padding(.horizontal, compact ? 10 : 12)
                    .frame(height: 32)
                    .background(
                        Capsule()
                            .fill(frameOpen ? Color.white : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chọn bố cục và khung in Photobooth")

                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 0.6, height: 15)
                    .padding(.horizontal, 2)

                Button(action: {
                    viewModel.cyclePhotoboothTimer()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(viewModel.photoboothTimer == .manual ? 0.55 : 0.90))
                        Text(viewModel.photoboothTimer.badgeTitle)
                            .font(.system(size: compact ? 11.5 : 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, compact ? 10 : 12)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thay đổi thời gian đếm ngược Photobooth")
            }
            .padding(2)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
            )

            Spacer(minLength: 4)

            // 3. Nhập ảnh sẵn từ Thư viện
            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: layout.slotCount,
                matching: .images
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                    )
            }
            .accessibilityLabel("Chọn ảnh từ Thư viện")
            .onChangeCompatible(of: selectedPickerItems) { items in
                guard !items.isEmpty else { return }
                Task { @MainActor in
                    var loaded: [CGImage] = []
                    for it in items {
                        if let data = try? await it.loadTransferable(type: Data.self),
                           let ui = UIImage(data: data),
                           let normalized = Self.normalizedUprightCGImage(ui) {
                            loaded.append(normalized)
                        }
                    }
                    selectedPickerItems = []
                    if !loaded.isEmpty {
                        viewModel.importPhotoboothPhotos(loaded)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static func normalizedUprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let maxSide: CGFloat = 1800
        let scale = min(1.0, maxSide / max(1.0, max(image.size.width, image.size.height)))
        let size = CGSize(width: round(image.size.width * scale), height: round(image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.cgImage
    }
}

// MARK: - Photobooth Live Viewfinder Overlay (Khung cắt vuông 90° chuẩn in · Thanh tiến độ tinh gọn · Khay Khung & Bố cục)
public struct PhotoboothViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    public init(viewModel: CameraViewModel, topInset: CGFloat, bottomInset: CGFloat) {
        self.viewModel = viewModel
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    public var body: some View {
        let layout = viewModel.photoboothStripConfig.layout
        let activeFrame = viewModel.photoboothStripConfig.frameStyle
        let total = layout.slotCount
        let filled = viewModel.photoboothFilledCount
        let activeIdx = viewModel.photoboothActiveSlotIndex
        let showFramePicker = viewModel.isPhotoboothLiveFramePickerOpen && !viewModel.isPhotoboothSequenceRunning

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let slotAspect = layout.slotAspectRatio
            let usableH = h * (showFramePicker ? 0.46 : 0.68)
            let guideW = min(w * 0.90, usableH * slotAspect)
            let guideH = guideW / max(0.3, slotAspect)
            let windowCenterY = showFramePicker ? (h * 0.34) : (h * 0.46)

            ZStack {
                // 1. Cửa sổ khung cắt vuông 90° sắc cạnh đúng tỷ lệ ô in thật (không bo góc giả)
                boothCropMatteLayer(
                    canvasSize: CGSize(width: w, height: h),
                    windowSize: CGSize(width: guideW, height: guideH),
                    windowCenterY: windowCenterY,
                    frameStyle: activeFrame
                )
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // 2. Chỉ báo số tấm tối giản không hộp nền rối mắt
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(red: 0.95, green: 0.25, blue: 0.25))
                            .frame(width: 5.5, height: 5.5)
                        Text("\(min(total, activeIdx + 1)) / \(total)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                    }
                    .padding(.top, max(6, topInset - 2))

                    Spacer()

                    // 3. Khay chọn nhanh Bố cục (4×1, 2×4, 2×4 Đôi...) + 24 Khung thật (có chất liệu vải/giấy)
                    if showFramePicker {
                        liveFrameSelectorStrip(activeLayout: layout, activeFrame: activeFrame)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // 4. Hàng ảnh thu nhỏ sắc cạnh + nút Khung + nút Xem gọn gàng
                    HStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(0..<total, id: \.self) { idx in
                                    let slot = idx < viewModel.photoboothSlots.count ? viewModel.photoboothSlots[idx] : nil
                                    let isActive = idx == activeIdx
                                    Button(action: {
                                        viewModel.retakePhotoboothSlot(idx)
                                    }) {
                                        ZStack {
                                            Rectangle()
                                                .fill(Color.black.opacity(0.55))
                                                .frame(width: 28, height: 34)

                                            if let slot {
                                                Image(uiImage: UIImage(cgImage: slot.displayImage))
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 28, height: 34)
                                                    .clipped()
                                            } else {
                                                Text("\(idx + 1)")
                                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                                    .foregroundColor(isActive ? .white : .white.opacity(0.48))
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                                .stroke(isActive ? Color.white : Color.white.opacity(0.24), lineWidth: isActive ? 1.5 : 0.6)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Khung ảnh số \(idx + 1)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxWidth: total > 5 ? 165 : CGFloat(total) * 33)

                        Button(action: {
                            HapticFeedbackService.shared.triggerSelectionChange()
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                viewModel.isPhotoboothLiveFramePickerOpen.toggle()
                            }
                        }) {
                            HStack(spacing: 5) {
                                frameMiniSwatch(activeFrame, width: 12, height: 16)
                                Text("Khung")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(showFramePicker ? .black : .white)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(
                                Capsule()
                                    .fill(showFramePicker ? Color.white : Color.black.opacity(0.56))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                            )
                        }
                        .buttonStyle(.plain)

                        if filled > 0 {
                            Button(action: {
                                viewModel.openPhotoboothEditor()
                            }) {
                                Text(filled >= total ? "Xem ảnh" : "Xem (\(filled))")
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(Capsule().fill(Color.white))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(8, bottomInset - 2))
                }

                // 5. Số đếm ngược lớn sắc nét ngay giữa cửa sổ khung ảnh
                if viewModel.photoboothCountdownRemaining > 0 {
                    Text("\(viewModel.photoboothCountdownRemaining)")
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.58), radius: 12, y: 3)
                        .position(x: w * 0.5, y: windowCenterY)
                        .id(viewModel.photoboothCountdownRemaining)
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // 6. Chớp đèn Flash Studio lúc bấm màn trập
                if viewModel.photoboothFlashBlink {
                    Color.white.opacity(0.90)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Sharp 90-Degree WYSIWYG Studio Crop Matte
    @ViewBuilder
    private func boothCropMatteLayer(
        canvasSize: CGSize,
        windowSize: CGSize,
        windowCenterY: CGFloat,
        frameStyle: PhotoboothFrameStyle
    ) -> some View {
        let winRect = CGRect(
            x: (canvasSize.width - windowSize.width) * 0.5,
            y: windowCenterY - windowSize.height * 0.5,
            width: windowSize.width,
            height: windowSize.height
        )
        let primaryTint = frameStyle.swatchColors.first ?? Color.black

        ZStack {
            Canvas { ctx, size in
                var outer = Path()
                outer.addRect(CGRect(origin: .zero, size: size))
                // Cửa sổ cắt vuông sắc cạnh 90° khớp 100% ảnh in Photobooth thật
                outer.addRect(winRect)
                ctx.fill(outer, with: .color(Color.black.opacity(0.50)), style: FillStyle(eoFill: true))
                ctx.fill(outer, with: .color(primaryTint.opacity(0.08)), style: FillStyle(eoFill: true))

                if frameStyle == .kodak35mmSprocket {
                    let holeW: CGFloat = 6.5
                    let holeH: CGFloat = 9.5
                    var y = winRect.minY + 10
                    while y + holeH < winRect.maxY - 6 {
                        let leftR = CGRect(x: max(4, winRect.minX - 12), y: y, width: holeW, height: holeH)
                        let rightR = CGRect(x: min(size.width - holeW - 4, winRect.maxX + 5.5), y: y, width: holeW, height: holeH)
                        ctx.fill(Path(roundedRect: leftR, cornerRadius: 1.5), with: .color(Color.white.opacity(0.45)))
                        ctx.fill(Path(roundedRect: rightR, cornerRadius: 1.5), with: .color(Color.white.opacity(0.45)))
                        y += 22
                    }
                }
            }

            // Viền mảnh 1pt gọn sắc nét (không phát sáng màu AI)
            Rectangle()
                .stroke(Color.white.opacity(0.62), lineWidth: 1.0)
                .frame(width: windowSize.width, height: windowSize.height)
                .position(x: canvasSize.width * 0.5, y: windowCenterY)
        }
    }

    // MARK: - Unified Live Layout + 24 Real Frame Studio Tray
    private func liveFrameSelectorStrip(activeLayout: PhotoboothLayout, activeFrame: PhotoboothFrameStyle) -> some View {
        VStack(spacing: 10) {
            // Hàng 1: Bố cục (4×1, 2×4, 2×4 Đôi, 2×2, 3×1, 2×1, 3×2, 1×1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoboothLayout.allCases) { item in
                        let isSel = (activeLayout == item)
                        Button(action: {
                            viewModel.selectPhotoboothLayout(item)
                        }) {
                            Text(item.shortBadge)
                                .font(.system(size: 11.5, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSel ? .black : .white.opacity(0.78))
                                .padding(.horizontal, 11)
                                .frame(height: 27)
                                .background(
                                    Capsule()
                                        .fill(isSel ? Color.white : Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            // Hàng 2: 24 Khung in thật dạng thẻ vuông sắc cạnh (hiện đúng chất liệu vải/giấy studio)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoboothFrameStyle.allCases.filter { $0 != .customAITexture }) { frame in
                        let isSel = (activeFrame == frame)
                        Button(action: {
                            viewModel.selectPhotoboothFrameStyle(frame)
                        }) {
                            VStack(spacing: 4) {
                                frameMiniSwatch(frame, width: 42, height: 56)
                                    .overlay(
                                        VStack(spacing: 3) {
                                            Rectangle().fill(Color.black.opacity(0.28)).frame(width: 28, height: 13)
                                            Rectangle().fill(Color.black.opacity(0.28)).frame(width: 28, height: 13)
                                        }
                                        .offset(y: -3)
                                    )
                                    .overlay(
                                        Rectangle()
                                            .stroke(isSel ? Color.white : Color.white.opacity(0.22), lineWidth: isSel ? 1.8 : 0.6)
                                    )

                                Text(frame.displayName)
                                    .font(.system(size: 9.5, weight: isSel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSel ? .white : .white.opacity(0.65))
                                    .lineLimit(1)
                                    .frame(width: 54)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func frameMiniSwatch(_ frame: PhotoboothFrameStyle, width: CGFloat, height: CGFloat) -> some View {
        if let texName = frame.bundledTextureFilename,
           let uiImg = PhotoboothAssetManager.shared.bundledFrameTextureImage(filename: texName) {
            Image(uiImage: uiImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
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
                .frame(width: width, height: height)
        }
    }
}
