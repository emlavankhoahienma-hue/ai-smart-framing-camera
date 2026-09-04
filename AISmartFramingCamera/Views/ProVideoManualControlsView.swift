import SwiftUI

public struct ProVideoManualControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var proService = ProVideoManualControlsService.shared
    
    @State private var isCollapsed: Bool = false
    private let haptic = UISelectionFeedbackGenerator()
    
    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - Floating Pro Top Tabs
            HStack(spacing: 6) {
                // ISO Tab
                proTabButton(
                    tab: .iso,
                    title: "ISO",
                    valueString: proService.isAutoISO ? "AUTO (\(Int(proService.measuredLiveISO)))" : "\(Int(proService.currentISO))",
                    isAuto: proService.isAutoISO
                )
                
                // Shutter Tab
                proTabButton(
                    tab: .shutter,
                    title: "SEC",
                    valueString: proService.isAutoShutter ? "AUTO" : "1/\(Int(proService.currentShutterSpeed))s",
                    isAuto: proService.isAutoShutter
                )
                
                // Aperture / EV Tab
                proTabButton(
                    tab: .aperture,
                    title: "f/\(String(format: "%.1f", proService.hardwareLensAperture))",
                    valueString: proService.isAutoEV ? "0.0 EV" : String(format: "%+.1f EV", proService.currentEVBias),
                    isAuto: proService.isAutoEV
                )
                
                // WB Tab
                proTabButton(
                    tab: .wb,
                    title: "WB",
                    valueString: proService.isAutoWB ? "AWB" : "\(Int(proService.currentKelvin))K",
                    isAuto: proService.isAutoWB
                )
                
                // Collapse / Expand Toggle Button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                    haptic.selectionChanged()
                }) {
                    Image(systemName: isCollapsed ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            
            // MARK: - Expandable Adjustment Drawer Panel
            if !isCollapsed {
                VStack(spacing: 10) {
                    switch viewModel.selectedProTab {
                    case .iso:
                        isoControlPanel
                    case .shutter:
                        shutterControlPanel
                    case .aperture:
                        apertureEVControlPanel
                    case .wb:
                        whiteBalanceControlPanel
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black.opacity(0.82))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
                        )
                )
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .onAppear {
            proService.syncHardwareCapabilities()
        }
    }
    
    // MARK: - Tab Selector Pill
    private func proTabButton(tab: ProVideoParameterTab, title: String, valueString: String, isAuto: Bool) -> some View {
        let isSelected = viewModel.selectedProTab == tab
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.selectedProTab = tab
                if isCollapsed { isCollapsed = false }
            }
            haptic.selectionChanged()
        }) {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    if isAuto {
                        Text("A")
                            .font(.system(size: 7.5, weight: .heavy))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.3))
                            .cornerRadius(3)
                            .foregroundColor(.cyan)
                    }
                }
                Text(valueString)
                    .font(.system(size: 11, weight: isSelected ? .heavy : .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .yellow : .white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.yellow.opacity(0.18) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.yellow.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
    }
    
    // MARK: - 1. ISO Panel
    private var isoControlPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ĐỘ NHẠY SÁNG ISO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                // AUTO Button
                Button(action: {
                    proService.setAutoISO(!proService.isAutoISO)
                    haptic.selectionChanged()
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proService.isAutoISO ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(proService.isAutoISO ? "AUTO: BẬT" : "AUTO: TẮT")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(proService.isAutoISO ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(proService.isAutoISO ? .green : .white)
                }
            }
            
            // Quick Presets
            let presets: [Float] = [50, 100, 200, 400, 800, 1600, 3200]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        let isCur = !proService.isAutoISO && abs(proService.currentISO - preset) < 10
                        Button(action: {
                            proService.setManualISO(preset)
                            haptic.selectionChanged()
                        }) {
                            Text("\(Int(preset))")
                                .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                                .foregroundColor(isCur ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isCur ? Color.yellow : Color.white.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            
            // Slider
            HStack(spacing: 12) {
                Text("\(Int(proService.minISO))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                
                Slider(
                    value: Binding(
                        get: { Double(proService.currentISO) },
                        set: {
                            proService.setManualISO(Float($0))
                            haptic.selectionChanged()
                        }
                    ),
                    in: Double(proService.minISO)...Double(proService.maxISO),
                    step: 25.0
                )
                .accentColor(.yellow)
                
                Text("\(Int(proService.maxISO))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - 2. Shutter Speed Panel
    private var shutterControlPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("TỐC ĐỘ MÀN TRẬP (SHUTTER)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Button(action: {
                    proService.setAutoShutter(!proService.isAutoShutter)
                    haptic.selectionChanged()
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proService.isAutoShutter ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(proService.isAutoShutter ? "AUTO: BẬT" : "AUTO: TẮT")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(proService.isAutoShutter ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(proService.isAutoShutter ? .green : .white)
                }
            }
            
            // Cine Shutter Speed Presets (180 deg cinema rule)
            let shutterPresets: [(label: String, val: Double)] = [
                ("1/24", 24),
                ("1/48 (180°)", 48),
                ("1/50", 50),
                ("1/60", 60),
                ("1/120", 120),
                ("1/240", 240),
                ("1/500", 500),
                ("1/1000", 1000)
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(shutterPresets, id: \.val) { preset in
                        let isCur = !proService.isAutoShutter && abs(proService.currentShutterSpeed - preset.val) < 2
                        Button(action: {
                            proService.setManualShutterSpeed(preset.val)
                            haptic.selectionChanged()
                        }) {
                            Text(preset.label)
                                .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                                .foregroundColor(isCur ? .black : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isCur ? Color.yellow : Color.white.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            
            // Slider
            HStack(spacing: 12) {
                Text("1/\(Int(proService.minShutterSpeed))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                
                Slider(
                    value: Binding(
                        get: { proService.currentShutterSpeed },
                        set: {
                            proService.setManualShutterSpeed($0)
                            haptic.selectionChanged()
                        }
                    ),
                    in: proService.minShutterSpeed...min(2000.0, proService.maxShutterSpeed),
                    step: 10.0
                )
                .accentColor(.yellow)
                
                Text("1/2000")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - 3. Aperture & EV Panel
    private var apertureEVControlPanel: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KHẨU ĐỘ VẬT LÝ:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text("f/\(String(format: "%.1f", proService.hardwareLensAperture)) (Cố định quang học)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                
                Spacer()
                
                // Auto / Reset EV Button
                Button(action: {
                    proService.setAutoEV(true)
                    haptic.selectionChanged()
                }) {
                    Text("RESET 0.0 EV")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(proService.currentEVBias == 0 ? Color.green.opacity(0.2) : Color.white.opacity(0.12))
                        .cornerRadius(8)
                        .foregroundColor(proService.currentEVBias == 0 ? .green : .white)
                }
            }
            
            // EV Presets
            let evPresets: [Float] = [-1.5, -1.0, -0.5, 0.0, +0.5, +1.0, +1.5]
            HStack(spacing: 8) {
                ForEach(evPresets, id: \.self) { ev in
                    let isCur = abs(proService.currentEVBias - ev) < 0.08
                    Button(action: {
                        proService.setManualEVBias(ev)
                        haptic.selectionChanged()
                    }) {
                        Text(String(format: "%+.1f", ev))
                            .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                            .foregroundColor(isCur ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(isCur ? Color.yellow : Color.white.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }
            
            // Slider
            HStack(spacing: 12) {
                Text("-2.0 EV")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                
                Slider(
                    value: Binding(
                        get: { Double(proService.currentEVBias) },
                        set: {
                            proService.setManualEVBias(Float($0))
                            haptic.selectionChanged()
                        }
                    ),
                    in: -2.0...2.0,
                    step: 0.1
                )
                .accentColor(.yellow)
                
                Text("+2.0 EV")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - 4. White Balance Panel
    private var whiteBalanceControlPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("CÂN BẰNG TRẮNG (WHITE BALANCE)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Button(action: {
                    proService.setAutoWB(!proService.isAutoWB)
                    haptic.selectionChanged()
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(proService.isAutoWB ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(proService.isAutoWB ? "AWB: BẬT" : "AWB: TẮT")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(proService.isAutoWB ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(proService.isAutoWB ? .green : .white)
                }
            }
            
            // WB Scene Presets
            let wbPresets: [(name: String, kelvin: Float)] = [
                ("3200K Vàng", 3200),
                ("4300K Huỳnh quang", 4300),
                ("5600K Ban ngày", 5600),
                ("6500K Mây", 6500),
                ("7500K Râm", 7500)
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(wbPresets, id: \.kelvin) { preset in
                        let isCur = !proService.isAutoWB && abs(proService.currentKelvin - preset.kelvin) < 100
                        Button(action: {
                            proService.setManualWhiteBalance(kelvin: preset.kelvin, tint: proService.currentTint)
                            haptic.selectionChanged()
                        }) {
                            Text(preset.name)
                                .font(.system(size: 10.5, weight: isCur ? .heavy : .medium))
                                .foregroundColor(isCur ? .black : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isCur ? Color.yellow : Color.white.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            
            // Kelvin Slider with warm-to-cool visual
            HStack(spacing: 12) {
                Text("2500K")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange)
                
                Slider(
                    value: Binding(
                        get: { Double(proService.currentKelvin) },
                        set: {
                            proService.setManualWhiteBalance(kelvin: Float($0), tint: proService.currentTint)
                            haptic.selectionChanged()
                        }
                    ),
                    in: 2500...9000,
                    step: 50.0
                )
                .accentColor(.cyan)
                
                Text("9000K")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            
            // Tint Adjustment Row
            HStack(spacing: 10) {
                Text("TINT:")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                Text("-30 G")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green)
                
                Slider(
                    value: Binding(
                        get: { Double(proService.currentTint) },
                        set: {
                            proService.setManualWhiteBalance(kelvin: proService.currentKelvin, tint: Float($0))
                            haptic.selectionChanged()
                        }
                    ),
                    in: -30...30,
                    step: 1.0
                )
                .accentColor(.purple)
                
                Text("+30 M")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.purple)
            }
        }
    }
}
