import SwiftUI

// MARK: - Active Inline Tool Panel Inside Vintage Camera Drawer
private enum VintageDrawerSubPanel: Equatable {
    case none
    case vintageOptions   // Light Leak Ngẫu Nhiên 0-100% + Dấu Thời Gian (4 thẻ)
    case recipeTuning     // Thước xoay chỉnh chi tiết công thức phim (Contrast/Sat/Warmth/Fade/Halation/Grain...)
}

// MARK: - Hardware Miniature Camera Tag Label (Highlights blue "R" suffix like FXN R / OFM R / PAF R)
private struct VintageCameraTagText: View {
    let tag: String
    let isSelected: Bool

    var body: some View {
        Group {
            if !isSelected && tag.hasSuffix(" R") {
                let base = String(tag.dropLast(2))
                (Text(base).foregroundColor(Color.white.opacity(0.84))
                 + Text(" R").foregroundColor(Color(red: 0.30, green: 0.56, blue: 1.00)))
            } else {
                Text(tag)
                    .foregroundColor(isSelected ? Color.black : Color.white.opacity(0.84))
            }
        }
        .font(.system(size: 10.2, weight: isSelected ? .bold : .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.76)
        .padding(.horizontal, isSelected ? 8.5 : 4.0)
        .padding(.vertical, isSelected ? 2.8 : 2.0)
        .background(
            Group {
                if isSelected {
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: Color.white.opacity(0.22), radius: 4, y: 1)
                }
            }
        )
    }
}

// MARK: - Studio-Lit Miniature 3D Hardware Camera Card (Transparent PNG + Crisp White Selected Pill)
public struct VintageHardwareCameraCard: View {
    let preset: FilmPreset
    let isSelected: Bool

    public init(preset: FilmPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let uiImage = VintageCameraIconCache.shared.icon(named: preset.cameraIconAssetName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 50)
                        .shadow(color: Color.black.opacity(isSelected ? 0.65 : 0.42), radius: isSelected ? 8 : 4, y: 3)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 48, height: 42)
                        Image(systemName: preset.deviceIconSF)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.88))
                    }
                }
            }
            .frame(width: 62, height: 54)
            .scaleEffect(isSelected ? 1.07 : 0.96)
            .opacity(isSelected ? 1.0 : 0.88)

            VintageCameraTagText(tag: preset.cameraDisplayTag, isSelected: isSelected)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isSelected)
    }
}

// MARK: - Original Camera Off Card (Matches Hardware Shelf Form)
private struct VintageOriginalCameraCard: View {
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let phoneImg = VintageCameraIconCache.shared.icon(named: "cam_retro_phone") {
                    Image(uiImage: phoneImg)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 50, height: 48)
                        .saturation(0.15)
                        .opacity(isSelected ? 0.96 : 0.68)
                        .shadow(color: Color.black.opacity(0.50), radius: 5, y: 3)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.84))
                        )
                }

                // Subtle status badge indicating pure sensor color
                Circle()
                    .fill(isSelected ? Color.white : Color(red: 0.22, green: 0.23, blue: 0.26))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: "circle.slash")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(isSelected ? .black : Color.white.opacity(0.75))
                    )
                    .offset(x: -18, y: 15)
            }
            .frame(width: 62, height: 54)
            .scaleEffect(isSelected ? 1.05 : 0.95)

            VintageCameraTagText(tag: "Original", isSelected: isSelected)
        }
        .frame(width: 68)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isSelected)
    }
}

