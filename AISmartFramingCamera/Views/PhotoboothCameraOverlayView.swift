import SwiftUI
import UIKit
import PhotosUI

// MARK: - Compact 1-Tap Photobooth Trigger Pill (Top-Leading Viewfinder Overlay)
public struct PhotoboothQuickTriggerButton: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let availability = viewModel.featureAvailability(.photobooth)
        Button(action: {
            viewModel.enterPhotoboothMode()
        }) {
            HStack(spacing: 5) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AlignTheme.studioAccent)
                Text("BOOTH")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundColor(AlignTheme.studioInkPrimary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(AlignTheme.studioSurface)
                    .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
            )
            .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
            .opacity(availability.isAvailable ? 1.0 : 0.36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mở chế độ Photobooth Studio")
    }
}

// MARK: - Photobooth Top Bar (Layout Selector + Timer + Import + Exit)
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
        HStack(spacing: compact ? 6 : 8) {
            Button(action: {
                viewModel.exitPhotoboothMode()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Thoát")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .foregroundColor(AlignTheme.studioInkPrimary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Layout Switcher Menu (4x1, 2x2, 3x1, 2x1, 6-Cut, 1x1)
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
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(AlignTheme.studioAccent)
                    Text(layout.shortBadge)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.60))
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(AlignTheme.studioAccentBorder, lineWidth: 0.7))
                )
            }

            // Timer Cycle Button (3s / 5s / 8s / Tay)
            Button(action: {
                viewModel.cyclePhotoboothTimer()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(viewModel.photoboothTimer == .manual ? .white.opacity(0.65) : AlignTheme.studioAccent)
                    Text(viewModel.photoboothTimer.badgeTitle)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6))
                )
            }
            .buttonStyle(.plain)

            // Quick Multi-Photo Import from Library
            PhotosPicker(
                selection: $selectedPickerItems,
                maxSelectionCount: layout.slotCount,
                matching: .images
            ) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
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

// MARK: - Photobooth Live Viewfinder Overlay (Guide Aspect + Countdown + Filmstrip Pill + Studio Flash Blink)
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
        let total = layout.slotCount
        let filled = viewModel.photoboothFilledCount
        let activeIdx = viewModel.photoboothActiveSlotIndex

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let slotAspect = layout.slotAspectRatio
            let guideW = min(w * 0.90, h * 0.68 * slotAspect)
            let guideH = guideW / max(0.3, slotAspect)

            ZStack {
                // 1. Subtle Slot Proportion Guide Rectangle so user frames exactly what fits inside print cut
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.42), style: StrokeStyle(lineWidth: 1.0, dash: [6, 5]))
                    .frame(width: guideW, height: guideH)
                    .allowsHitTesting(false)

                // 2. Top Progress Badge (Khung 1/4 ...)
                VStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.isPhotoboothSequenceRunning ? Color.red : AlignTheme.studioAccent)
                            .frame(width: 7, height: 7)
                        Text("BOOTH \(layout.shortBadge) · KHUNG \(min(total, activeIdx + 1))/\(total)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.62))
                            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                    )
                    .padding(.top, topInset)

                    Spacer()

                    // 3. Bottom Compact Thumbnail Filmstrip Bar + Decorate Button
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            ForEach(0..<total, id: \.self) { idx in
                                let slot = idx < viewModel.photoboothSlots.count ? viewModel.photoboothSlots[idx] : nil
                                let isActive = idx == activeIdx
                                Button(action: {
                                    viewModel.retakePhotoboothSlot(idx)
                                }) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.black.opacity(0.55))
                                            .frame(width: 34, height: 34)

                                        if let slot {
                                            Image(uiImage: UIImage(cgImage: slot.displayImage))
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 34, height: 34)
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        } else {
                                            Text("\(idx + 1)")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(isActive ? AlignTheme.studioAccent : .white.opacity(0.55))
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(isActive ? AlignTheme.studioAccent : Color.white.opacity(0.24), lineWidth: isActive ? 1.5 : 0.7)
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
                            .fill(Color.black.opacity(0.64))
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.6))
                    )
                    .padding(.bottom, max(8, bottomInset - 2))
                }

                // 4. Crisp Giant Countdown Numeral
                if viewModel.photoboothCountdownRemaining > 0 {
                    Text("\(viewModel.photoboothCountdownRemaining)")
                        .font(.system(size: 92, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.65), radius: 14, y: 4)
                        .id(viewModel.photoboothCountdownRemaining)
                        .transition(.scale(scale: 1.35).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // 5. Crisp Studio Booth Flash Blink
                if viewModel.photoboothFlashBlink {
                    Color.white.opacity(0.90)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }
}
