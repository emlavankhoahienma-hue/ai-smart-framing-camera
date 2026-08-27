import SwiftUI
import UIKit

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode
    
    @State private var geminiKeyInput: String = ""
    @State private var showKeyInput: Bool = false
    @State private var isKeyVisible: Bool = true
    @State private var keySavedMessage: String? = nil
    @State private var selectedModel: AIVisionModel = .autoStrongest
    @State private var customModelInput: String = ""
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - Gemini AI Vision Configuration
                Section(header: Text("🤖 Cấu hình AI Vision đa mô hình")) {
                    // Connection Status
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
                    
                    // Model Selection
                    Picker("Mô hình AI Vision", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }
                    
                    // Custom Model Name Override
                    HStack {
                        Label("Model ID chỉ định:", systemImage: "cpu")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        TextField("Mặc định (Auto)", text: $customModelInput)
                            .font(.system(size: 12, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: customModelInput) { newVal in
                                viewModel.geminiService.customModelName = newVal
                            }
                    }
                    
                    // Toggle Open Key Box
                    Button(action: {
                        if !showKeyInput {
                            geminiKeyInput = viewModel.geminiService.apiKey
                        }
                        showKeyInput.toggle()
                    }) {
                        HStack {
                            Image(systemName: showKeyInput ? "chevron.up" : "pencil.and.outline")
                            Text(viewModel.geminiService.hasAPIKey ? "Chỉnh sửa / Dán lại API Key" : "Nhập / Dán Gemini API Key")
                        }
                        .foregroundColor(.cyan)
                    }
                    
                    // Key Input Deck
                    if showKeyInput {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Google AI Studio Key:")
                                    .font(.caption.bold())
                                    .foregroundColor(.gray)
                                Spacer()
                                Link("Lấy Key miễn phí ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                    .font(.caption)
                                    .foregroundColor(.cyan)
                            }
                            
                            // Text Input with Eye Toggle & Clear
                            HStack {
                                if isKeyVisible {
                                    TextField("Dán API Key (AIzaSy...)", text: $geminiKeyInput)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .font(.system(size: 13, design: .monospaced))
                                } else {
                                    SecureField("AIzaSy...", text: $geminiKeyInput)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .font(.system(size: 13, design: .monospaced))
                                }
                                
                                if !geminiKeyInput.isEmpty {
                                    Button(action: { geminiKeyInput = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                }
                                
                                Button(action: { isKeyVisible.toggle() }) {
                                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            
                            // Action Buttons: Paste from Clipboard + Save
                            HStack(spacing: 10) {
                                // Paste button (Reads UIPasteboard directly)
                                Button(action: {
                                    if let clipboardText = UIPasteboard.general.string {
                                        let cleaned = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        geminiKeyInput = cleaned
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.clipboard")
                                        Text("Dán từ Clipboard")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                                }
                                
                                // Save button
                                Button(action: {
                                    let key = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !key.isEmpty {
                                        viewModel.geminiService.apiKey = key
                                        keySavedMessage = "✓ Đã lưu thành công!"
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            keySavedMessage = nil
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Lưu Key")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                            }
                            
                            // Test Connection Button
                            Button(action: {
                                let key = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !key.isEmpty {
                                    viewModel.geminiService.apiKey = key
                                }
                                isTestingKey = true
                                testResult = "Đang kiểm tra kết nối với Google AI Studio..."
                                viewModel.geminiService.testAPIKey { success, message in
                                    isTestingKey = false
                                    testResult = message
                                }
                            }) {
                                HStack(spacing: 6) {
                                    if isTestingKey {
                                        ProgressView().scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                    }
                                    Text("Kiểm tra kết nối API Key")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(0.15))
                                .foregroundColor(.purple)
                                .cornerRadius(8)
                            }
                            
                            if let result = testResult {
                                Text(result)
                                    .font(.caption.bold())
                                    .foregroundColor(result.contains("✅") ? .green : .red)
                                    .padding(.top, 2)
                            }
                            
                            if let msg = keySavedMessage {
                                Text(msg)
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Toggle("Bật AI Vision khi bấm nút AI", isOn: $viewModel.useGeminiForAnalysis)
                    
                    if !viewModel.geminiService.hasAPIKey && viewModel.useGeminiForAnalysis {
                        Text("⚠️ Chưa có API Key — Camera sẽ dùng Vision cục bộ trên chip Neural Engine làm fallback")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                // MARK: - AI Framing Engine
                Section(header: Text("🎯 Quy tắc & Bố cục AI")) {
                    Picker("Quy tắc bố cục", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }
                    
                    Toggle("Tự động Zoom theo AI", isOn: $viewModel.isAutoZoomEnabled)
                    Toggle("AI Full Color — Tự động chỉnh màu 100%", isOn: $viewModel.isAIFullColorEnabled)
                    Toggle("Không gian 3D ARKit", isOn: $viewModel.isARModeEnabled)
                }
                
                // MARK: - Color Info (Gemini recipe preview)
                if let recipe = viewModel.geminiColorRecipe {
                    Section(header: Text("🎨 Công thức màu từ AI")) {
                        colorRow("Nhiệt độ màu", value: "\(Int(recipe.temperatureK)) K", color: recipe.temperatureK < 5000 ? .orange : .cyan)
                        colorRow("Độ bão hòa (Saturation)", value: String(format: "×%.2f", recipe.saturation), color: .yellow)
                        colorRow("Độ tương phản (Contrast)", value: String(format: "×%.2f", recipe.contrast), color: .white)
                        colorRow("Nâng vùng tối (Shadow Lift)", value: String(format: "%.2f", recipe.shadowLift), color: .gray)
                        colorRow("Làm dịu vùng sáng (Highlight Roll)", value: String(format: "%.2f", recipe.highlightRoll), color: .white)
                        colorRow("Hạt phim 35mm (Film Grain)", value: String(format: "%.2f", recipe.grain), color: .gray)
                        colorRow("Tối góc (Vignette)", value: String(format: "%.2f", recipe.vignette), color: .black)
                        colorRow("Bảng màu (Grade)", value: recipe.colorGrade.rawValue, color: .purple)
                    }
                }
                
                // MARK: - Neural Engine & Performance
                Section(header: Text("⚡ Phần cứng & Model")) {
                    hardwareRow("Model hiện tại", selectedModel.displayName)
                    hardwareRow("Cơ chế Fallback", "Tự động đổi model khi lỗi", color: .cyan)
                    hardwareRow("Neural Engine", "A11 – A18 Bionic / Pro")
                    hardwareRow("Độ trễ AI", "< 12 ms/frame (Vision)", color: .green)
                }
                
                // MARK: - App Info
                Section(header: Text("ℹ️ Thông tin ứng dụng")) {
                    HStack { Text("Phiên bản"); Spacer(); Text("2.1.0 Pro").foregroundColor(.gray) }
                    HStack { Text("Kiến trúc"); Spacer()
                        Text("SwiftUI · Vision · CoreImage · ARKit · Gemini Pro").font(.caption).foregroundColor(.gray)
                    }
                }
            }
            .navigationBarTitle("Cài đặt AI Camera", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") { presentationMode.wrappedValue.dismiss() }.foregroundColor(.yellow)
            )
            .onAppear {
                selectedModel = viewModel.geminiService.selectedModel
                customModelInput = viewModel.geminiService.customModelName
            }
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