// MARK: - Circular Optical Accessory Lens Orb (Matches Dazz Cam Bottom Optical Row)
private struct VintageOpticalAccessoryOrb: View {
    let title: String
    let badgeText: String?
    let colors: [Color]
    let glintColor: Color
    let iconName: String
    let isActive: Bool
    let isPanelOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    // Realistic dark optical lens glass sphere with coated reflection
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: colors),
                                center: UnitPoint(x: 0.34, y: 0.30),
                                startRadius: 2,
                                endRadius: 21
                            )
                        )
                        .frame(width: 38, height: 38)
                        .overlay(
                            // Subtle specular lens coating arc
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [glintColor.opacity(0.55), Color.clear],
                                        center: UnitPoint(x: 0.28, y: 0.24),
                                        startRadius: 1,
                                        endRadius: 11
                                    )
                                )
                                .frame(width: 36, height: 36)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isPanelOpen
                                        ? Color.white.opacity(0.90)
                                        : (isActive ? Color.white.opacity(0.42) : Color.white.opacity(0.16)),
                                    lineWidth: isPanelOpen ? 1.4 : 0.8
                                )
                        )

                    Image(systemName: iconName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Color.white.opacity(isActive ? 0.96 : 0.74))

                    // Bottom-right white checkmark badge when active (matching Screenshot #2)
                    if isActive {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 14, height: 14)
                                .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.0, weight: .black))
                                .foregroundColor(.black)
                        }
                        .offset(x: 13, y: 13)
                    } else if let badgeText, !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white))
                            .offset(x: 13, y: -13)
                    }
                }

                let displayCaption = (isActive ? badgeText : nil) ?? title
                Text(displayCaption)
                    .font(.system(size: 8.8, weight: isActive || isPanelOpen ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isActive || isPanelOpen ? Color.white.opacity(0.95) : Color.white.opacity(0.60))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 50)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Wide Sleek Dark Capsule Light Leak Slider (Matches Screenshot #1 Verbatim)
private struct VintageLightLeakCapsuleSlider: View {
    let value: Float
    let onChanged: (Float) -> Void

    @State private var isDragging: Bool = false
    @State private var lastNotch: Int = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(1.0, geo.size.width)
            let height: CGFloat = 28.0
            let thumbW: CGFloat = 14.0
            let thumbH: CGFloat = 22.0
            let inset: CGFloat = 4.0
            let span = max(1.0, width - thumbW - inset * 2.0)
            let clamped = CGFloat(max(0.0, min(1.0, value)))
            let thumbX = inset + thumbW * 0.5 + clamped * span

            ZStack(alignment: .leading) {
                // Dark matte rounded track
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(height: height)

                // Subtle warm amber fill behind thumb when > 0
                if clamped > 0.005 {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.96, green: 0.42, blue: 0.14).opacity(0.35),
                                    Color(red: 1.00, green: 0.56, blue: 0.18).opacity(0.52)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(thumbW + inset * 2, thumbX + thumbW * 0.5 + 2), height: height)
                }

                // Crisp vertical white rounded pill thumb
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: thumbW, height: thumbH)
                    .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(isDragging ? 1.08 : 1.0)
                    .position(x: thumbX, y: height * 0.5)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            lastNotch = Int(round(value * 20.0))
                        }
                        let norm = (drag.location.x - (inset + thumbW * 0.5)) / span
                        let raw = Float(max(0.0, min(1.0, norm)))
                        let snapped: Float = raw < 0.025 ? 0.0 : raw
                        let notch = Int(round(snapped * 20.0))
                        if notch != lastNotch {
                            if notch == 0 || notch == 10 || notch == 20 {
                                HapticFeedbackService.shared.triggerLight()
                            } else {
                                HapticFeedbackService.shared.triggerSelectionChange()
                            }
                            lastNotch = notch
                        }
                        onChanged(snapped)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 28)
    }
}

