import SwiftUI
import UIKit
import PhotosUI

// MARK: - Photobooth Top Bar (Thoát · Bố cục · Chọn Khung Live · Hẹn giờ · Nhập ảnh)
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
        let activeFrame = viewModel.photoboothStripConfig.frameStyle
        let frameOpen = viewModel.isPhotoboothLiveFramePickerOpen

        HStack(spacing: compact ? 5 : 6) {
            Button(action: {
                viewModel.exitPhotoboothMode()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(AlignTheme.studioSurface)
                            .overlay(Circle().stroke(AlignTheme.studioHairline, lineWidth: 0.6))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thoát Photobooth")

            Spacer(minLength: 2)

            // 1. Chọn Bố cục in (4x1, 2x2, 3x1, 2x1, 6 Cut, 1x1)
            Menu {
                ForEach(PhotoboothLayout.allCases) { item in
                    Button(action: {
                        viewModel.selectPhotoboothLayout(item)
                    }) {
                        Label(
                            item.displayName,
                            systemImage: item == layout ? "checkmark.circle.fill" : "rectangle.split.2x2"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(AlignTheme.studioAccent)
                    Text(layout.shortBadge)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.60))
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                )
            }

            // 2. Chọn Khung In Trực Tiếp Trên Liveview (16 khung thiết kế thật)
            Button(action: {
                HapticFeedbackService.shared.triggerSelectionChange()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    viewModel.isPhotoboothLiveFramePickerOpen.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: activeFrame.swatchColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 0.7))

                    Text(compact ? "Khung" : activeFrame.displayName)
                        .font(.system(size: 10.8, weight: .bold, design: .rounded))
                        .foregroundColor(frameOpen ? .black : .white)
                        .lineLimit(1)
                        .frame(maxWidth: compact ? 52 : 84)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(frameOpen ? AlignTheme.studioAccent : AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(frameOpen ? AlignTheme.studioAccent : AlignTheme.studioAccentBorder, lineWidth: 0.7))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chọn khung in Photobooth trực tiếp")

            // 3. Hẹn giờ chụp liên hoàn (3s / 5s / 8s / Tay)
            Button(action: {
                viewModel.cyclePhotoboothTimer()
            }) {
                HStack(spacing: 3.5) {
                    Image(systemName: "timer")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(viewModel.photoboothTimer == .manual ? .white.opacity(0.65) : AlignTheme.studioAccent)
                    Text(viewModel.photoboothTimer.badgeTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8.5)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6))
                )
            }
            .buttonStyle(.plain)

            // 4. Nhập ảnh có sẵn từ Thư viện
            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: layout.slotCount,
                matching: .images
            ) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(AlignTheme.studioSurface)
                            .overlay(Circle().stroke(AlignTheme.studioHairline, lineWidth: 0.6))
                    )
            }
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

