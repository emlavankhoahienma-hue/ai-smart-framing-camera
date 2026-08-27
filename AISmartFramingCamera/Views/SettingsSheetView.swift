import SwiftUI

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - AI Framing Engine
                Section(header: Text("Trí tuệ nhân tạo (AI Framing Engine)")) {
                    Picker("Quy tắc bố cục chính", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }
                            .tag(rule)
                        }
                    }
                    
                    Toggle("Tự động cân chỉnh Zoom (Auto-Zoom)", isOn: $viewModel.isAutoZoomEnabled)
                    
                    Toggle("Tự động chọn màu theo bối cảnh (Auto-Color)", isOn: $viewModel.isAutoColorTuningEnabled)
                    
                    Toggle("Hỗ trợ không gian AR (ARKit 3D Alignment)", isOn: $viewModel.isARModeEnabled)
                }
                
                // MARK: - Neural Engine & Performance
                Section(header: Text("Phần cứng & Hiệu năng")) {
                    HStack {
                        Label("Bộ xử lý Neural Engine", systemImage: "cpu")
                        Spacer()
                        Text("A11 - A18 Bionic / Pro")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Label("Độ trễ AI Real-time", systemImage: "speedometer")
                        Spacer()
                        Text("< 12 ms / frame")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    
                    HStack {
                        Label("Khung hình Vision Pipeline", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text("30 FPS Throttled")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                
                // MARK: - App Information
                Section(header: Text("Thông tin ứng dụng")) {
                    HStack {
                        Text("Phiên bản")
                        Spacer()
                        Text("1.0.0 (CI/CD Build)")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("Công nghệ cốt lõi")
                        Spacer()
                        Text("SwiftUI • Vision • CoreImage • ARKit")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationBarTitle("Cài đặt AI Camera", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.yellow)
            )
        }
    }
}
