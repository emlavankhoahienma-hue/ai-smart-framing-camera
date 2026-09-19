import SwiftUI

public struct ProVideoManualControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var proService = ProVideoManualControlsService.shared
    public init(viewModel: CameraViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(spacing: 0) {
            CameraDrawerHeader(title: "Điều khiển Pro") { viewModel.isShowingProControlsDrawer = false }
                .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ProVideoParameterTab.allCases) { tab in
                                Button { viewModel.selectedProTab = tab } label: {
                                    Text(title(tab)).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).frame(height: 44)
                                        .foregroundColor(viewModel.selectedProTab == tab ? .black : .white)
                                        .background(viewModel.selectedProTab == tab ? CameraUI.accent : .white.opacity(0.08), in: Capsule())
                                }.buttonStyle(CameraPressStyle())
                                .accessibilityAddTraits(viewModel.selectedProTab == tab ? .isSelected : [])
                            }
                        }
                    }
                    parameterPanel
                    Divider()
                    Toggle("Tô viền vùng nét", isOn: $viewModel.isFocusPeakingEnabled).font(.subheadline)
                    Button("Khôi phục tự động") { proService.resetToFullAuto() }.frame(minHeight: 44)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .modifier(CameraGlass()).tint(CameraUI.accent).foregroundColor(.white)
        .onAppear { proService.syncHardwareCapabilities() }
    }

    @ViewBuilder private var parameterPanel: some View {
        switch viewModel.selectedProTab {
        case .iso:
            parameterHeader("Độ nhạy sáng", value: String(format: "%.0f", proService.currentISO), auto: proService.isAutoISO) {
                proService.setAutoISO(!proService.isAutoISO)
            }
            ProParameterSlider(title: "ISO", value: Binding(get: { Double(proService.currentISO) }, set: { proService.setManualISO(Float($0)) }),
                               bounds: Double(proService.minISO)...max(Double(proService.minISO), Double(proService.maxISO)))
            presets([100, 200, 400, 800, 1600], bounds: Double(proService.minISO)...max(Double(proService.minISO), Double(proService.maxISO))) {
                proService.setManualISO(Float($0))
            }
        case .shutter:
            parameterHeader("Tốc độ màn trập", value: "1/\(Int(proService.currentShutterSpeed)) s", auto: proService.isAutoShutter) {
                proService.setAutoShutter(!proService.isAutoShutter)
            }
            ProParameterSlider(title: "Mẫu số tốc độ màn trập", value: Binding(get: { proService.currentShutterSpeed }, set: { proService.setManualShutterSpeed($0) }),
                               bounds: shutterBounds)
            presets([24, 48, 60, 120, 240, 500], bounds: shutterBounds, prefix: "1/") { proService.setManualShutterSpeed($0) }
        case .aperture:
            parameterHeader("Bù phơi sáng", value: String(format: "%+.1f EV", proService.currentEVBias), auto: proService.isAutoEV) {
                proService.setAutoEV(true)
            }
            ProParameterSlider(title: "Bù sáng EV", value: Binding(get: { Double(proService.currentEVBias) }, set: { proService.setManualEVBias(Float($0)) }), bounds: -2...2)
            Text(String(format: "Khẩu độ ống kính cố định: f/%.1f", proService.hardwareLensAperture))
                .font(.caption).foregroundColor(.secondary)
        case .wb:
            parameterHeader("Cân bằng trắng", value: "\(Int(proService.currentKelvin)) K", auto: proService.isAutoWB) {
                proService.setAutoWB(!proService.isAutoWB)
            }
            ProParameterSlider(title: "Nhiệt độ màu", value: Binding(get: { Double(proService.currentKelvin) }, set: {
                proService.setManualWhiteBalance(kelvin: Float($0), tint: proService.currentTint)
            }), bounds: 2500...9000)
            ProParameterSlider(title: "Sắc xanh / hồng", value: Binding(get: { Double(proService.currentTint) }, set: {
                proService.setManualWhiteBalance(kelvin: proService.currentKelvin, tint: Float($0))
            }), bounds: -30...30)
            presets([3200, 4300, 5600, 6500], bounds: 2500...9000, suffix: "K") {
                proService.setManualWhiteBalance(kelvin: Float($0), tint: proService.currentTint)
            }
        case .focus:
            parameterHeader("Lấy nét", value: proService.isAutoFocus ? "AF" : "MF", auto: proService.isAutoFocus) {
                proService.setAutoFocus(!proService.isAutoFocus)
                if !proService.isAutoFocus { viewModel.isFocusPeakingEnabled = true }
            }.disabled(!proService.isManualFocusSupported)
            ProParameterSlider(title: "Gần → Vô cực", value: Binding(get: { Double(proService.currentLensPosition) }, set: {
                proService.setManualFocus(Float($0)); viewModel.isFocusPeakingEnabled = true
            }), bounds: 0...1).disabled(!proService.isManualFocusSupported)
            Text(proService.isManualFocusSupported ? "Chạm khung ngắm để trở lại lấy nét tự động." : "Camera này không hỗ trợ lấy nét tay.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
    private var shutterBounds: ClosedRange<Double> {
        let lower = max(1, proService.minShutterSpeed)
        return lower...max(lower, min(2000, proService.maxShutterSpeed))
    }
    private func title(_ tab: ProVideoParameterTab) -> String {
        switch tab { case .iso: return "ISO"; case .shutter: return "Tốc độ"; case .aperture: return "EV"; case .wb: return "WB"; case .focus: return "Nét" }
    }
    private func parameterHeader(_ title: String, value: String, auto: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.title3.weight(.medium).monospacedDigit())
            }
            Spacer()
            Button(auto ? "Tự động" : "Chỉnh tay", action: action).buttonStyle(.bordered).frame(minHeight: 44)
        }
    }
    private func presets(_ values: [Double], bounds: ClosedRange<Double>, prefix: String = "", suffix: String = "", action: @escaping (Double) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values.filter { bounds.contains($0) }, id: \.self) { value in
                    Button("\(prefix)\(Int(value))\(suffix)") { action(value) }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct ProParameterSlider: View {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    private var safeBounds: ClosedRange<Double> { bounds.lowerBound...max(bounds.lowerBound + 0.001, bounds.upperBound) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Slider(value: Binding(get: { min(safeBounds.upperBound, max(safeBounds.lowerBound, value)) }, set: { value = $0 }), in: safeBounds)
                .disabled(bounds.lowerBound >= bounds.upperBound).accessibilityLabel(title)
        }
    }
}