// MARK: - Photobooth Live Viewfinder Overlay (WYSIWYG Frame Matte · Live Frame Selector · Mini-Strip · Countdown)
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
            // Chừa không gian cho thanh chọn khung live hoặc thanh filmstrip phía dưới
            let usableH = h * (showFramePicker ? 0.56 : 0.68)
            let guideW = min(w * 0.88, usableH * slotAspect)
            let guideH = guideW / max(0.3, slotAspect)
            let windowCenterY = showFramePicker ? (h * 0.41) : (h * 0.47)

            ZStack {
                // 1. Khung viền mờ WYSIWYG đồng màu khung in thật (cắt đúng tỷ lệ ô ảnh thay vì vẽ hộp nét đứt lơ lửng)
                boothCropMatteLayer(
                    canvasSize: CGSize(width: w, height: h),
                    windowSize: CGSize(width: guideW, height: guideH),
                    windowCenterY: windowCenterY,
                    frameStyle: activeFrame
                )
                .allowsHitTesting(false)

                // 2. Huy hiệu trên cùng: Tiến độ chụp + REC Tua nhanh hậu trường
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6.5, height: 6.5)
                            Text("BOOTH \(layout.shortBadge) · KHUNG \(min(total, activeIdx + 1))/\(total) · REC")
                                .font(.system(size: 9.8, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.66))
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                        )
                    }
                    .padding(.top, topInset)

                    Spacer()

                    // 3. Khay chọn nhanh 16 khung in trực tiếp ngay trên Liveview (tự đóng khi đang đếm ngược)
                    if showFramePicker {
                        liveFrameSelectorStrip(activeFrame: activeFrame)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // 4. Thanh Filmstrip thu nhỏ mang đúng màu khung đang chọn + nút Mở Studio Trang trí
                    HStack(spacing: 8) {
                        HStack(spacing: 4.5) {
                            ForEach(0..<total, id: \.self) { idx in
                                let slot = idx < viewModel.photoboothSlots.count ? viewModel.photoboothSlots[idx] : nil
                                let isActive = idx == activeIdx
                                Button(action: {
                                    viewModel.retakePhotoboothSlot(idx)
                                }) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: activeFrame.swatchColors,
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 34, height: 34)

                                        if let slot {
                                            Image(uiImage: UIImage(cgImage: slot.displayImage))
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 30, height: 30)
                                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        } else {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(Color.black.opacity(0.50))
                                                .frame(width: 30, height: 30)
                                                .overlay(
                                                    Text("\(idx + 1)")
                                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                        .foregroundColor(isActive ? AlignTheme.studioAccent : .white.opacity(0.70))
                                                )
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                            .stroke(isActive ? AlignTheme.studioAccent : Color.white.opacity(0.28), lineWidth: isActive ? 1.6 : 0.7)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Khung ảnh số \(idx + 1)")
                            }
                        }

                        if filled > 0 {
                            Button(action: {
                                viewModel.openPhotoboothEditor()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(filled >= total ? "Trang trí" : "Xem (\(filled))")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(Capsule().fill(AlignTheme.studioAccent))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.68))
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.6))
                    )
                    .padding(.bottom, max(8, bottomInset - 2))
                }

                // 5. Số đếm ngược lớn sắc nét ngay giữa cửa sổ khung ảnh
                if viewModel.photoboothCountdownRemaining > 0 {
                    Text("\(viewModel.photoboothCountdownRemaining)")
                        .font(.system(size: 92, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.65), radius: 14, y: 4)
                        .position(x: w * 0.5, y: windowCenterY)
                        .id(viewModel.photoboothCountdownRemaining)
                        .transition(.scale(scale: 1.35).combined(with: .opacity))
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

    // MARK: - WYSIWYG Frame-Colored Studio Crop Matte
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
            // Lớp mặt nạ ngoài vùng khung cắt: tối dịu pha nhẹ sắc thái của khung in đang chọn
            Canvas { ctx, size in
                var outer = Path()
                outer.addRect(CGRect(origin: .zero, size: size))
                let cutout = Path(roundedRect: winRect, cornerRadius: 10)
                outer.addPath(cutout)
                ctx.fill(outer, with: .color(Color.black.opacity(0.46)), style: FillStyle(eoFill: true))
                ctx.fill(outer, with: .color(primaryTint.opacity(0.14)), style: FillStyle(eoFill: true))

                // Nếu là khung cuộn phim 35mm, hiển thị lỗ đục phim tinh tế hai bên lề matte
                if frameStyle == .kodak35mmSprocket {
                    let holeW: CGFloat = 7
                    let holeH: CGFloat = 10
                    var y = winRect.minY + 10
                    while y + holeH < winRect.maxY - 6 {
                        let leftR = CGRect(x: max(4, winRect.minX - 13), y: y, width: holeW, height: holeH)
                        let rightR = CGRect(x: min(size.width - holeW - 4, winRect.maxX + 6), y: y, width: holeW, height: holeH)
                        ctx.fill(Path(roundedRect: leftR, cornerRadius: 2), with: .color(Color.white.opacity(0.50)))
                        ctx.fill(Path(roundedRect: rightR, cornerRadius: 2), with: .color(Color.white.opacity(0.50)))
                        y += 22
                    }
                }
            }

            // Viền khung mảnh đồng màu sắc nét + dấu góc L tinh tế (không rối)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [primaryTint.opacity(0.90), Color.white.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.8
                )
                .frame(width: windowSize.width, height: windowSize.height)
                .position(x: canvasSize.width * 0.5, y: windowCenterY)
        }
    }

    // MARK: - Live Horizontal 16-Frame Swatch Picker Strip
    private func liveFrameSelectorStrip(activeFrame: PhotoboothFrameStyle) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoboothFrameStyle.allCases.filter { $0 != .customAITexture }) { frame in
                    let isSel = (activeFrame == frame)
                    Button(action: {
                        viewModel.selectPhotoboothFrameStyle(frame)
                    }) {
                        VStack(spacing: 3.5) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: frame.swatchColors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 40, height: 48)
                                .overlay(
                                    VStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.28)).frame(width: 26, height: 11)
                                        RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.28)).frame(width: 26, height: 11)
                                    }
                                    .offset(y: -3)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSel ? AlignTheme.studioAccent : Color.white.opacity(0.28), lineWidth: isSel ? 2.0 : 0.7)
                                )

                            Text(frame.displayName)
                                .font(.system(size: 9.2, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSel ? AlignTheme.studioAccent : .white.opacity(0.84))
                                .lineLimit(1)
                                .frame(width: 52)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.6))
        )
        .padding(.horizontal, 10)
    }
}