// MARK: - Vintage Options Panel: Light Leak Ngẫu Nhiên 0-100% + Dấu Thời Gian (4 Cards)
private struct VintageLeakAndDateOptionsPanel: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. Light Leak Ngẫu Nhiên + Sky-Blue % Readout
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Light Leak Ngẫu Nhiên")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Text("\(viewModel.vintageLightLeak.percentInt)%")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 0.24, green: 0.72, blue: 0.98))
                        .monospacedDigit()

                    Spacer()

                    // Manual pattern shuffle button (#1..#8)
                    Button(action: {
                        viewModel.shuffleLightLeakPattern()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.0, weight: .semibold))
                            Text("Mẫu #\(viewModel.vintageLightLeak.patternIndex + 1)")
                                .font(.system(size: 10.2, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(Color.white.opacity(0.88))
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.11))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Đổi mẫu vệt rò sáng khác")
                }

                VintageLightLeakCapsuleSlider(
                    value: viewModel.vintageLightLeak.intensity,
                    onChanged: { newValue in
                        viewModel.setLightLeakIntensity(newValue)
                    }
                )

                // Randomize on capture toggle (matches Screenshot #1 radio-check row)
                Button(action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    viewModel.setLightLeakRandomizeOnCapture(!viewModel.vintageLightLeak.randomizeOnCapture)
                }) {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(viewModel.vintageLightLeak.randomizeOnCapture ? Color.white : Color.white.opacity(0.16))
                                .frame(width: 16, height: 16)
                            if viewModel.vintageLightLeak.randomizeOnCapture {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .black))
                                    .foregroundColor(.black)
                            }
                        }
                        Text("Tự đổi vệt rò sáng ngẫu nhiên sau mỗi ảnh chụp")
                            .font(.system(size: 11.0, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.74))
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // 2. Dấu Thời Gian (4 Squircle Cards Matching Screenshot #1)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Dấu Thời Gian")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    if viewModel.vintageDateStampStyle.isEnabled {
                        Text(viewModel.vintageDateStampStyle.formattedDate())
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 1.00, green: 0.36, blue: 0.16))
                    }
                }

                HStack(spacing: 8) {
                    ForEach(VintageDateStampStyle.allCases) { style in
                        let isSelected = (viewModel.vintageDateStampStyle == style)
                        Button(action: {
                            viewModel.selectVintageDateStampStyle(style)
                        }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(style == .off ? Color.white.opacity(0.16) : Color(red: 0.08, green: 0.08, blue: 0.09))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(
                                                isSelected ? Color.white.opacity(0.52) : Color.white.opacity(0.08),
                                                lineWidth: isSelected ? 1.0 : 0.6
                                            )
                                    )

                                dateStampCardContent(for: style)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .overlay(alignment: .bottomTrailing) {
                                if isSelected {
                                    ZStack {
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 17, height: 17)
                                            .shadow(color: Color.black.opacity(0.45), radius: 2, y: 1)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9.0, weight: .black))
                                            .foregroundColor(.black)
                                    }
                                    .offset(x: 4, y: 4)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Dấu thời gian \(style.displayName)")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )
        )
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func dateStampCardContent(for style: VintageDateStampStyle) -> some View {
        switch style {
        case .off:
            Image(systemName: "circle.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.90))
        case .classicQuartz:
            Text(style.previewSampleText)
                .font(.system(size: 10.6, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(Color(red: 1.00, green: 0.34, blue: 0.14))
                .shadow(color: Color(red: 1.00, green: 0.18, blue: 0.04).opacity(0.85), radius: 3)
        case .retroLED:
            Text(style.previewSampleText)
                .font(.system(size: 10.4, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundColor(Color(red: 1.00, green: 0.48, blue: 0.14))
                .shadow(color: Color(red: 1.00, green: 0.28, blue: 0.04).opacity(0.85), radius: 3)
        case .compactSlanted:
            Text(style.previewSampleText)
                .font(.system(size: 10.8, weight: .bold, design: .monospaced))
                .italic()
                .tracking(0.8)
                .foregroundColor(Color(red: 1.00, green: 0.28, blue: 0.12))
                .shadow(color: Color(red: 0.98, green: 0.12, blue: 0.04).opacity(0.90), radius: 3.5)
        }
    }
}

// MARK: - Live Sample Look Preview Sheet ("ẢNH MẪU" — Real GPU Render on sample_look.jpg)
public struct VintageSampleLookPreviewSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var renderedImage: UIImage? = nil
    @State private var isComparingOriginal: Bool = false
    @State private var renderTask: Task<Void, Never>? = nil

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    private var activeCameraTitle: String {
        viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.cameraDisplayTag : "Original"
    }

    private var activeCameraSubtitle: String {
        viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.rawValue : "Màu tự nhiên của cảm biến"
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

                VStack(spacing: 12) {
                    // Top bar: Active camera name + Compare toggle + Done
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeCameraTitle)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text(activeCameraSubtitle)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.60))
                        }

                        Spacer()

                        Button(action: { dismiss() }) {
                            Text("Xong")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Live GPU-graded reference sample photo (Hold to compare Original)
                    GeometryReader { geo in
                        let baseUIImage = VintageCameraIconCache.shared.sampleLookUIImage()
                        let displayImage = isComparingOriginal ? baseUIImage : (renderedImage ?? baseUIImage)

                        ZStack {
                            if let img = displayImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
                                    )
                                    .shadow(color: Color.black.opacity(0.65), radius: 16, y: 6)
                            } else {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        Text("Không tìm thấy ảnh mẫu")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(Color.white.opacity(0.6))
                                    )
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(alignment: .topLeading) {
                            Text(isComparingOriginal ? "ẢNH GỐC" : activeCameraTitle.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isComparingOriginal ? .black : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(isComparingOriginal ? Color.white : Color.black.opacity(0.58))
                                )
                                .padding(12)
                        }
                        .overlay(alignment: .bottomLeading) {
                            Text("Nhấn giữ ảnh để so sánh gốc")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.75))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.52)))
                                .padding(12)
                                .opacity(isComparingOriginal ? 0.0 : 1.0)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !isComparingOriginal {
                                        isComparingOriginal = true
                                    }
                                }
                                .onEnded { _ in
                                    isComparingOriginal = false
                                }
                        )
                    }
                    .padding(.horizontal, 14)

                    // Quick Light Leak & Date Stamp Strip inside Sample Look
                    HStack(spacing: 10) {
                        Button(action: {
                            viewModel.shuffleLightLeakPattern()
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "sun.max.trianglebadge.exclamationmark")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Leak \(viewModel.vintageLightLeak.percentInt)%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .foregroundColor(viewModel.vintageLightLeak.isIdentity ? Color.white.opacity(0.80) : .black)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(viewModel.vintageLightLeak.isIdentity ? Color.white.opacity(0.11) : Color(red: 1.00, green: 0.60, blue: 0.22))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: {
                            let all = VintageDateStampStyle.allCases
                            let idx = all.firstIndex(of: viewModel.vintageDateStampStyle) ?? 0
                            let next = all[(idx + 1) % all.count]
                            viewModel.selectVintageDateStampStyle(next)
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Ngày: \(viewModel.vintageDateStampStyle.displayName)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(viewModel.vintageDateStampStyle.isEnabled ? .white : Color.white.opacity(0.80))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(viewModel.vintageDateStampStyle.isEnabled ? Color(red: 0.92, green: 0.28, blue: 0.14) : Color.white.opacity(0.11))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()

                        if viewModel.isFilmSimulationActive {
                            Text("\(Int(round(viewModel.filmSimulationIntensity * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.82))
                        }
                    }
                    .padding(.horizontal, 16)

                    // Category tabs + Hardware Camera Strip right inside Sample Look sheet
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FilmPresetCategory.allCases) { cat in
                                let isSel = viewModel.selectedFilmCategory == cat
                                Button(action: { viewModel.selectFilmCategory(cat) }) {
                                    Text(cat.displayName)
                                        .font(.system(size: 11.5, weight: isSel ? .bold : .medium, design: .rounded))
                                        .foregroundColor(isSel ? .white : Color.white.opacity(0.50))
                                        .padding(.bottom, 3)
                                        .overlay(alignment: .bottom) {
                                            Rectangle()
                                                .fill(isSel ? Color.white : Color.clear)
                                                .frame(height: 1.5)
                                        }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button(action: { viewModel.disableFilmSimulation() }) {
                                VintageOriginalCameraCard(isSelected: !viewModel.isFilmSimulationActive)
                            }
                            .buttonStyle(PlainButtonStyle())

                            ForEach(viewModel.selectedFilmCategory.presets) { preset in
                                let isSel = viewModel.isFilmSimulationActive && viewModel.selectedFilmPreset == preset
                                Button(action: { viewModel.selectPreset(preset) }) {
                                    VintageHardwareCameraCard(preset: preset, isSelected: isSel)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }
            .onAppear { scheduleRender() }
            .onChange(of: viewModel.selectedFilmPreset) { _, _ in scheduleRender() }
            .onChange(of: viewModel.isFilmSimulationActive) { _, _ in scheduleRender() }
            .onChange(of: viewModel.filmSimulationIntensity) { _, _ in scheduleRender() }
            .onChange(of: viewModel.vintageLightLeak) { _, _ in scheduleRender() }
            .onChange(of: viewModel.vintageDateStampStyle) { _, _ in scheduleRender() }
            .onChange(of: viewModel.filmTuning) { _, _ in scheduleRender() }
            .onDisappear { renderTask?.cancel() }
        }
        .preferredColorScheme(.dark)
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let isFilmOn = viewModel.isFilmSimulationActive
        let preset = viewModel.selectedFilmPreset
        let intensity = Float(viewModel.filmSimulationIntensity)
        let wb = viewModel.activeProSoftwareWB
        let tuning = viewModel.filmTuning
        let style = viewModel.effectivePhotographicStyle
        let leak = viewModel.vintageLightLeak
        let stamp = viewModel.vintageDateStampStyle

        renderTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let sourceUI = VintageCameraIconCache.shared.sampleLookUIImage(),
                  let cg = sourceUI.cgImage else {
                return
            }

            var params = UnifiedColorRenderParams()
            params.preset = preset
            params.isFilmActive = isFilmOn && preset != .standard && preset != .proColorGrade && preset != .aiFullAuto
            params.filmIntensity = intensity
            params.softwareWB = wb
            params.filmTuning = tuning
            params.photographicStyle = style
            params.lightLeak = leak
            params.isStillMode = true

            let outputCG = UnifiedMetalColorEngine.shared.renderStillCGImage(
                cg,
                params: params,
                dateStampStyle: stamp,
                date: Date()
            ) ?? cg

            guard !Task.isCancelled else { return }
            let resultUI = UIImage(cgImage: outputCG)
            await MainActor.run {
                self.renderedImage = resultUI
            }
        }
    }
}

// MARK: - Redesigned Dazz-Style Vintage Camera Drawer (Hardware Shelf + Optical Accessories + Leak/Date Panel)
public struct VintageCameraDrawerView: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var activeSubPanel: VintageDrawerSubPanel = .none
    @State private var selectedAxis: FilmTuningAxis = .contrast
    @State private var isShowingSampleLook: Bool = false

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            topHeaderRow

            if viewModel.isFilmSimulationActive && activeSubPanel == .none {
                compactIntensityStrip
            }

            if activeSubPanel == .vintageOptions {
                VintageLeakAndDateOptionsPanel(viewModel: viewModel)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if activeSubPanel == .recipeTuning {
                recipeTuningPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            cameraHardwareShelf

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            opticalAccessoriesRow
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.65)
                )
                .shadow(color: Color.black.opacity(0.62), radius: 22, y: 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .gesture(dismissDragGesture)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: activeSubPanel)
        .sheet(isPresented: $isShowingSampleLook) {
            VintageSampleLookPreviewSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 1. Top Header (Category Tabs + "ẢNH MẪU" Pill + Close)
    @ViewBuilder
    private var topHeaderRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 13) {
                    ForEach(FilmPresetCategory.allCases) { category in
                        let isSelected = viewModel.selectedFilmCategory == category
                        Button(action: {
                            viewModel.selectFilmCategory(category)
                        }) {
                            VStack(spacing: 3) {
                                Text(category.displayName)
                                    .font(.system(size: 11.2, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.54))

                                Rectangle()
                                    .fill(isSelected ? Color.white : Color.clear)
                                    .frame(height: 1.5)
                                    .cornerRadius(1)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
            }

            // Sleek dark "ẢNH MẪU" pill button matching Screenshot #2
            Button(action: {
                HapticFeedbackService.shared.triggerSelectionChange()
                isShowingSampleLook = true
            }) {
                HStack(spacing: 4.5) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("ẢNH MẪU")
                        .font(.system(size: 9.8, weight: .bold, design: .rounded))
                        .tracking(0.3)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.13))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Xem thử màu trên ảnh mẫu")

            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                    viewModel.isShowingFilmDrawer = false
                }
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.82))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.11)))
                    .padding(.trailing, 10)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đóng bảng chọn máy ảnh")
        }
    }

    // MARK: - 2. Compact Intensity Strip (Shown when a film camera is active)
    @ViewBuilder
    private var compactIntensityStrip: some View {
        HStack(spacing: 8) {
            Text(viewModel.selectedFilmPreset.cameraDisplayTag.uppercased())
                .font(.system(size: 9.2, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.86))
                .fixedSize()

            Slider(value: $viewModel.filmSimulationIntensity, in: 0.1...1.0, step: 0.05)
                .tint(Color.white)
                .controlSize(.mini)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.filmSimulationIntensity = 1.0
                }
            }) {
                Text("\(Int(round(viewModel.filmSimulationIntensity * 100)))%")
                    .font(.system(size: 9.4, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .fixedSize()
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 3. Miniature 3D Hardware Camera Shelf
    @ViewBuilder
    private var cameraHardwareShelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(action: {
                        viewModel.disableFilmSimulation()
                    }) {
                        VintageOriginalCameraCard(isSelected: !viewModel.isFilmSimulationActive)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .id("raw_off_card")

                    ForEach(viewModel.selectedFilmCategory.presets) { preset in
                        let isSelected = viewModel.isFilmSimulationActive && viewModel.selectedFilmPreset == preset
                        Button(action: {
                            viewModel.selectPreset(preset)
                        }) {
                            VintageHardwareCameraCard(preset: preset, isSelected: isSelected)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(preset.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .onAppear {
                if viewModel.isFilmSimulationActive {
                    proxy.scrollTo(viewModel.selectedFilmPreset.id, anchor: .center)
                } else {
                    proxy.scrollTo("raw_off_card", anchor: .center)
                }
            }
        }
    }

    // MARK: - 4. Circular Optical Accessories Row (Light Leak, Dấu ngày, Quầng sáng, Độ phai, Hạt phim, Tinh chỉnh)
    @ViewBuilder
    private var opticalAccessoriesRow: some View {
        let leakActive = !viewModel.vintageLightLeak.isIdentity
        let dateActive = viewModel.vintageDateStampStyle.isEnabled
        let haloActive = viewModel.filmTuning.halation >= 0.05
        let fadeActive = viewModel.filmTuning.fade >= 0.05
        let grainActive = viewModel.filmTuning.grain >= 0.05
        let tuningActive = !viewModel.filmTuning.isIdentity

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 11) {
                VintageOpticalAccessoryOrb(
                    title: "Light Leak",
                    badgeText: leakActive ? "\(viewModel.vintageLightLeak.percentInt)%" : nil,
                    colors: [
                        Color(red: 0.96, green: 0.40, blue: 0.12),
                        Color(red: 0.44, green: 0.14, blue: 0.06),
                        Color(red: 0.10, green: 0.07, blue: 0.07)
                    ],
                    glintColor: Color(red: 1.0, green: 0.78, blue: 0.42),
                    iconName: "sun.max.fill",
                    isActive: leakActive,
                    isPanelOpen: activeSubPanel == .vintageOptions
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    if activeSubPanel == .vintageOptions {
                        activeSubPanel = .none
                    } else {
                        activeSubPanel = .vintageOptions
                    }
                }

                VintageOpticalAccessoryOrb(
                    title: "Dấu ngày",
                    badgeText: dateActive ? viewModel.vintageDateStampStyle.displayName : nil,
                    colors: [
                        Color(red: 0.78, green: 0.16, blue: 0.10),
                        Color(red: 0.30, green: 0.08, blue: 0.07),
                        Color(red: 0.09, green: 0.08, blue: 0.09)
                    ],
                    glintColor: Color(red: 1.0, green: 0.48, blue: 0.32),
                    iconName: "calendar",
                    isActive: dateActive,
                    isPanelOpen: activeSubPanel == .vintageOptions
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    if activeSubPanel == .vintageOptions {
                        activeSubPanel = .none
                    } else {
                        activeSubPanel = .vintageOptions
                    }
                }

                VintageOpticalAccessoryOrb(
                    title: "Quầng sáng",
                    badgeText: haloActive ? "\(Int(round(viewModel.filmTuning.halation * 100)))%" : nil,
                    colors: [
                        Color(red: 0.74, green: 0.24, blue: 0.32),
                        Color(red: 0.26, green: 0.10, blue: 0.20),
                        Color(red: 0.09, green: 0.08, blue: 0.12)
                    ],
                    glintColor: Color(red: 1.0, green: 0.65, blue: 0.72),
                    iconName: "sparkles",
                    isActive: haloActive,
                    isPanelOpen: false
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    var next = viewModel.filmTuning
                    if next.halation < 0.05 {
                        next.halation = 0.45
                    } else if next.halation < 0.75 {
                        next.halation = 0.85
                    } else {
                        next.halation = 0.0
                    }
                    viewModel.filmTuning = next
                }

                VintageOpticalAccessoryOrb(
                    title: "Độ phai",
                    badgeText: fadeActive ? "\(Int(round(viewModel.filmTuning.fade * 100)))%" : nil,
                    colors: [
                        Color(red: 0.34, green: 0.36, blue: 0.42),
                        Color(red: 0.16, green: 0.17, blue: 0.20),
                        Color(red: 0.07, green: 0.07, blue: 0.09)
                    ],
                    glintColor: Color.white,
                    iconName: "aqi.medium",
                    isActive: fadeActive,
                    isPanelOpen: false
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    var next = viewModel.filmTuning
                    if next.fade < 0.05 {
                        next.fade = 0.35
                    } else if next.fade < 0.65 {
                        next.fade = 0.70
                    } else {
                        next.fade = 0.0
                    }
                    viewModel.filmTuning = next
                }

                VintageOpticalAccessoryOrb(
                    title: "Hạt phim",
                    badgeText: grainActive ? "\(Int(round(viewModel.filmTuning.grain * 100)))%" : nil,
                    colors: [
                        Color(red: 0.26, green: 0.44, blue: 0.62),
                        Color(red: 0.12, green: 0.20, blue: 0.30),
                        Color(red: 0.07, green: 0.09, blue: 0.12)
                    ],
                    glintColor: Color(red: 0.65, green: 0.86, blue: 1.0),
                    iconName: "circle.dotted",
                    isActive: grainActive,
                    isPanelOpen: false
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    var next = viewModel.filmTuning
                    if next.grain < 0.05 {
                        next.grain = 0.40
                    } else if next.grain < 0.70 {
                        next.grain = 0.80
                    } else {
                        next.grain = 0.0
                    }
                    viewModel.filmTuning = next
                }

                VintageOpticalAccessoryOrb(
                    title: "Tinh chỉnh",
                    badgeText: nil,
                    colors: [
                        Color(red: 0.46, green: 0.26, blue: 0.64),
                        Color(red: 0.20, green: 0.12, blue: 0.30),
                        Color(red: 0.08, green: 0.08, blue: 0.11)
                    ],
                    glintColor: Color(red: 0.86, green: 0.68, blue: 1.0),
                    iconName: "slider.horizontal.3",
                    isActive: tuningActive,
                    isPanelOpen: activeSubPanel == .recipeTuning
                ) {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    activeSubPanel = (activeSubPanel == .recipeTuning) ? .none : .recipeTuning
                }
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: - 5. Precision Film Recipe Tuning Ruler Panel
    @ViewBuilder
    private var recipeTuningPanel: some View {
        let axes = FilmTuningAxis.allCases.filter { $0 != .intensity }
        let activeAxis = axes.contains(selectedAxis) ? selectedAxis : .contrast

        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(activeAxis.rawValue.uppercased())
                    .font(.system(size: 9.2, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.66))

                Text(activeAxis.displayValue(intensity: viewModel.filmSimulationIntensity, tuning: viewModel.filmTuning))
                    .font(.system(size: 10.2, weight: .bold, design: .monospaced))
                    .foregroundColor(AlignTheme.studioAccent)

                Spacer()

                if !viewModel.filmTuning.isIdentity {
                    Button(action: { viewModel.resetFilmTuning() }) {
                        Text("Đặt lại")
                            .font(.system(size: 9.2, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            ProPrecisionRulerDial(
                normalizedValue: activeAxis.normalizedValue(intensity: viewModel.filmSimulationIntensity, tuning: viewModel.filmTuning),
                tickCount: 31,
                majorEvery: 5,
                centerHighlight: activeAxis.isBipolar,
                onChanged: { newNorm in
                    activeAxis.applyNormalized(newNorm, to: viewModel)
                }
            )
            .frame(height: 26)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(axes) { axis in
                        let isSelected = (axis == activeAxis)
                        let isEdited = axis.isModified(
                            intensity: viewModel.filmSimulationIntensity,
                            tuning: viewModel.filmTuning,
                            isFilmActive: viewModel.isFilmSimulationActive
                        )
                        Button(action: {
                            HapticFeedbackService.shared.triggerSelectionChange()
                            selectedAxis = axis
                        }) {
                            HStack(spacing: 3) {
                                if isEdited {
                                    Circle()
                                        .fill(isSelected ? .black : AlignTheme.studioAccent)
                                        .frame(width: 4, height: 4)
                                }
                                Text(axis.rawValue)
                                    .font(.system(size: 9.4, weight: isSelected ? .bold : .medium, design: .rounded))
                            }
                            .foregroundColor(isSelected ? .black : Color.white.opacity(0.84))
                            .padding(.horizontal, 8.5)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white : Color.white.opacity(0.09))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                )
        )
        .padding(.horizontal, 10)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                if value.translation.height > 24 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        viewModel.isShowingFilmDrawer = false
                    }
                }
            }
    }
}

// MARK: - Live Glowing 35mm Quartz Date Stamp Overlay on 4:3 Viewfinder
public struct VintageDateStampViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let style = viewModel.effectiveVintageDateStampStyle
        if style.isEnabled {
            let text = style.formattedDate()
            Group {
                switch style {
                case .off:
                    EmptyView()
                case .classicQuartz:
                    Text(text)
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(Color(red: 1.00, green: 0.32, blue: 0.12))
                        .shadow(color: Color(red: 1.00, green: 0.14, blue: 0.02).opacity(0.92), radius: 4.5)
                        .shadow(color: Color(red: 1.00, green: 0.45, blue: 0.15).opacity(0.55), radius: 1.5)
                case .retroLED:
                    Text(text)
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(Color(red: 1.00, green: 0.46, blue: 0.12))
                        .shadow(color: Color(red: 1.00, green: 0.24, blue: 0.02).opacity(0.90), radius: 4.0)
                        .shadow(color: Color(red: 1.00, green: 0.68, blue: 0.22).opacity(0.50), radius: 1.2)
                case .compactSlanted:
                    Text(text)
                        .font(.system(size: 13.8, weight: .bold, design: .monospaced))
                        .italic()
                        .tracking(1.7)
                        .foregroundColor(Color(red: 1.00, green: 0.26, blue: 0.10))
                        .shadow(color: Color(red: 0.98, green: 0.10, blue: 0.02).opacity(0.95), radius: 5.0)
                        .shadow(color: Color(red: 1.00, green: 0.50, blue: 0.18).opacity(0.55), radius: 1.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
