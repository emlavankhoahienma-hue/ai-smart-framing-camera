import SwiftUI

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode
    
    @State private var geminiKeyInput: String = ""
    @State private var showKeyInput: Bool = false
    @State private var keySaved: Bool = false
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - Gemini API
                Section(header: Text("🤖 Gemini AI API")) {
                    HStack {
                        Label("Trạng thái API Key", systemImage: "key.fill")
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Đã kết nối").foregroundColor(.green).font(.subheadline)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("Chưa cài").foregroundColor(.red).font(.subheadline)
                            }
                        }
                    }
                    
                    Button(action: { showKeyInput.toggle() }) {
                        HStack {
                            Image(systemName: "pencil.and.outline")
                            Text(viewModel.geminiService.hasAPIKey ? "Thay đổi API Key" : "Nhập Gemini API Key")
                        }
                        .foregroundColor(.cyan)
                    }
                    
                    if showKeyInput {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lấy API key miễn phí tại: aistudio.google.com")
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            SecureField("AIzaSy...", text: $geminiKeyInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.system(size: 13, design: .monospaced))
                            
                            Button(action: {
                                let key = geminiKeyInput.trimmingCharacters(in: .whitespaces)
                                if !key.isEmpty {
                                    viewModel.geminiService.apiKey = key
                                    geminiKeyInput = ""
                                    showKeyInput = false
                                    keySaved = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        keySaved = false
                                    }
                                }
                            }) {
                                Text(keySaved ? "✓ Đã lưu!" : "Lưu API Key")
                                    .frame(maxWidth: .infinity)
                                    .foregroundColor(.black)
                                    .padding(.vertical, 8)
                                    .background(keySaved ? Color.green : Color.cyan)
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Toggle("Dùng Gemini AI khi bấm nút AI", isOn: $viewModel.useGeminiForAnalysis)
                    
                    if !viewModel.geminiService.hasAPIKey && viewModel.useGeminiForAnalysis {
                        Text("⚠️ Thiếu API Key — AI sẽ dùng Vision cục bộ làm fallback")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                // MARK: - AI Framing Engine
                Section(header: Text("🎯 AI Framing Engine")) {
                    Picker("Quy tắc bố cục", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }
                    
                    Toggle("Auto-Zoom theo AI", isOn: $viewModel.isAutoZoomEnabled)
                    Toggle("AI Full Color — AI toàn quyền màu sắc", isOn: $viewModel.isAIFullColorEnabled)
                    Toggle("ARKit Spatial Mode", isOn: $viewModel.isARModeEnabled)
                }
                
                // MARK: - Color Info (Gemini recipe preview)
                if let recipe = viewModel.geminiColorRecipe {
                    Section(header: Text("🎨 Gemini Color Recipe")) {
                        colorRow("Nhiệt độ màu", value: "\(Int(recipe.temperatureK)) K", color: recipe.temperatureK < 5000 ? .orange : .cyan)
                        colorRow("Saturation", value: String(format: "×%.2f", recipe.saturation), color: .yellow)
                        colorRow("Contrast", value: String(format: "×%.2f", recipe.contrast), color: .white)
                        colorRow("Shadow Lift", value: String(format: "%.2f", recipe.shadowLift), color: .gray)
                        colorRow("Highlight Roll", value: String(format: "%.2f", recipe.highlightRoll), color: .white)
                        colorRow("Film Grain", value: String(format: "%.2f", recipe.grain), color: .gray)
                        colorRow("Vignette", value: String(format: "%.2f", recipe.vignette), color: .black)
                        colorRow("Color Grade", value: recipe.colorGrade.rawValue, color: .purple)
                    }
                }
                
                // MARK: - Neural Engine & Performance
                Section(header: Text("⚡ Phần cứng & Hiệu năng")) {
                    hardwareRow("Neural Engine", "A11 – A18 Bionic / Pro")
                    hardwareRow("Độ trễ AI Real-time", "< 12 ms/frame", color: .green)
                    hardwareRow("Vision Pipeline", "20 FPS throttled")
                    hardwareRow("Gemini Model", "gemini-2.0-flash-exp")
                }
                
                // MARK: - App Info
                Section(header: Text("ℹ️ Thông tin ứng dụng")) {
                    HStack { Text("Phiên bản"); Spacer(); Text("2.0.0 (build.7+)").foregroundColor(.gray) }
                    HStack { Text("Công nghệ"); Spacer()
                        Text("SwiftUI · Vision · CoreImage · ARKit · Gemini").font(.caption).foregroundColor(.gray)
                    }
                }
            }
            .navigationBarTitle("Cài đặt AI Camera", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") { presentationMode.wrappedValue.dismiss() }.foregroundColor(.yellow)
            )
        }
    }
    
    private func colorRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundColor(color)
        }
    }
    
    private func hardwareRow(_ label: String, _ value: String, color: Color = .gray) -> some View {
        HStack {
            Label(label, systemImage: "cpu")
            Spacer()
            Text(value).font(.subheadline).foregroundColor(color)
        }
    }
}
