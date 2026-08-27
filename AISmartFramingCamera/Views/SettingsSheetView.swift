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
    @State private var isCopiedDevInfo: Bool = false
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - Developer Information (VanKhoa)
                Section(header: Text("👨‍💻 THÔNG TIN DEVELOPER")) {
                    HStack {
                        Label("Tên Dev", systemImage: "person.crop.circle.fill")
                        Spacer()
                        Text("VanKhoa")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    
                    HStack {
                        Label("Developer", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Text("VanKhoa")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    
                    HStack {
                        Label("Mail", systemImage: "envelope.fill")
                        Spacer()
                        Text("tranvantrinhhd@gmail.com")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    
                    HStack {
                        Label("Contacs", systemImage: "phone.fill")
                        Spacer()
                        Text("+84 344197212")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                
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
                    
                    if showKeyInput {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Google AI Studio Key:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Link("Lấy Key miễn phí ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                            
                            // Input Box with Show/Hide Toggle & Clear Button
                            HStack(spacing: 8) {
                                if isKeyVisible {
                                    TextField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.system(size: 13, design: .monospaced))
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                } else {
                                    SecureField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.system(size: 13, design: .monospaced))
                                }
                                
                                if !geminiKeyInput.isEmpty {
                                    Button(action: { geminiKeyInput = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                            .font(.system(size: 14))
                                    }
                                }
                                
                                Button(action: { isKeyVisible.toggle() }) {
                                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 14))
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            
                            // Buttons Row: Direct Pasteboard Paste + Save
                            HStack(spacing: 10) {
                                Button(action: {
                                    if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                        geminiKeyInput = clip
                                        viewModel.geminiService.apiKey = clip
                                        keySavedMessage = "✅ Đã dán và lưu Key từ Clipboard!"
                                        testResult = nil
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { keySavedMessage = nil }
                                    } else {
                                        keySavedMessage = "⚠️ Clipboard đang trống"
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.clipboard.fill")
                                        Text("Dán từ Clipboard")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.blue.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                                
                                Button(action: {
                                    let cleaned = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    viewModel.geminiService.apiKey = cleaned
                                    keySavedMessage = cleaned.isEmpty ? "Đã xóa API Key" : "✅ Đã lưu API Key thành công!"
                                    testResult = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { keySavedMessage = nil }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Lưu Key")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.green)
                                    .foregroundColor(.black)
                                    .cornerRadius(8)
                                }
                            }
                            
                            // Test Connection Button
                            Button(action: {
                                isTestingKey = true
                                testResult = nil
                                viewModel.geminiService.testAPIKey { success, message in
                                    isTestingKey = false
                                    testResult = message
                                }
                            }) {
                                HStack {
                                    if isTestingKey {
                                        ProgressView().scaleEffect(0.8).padding(.trailing, 4)
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                    }
                                    Text(isTestingKey ? "Đang kiểm tra kết nối..." : "Kiểm tra kết nối API Key")
                                }
                                .font(.subheadline.bold())
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
                
                // MARK: - AI Framing & Zoom
                Section(header: Text("🎯 Quy tắc & Bố cục AI")) {
                    Picker("Quy tắc bố cục", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }
                    
                    Toggle("Tự động Zoom theo AI (Auto-Zoom)", isOn: $viewModel.isAutoZoomEnabled)
                    Toggle("AI Full Color — Màu Leica Natural 100%", isOn: $viewModel.isAIFullColorEnabled)
                    Toggle("Không gian 3D ARKit", isOn: $viewModel.isARModeEnabled)
                }
                
                // MARK: - Developer Error & Performance Console
                Section(header: Text("🛠 NHẬT KÝ LỖI & DEV CONSOLE")) {
                    HStack {
                        Label("Trạng thái lỗi", systemImage: "exclamationmark.bubble.fill")
                        Spacer()
                        Text(viewModel.geminiError ?? "Không có lỗi (Healthy)")
                            .font(.caption.monospaced())
                            .foregroundColor(viewModel.geminiError != nil ? .red : .green)
                    }
                    
                    if viewModel.geminiLatencyMs > 0 {
                        HStack {
                            Label("Độ trễ AI phản hồi", systemImage: "timer")
                            Spacer()
                            Text("\(viewModel.geminiLatencyMs) ms")
                                .font(.caption.monospaced())
                                .foregroundColor(.cyan)
                        }
                    }
                    
                    if !viewModel.activeModelUsedName.isEmpty {
                        HStack {
                            Label("Model đang active", systemImage: "cpu.fill")
                            Spacer()
                            Text(viewModel.activeModelUsedName)
                                .font(.caption.monospaced())
                                .foregroundColor(.yellow)
                        }
                    }
                }
                
                // MARK: - Hardware & Engine Specs
                Section(header: Text("⚡ Phần cứng & Kiến trúc tích hợp")) {
                    hardwareRow("Hybrid AI Engine", "Google Gemini + Apple Neural Engine", color: .yellow)
                    hardwareRow("Xử lý màu đồ họa", "Metal GPU (32-bit Floating Point)", color: .cyan)
                    hardwareRow("Tracking thị giác", "Vision Optical Flow (60 FPS)", color: .green)
                    hardwareRow("Tối ưu Neural Engine", "A11 đến A18 Pro Bionic")
                }
                
                // MARK: - App Info
                Section(header: Text("ℹ️ Thông tin ứng dụng")) {
                    HStack { Text("Ứng dụng"); Spacer(); Text("VanKhoa AI Camera").font(.subheadline.bold()).foregroundColor(.white) }
                    HStack { Text("Phiên bản"); Spacer(); Text("2.5.0 Pro Studio").foregroundColor(.gray) }
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
    
    private func hardwareRow(_ label: String, _ value: String, color: Color = .gray) -> some View {
        HStack {
            Label(label, systemImage: "cpu")
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(color)
        }
    }
}
